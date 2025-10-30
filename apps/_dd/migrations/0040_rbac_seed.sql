-- =====================================================
-- Migration: V002__seed_rbac_permissions_and_roles.sql
-- Description: Seeds initial permissions, roles, and their relationships
-- =====================================================
-- Dependencies: V001__create_rbac_schema.sql

-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (permission_id, permission_name, description) VALUES
    (1, 'user:read', 'Permission to read user information'),
    (2, 'user:manage', 'Permission to manage users (includes read, create, update, delete)');

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage implies user:read

INSERT INTO permission_hierarchy (parent_permission_name, child_permission_name) VALUES
    ('user:manage', 'user:read');

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