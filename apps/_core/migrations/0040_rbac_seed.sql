-- =====================================================
-- Description: Seeds initial permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (id, permission_name, description) VALUES
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

INSERT INTO roles (id, role_name, description) VALUES
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

INSERT INTO modules (id, module_name, description, view_permission, logo_url, logo_color) VALUES
    (1, '_core', 'Core', 'admin', 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNmZmZmZmYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBjbGFzcz0ibHVjaWRlIGx1Y2lkZS1zZXR0aW5ncy1pY29uIGx1Y2lkZS1zZXR0aW5ncyI+PHBhdGggZD0iTTkuNjcxIDQuMTM2YTIuMzQgMi4zNCAwIDAgMSA0LjY1OSAwIDIuMzQgMi4zNCAwIDAgMCAzLjMxOSAxLjkxNSAyLjM0IDIuMzQgMCAwIDEgMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAgMCAzLjgzMSAyLjM0IDIuMzQgMCAwIDEtMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAtMy4zMTkgMS45MTUgMi4zNCAyLjM0IDAgMCAxLTQuNjU5IDAgMi4zNCAyLjM0IDAgMCAwLTMuMzItMS45MTUgMi4zNCAyLjM0IDAgMCAxLTIuMzMtNC4wMzMgMi4zNCAyLjM0IDAgMCAwIDAtMy44MzFBMi4zNCAyLjM0IDAgMCAxIDYuMzUgNi4wNTFhMi4zNCAyLjM0IDAgMCAwIDMuMzE5LTEuOTE1Ii8+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMyIvPjwvc3ZnPg==', '#e42528'),
    (2, '_public', 'Public', 'user:read', NULL, NULL);

-- =====================================================
-- RESET SEQUENCES (Reserve Ids < 10000 for internal use)
-- =====================================================

SELECT setval('permissions_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM permissions)));
SELECT setval('roles_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM roles)));
SELECT setval('modules_id_seq', GREATEST(1000, (SELECT MAX(id) + 1 FROM modules)));