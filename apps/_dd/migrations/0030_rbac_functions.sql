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
        RAISE EXCEPTION 'Cannot add permission hierarchy: would create a cycle. Permission % cannot be both ancestor and descendant of permission %', 
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
CREATE OR REPLACE FUNCTION rbac.set_request_context(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL,
    p_oauth_scopes TEXT DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Ensure user exists and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(p_external_id, p_email);
    
    -- Set PostgreSQL session variables for the current transaction
    -- These are automatically cleared when the transaction ends
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, false);
    PERFORM set_config('app.current_external_id', p_external_id, false);
    
    -- Store OAuth2 scopes if present (for API requests)
    IF p_oauth_scopes IS NOT NULL THEN
        PERFORM set_config('app.oauth_scopes', p_oauth_scopes, false);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.set_request_context IS 
'Sets request context from JWT. Call at start of each request. Context is transaction-scoped.';

-- =====================================================
-- PERMISSION HIERARCHY
-- =====================================================

-- Add a permission hierarchy relationship
-- Example: customer.manage implies customer.read
CREATE OR REPLACE FUNCTION rbac.add_permission_implies(
    p_parent_permission TEXT,
    p_child_permission TEXT
)
RETURNS void AS $$
BEGIN
    INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id)
    SELECT 
        pp.permission_id,
        cp.permission_id
    FROM permissions pp
    CROSS JOIN permissions cp
    WHERE pp.permission_name = p_parent_permission
      AND cp.permission_name = p_child_permission
    ON CONFLICT (parent_permission_id, child_permission_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.add_permission_implies IS 
'Defines permission hierarchy. Parent permission implies child permission.';

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
    p_resource TEXT,
    p_action TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_oauth_scopes TEXT;
    v_has_permission BOOLEAN;
BEGIN
    -- Check if user has the permission (including hierarchy)
    -- Using recursive CTE to follow the hierarchy
    WITH RECURSIVE permission_tree AS (
        -- Start with direct permissions from roles
        SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
        FROM users u
        JOIN user_roles ur ON u.user_id = ur.user_id
        JOIN roles r ON ur.role_id = r.role_id
        JOIN role_permissions rp ON r.role_id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.permission_id
        WHERE u.external_id = p_external_id
          AND u.is_active = TRUE
          AND r.is_active = TRUE
        
        UNION
        
        -- Add implied permissions (children in hierarchy)
        SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
        JOIN permissions p ON ph.child_permission_id = p.permission_id
    )
    SELECT EXISTS (
        SELECT 1 FROM permission_tree
        WHERE resource = p_resource AND action = p_action
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
            SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
            FROM permissions p
            WHERE p.permission_name = ANY(string_to_array(v_oauth_scopes, ' '))
            
            UNION
            
            -- Add implied permissions
            SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
            FROM permission_tree pt
            JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
            JOIN permissions p ON ph.child_permission_id = p.permission_id
        )
        SELECT 1 FROM permission_tree
        WHERE resource = p_resource AND action = p_action
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.user_has_permission IS 
'Checks if user has permission, considering hierarchy and OAuth scopes.';

-- Check if current request user has permission
-- Uses session variables set by set_request_context
CREATE OR REPLACE FUNCTION rbac.current_user_has_permission(
    p_resource TEXT,
    p_action TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_external_id TEXT;
BEGIN
    v_external_id := current_setting('app.current_external_id', true);
    
    IF v_external_id IS NULL THEN
        RETURN FALSE;
    END IF;
    
    RETURN rbac.user_has_permission(v_external_id, p_resource, p_action);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION rbac.current_user_has_permission IS 
'Checks if current request user has permission. Uses session context.';

-- Require permission or raise exception
-- Use this in application functions to enforce permissions
CREATE OR REPLACE FUNCTION rbac.require_permission(
    p_resource TEXT,
    p_action TEXT
)
RETURNS void AS $$
BEGIN
    IF NOT rbac.current_user_has_permission(p_resource, p_action) THEN
        RAISE EXCEPTION 'Permission denied: %.% required', p_resource, p_action
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
    permission_name TEXT,
    resource TEXT,
    action TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE permission_tree AS (
        -- Direct permissions
        SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
        FROM users u
        JOIN user_roles ur ON u.user_id = ur.user_id
        JOIN roles r ON ur.role_id = r.role_id
        JOIN role_permissions rp ON r.role_id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.permission_id
        WHERE u.external_id = p_external_id
          AND u.is_active = TRUE
          AND r.is_active = TRUE
        
        UNION
        
        -- Implied permissions
        SELECT DISTINCT p.permission_id, p.permission_name, p.resource, p.action
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.parent_permission_id
        JOIN permissions p ON ph.child_permission_id = p.permission_id
    )
    SELECT DISTINCT pt.permission_name, pt.resource, pt.action
    FROM permission_tree pt
    ORDER BY pt.resource, pt.action;
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

-- =====================================================
-- ROLE MANAGEMENT
-- =====================================================

-- Grant a role to a user
CREATE OR REPLACE FUNCTION rbac.grant_role_to_user(
    p_external_id TEXT,
    p_role_name TEXT,
    p_granted_by_external_id TEXT
)
RETURNS void AS $$
DECLARE
    v_granted_by_user_id INTEGER;
BEGIN
    -- Get the user_id of the person granting the role
    SELECT user_id INTO v_granted_by_user_id
    FROM users
    WHERE external_id = p_granted_by_external_id;
    
    INSERT INTO user_roles (user_id, role_id, assigned_by)
    SELECT u.user_id, r.role_id, v_granted_by_user_id
    FROM users u
    CROSS JOIN roles r
    WHERE u.external_id = p_external_id
      AND r.role_name = p_role_name
    ON CONFLICT (user_id, role_id) DO UPDATE
    SET assigned_by = EXCLUDED.assigned_by,
        assigned_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.grant_role_to_user IS 
'Assigns a role to a user.';

-- Revoke a role from a user
CREATE OR REPLACE FUNCTION rbac.revoke_role_from_user(
    p_external_id TEXT,
    p_role_name TEXT
)
RETURNS void AS $$
BEGIN
    DELETE FROM user_roles ur
    USING users u, roles r
    WHERE ur.user_id = u.user_id
      AND ur.role_id = r.role_id
      AND u.external_id = p_external_id
      AND r.role_name = p_role_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.revoke_role_from_user IS 
'Removes a role from a user.';