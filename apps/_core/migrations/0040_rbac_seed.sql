-- =====================================================
-- Description: Seeds initial modules, permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED MODULES
-- =====================================================

INSERT INTO modules (id, module_name, module_slug, description, view_permission, icon_name, logo_color, home_page) VALUES
    (1, '_core', 'admin', 'Administration', 'admin', 'settings', '#029948', '/admin/users');

-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('user:read', 'Read user information', 1),
    ('user:manage', 'Manage users (includes read, create, update, delete)', 1),
    ('public:read', 'Read public information', 1),
    ('admin', 'Manage administrative functions', 1);

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage implies user:read

INSERT INTO permission_hierarchy (including_permission_name, included_permission_name) VALUES
    ('user:manage', 'user:read');

-- =====================================================
-- SEED ROLES
-- =====================================================

INSERT INTO roles (id, role_name, description, origin, module_id) VALUES
    (1, 'User', 'Standard user role with read-only access', 'system', 1),
    (2, 'Administrator', 'Administrator role with full management capabilities', 'system', 1);

-- =====================================================
-- SEED ROLE-PERMISSION MAPPINGS
-- =====================================================

-- User role gets user:read and public:read permissions
INSERT INTO role_permissions (role_id, permission_name) VALUES 
    (1, 'user:read'),
    (1, 'public:read');

-- Administrator role gets user:manage, public:read, and admin permissions
INSERT INTO role_permissions (role_id, permission_name) VALUES 
    (2, 'user:manage'),
    (2, 'public:read'),
    (2, 'admin');

-- =====================================================
-- SET MODULE FK REFERENCES
-- =====================================================

UPDATE modules SET
    admin_permission = 'admin',
    default_admin_role_id = (SELECT id FROM roles WHERE role_name = 'Administrator')
WHERE module_name = '_core';

-- =====================================================
-- RESET SEQUENCES (Reserve Ids < 10000 for internal use)
-- =====================================================

SELECT setval('roles_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM roles)));
SELECT setval('modules_id_seq', GREATEST(1000, (SELECT MAX(id) + 1 FROM modules)));

-- =====================================================
-- MODULE VIEW PERMISSION FOREIGN KEY
-- =====================================================
-- A module and its view_permission point at each other: the permission's
-- module_id names the module, so the module row has to exist first, and the
-- first module of all is seeded before any permission exists. That is what
-- DEFERRABLE INITIALLY DEFERRED is for - deferred to commit, both rows are
-- there by then - and it is why this one constraint is NO ACTION: RESTRICT
-- never defers. Every other permission foreign key is checked immediately and
-- fails early, because entities and queues are always created after the
-- permissions they name.
--
-- It is created HERE, at the end of the seed, rather than beside the other
-- modules foreign keys in 0020, and that placement is the point. A deferred
-- check is a pending trigger event, and PostgreSQL refuses ALTER TABLE on a
-- table that has one; declaring the constraint before the seed would leave the
-- seed's own INSERT queued and 0050's ALTER TABLE modules ENABLE ROW LEVEL
-- SECURITY - and the ALTERs in 0282 and 0284 - would fail with SQLSTATE 55006.
-- That is invisible when each migration runs in its own transaction and fatal
-- when the extension installer runs all of them in one. ADD CONSTRAINT
-- validates the rows already present with a single scan instead, queuing
-- nothing, so both install paths behave the same from here on.
--
-- Consequence for any caller that creates a module over PostgREST, where each
-- request is its own transaction: name a permission that already exists (the
-- default 'user:read' does), create the module's own permissions, then update
-- the module. A view_permission created in a later request fails at the module
-- request's commit, not on the statement.
ALTER TABLE modules ADD CONSTRAINT modules_view_permission_fkey
    FOREIGN KEY (view_permission) REFERENCES permissions(permission_name)
    ON DELETE NO ACTION ON UPDATE CASCADE
    DEFERRABLE INITIALLY DEFERRED;