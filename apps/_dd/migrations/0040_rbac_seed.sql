-- =====================================================
-- Description: Seeds initial permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (permission_id, permission_name, description) VALUES
    (1, 'user:read', 'Permission to read user information'),
    (2, 'user:manage', 'Permission to manage users (includes read, create, update, delete)');

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage (ID=2) implies user:read (ID=1)

INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id) VALUES
    (2, 1);

-- =====================================================
-- SEED ROLES
-- =====================================================

INSERT INTO roles (role_id, role_name, description) VALUES
    (1, 'User', 'Standard user role with read-only access to user information'),
    (2, 'Administrator', 'Administrator role with full user management capabilities');

-- =====================================================
-- SEED ROLE-PERMISSION MAPPINGS
-- =====================================================

-- User role gets user:read permission
INSERT INTO role_permissions (role_id, permission_id) VALUES (1, 1);

-- Administrator role gets user:manage permission
INSERT INTO role_permissions (role_id, permission_id) VALUES (2, 2);

-- =====================================================
-- RESET SEQUENCES (Reserve IDs < 10000 for internal use)
-- =====================================================

SELECT setval('permissions_permission_id_seq', GREATEST(10000, (SELECT MAX(permission_id) + 1 FROM permissions)));
SELECT setval('roles_role_id_seq', GREATEST(10000, (SELECT MAX(role_id) + 1 FROM roles)));