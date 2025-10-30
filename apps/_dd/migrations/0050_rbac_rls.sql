-- =====================================================
-- Description: Enable Row Level Security (RLS) policies
-- =====================================================

-- =====================================================
-- GRANT BYPASSRLS TO FUNCTION OWNER
-- =====================================================
-- This allows SECURITY DEFINER functions to bypass RLS and avoid recursion
-- Replace 'postgres' with your actual application database role if different
-- Note: This must be run by a superuser

ALTER ROLE postgres BYPASSRLS;

-- If you have a specific application role (e.g., 'app_user'), use that instead:
-- ALTER ROLE app_user BYPASSRLS;

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
-- MODULES - public:read for SELECT, admin:manage for others
-- =====================================================

CREATE POLICY modules_select_policy ON modules
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('public:read')));

CREATE POLICY modules_insert_policy ON modules
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY modules_update_policy ON modules
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY modules_delete_policy ON modules
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

-- =====================================================
-- USERS - user:read for SELECT, user:manage for others
-- =====================================================

CREATE POLICY users_select_policy ON users
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('user:read')));

CREATE POLICY users_insert_policy ON users
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_update_policy ON users
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('user:manage')))
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_delete_policy ON users
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('user:manage')));

-- =====================================================
-- PERMISSIONS - admin:manage for all operations
-- =====================================================

CREATE POLICY permissions_select_policy ON permissions
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

CREATE POLICY permissions_insert_policy ON permissions
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY permissions_update_policy ON permissions
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY permissions_delete_policy ON permissions
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

-- =====================================================
-- ROLES - admin:manage for all operations
-- =====================================================

CREATE POLICY roles_select_policy ON roles
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

CREATE POLICY roles_insert_policy ON roles
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY roles_update_policy ON roles
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY roles_delete_policy ON roles
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

-- =====================================================
-- USER_ROLES - admin:manage for all operations
-- =====================================================

CREATE POLICY user_roles_select_policy ON user_roles
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

CREATE POLICY user_roles_insert_policy ON user_roles
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY user_roles_update_policy ON user_roles
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY user_roles_delete_policy ON user_roles
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

-- =====================================================
-- ROLE_PERMISSIONS - admin:manage for all operations
-- =====================================================

CREATE POLICY role_permissions_select_policy ON role_permissions
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

CREATE POLICY role_permissions_insert_policy ON role_permissions
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY role_permissions_update_policy ON role_permissions
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY role_permissions_delete_policy ON role_permissions
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

-- =====================================================
-- PERMISSION_HIERARCHY - admin:manage for all operations
-- =====================================================

CREATE POLICY permission_hierarchy_select_policy ON permission_hierarchy
    FOR SELECT
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));

CREATE POLICY permission_hierarchy_insert_policy ON permission_hierarchy
    FOR INSERT
    TO authenticated
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY permission_hierarchy_update_policy ON permission_hierarchy
    FOR UPDATE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')))
    WITH CHECK ((select rbac.has_permission('admin:manage')));

CREATE POLICY permission_hierarchy_delete_policy ON permission_hierarchy
    FOR DELETE
    TO authenticated
    USING ((select rbac.has_permission('admin:manage')));