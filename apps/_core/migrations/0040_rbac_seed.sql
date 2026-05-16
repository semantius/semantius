-- =====================================================
-- Description: Seeds initial modules, permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED MODULES
-- =====================================================

INSERT INTO modules (id, module_name, module_slug, description, view_permission, logo_url, logo_color, home_page) VALUES
    (1, '_core', 'admin', 'Administration', 'admin', 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNmZmZmZmYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBjbGFzcz0ibHVjaWRlIGx1Y2lkZS1zZXR0aW5ncy1pY29uIGx1Y2lkZS1zZXR0aW5ncyI+PHBhdGggZD0iTTkuNjcxIDQuMTM2YTIuMzQgMi4zNCAwIDAgMSA0LjY1OSAwIDIuMzQgMi4zNCAwIDAgMCAzLjMxOSAxLjkxNSAyLjM0IDIuMzQgMCAwIDEgMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAgMCAzLjgzMSAyLjM0IDIuMzQgMCAwIDEtMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAtMy4zMTkgMS45MTUgMi4zNCAyLjM0IDAgMCAxLTQuNjU5IDAgMi4zNCAyLjM0IDAgMCAwLTMuMzItMS45MTUgMi4zNCAyLjM0IDAgMCAxLTIuMzMtNC4wMzMgMi4zNCAyLjM0IDAgMCAwIDAtMy44MzFBMi4zNCAyLjM0IDAgMCAxIDYuMzUgNi4wNTFhMi4zNCAyLjM0IDAgMCAwIDMuMzE5LTEuOTE1Ii8+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMyIvPjwvc3ZnPg==', '#e42528', '/admin/users');

-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (id, permission_name, description, module_id) VALUES
    (1, 'user:read', 'Read user information', 1),
    (2, 'user:manage', 'Manage users (includes read, create, update, delete)', 1),
    (3, 'public:read', 'Read public information', 1),
    (4, 'admin', 'Manage administrative functions', 1);

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage (Id=2) implies user:read (Id=1)

INSERT INTO permission_hierarchy (including_permission_id, included_permission_id) VALUES
    (2, 1);

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
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (1, 1),
    (1, 3);

-- Administrator role gets user:manage, public:read, and admin permissions
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (2, 2),
    (2, 3),
    (2, 4);

-- =====================================================
-- SET MODULE FK REFERENCES
-- =====================================================

UPDATE modules SET
    admin_permission_id = (SELECT id FROM permissions WHERE permission_name = 'admin'),
    default_admin_role_id = (SELECT id FROM roles WHERE role_name = 'Administrator')
WHERE module_name = '_core';

-- =====================================================
-- RESET SEQUENCES (Reserve Ids < 10000 for internal use)
-- =====================================================

SELECT setval('permissions_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM permissions)));
SELECT setval('roles_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM roles)));
SELECT setval('modules_id_seq', GREATEST(1000, (SELECT MAX(id) + 1 FROM modules)));