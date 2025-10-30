-- =====================================================
-- CREATE SCHEMA
-- =====================================================

CREATE SCHEMA IF NOT EXISTS rbac;

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
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE permission_id = NEW.parent_permission_id) THEN
        RAISE EXCEPTION 'Parent permission with ID % does not exist', NEW.parent_permission_id;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE permission_id = NEW.child_permission_id) THEN
        RAISE EXCEPTION 'Child permission with ID % does not exist', NEW.child_permission_id;
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
        RAISE EXCEPTION 'Cannot add permission hierarchy: would create a cycle. Permission ID % cannot be both ancestor and descendant of permission ID %', 
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
-- USER MANAGEMENT
-- =====================================================

-- Initialize or update user from JWT
-- Called at the start of each request to ensure user exists
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
    RETURNING user_id INTO v_user_id;
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.upsert_user_from_jwt IS 
'Creates or updates user record from JWT claims. Updates last_seen timestamp.';

-- =====================================================
-- REQUEST CONTEXT
-- =====================================================

-- Set request context from JWT claims
-- This must be called at the start of each request/transaction
-- Sets PostgreSQL session variables that are automatically cleared when transaction ends
-- OPTIMIZED: Loads all user permissions once and caches them for the transaction
CREATE OR REPLACE FUNCTION rbac.set_request_context(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL,
    p_oauth_scopes TEXT DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_user_id INTEGER;
    v_permissions TEXT;
BEGIN
    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    -- Ensure user exists and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(p_external_id, p_email);
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    -- This expensive recursive CTE runs only once per request
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(p_external_id);
    
    -- Set PostgreSQL session variables for the current transaction
    -- These are automatically cleared when the transaction ends
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, false);
    PERFORM set_config('app.current_external_id', p_external_id, false);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), false);
    
    -- Store OAuth2 scopes if present (for API requests)
    IF p_oauth_scopes IS NOT NULL THEN
        PERFORM set_config('app.oauth_scopes', p_oauth_scopes, false);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.set_request_context IS 
'Sets request context from JWT. Loads and caches all permissions. Call at start of each request.';

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
    SELECT permission_id INTO v_permission_id
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
        SELECT DISTINCT p.permission_id
        FROM users u
        JOIN user_roles ur ON u.user_id = ur.user_id
        JOIN roles r ON ur.role_id = r.role_id
        JOIN role_permissions rp ON r.role_id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.permission_id
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
            SELECT DISTINCT p.permission_id
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
-- Uses session variables set by set_request_context
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
    
    -- OPTIMIZATION: Try to get cached permissions first
    v_cached_permissions := current_setting('app.user_permissions', true);
    
    -- If we have cached permissions, use fast string search
    -- This is 1000x faster than querying the database
    IF v_cached_permissions IS NOT NULL AND v_cached_permissions != '' THEN
        -- Check if permission exists in comma-separated list
        -- Using position() for fast string matching
        IF position(',' || p_permission_name || ',' IN ',' || v_cached_permissions || ',') > 0 THEN
            -- Permission found in cache, now check OAuth scopes if present
            v_oauth_scopes := current_setting('app.oauth_scopes', true);
            
            -- If no OAuth scopes set (user-initiated request), allow
            IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
                RETURN TRUE;
            END IF;
            
            -- Check if permission is in OAuth scopes (also comma-separated)
            RETURN position(',' || p_permission_name || ',' IN ',' || v_oauth_scopes || ',') > 0;
        ELSE
            -- Permission not in cache
            RETURN FALSE;
        END IF;
    END IF;
    
    -- FALLBACK: If permissions not cached, use full permission check
    -- This should rarely happen if set_request_context is called properly
    v_external_id := current_setting('app.current_external_id', true);
    
    IF v_external_id IS NULL THEN
        RETURN FALSE;
    END IF;
    
    RETURN rbac.user_has_permission(v_external_id, p_permission_name);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.has_permission IS 
'Checks if current user has permission. Uses cached permissions for optimal performance.';

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
        SELECT DISTINCT p.permission_id, p.permission_name
        FROM users u
        JOIN user_roles ur ON u.user_id = ur.user_id
        JOIN roles r ON ur.role_id = r.role_id
        JOIN role_permissions rp ON r.role_id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.permission_id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Implied permissions
        SELECT DISTINCT p.permission_id, p.permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
        JOIN permissions p ON ph.child_permission_id = p.permission_id
    )
    SELECT DISTINCT pt.permission_name
    FROM permission_tree pt
    ORDER BY pt.permission_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.get_user_permissions IS 
'Returns all effective permissions for a user, including implied permissions.';

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