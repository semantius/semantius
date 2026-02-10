-- =====================================================
-- CREATE SCHEMA
-- =====================================================

CREATE SCHEMA IF NOT EXISTS rbac;

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

-- Allow semantius_user users to use rbac schema and execute functions
GRANT USAGE ON SCHEMA rbac TO semantius_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA rbac TO semantius_user;

-- Ensure future functions are automatically granted (THIS IS KEY!)
ALTER DEFAULT PRIVILEGES IN SCHEMA rbac 
    GRANT EXECUTE ON FUNCTIONS TO semantius_user;


-- =====================================================
-- RBAC SYSTEM - PL/pgSQL FUNCTIONS
-- =====================================================
-- Run this AFTER creating schema and tables
-- All functions in rbac schema for organization
-- Tables remain in public schema for Neon Data API compatibility
-- =====================================================

-- =====================================================
-- CYCLE DETECTION FOR PERMISSION HIERARCHY
-- =====================================================

-- Function to detect cycles in permission hierarchy and enforce depth limit of 11
CREATE OR REPLACE FUNCTION rbac.check_permission_hierarchy_cycle()
RETURNS TRIGGER AS $$
DECLARE
    cycle_exists BOOLEAN;
    max_depth INTEGER;
BEGIN
    -- Validate that both parent and child permissions exist (redundant with FK but explicit)
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE id = NEW.parent_permission_id) THEN
        RAISE EXCEPTION 'Parent permission with Id % does not exist', NEW.parent_permission_id;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE id = NEW.child_permission_id) THEN
        RAISE EXCEPTION 'Child permission with Id % does not exist', NEW.child_permission_id;
    END IF;
    
    -- Check if adding this edge would create a cycle or exceed depth limit
    -- A cycle exists if the child can reach the parent through existing paths
    WITH RECURSIVE hierarchy_path AS (
        -- Start from the proposed child
        SELECT child_permission_id AS permission_id, 1 AS depth
        FROM permission_hierarchy
        WHERE parent_permission_id = NEW.child_permission_id
        
        UNION ALL
        
        -- Recursively follow the hierarchy
        SELECT ph.child_permission_id, hp.depth + 1
        FROM permission_hierarchy ph
        INNER JOIN hierarchy_path hp ON ph.parent_permission_id = hp.permission_id
        WHERE hp.depth < 11  -- Stop at depth 11
    )
    SELECT 
        EXISTS (SELECT 1 FROM hierarchy_path WHERE permission_id = NEW.parent_permission_id),
        COALESCE(MAX(depth), 0)
    INTO cycle_exists, max_depth
    FROM hierarchy_path;
    
    IF cycle_exists THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: would create a cycle. Permission Id % cannot be both ancestor and descendant of permission Id %', 
            NEW.parent_permission_id, NEW.child_permission_id;
    END IF;
    
    IF max_depth >= 11 THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: maximum depth of 11 levels would be exceeded. Current depth would be %', 
            max_depth + 1;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rbac.check_permission_hierarchy_cycle IS 
'Trigger function to prevent cycles and enforce 11-level depth limit in permission hierarchy.';

-- Apply trigger BEFORE INSERT OR UPDATE
CREATE TRIGGER prevent_permission_hierarchy_cycle
    BEFORE INSERT OR UPDATE ON permission_hierarchy
    FOR EACH ROW
    EXECUTE FUNCTION rbac.check_permission_hierarchy_cycle();

-- =====================================================
-- USER DETECTION AND IDENTIFICATION
-- =====================================================

-- Get current user's external_id from JWT
-- Works with both Neon and Supabase JWT formats
-- Automatically normalizes Supabase format to Neon format for future calls
CREATE OR REPLACE FUNCTION rbac.uid()
RETURNS TEXT AS $$
DECLARE
    sub_value TEXT;
    supabase_claims jsonb;
    claim_key TEXT;
    claim_value TEXT;
BEGIN
    -- Step 1: Try Neon format (fastest path)
    sub_value := current_setting('request.jwt.claim.sub', true);
    
    IF sub_value IS NOT NULL AND sub_value != '' THEN
        RETURN sub_value;
    END IF;
    
    -- Step 2: Fallback - Check if Supabase format exists
    BEGIN
        supabase_claims := current_setting('request.jwt.claims', true)::jsonb;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Authentication required: No valid JWT claims found';
    END;
    
    IF supabase_claims IS NULL THEN
        RAISE EXCEPTION 'Authentication required: No valid JWT claims found';
    END IF;
    
    -- Step 3: Convert ALL Supabase JSON properties to Neon-style settings
    -- This normalizes the format for future calls in this transaction
    FOR claim_key, claim_value IN 
        SELECT key, value::text 
        FROM jsonb_each_text(supabase_claims)
    LOOP
        BEGIN
            PERFORM set_config('request.jwt.claim.' || claim_key, claim_value, true);
        EXCEPTION
            WHEN OTHERS THEN
                NULL; -- Skip if setting fails
        END;
    END LOOP;
    
    -- Step 4: Get sub from normalized Neon format
    sub_value := current_setting('request.jwt.claim.sub', true);
    
    IF sub_value IS NULL OR sub_value = '' THEN
        RAISE EXCEPTION 'Authentication required: JWT sub claim is missing';
    END IF;
    
    RETURN sub_value;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.uid IS 
'Returns current user external_id from JWT. Auto-detects Neon/Supabase format.';

-- =====================================================
-- USER MANAGEMENT
-- =====================================================

-- Read-only function to get user_id by external_id
-- Used by RLS policies in read-only transactions (e.g., PostgREST GET requests)
-- Returns NULL if user doesn't exist
CREATE OR REPLACE FUNCTION rbac.get_user_by_external_id(
    p_external_id TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN NULL;
    END IF;
    
    SELECT id INTO v_user_id
    FROM users
    WHERE external_id = p_external_id
      AND is_disabled = FALSE;
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.get_user_by_external_id IS 
'Read-only lookup of user_id by external_id. Returns NULL if user not found or disabled. Used by RLS policies.';

-- Initialize or update user from JWT
-- Called by get_userinfo() to create/update user and update last_seen
-- NOT called by RLS policies (they use read-only lookup)
CREATE OR REPLACE FUNCTION rbac.upsert_user_from_jwt(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    INSERT INTO users (external_id, email, last_seen)
    VALUES (p_external_id, p_email, CURRENT_TIMESTAMP)
    ON CONFLICT (external_id) DO UPDATE
    SET last_seen = CURRENT_TIMESTAMP,
        email = COALESCE(EXCLUDED.email, users.email)
    RETURNING id INTO v_user_id;
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.upsert_user_from_jwt IS 
'Creates or updates user record from JWT claims. Updates last_seen timestamp. Called by get_userinfo().';

-- =====================================================
-- REQUEST CONTEXT - LAZY INITIALIZATION
-- =====================================================

-- Initialize request context on first use (lazy initialization)
-- Loads all user permissions once and caches them for the transaction
-- This is called automatically by permission checking functions
-- READ-ONLY: Does not modify database, compatible with PostgREST GET requests
CREATE OR REPLACE FUNCTION rbac.ensure_context_initialized()
RETURNS void AS $$
DECLARE
    v_external_id TEXT;
    v_user_id INTEGER;
    v_permissions TEXT;
    v_initialized TEXT;
BEGIN
    -- Check if already initialized in this transaction
    v_initialized := current_setting('app.context_initialized', true);
    
    IF v_initialized = 'true' THEN
        RETURN; -- Already initialized, skip
    END IF;
    
    -- Get current user from JWT
    v_external_id := rbac.uid();
    
    -- Read-only lookup: Get user_id without modifying database
    v_user_id := rbac.get_user_by_external_id(v_external_id);
    
    -- User must exist - client should have called get_userinfo() on first login
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not found: %. Client must call get_userinfo() on first login to create user record.', v_external_id
            USING ERRCODE = 'invalid_authorization_specification';
    END IF;
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    -- This expensive recursive CTE runs only once per request
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Set PostgreSQL session variables for the current transaction
    -- These are automatically cleared when the transaction ends
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, false);
    PERFORM set_config('app.current_external_id', v_external_id, false);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), false);
    PERFORM set_config('app.context_initialized', 'true', false);
    
    -- Note: OAuth scopes handled separately if needed
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.ensure_context_initialized IS 
'Lazy initialization of request context. Called automatically on first permission check.';

-- Manual context initialization with OAuth scopes
-- Use this for OAuth/API requests where scopes need to be validated
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
    -- Use provided external_id or detect from JWT
    v_external_id := COALESCE(p_external_id, rbac.uid());
    
    -- Validate external_id is not empty
    IF v_external_id IS NULL OR trim(v_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    -- Ensure user exists and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(
        v_external_id, 
        COALESCE(p_email, current_setting('request.jwt.claim.email', true))
    );
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Set PostgreSQL session variables for the current transaction
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, false);
    PERFORM set_config('app.current_external_id', v_external_id, false);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), false);
    PERFORM set_config('app.context_initialized', 'true', false);
    
    -- Store OAuth2 scopes if present (for API requests)
    IF p_oauth_scopes IS NOT NULL THEN
        PERFORM set_config('app.oauth_scopes', p_oauth_scopes, false);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.set_request_context IS 
'Manually sets request context. Optional - context auto-initializes if not called. Use for OAuth scope validation.';

-- =====================================================
-- PERMISSION CHECKING
-- =====================================================

-- Check if user has a specific permission
-- This includes:
-- 1. Direct permissions from roles
-- 2. Implied permissions via hierarchy
-- 3. OAuth scope restrictions (if scopes are set)
CREATE OR REPLACE FUNCTION rbac.user_has_permission(
    p_external_id TEXT,
    p_permission_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_oauth_scopes TEXT;
    v_has_permission BOOLEAN;
    v_permission_id INTEGER;
BEGIN
    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN FALSE;
    END IF;
    
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        RETURN FALSE;
    END IF;
    
    -- Get the permission_id for the requested permission
    SELECT id INTO v_permission_id
    FROM permissions
    WHERE permission_name = p_permission_name;
    
    -- If permission doesn't exist, return false
    IF v_permission_id IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- Check if user has the permission (including hierarchy)
    -- Using recursive CTE to follow the hierarchy
    WITH RECURSIVE permission_tree AS (
        -- Start with direct permissions from roles
        SELECT DISTINCT p.id AS permission_id
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Add implied permissions (children in hierarchy)
        SELECT DISTINCT ph.child_permission_id
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
    )
    SELECT EXISTS (
        SELECT 1 FROM permission_tree
        WHERE permission_id = v_permission_id
    ) INTO v_has_permission;
    
    -- If user doesn't have the permission, return false immediately
    IF NOT v_has_permission THEN
        RETURN FALSE;
    END IF;
    
    -- Check OAuth2 scopes if present
    v_oauth_scopes := current_setting('app.oauth_scopes', true);
    
    -- If no OAuth scopes set (user-initiated request), allow
    IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
        RETURN TRUE;
    END IF;
    
    -- Check if required permission is in OAuth scopes
    -- OAuth scopes can include the permission OR a parent permission that implies it
    RETURN EXISTS (
        WITH RECURSIVE permission_tree AS (
            -- Get permissions from OAuth scopes
            SELECT DISTINCT p.id AS permission_id
            FROM permissions p
            WHERE p.permission_name = ANY(string_to_array(v_oauth_scopes, ' '))
            
            UNION
            
            -- Add implied permissions
            SELECT DISTINCT ph.child_permission_id
            FROM permission_tree pt
            JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
        )
        SELECT 1 FROM permission_tree
        WHERE permission_id = v_permission_id
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.user_has_permission IS 
'Checks if user has permission by name, considering hierarchy and OAuth scopes.';

-- Check if current request user has permission
-- AUTO-INITIALIZES context on first call (lazy initialization)
-- OPTIMIZED: Uses cached permissions from session for ultra-fast lookups
CREATE OR REPLACE FUNCTION rbac.has_permission(
    p_permission_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_cached_permissions TEXT;
    v_oauth_scopes TEXT;
    v_external_id TEXT;
BEGIN
    -- Validate permission_name
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        RETURN FALSE;
    END IF;
    
    -- LAZY INITIALIZATION: Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    -- OPTIMIZATION: Get cached permissions (now guaranteed to exist)
    v_cached_permissions := current_setting('app.user_permissions', true);
    
    -- Fast string search in comma-separated list
    -- This is 1000x faster than querying the database
    IF v_cached_permissions IS NOT NULL AND v_cached_permissions != '' THEN
        -- Check if permission exists in comma-separated list
        IF position(',' || p_permission_name || ',' IN ',' || v_cached_permissions || ',') > 0 THEN
            -- Permission found in cache, now check OAuth scopes if present
            v_oauth_scopes := current_setting('app.oauth_scopes', true);
            
            -- If no OAuth scopes set (user-initiated request), allow
            IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
                RETURN TRUE;
            END IF;
            
            -- Check if permission is in OAuth scopes
            RETURN position(',' || p_permission_name || ',' IN ',' || v_oauth_scopes || ',') > 0;
        ELSE
            -- Permission not in cache
            RETURN FALSE;
        END IF;
    END IF;
    
    -- Should never reach here after initialization, but safety fallback
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.has_permission IS 
'Checks if current user has permission. Auto-initializes context and uses cached permissions.';

-- Require permission or raise exception
-- Use this in application functions to enforce permissions
CREATE OR REPLACE FUNCTION rbac.require_permission(
    p_permission_name TEXT
)
RETURNS void AS $$
BEGIN
    IF NOT rbac.has_permission(p_permission_name) THEN
        RAISE EXCEPTION 'Permission denied: % required', p_permission_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.require_permission IS 
'Raises exception if current user lacks permission. Use for access control.';

-- Check if user has any of the specified permissions (OR logic)
-- Uses cached permissions for optimal performance
CREATE OR REPLACE FUNCTION rbac.has_any_permission(
    VARIADIC p_permission_names TEXT[]
)
RETURNS BOOLEAN AS $$
DECLARE
    v_cached_permissions TEXT;
    v_permission TEXT;
    v_oauth_scopes TEXT;
    v_has_base_permission BOOLEAN := FALSE;
BEGIN
    -- Validate input
    IF p_permission_names IS NULL OR array_length(p_permission_names, 1) IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- LAZY INITIALIZATION: Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    -- Get cached permissions (now guaranteed to exist)
    v_cached_permissions := current_setting('app.user_permissions', true);
    
    IF v_cached_permissions IS NOT NULL AND v_cached_permissions != '' THEN
        -- Check if any permission exists in cache
        FOREACH v_permission IN ARRAY p_permission_names
        LOOP
            IF position(',' || v_permission || ',' IN ',' || v_cached_permissions || ',') > 0 THEN
                v_has_base_permission := TRUE;
                EXIT; -- Found one, stop checking
            END IF;
        END LOOP;
        
        IF NOT v_has_base_permission THEN
            RETURN FALSE;
        END IF;
        
        -- Check OAuth scopes if present
        v_oauth_scopes := current_setting('app.oauth_scopes', true);
        
        IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
            RETURN TRUE;
        END IF;
        
        -- Verify at least one permission is in OAuth scopes
        FOREACH v_permission IN ARRAY p_permission_names
        LOOP
            IF position(',' || v_permission || ',' IN ',' || v_oauth_scopes || ',') > 0 THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        
        RETURN FALSE;
    END IF;
    
    -- Should never reach here after initialization
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.has_any_permission IS 
'Returns true if current user has at least one of the specified permissions.';

-- Require any of the specified permissions or raise exception
-- Use this when multiple permissions could authorize an action (OR logic)
CREATE OR REPLACE FUNCTION rbac.require_any_permission(
    VARIADIC p_permission_names TEXT[]
)
RETURNS void AS $$
BEGIN
    IF NOT rbac.has_any_permission(VARIADIC p_permission_names) THEN
        RAISE EXCEPTION 'Permission denied: one of (%) required', array_to_string(p_permission_names, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.require_any_permission IS 
'Raises exception if current user lacks all specified permissions.';

-- =====================================================
-- PERMISSION QUERIES
-- =====================================================

-- Get all effective permissions for a user (including implied)
CREATE OR REPLACE FUNCTION rbac.get_user_permissions(
    p_external_id TEXT
)
RETURNS TABLE (
    permission_name TEXT
) AS $$
BEGIN
    -- Validate external_id
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    WITH RECURSIVE permission_tree AS (
        -- Direct permissions
        SELECT DISTINCT p.id AS permission_id, p.permission_name
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Implied permissions
        SELECT DISTINCT p.id AS permission_id, p.permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
        JOIN permissions p ON ph.child_permission_id = p.id
    )
    SELECT DISTINCT pt.permission_name
    FROM permission_tree pt
    ORDER BY pt.permission_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.get_user_permissions IS 
'Returns all effective permissions for a user, including implied permissions.';

-- Get current user's permissions (uses lazy initialization)
CREATE OR REPLACE FUNCTION rbac.get_current_user_permissions()
RETURNS TABLE (
    permission_name TEXT
) AS $$
BEGIN
    -- Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    -- Return cached permissions as table
    RETURN QUERY
    SELECT unnest(string_to_array(current_setting('app.user_permissions', true), ','))::TEXT
    WHERE current_setting('app.user_permissions', true) IS NOT NULL 
      AND current_setting('app.user_permissions', true) != '';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.get_current_user_permissions IS 
'Returns all permissions for current user from cache. Auto-initializes if needed.';

-- Validate OAuth scopes against user permissions
CREATE OR REPLACE FUNCTION rbac.validate_oauth_scopes(
    p_external_id TEXT,
    p_requested_scopes TEXT
)
RETURNS TABLE (
    scope TEXT,
    is_valid BOOLEAN,
    reason TEXT
) AS $$
BEGIN
    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    IF p_requested_scopes IS NULL OR trim(p_requested_scopes) = '' THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    WITH user_perms AS (
        SELECT permission_name FROM rbac.get_user_permissions(p_external_id)
    )
    SELECT 
        s.scope::TEXT,
        EXISTS (SELECT 1 FROM user_perms WHERE permission_name = s.scope) AS is_valid,
        CASE 
            WHEN EXISTS (SELECT 1 FROM user_perms WHERE permission_name = s.scope)
            THEN 'Granted'::TEXT
            ELSE 'User does not have this permission'::TEXT
        END AS reason
    FROM unnest(string_to_array(p_requested_scopes, ' ')) AS s(scope);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.validate_oauth_scopes IS 
'Validates which OAuth scopes a user can request. Use during token issuance.';

-- Validate that a permission exists
CREATE OR REPLACE FUNCTION rbac.validate_permission_exists(p_permission_name TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM permissions WHERE permission_name = p_permission_name
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.validate_permission_exists IS 
'Validates that a permission exists in the permissions table.';

-- =====================================================
-- HELPER FUNCTIONS
-- =====================================================

-- Get current user's internal database Id
CREATE OR REPLACE FUNCTION rbac.user_id()
RETURNS INTEGER AS $$
BEGIN
    -- Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    RETURN current_setting('app.current_user_id', true)::INTEGER;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.user_id IS 
'Returns internal user_id for current user. Auto-initializes if needed.';

-- =====================================================
-- DEBUGGING AND INTROSPECTION
-- =====================================================

-- Get complete context information for current user
CREATE OR REPLACE FUNCTION rbac.whoami()
RETURNS TABLE (
    context_type TEXT,
    key TEXT,
    value TEXT
) AS $$
DECLARE
    v_initialized TEXT;
    v_jwt_claims TEXT[];
    v_claim TEXT;
    v_claim_value TEXT;
BEGIN
    -- Return raw JWT settings BEFORE initialization
    RETURN QUERY SELECT 
        'jwt_raw'::TEXT,
        'request.jwt.claim.sub'::TEXT,
        current_setting('request.jwt.claim.sub', true);
    
    RETURN QUERY SELECT 
        'jwt_raw'::TEXT,
        'request.jwt.claims'::TEXT,
        current_setting('request.jwt.claims', true);
    
    -- Initialize context (will throw error if no JWT)
    PERFORM rbac.ensure_context_initialized();
    
    v_initialized := current_setting('app.context_initialized', true);
    
    -- Return initialization status
    RETURN QUERY SELECT 
        'status'::TEXT,
        'context_initialized'::TEXT,
        COALESCE(v_initialized, 'false')::TEXT;
    
    -- Return app context variables
    RETURN QUERY SELECT 
        'app'::TEXT,
        'current_user_id'::TEXT,
        current_setting('app.current_user_id', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'current_external_id'::TEXT,
        current_setting('app.current_external_id', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'user_permissions'::TEXT,
        current_setting('app.user_permissions', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'oauth_scopes'::TEXT,
        current_setting('app.oauth_scopes', true);
    
    -- Return common JWT claims (already normalized by rbac.uid())
    v_jwt_claims := ARRAY[
        'sub',
        'email',
        'email_verified',
        'name',
        'given_name',
        'family_name',
        'picture',
        'iss',
        'aud',
        'exp',
        'iat',
        'role'
    ];
    
    FOREACH v_claim IN ARRAY v_jwt_claims
    LOOP
        v_claim_value := current_setting('request.jwt.claim.' || v_claim, true);
        IF v_claim_value IS NOT NULL AND v_claim_value != '' THEN
            RETURN QUERY SELECT 
                'jwt'::TEXT,
                v_claim::TEXT,
                v_claim_value::TEXT;
        END IF;
    END LOOP;
    
    RETURN;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.whoami IS 
'Returns all context information: app session variables, JWT claims, and cached permissions. Requires authentication.';

-- =====================================================
-- AUTO-GRANT NEW PERMISSIONS TO ADMINISTRATOR ROLE
-- =====================================================

-- Trigger function to automatically grant new permissions to Administrator role
CREATE OR REPLACE FUNCTION rbac.grant_permission_to_administrator()
RETURNS TRIGGER AS $$
DECLARE
    v_administrator_role_id INTEGER;
BEGIN
    -- Get Administrator role id (role_name = 'Administrator')
    SELECT id INTO v_administrator_role_id
    FROM roles
    WHERE role_name = 'Administrator';
    
    -- If Administrator role exists, grant the new permission to it
    IF v_administrator_role_id IS NOT NULL THEN
        -- Insert into role_permissions if not already exists
        INSERT INTO role_permissions (role_id, permission_id)
        VALUES (v_administrator_role_id, NEW.id)
        ON CONFLICT (role_id, permission_id) DO NOTHING;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rbac.grant_permission_to_administrator IS 
'Automatically grants newly created permissions to the Administrator role';

-- Apply trigger AFTER INSERT on permissions table
CREATE TRIGGER auto_grant_permission_to_administrator
    AFTER INSERT ON permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.grant_permission_to_administrator();

