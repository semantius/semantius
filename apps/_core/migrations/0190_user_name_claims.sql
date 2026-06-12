-- =====================================================
-- MIGRATION: Add first_name and last_name to users,
-- populate display_name from JWT name claim
-- =====================================================
-- JWT claims given_name and family_name are now stored
-- as first_name and last_name in the users table.
-- JWT name claim is stored as display_name (column already exists).
-- sub (external_id) is already UNIQUE NOT NULL.

-- Add columns
ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name TEXT DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name TEXT DEFAULT '';

-- Mark external_id as unique in data dictionary (matches the UNIQUE constraint on the table)
UPDATE fields SET unique_value = TRUE WHERE table_name = 'users' AND field_name = 'external_id';

-- Add data dictionary entries for the new fields
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('users', 'first_name', 'First Name', 'First name from JWT given_name claim', 'text', FALSE, 22, 'default', 'default', 'core', TRUE, '', ''),
    ('users', 'last_name',  'Last Name',  'Last name from JWT family_name claim', 'text', FALSE, 23, 'default', 'default', 'core', TRUE, '', '')
ON CONFLICT DO NOTHING;

-- =====================================================
-- Update upsert_user_from_jwt to accept display_name/first_name/last_name
-- Drop the old 2-parameter version first, then create the new 5-parameter version
-- =====================================================
DROP FUNCTION IF EXISTS rbac.upsert_user_from_jwt(TEXT, TEXT);

CREATE OR REPLACE FUNCTION rbac.upsert_user_from_jwt(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL,
    p_display_name TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    PERFORM rbac.uid();

    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;

    INSERT INTO users (external_id, email, display_name, first_name, last_name, last_seen)
    VALUES (p_external_id, p_email, COALESCE(p_display_name, ''), COALESCE(p_first_name, ''), COALESCE(p_last_name, ''), CURRENT_TIMESTAMP)
    ON CONFLICT (external_id) DO UPDATE
    SET last_seen = CURRENT_TIMESTAMP,
        email = COALESCE(EXCLUDED.email, users.email),
        display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), users.display_name),
        first_name = COALESCE(NULLIF(EXCLUDED.first_name, ''), users.first_name),
        last_name = COALESCE(NULLIF(EXCLUDED.last_name, ''), users.last_name)
    RETURNING id INTO v_user_id;
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.upsert_user_from_jwt IS
'Creates or updates user record from JWT claims. Stores name as display_name, given_name as first_name, family_name as last_name. Updates last_seen timestamp. Called by get_userinfo().';

REVOKE EXECUTE ON FUNCTION rbac.upsert_user_from_jwt(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

-- =====================================================
-- Update get_userinfo to pass first_name/last_name from JWT claims
-- and include them in the response
-- =====================================================
CREATE OR REPLACE FUNCTION public.get_userinfo()
RETURNS JSONB AS $$
DECLARE
    v_external_id TEXT;
    v_email TEXT;
    v_display_name TEXT;
    v_first_name TEXT;
    v_last_name TEXT;
    v_user_id INTEGER;
    v_result JSONB;
    v_roles JSONB;
    v_permissions JSONB;
    v_modules JSONB;
BEGIN
    -- Get current user from JWT
    v_external_id := rbac.uid();

    -- Get claims from JWT
    v_email := current_setting('request.jwt.claim.email', true);
    v_display_name := current_setting('request.jwt.claim.name', true);
    v_first_name := current_setting('request.jwt.claim.given_name', true);
    v_last_name := current_setting('request.jwt.claim.family_name', true);

    -- Create or update user record and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(v_external_id, v_email, v_display_name, v_first_name, v_last_name);
    
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

    -- Explicitly initialize the context cache with the permissions we just computed.
    -- This is necessary because get_user_modules() -> has_any_permission() uses
    -- ensure_context_initialized() which may see a stale snapshot (STABLE function)
    -- when the user was just created in this same function call.
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, true);
    PERFORM set_config('app.current_external_id', v_external_id, true);
    PERFORM set_config('app.user_permissions', COALESCE(
        (SELECT string_agg(p.value #>> '{}', ',' ORDER BY p.value #>> '{}')
         FROM jsonb_array_elements(v_permissions) AS p(value)),
        ''
    ), true);
    PERFORM set_config('app.context_initialized', 'true', true);

    -- Build modules array (filtered by permissions via helper function)
    v_modules := public.get_user_modules();
    
    -- Build the final JSON result
    SELECT jsonb_build_object(
        'user_id', u.id,
        'external_id', u.external_id,
        'email', u.email,
        'display_name', u.display_name,
        'first_name', u.first_name,
        'last_name', u.last_name,
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_userinfo IS
'Returns complete user profile with roles, permissions, and modules. Creates/updates user from JWT claims (email, name, given_name, family_name). Call on login.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_userinfo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;

-- =====================================================
-- Update set_request_context to pass first_name/last_name
-- =====================================================
CREATE OR REPLACE FUNCTION rbac.set_request_context(
    p_external_id TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_oauth_scopes TEXT DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_external_id TEXT;
    v_user_id INTEGER;
    v_permissions TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Use provided external_id or detect from JWT
    v_external_id := COALESCE(p_external_id, rbac.uid());
    
    -- Validate external_id is not empty
    IF v_external_id IS NULL OR trim(v_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    -- Ensure user exists and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(
        v_external_id, 
        COALESCE(p_email, current_setting('request.jwt.claim.email', true)),
        current_setting('request.jwt.claim.name', true),
        current_setting('request.jwt.claim.given_name', true),
        current_setting('request.jwt.claim.family_name', true)
    );
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Set PostgreSQL session variables scoped to the current transaction (LOCAL)
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, true);
    PERFORM set_config('app.current_external_id', v_external_id, true);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), true);
    PERFORM set_config('app.context_initialized', 'true', true);

    -- Store OAuth2 scopes if present (for API requests)
    IF p_oauth_scopes IS NOT NULL THEN
        PERFORM set_config('app.oauth_scopes', p_oauth_scopes, true);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.set_request_context IS 
'Manually sets request context. Optional - context auto-initializes if not called. Use for OAuth scope validation.';
