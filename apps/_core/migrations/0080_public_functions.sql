-- =====================================================
-- PUBLIC FUNCTIONS
-- =====================================================
-- User-facing functions in the public schema
-- These provide convenient access to RBAC and user information
-- =====================================================

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
BEGIN
    -- Get current user from JWT
    v_external_id := rbac.uid();
    
    -- Get email from JWT if available
    v_email := current_setting('request.jwt.claim.email', true);
    
    -- Create or update user record and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(v_external_id, v_email);
    
    -- Build roles array with role details
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'role_id', r.role_id,
            'role_name', r.role_name,
            'description', r.description,
            'module_id', r.module_id,
            'assigned_at', ur.assigned_at
        ) ORDER BY r.role_name
    ), '[]'::jsonb)
    INTO v_roles
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.role_id
    WHERE ur.user_id = v_user_id;
    
    -- Build permissions array (all effective permissions including inherited)
    SELECT COALESCE(jsonb_agg(
        permission_name ORDER BY permission_name
    ), '[]'::jsonb)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Build the final JSON result
    SELECT jsonb_build_object(
        'user_id', u.user_id,
        'external_id', u.external_id,
        'email', u.email,
        'is_disabled', u.is_disabled,
        'created_at', u.created_at,
        'updated_at', u.updated_at,
        'last_seen', u.last_seen,
        'roles', v_roles,
        'permissions', v_permissions
    )
    INTO v_result
    FROM users u
    WHERE u.user_id = v_user_id;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_userinfo IS 
'Returns current authenticated user info as JSON with nested roles and permissions. Creates/updates user record and updates last_seen. Call once when new login detected.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;
