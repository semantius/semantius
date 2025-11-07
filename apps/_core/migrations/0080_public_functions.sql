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
-- Returns the user record from the users table for the current JWT
-- Automatically initializes context and validates authentication
CREATE OR REPLACE FUNCTION public.get_userinfo()
RETURNS TABLE (
    user_id INTEGER,
    external_id TEXT,
    email TEXT,
    is_disabled BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    last_seen TIMESTAMPTZ
) AS $$
BEGIN
    -- Ensure context is initialized (validates JWT and upserts user)
    PERFORM rbac.ensure_context_initialized();
    
    -- Return the current user's record
    RETURN QUERY
    SELECT 
        u.user_id,
        u.external_id,
        u.email,
        u.is_disabled,
        u.created_at,
        u.updated_at,
        u.last_seen
    FROM users u
    WHERE u.user_id = rbac.user_id();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION public.get_userinfo IS 
'Returns current authenticated user information from the users table. Requires valid JWT.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;
