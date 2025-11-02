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
    USING ((select rbac.has_any_permission(VARIADIC ARRAY['admin', view_permission])));

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