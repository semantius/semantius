-- =====================================================
-- PUBLIC FUNCTIONS
-- =====================================================
-- User-facing functions in the public schema
-- These provide convenient access to RBAC and user information
-- =====================================================

-- =====================================================
-- GET USER MODULES (Helper function)
-- =====================================================

-- Get modules the current user has permission to view
-- This function manually filters modules by permission since it may be
-- called from a SECURITY DEFINER context where RLS is bypassed
-- Used internally by get_userinfo()
CREATE OR REPLACE FUNCTION public.get_user_modules()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE(
        (SELECT jsonb_agg(
            jsonb_build_object(
                'id', m.id,
                'module_name', m.module_name,
                'description', m.description,
                'view_permission', m.view_permission,
                'logo_url', m.logo_url,
                'logo_color', m.logo_color,
                'home_page', m.home_page,
                'alias', m.alias,
                'created_at', m.created_at,
                'updated_at', m.updated_at
            ) ORDER BY m.module_name
        )
        FROM modules m
        WHERE rbac.has_any_permission('admin', m.view_permission)),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.get_user_modules IS 
'Returns modules array filtered by RLS. Used internally by get_userinfo().';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_user_modules() TO semantius_user;

-- =====================================================
-- GET USER INFO
-- =====================================================

-- Get current authenticated user's information
-- Returns the user record from the users table for the current JWT as JSON
-- IMPORTANT: This function creates/updates the user record and updates last_seen
-- Clients should call this function when they detect a new login to initialize the user
CREATE OR REPLACE FUNCTION public.get_userinfo()
RETURNS JSONB AS $$
DECLARE
    v_external_id TEXT;
    v_email TEXT;
    v_user_id INTEGER;
    v_result JSONB;
    v_roles JSONB;
    v_permissions JSONB;
    v_modules JSONB;
BEGIN
    -- Get current user from JWT
    v_external_id := rbac.uid();
    
    -- Get email from JWT if available
    v_email := current_setting('request.jwt.claim.email', true);
    
    -- Create or update user record and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(v_external_id, v_email);
    
    -- Verify user was created/found successfully
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create or find user: external_id = %', v_external_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    -- Verify user exists in users table
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User not found in users table: user_id = %', v_user_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    -- Build roles array with role details
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'role_id', r.id,
            'role_name', r.role_name,
            'description', r.description,
            'module_id', r.module_id,
            'assigned_at', ur.assigned_at
        ) ORDER BY r.role_name
    ), '[]'::jsonb)
    INTO v_roles
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = v_user_id;
    
    -- Build permissions array (all effective permissions including inherited)
    SELECT COALESCE(jsonb_agg(
        permission_name ORDER BY permission_name
    ), '[]'::jsonb)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Build modules array (filtered by permissions via helper function)
    v_modules := public.get_user_modules();
    
    -- Build the final JSON result
    SELECT jsonb_build_object(
        'user_id', u.id,
        'external_id', u.external_id,
        'email', u.email,
        'is_disabled', u.is_disabled,
        'created_at', u.created_at,
        'updated_at', u.updated_at,
        'last_seen', u.last_seen,
        'roles', v_roles,
        'permissions', v_permissions,
        'modules', v_modules
    )
    INTO v_result
    FROM users u
    WHERE u.id = v_user_id;
    
    -- Final safety check (should never be NULL after previous validations)
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Unexpected error: unable to build user info JSON for user_id = %', v_user_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_userinfo IS 
'Returns current authenticated user info as JSON with nested roles, permissions, and modules (filtered by RLS via helper function). Creates/updates user record and updates last_seen. Call once when new login detected.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;


-- =====================================================
-- GET SCHEMA
-- =====================================================

-- Get schema information for a table including all its fields
-- Returns JSON with table metadata and an array of field records
-- Raises an error when the table is not found
CREATE OR REPLACE FUNCTION public.get_schema(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_fields_array JSON;
    v_result JSON;
BEGIN
    -- Check if table exists in tables metadata
    SELECT * INTO v_table_record
    FROM tables
    WHERE table_name = p_table_name;
    
    -- Raise error if table not found
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table "%" not found in tables metadata', p_table_name
            USING ERRCODE = 'undefined_table';
    END IF;
    
    -- Build fields array with all field records
    -- Using json_agg to preserve insertion order
    SELECT COALESCE(json_agg(
        json_build_object(
            'field_name', f.field_name,
            'title', f.title,
            'description', f.description,
            'format', f.format,
            'is_pk', f.is_pk,
            'is_nullable', f.is_nullable,
            'default_value', f.default_value,
            'field_order', f.field_order,
            'ctype', f.ctype,
            'is_core', f.is_core,
            'created_at', f.created_at,
            'updated_at', f.updated_at
        ) ORDER BY f.field_order
    ), '[]'::json)
    INTO v_fields_array
    FROM fields f
    WHERE f.table_name = p_table_name;
    
    -- Build the final JSON result with table info and fields array
    -- Using json_build_object to preserve key insertion order
    -- This ensures 'fields' appears at the end as desired
    v_result := json_build_object(
        'table_name', v_table_record.table_name,
        'singular', v_table_record.singular,
        'plural', v_table_record.plural,
        'singular_label', v_table_record.singular_label,
        'plural_label', v_table_record.plural_label,
        'icon_url', v_table_record.icon_url,
        'description', v_table_record.description,
        'module_id', v_table_record.module_id,
        'view_permission', v_table_record.view_permission,
        'edit_permission', v_table_record.edit_permission,
        'id_column', v_table_record.id_column,
        'label_column', v_table_record.label_column,
        'created_at', v_table_record.created_at,
        'updated_at', v_table_record.updated_at,
        'fields', v_fields_array
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_schema IS 
'Returns table schema as JSON including all table metadata and an array of field records. Raises an error if table not found.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_schema(TEXT) TO semantius_user;

-- =====================================================
-- PING
-- =====================================================

CREATE OR REPLACE FUNCTION public.ping()
RETURNS TABLE(
    server_time TIMESTAMP WITH TIME ZONE,
    current_user_name TEXT,
    current_role_name TEXT,
    session_user_name TEXT
) AS $$
BEGIN
    RETURN QUERY SELECT 
        NOW() as server_time,
        current_user::TEXT as current_user_name,
        current_role::TEXT as current_role_name,
        session_user::TEXT as session_user_name;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.ping IS 
'Returns the current server timestamp and user information as a table. Useful for testing connectivity and server time.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.ping() TO semantius_user;



-- =====================================================
-- HAS PUBLIC READ
-- =====================================================

-- Function that returns comprehensive user access information
-- Returns JSON with current user's role, role membership, and permission status
CREATE OR REPLACE FUNCTION public.has_public_read()
RETURNS JSONB AS $$
DECLARE
    v_current_role TEXT;
    v_is_semantius_user BOOLEAN := FALSE;
    v_has_public_read BOOLEAN := FALSE;
BEGIN
    -- Get the current PostgreSQL role
    v_current_role := current_user;
    
    -- Check if current user is a member of semantius_user role
    -- Using pg_has_role to check role membership
    BEGIN
        v_is_semantius_user := pg_has_role(current_user, 'semantius_user', 'member');
    EXCEPTION WHEN OTHERS THEN
        -- If role doesn't exist or any other error, default to false
        v_is_semantius_user := FALSE;
    END;
    
    -- Check if user has public:read permission via RBAC system
    BEGIN
        v_has_public_read := rbac.has_permission('public:read'::text);
    EXCEPTION WHEN OTHERS THEN
        -- If RBAC system fails, default to false
        v_has_public_read := FALSE;
    END;
    
    -- Return all information as JSON
    RETURN jsonb_build_object(
        'current_role', v_current_role,
        'is_member_of_semantius_user', v_is_semantius_user,
        'has_public_read_permission', v_has_public_read
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.has_public_read IS 
'Returns current user access information: PostgreSQL role, semantius_user membership, and public:read permission status.';

-- Grant execute permission to semantius_user role
-- GRANT EXECUTE ON FUNCTION public.has_public_read() TO semantius_user;
