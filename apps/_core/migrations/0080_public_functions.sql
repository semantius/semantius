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

-- Get schema information for a table in extended JSON Schema format
-- Returns JSON Schema with table metadata and properties
-- Raises an error when the table is not found
CREATE OR REPLACE FUNCTION public.get_schema(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_properties JSON;
    v_required_fields JSON;
    v_result JSON;
BEGIN
    -- Check if table exists in tables metadata
    SELECT * INTO v_table_record
    FROM tables
    WHERE table_name = p_table_name;
    
    -- Raise error if table not found
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table "%" not found in tables', p_table_name
            USING ERRCODE = 'undefined_table';
    END IF;
    
    -- Check if user has view permission for this table
    -- Raise same error to avoid leaking table existence
    IF NOT rbac.has_permission(v_table_record.view_permission) THEN
        RAISE EXCEPTION 'Table "%" not found in tables metadata', p_table_name
            USING ERRCODE = 'undefined_table';
    END IF;
    
    -- Build properties object from fields
    -- Each field becomes a property with JSON Schema attributes
    WITH ordered_fields AS (
        SELECT 
            field_name,
            format,
            is_nullable,
            title,
            description,
            default_value,
            input_type,
            width,
            field_order,
            enum_values,
            reference_table,
            reference_delete_mode
        FROM fields
        WHERE table_name = p_table_name
        ORDER BY field_order
    ),
    properties_with_defaults AS (
        SELECT 
            field_name,
            field_order,
            (jsonb_build_object(
                'type', format_to_json_type(format),
                'title', title,
                'description', description,
                'inputMode', input_type,
                'width', width,
                'fieldOrder', field_order
            ) || 
            -- Add format field only for string-based formats (email, url, etc), not for type mappers (int32, float, etc)
            CASE 
                WHEN format IS NOT NULL 
                     AND format != '' 
                     AND format != 'text'
                     AND format NOT IN ('int32', 'int64', 'integer', 'float', 'double', 'number', 'boolean', 'object', 'array', 'null')
                THEN jsonb_build_object('format', format)
                ELSE '{}'::jsonb
            END ||
            -- Add enum field if enum_values is present
            CASE 
                WHEN enum_values IS NOT NULL AND jsonb_array_length(enum_values) > 0
                THEN jsonb_build_object('enum', enum_values)
                ELSE '{}'::jsonb
            END ||
            -- Add reference_table field if format is 'reference'
            CASE 
                WHEN format = 'reference' AND reference_table IS NOT NULL AND reference_table != ''
                THEN jsonb_build_object('referenceTable', reference_table, 'referenceDeleteMode', reference_delete_mode)
                ELSE '{}'::jsonb
            END ||
            -- Add default field separately to handle type conversion properly
            CASE 
                WHEN default_value IS NOT NULL AND trim(default_value) != '' THEN
                    CASE
                        WHEN format_to_json_type(format) = 'integer' THEN jsonb_build_object('default', (default_value::INTEGER))
                        WHEN format_to_json_type(format) = 'number' THEN jsonb_build_object('default', (default_value::NUMERIC))
                        WHEN format_to_json_type(format) = 'boolean' THEN jsonb_build_object('default', (default_value::BOOLEAN))
                        WHEN format_to_json_type(format) IN ('object', 'array') THEN jsonb_build_object('default', default_value::jsonb)
                        -- For strings, trim quotes if present (handles SQL literal strings like 'active')
                        ELSE jsonb_build_object('default', trim(both '''' from default_value))
                    END
                -- For string types without explicit default, add empty string default
                WHEN format_to_json_type(format) = 'string' THEN jsonb_build_object('default', '')
                ELSE '{}'::jsonb
            END)::json AS property_value
        FROM ordered_fields
    )
    SELECT COALESCE(
        json_object_agg(
            field_name,
            property_value ORDER BY field_order
        ),
        '{}'::json
    )
    INTO v_properties
    FROM properties_with_defaults;
    
    -- Build required fields array (fields where is_nullable = false)
    -- Exclude the id_column since it's auto-generated and not required for INSERT
    -- Exclude created_at and updated_at since they are auto-maintained by triggers
    WITH required_fields AS (
        SELECT field_name, field_order
        FROM fields
        WHERE table_name = p_table_name
          AND is_nullable = FALSE
          AND field_name != v_table_record.id_column
          AND field_name NOT IN ('created_at', 'updated_at')
        ORDER BY field_order
    )
    SELECT COALESCE(
        json_agg(field_name),
        '[]'::json
    )
    INTO v_required_fields
    FROM required_fields;
    
    -- Build the final JSON Schema result
    v_result := json_build_object(
        '$schema', 'https://semantius.com/meta/sem-schema/v1',
        '$id', 'https://example.com/schemas/' || p_table_name || '.schema.json',
        'title', v_table_record.singular_label,
        'description', v_table_record.description,
        'table', row_to_json(v_table_record),
        'type', 'object',
        'properties', v_properties,
        'required', v_required_fields,
        'additionalProperties', false
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_schema IS 
'Returns table schema in extended JSON Schema format with table metadata in a table object and fields as properties. Raises an error if table not found.';

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
