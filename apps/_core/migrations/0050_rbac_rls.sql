-- =====================================================
-- Description: Enable Row Level Security (RLS) policies
-- =====================================================

-- =====================================================
-- VERIFY BYPASSRLS ON FUNCTION OWNER
-- =====================================================
-- This check ensures SECURITY DEFINER functions can bypass RLS and avoid recursion
-- On Supabase: The 'postgres' role automatically has BYPASSRLS - no ALTER ROLE needed
-- On Neon: Roles created via Console/CLI/API inherit BYPASSRLS from 'neon_superuser' (projects after Aug 15, 2023)
-- On self-hosted: You may need to run: ALTER ROLE your_role BYPASSRLS;
-- Note: This verification will halt the script if BYPASSRLS is not available

DO $$
BEGIN
  ASSERT (
    SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user
  ), 'Current role does not have BYPASSRLS privilege';
END $$;


-- =====================================================
-- ENABLE RLS ON ALL RBAC TABLES
-- =====================================================

ALTER TABLE modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_hierarchy ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- MODULES - use view_permission column for SELECT, admin for others
-- =====================================================

CREATE POLICY modules_select_policy ON modules
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_any_permission('admin', view_permission)));

CREATE POLICY modules_insert_policy ON modules
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY modules_update_policy ON modules
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY modules_delete_policy ON modules
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- USERS - user:read for SELECT, user:manage for others
-- =====================================================

CREATE POLICY users_select_policy ON users
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('user:read')));

CREATE POLICY users_insert_policy ON users
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_update_policy ON users
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('user:manage')))
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_delete_policy ON users
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('user:manage')));

-- =====================================================
-- PERMISSIONS - admin for all operations
-- =====================================================

CREATE POLICY permissions_select_policy ON permissions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY permissions_insert_policy ON permissions
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permissions_update_policy ON permissions
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permissions_delete_policy ON permissions
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- ROLES - admin for all operations
-- =====================================================

CREATE POLICY roles_select_policy ON roles
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY roles_insert_policy ON roles
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY roles_update_policy ON roles
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY roles_delete_policy ON roles
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- USER_ROLES - admin for all operations
-- =====================================================

CREATE POLICY user_roles_select_policy ON user_roles
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_insert_policy ON user_roles
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_update_policy ON user_roles
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_delete_policy ON user_roles
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- ROLE_PERMISSIONS - admin for all operations
-- =====================================================

CREATE POLICY role_permissions_select_policy ON role_permissions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_insert_policy ON role_permissions
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_update_policy ON role_permissions
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_delete_policy ON role_permissions
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- PERMISSION_HIERARCHY - admin for all operations
-- =====================================================

CREATE POLICY permission_hierarchy_select_policy ON permission_hierarchy
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_insert_policy ON permission_hierarchy
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_update_policy ON permission_hierarchy
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_delete_policy ON permission_hierarchy
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- _VERSIONS - admin can query, deny insert/update/delete
-- =====================================================

CREATE POLICY versions_select_policy ON _versions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- No INSERT, UPDATE, or DELETE policies - these operations are denied to all semantius_user roles

-- =====================================================
-- GRANT TABLE ACCESS TO semantius_user ROLE
-- =====================================================
-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO semantius_user;

-- Grant table permissions (RLS policies will further restrict access)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO semantius_user;

-- Grant sequence usage for auto-increment columns
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO semantius_user;

-- Ensure future tables also get these grants
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO semantius_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT ON SEQUENCES TO semantius_user;

-- =====================================================
-- TRIGGER: Auto-assign role 1 (User) to new users
-- =====================================================
-- When a new user is inserted, automatically assign them to role 1 (User role)
-- This ensures all users have at least the basic User role

CREATE OR REPLACE FUNCTION rbac.auto_assign_user_role()
RETURNS TRIGGER AS $$
DECLARE
    v_is_first_user BOOLEAN;
BEGIN
    -- Insert the user into role 1 (User) if not already assigned
    -- Note: Role ID 1 is explicitly seeded in 0040_rbac_seed.sql and reserved for the User role
    INSERT INTO user_roles (user_id, role_id)
    VALUES (NEW.id, 1)
    ON CONFLICT (user_id, role_id) DO NOTHING;
    
    -- Check if this is the first user (no other users have last_seen set)
    -- If this is the first user, also assign Administrator role (role ID 2)
    SELECT NOT EXISTS (
        SELECT 1 FROM users 
        WHERE id != NEW.id 
        AND last_seen IS NOT NULL
    ) INTO v_is_first_user;
    
    IF v_is_first_user THEN
        -- Assign Administrator role (role ID 2) to the first user
        INSERT INTO user_roles (user_id, role_id)
        VALUES (NEW.id, 2)
        ON CONFLICT (user_id, role_id) DO NOTHING;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.auto_assign_user_role IS 
'Trigger function to automatically assign role 1 (User) to newly created users. Also assigns role 2 (Administrator) to the first user accessing the system.';

CREATE TRIGGER auto_assign_user_role_trigger
    AFTER INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION rbac.auto_assign_user_role();

COMMENT ON TRIGGER auto_assign_user_role_trigger ON users IS
'Automatically assigns role 1 (User) to new users after insertion.';

-- =====================================================
-- TRIGGER: Prevent deletion of role 1 from any user
-- =====================================================
-- This ensures that no user can have their User role removed,
-- maintaining the security principle that all users must have basic access

CREATE OR REPLACE FUNCTION rbac.prevent_user_role_deletion()
RETURNS TRIGGER AS $$
BEGIN
    -- Check if attempting to delete role 1 (User role)
    -- Note: Role ID 1 is explicitly seeded in 0040_rbac_seed.sql and reserved for the User role
    IF OLD.role_id = 1 THEN
        RAISE EXCEPTION 'Cannot delete role 1 (User) from user. All users must have the User role.'
            USING ERRCODE = 'P0001';
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.prevent_user_role_deletion IS 
'Trigger function to prevent deletion of role 1 (User) from any user.';

CREATE TRIGGER prevent_user_role_deletion_trigger
    BEFORE DELETE ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.prevent_user_role_deletion();

COMMENT ON TRIGGER prevent_user_role_deletion_trigger ON user_roles IS
'Prevents deletion of role 1 (User) from any user in user_roles table.';

-- =====================================================
-- TRIGGER: Default assigned_by to current user
-- =====================================================
-- When a user_role record is inserted without an assigned_by value,
-- automatically set it to the current user ID from the session context

CREATE OR REPLACE FUNCTION rbac.default_assigned_by()
RETURNS TRIGGER AS $$
DECLARE
    v_current_user_id INTEGER;
BEGIN
    IF NEW.assigned_by IS NULL THEN
        BEGIN
            v_current_user_id := rbac.user_id();
        EXCEPTION WHEN OTHERS THEN
            v_current_user_id := NULL;
        END;
        IF v_current_user_id IS NOT NULL THEN
            NEW.assigned_by := v_current_user_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rbac.default_assigned_by IS
'Trigger function to default assigned_by to the current user ID when not explicitly provided.';

CREATE TRIGGER default_assigned_by_trigger
    BEFORE INSERT ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_assigned_by();

COMMENT ON TRIGGER default_assigned_by_trigger ON user_roles IS
'Defaults assigned_by to the current session user when not provided on insert.';