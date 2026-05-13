-- Tests for silo buster refactor: new columns on modules, roles, permission_hierarchy
BEGIN;

SELECT plan(38);

SELECT authenticate_as('user3');

-- =====================================================
-- MODULES: module_type column
-- =====================================================

SELECT has_column('public', 'modules', 'module_type',
    'modules.module_type column exists');

SELECT is(
    (SELECT module_type FROM modules WHERE module_name = '_core'),
    'domain',
    'modules.module_type defaults to domain'
);

-- Test module_type enum constraint
SELECT throws_ok(
    $$INSERT INTO modules (module_name, module_type) VALUES ('bad_type_test', 'invalid')$$,
    '23514',
    NULL,
    'modules.module_type rejects invalid values'
);

-- Test setting module_type to master
INSERT INTO modules (module_name, module_type) VALUES ('master_test', 'master');
SELECT is(
    (SELECT module_type FROM modules WHERE module_name = 'master_test'),
    'master',
    'modules.module_type can be set to master'
);

-- =====================================================
-- MODULES: FK columns
-- =====================================================

SELECT has_column('public', 'modules', 'manage_permission_id',
    'modules.manage_permission_id column exists');

SELECT has_column('public', 'modules', 'admin_permission_id',
    'modules.admin_permission_id column exists');

SELECT has_column('public', 'modules', 'default_viewer_role_id',
    'modules.default_viewer_role_id column exists');

SELECT has_column('public', 'modules', 'default_manager_role_id',
    'modules.default_manager_role_id column exists');

SELECT has_column('public', 'modules', 'default_admin_role_id',
    'modules.default_admin_role_id column exists');

-- FK columns default to NULL
SELECT is(
    (SELECT manage_permission_id FROM modules WHERE module_name = '_core'),
    NULL,
    'modules.manage_permission_id defaults to NULL'
);

SELECT is(
    (SELECT default_viewer_role_id FROM modules WHERE module_name = '_core'),
    NULL,
    'modules.default_viewer_role_id defaults to NULL'
);

-- Test FK referential integrity: set manage_permission_id to a valid permission
UPDATE modules
SET manage_permission_id = (SELECT id FROM permissions WHERE permission_name = 'admin' LIMIT 1)
WHERE module_name = 'master_test';

SELECT is(
    (SELECT manage_permission_id FROM modules WHERE module_name = 'master_test'),
    (SELECT id FROM permissions WHERE permission_name = 'admin' LIMIT 1),
    'modules.manage_permission_id can reference a valid permission'
);

-- Test FK referential integrity: set default_viewer_role_id to a valid role
UPDATE modules
SET default_viewer_role_id = (SELECT id FROM roles WHERE role_name = 'User' LIMIT 1)
WHERE module_name = 'master_test';

SELECT is(
    (SELECT default_viewer_role_id FROM modules WHERE module_name = 'master_test'),
    (SELECT id FROM roles WHERE role_name = 'User' LIMIT 1),
    'modules.default_viewer_role_id can reference a valid role'
);

-- =====================================================
-- ROLES: slug column
-- =====================================================

SELECT has_column('public', 'roles', 'slug',
    'roles.slug column exists');

-- Test auto-generation from role_name
SELECT is(
    (SELECT slug FROM roles WHERE role_name = 'User'),
    'user',
    'roles.slug auto-generated from role_name (User -> user)'
);

SELECT is(
    (SELECT slug FROM roles WHERE role_name = 'Sales User'),
    'sales_user',
    'roles.slug auto-generated from role_name (Sales User -> sales_user)'
);

-- Test explicit slug
INSERT INTO roles (role_name, slug) VALUES ('Custom Role Test', 'custom_slug_test');
SELECT is(
    (SELECT slug FROM roles WHERE role_name = 'Custom Role Test'),
    'custom_slug_test',
    'roles.slug keeps explicitly provided value'
);

-- Test slug uniqueness
SELECT throws_ok(
    $$INSERT INTO roles (role_name, slug) VALUES ('Another Role', 'custom_slug_test')$$,
    '23505',
    NULL,
    'roles.slug must be unique'
);

-- Test slug format validation
SELECT throws_ok(
    $$INSERT INTO roles (role_name, slug) VALUES ('Bad Slug Role', 'Invalid Slug!')$$,
    '23514',
    NULL,
    'roles.slug rejects invalid characters'
);

-- =====================================================
-- ROLES: origin column
-- =====================================================

SELECT has_column('public', 'roles', 'origin',
    'roles.origin column exists');

-- Test default value
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'User'),
    'user',
    'roles.origin defaults to user'
);

-- Test setting origin to default
INSERT INTO roles (role_name, origin) VALUES ('Scaffold Role Test', 'default');
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'Scaffold Role Test'),
    'default',
    'roles.origin can be set to default'
);

-- Test origin enum constraint
SELECT throws_ok(
    $$INSERT INTO roles (role_name, origin) VALUES ('Bad Origin Role', 'invalid')$$,
    '23514',
    NULL,
    'roles.origin rejects invalid values'
);

-- =====================================================
-- PERMISSION_HIERARCHY: origin column
-- =====================================================

SELECT has_column('public', 'permission_hierarchy', 'origin',
    'permission_hierarchy.origin column exists');

-- Test default value
SELECT is(
    (SELECT DISTINCT origin FROM permission_hierarchy LIMIT 1),
    'user',
    'permission_hierarchy.origin defaults to user'
);

-- Test inserting with specific origin values
INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id, origin)
SELECT p1.id, p2.id, 'model'
FROM permissions p1, permissions p2
WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:read';

SELECT is(
    (SELECT origin FROM permission_hierarchy ph
     JOIN permissions p1 ON ph.parent_permission_id = p1.id
     JOIN permissions p2 ON ph.child_permission_id = p2.id
     WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:read'),
    'model',
    'permission_hierarchy.origin can be set to model'
);

-- Test origin enum constraint
SELECT throws_ok(
    $$INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id, origin)
      SELECT p1.id, p2.id, 'invalid'
      FROM permissions p1, permissions p2
      WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:manage'$$,
    '23514',
    NULL,
    'permission_hierarchy.origin rejects invalid values'
);

-- Test scaffold origin
INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id, origin)
SELECT p1.id, p2.id, 'scaffold'
FROM permissions p1, permissions p2
WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:manage';

SELECT is(
    (SELECT origin FROM permission_hierarchy ph
     JOIN permissions p1 ON ph.parent_permission_id = p1.id
     JOIN permissions p2 ON ph.child_permission_id = p2.id
     WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:manage'),
    'scaffold',
    'permission_hierarchy.origin can be set to scaffold'
);

-- =====================================================
-- FIELD METADATA: new columns have field metadata
-- =====================================================

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'modules' AND field_name = 'module_type'),
    1,
    'modules.module_type has field metadata'
);

SELECT is(
    (SELECT format FROM fields WHERE table_name = 'modules' AND field_name = 'module_type'),
    'enum',
    'modules.module_type field metadata has format=enum'
);

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'modules' AND field_name = 'module_type'),
    'readonly',
    'modules.module_type field metadata has input_type=readonly'
);

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'modules' AND field_name = 'manage_permission_id'),
    1,
    'modules.manage_permission_id has field metadata'
);

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'roles' AND field_name = 'slug'),
    1,
    'roles.slug has field metadata'
);

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'roles' AND field_name = 'slug'),
    'readonly',
    'roles.slug field metadata has input_type=readonly'
);

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'roles' AND field_name = 'origin'),
    1,
    'roles.origin has field metadata'
);

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'roles' AND field_name = 'origin'),
    'readonly',
    'roles.origin field metadata has input_type=readonly'
);

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'permission_hierarchy' AND field_name = 'origin'),
    1,
    'permission_hierarchy.origin has field metadata'
);

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'permission_hierarchy' AND field_name = 'origin'),
    'readonly',
    'permission_hierarchy.origin field metadata has input_type=readonly'
);

SELECT * FROM finish();
ROLLBACK;
