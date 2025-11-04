-- =====================================================
-- Description: Seeds initial permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (permission_id, permission_name, description) VALUES
    (1, 'user:read', 'Permission to read user information'),
    (2, 'user:manage', 'Permission to manage users (includes read, create, update, delete)'),
    (3, 'public:read', 'Permission to read public information'),
    (4, 'admin', 'Permission to manage administrative functions');

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage (Id=2) implies user:read (Id=1)

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

-- User role gets user:read and public:read permissions
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (1, 1),
    (1, 3);

-- Administrator role gets user:manage, public:read, and admin permissions
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (2, 2),
    (2, 3),
    (2, 4);

-- =====================================================
-- SEED MODULES
-- =====================================================

INSERT INTO modules (module_id, module_name, description, view_permission) VALUES
    (1, '_core', 'Core', 'admin'),
    (2, '_public', 'Public', 'user:read');

-- =====================================================
-- RESET SEQUENCES (Reserve Ids < 10000 for internal use)
-- =====================================================

SELECT setval('permissions_permission_id_seq', GREATEST(10000, (SELECT MAX(permission_id) + 1 FROM permissions)));
SELECT setval('roles_role_id_seq', GREATEST(10000, (SELECT MAX(role_id) + 1 FROM roles)));
SELECT setval('modules_module_id_seq', GREATEST(1000, (SELECT MAX(module_id) + 1 FROM modules)));