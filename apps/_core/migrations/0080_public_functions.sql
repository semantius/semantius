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
-- IMPORTANT: This function creates/updates the user record and updates last_seen
-- Clients MUST call this function after connecting to initialize their session
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
DECLARE
    v_external_id TEXT;
    v_email TEXT;
    v_user_id INTEGER;
BEGIN
    -- Get current user from JWT
    v_external_id := rbac.uid();
    
    -- Get email from JWT if available
    v_email := current_setting('request.jwt.claim.email', true);
    
    -- Create or update user record and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(v_external_id, v_email);
    
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
    WHERE u.user_id = v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_userinfo IS 
'Returns current authenticated user info. Creates/updates user record and updates last_seen. Clients must call this after connecting to initialize session.';

-- Grant execute permission to semantius_user role
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;
