-- Tests for model v3 refactor: new columns on modules, roles, permission_hierarchy
BEGIN;

SELECT plan(54);

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

-- FK columns default to NULL (except admin_permission_id which is set in seed)
SELECT is(
    (SELECT manage_permission_id FROM modules WHERE module_name = '_core'),
    NULL,
    'modules.manage_permission_id defaults to NULL for _core'
);

SELECT is(
    (SELECT default_viewer_role_id FROM modules WHERE module_name = '_core'),
    NULL,
    'modules.default_viewer_role_id defaults to NULL for _core'
);

-- _core module has admin_permission_id and default_admin_role_id set in seed
SELECT is(
    (SELECT admin_permission_id FROM modules WHERE module_name = '_core'),
    (SELECT id FROM permissions WHERE permission_name = 'admin' LIMIT 1),
    'modules.admin_permission_id is set to admin permission for _core'
);

SELECT is(
    (SELECT default_admin_role_id FROM modules WHERE module_name = '_core'),
    (SELECT id FROM roles WHERE role_name = 'Administrator' LIMIT 1),
    'modules.default_admin_role_id is set to Administrator role for _core'
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
    'system',
    'seed roles have origin=system'
);

-- Test setting origin to model_master
INSERT INTO roles (role_name, origin) VALUES ('Scaffold Role Test', 'model_master');
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'Scaffold Role Test'),
    'model_master',
    'roles.origin can be set to model_master'
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

-- Test model_master origin
INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id, origin)
SELECT p1.id, p2.id, 'model_master'
FROM permissions p1, permissions p2
WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:manage';

SELECT is(
    (SELECT origin FROM permission_hierarchy ph
     JOIN permissions p1 ON ph.parent_permission_id = p1.id
     JOIN permissions p2 ON ph.child_permission_id = p2.id
     WHERE p1.permission_name = 'user:manage' AND p2.permission_name = 'sales:manage'),
    'model_master',
    'permission_hierarchy.origin can be set to model_master'
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

-- =====================================================
-- §10.2 VALIDATION RULES: stored on entities
-- =====================================================

-- Verify validation_rules are set on roles entity
SELECT is(
    (SELECT jsonb_array_length(validation_rules) FROM entities WHERE table_name = 'roles'),
    2,
    'roles entity has 2 validation rules'
);

SELECT is(
    (SELECT validation_rules->0->>'code' FROM entities WHERE table_name = 'roles'),
    'origin_immutable_roles',
    'roles validation rule 0 is origin_immutable_roles'
);

SELECT is(
    (SELECT validation_rules->1->>'code' FROM entities WHERE table_name = 'roles'),
    'system_role_slug_immutable',
    'roles validation rule 1 is system_role_slug_immutable'
);

-- Verify validation_rules are set on permission_hierarchy entity
SELECT is(
    (SELECT jsonb_array_length(validation_rules) FROM entities WHERE table_name = 'permission_hierarchy'),
    1,
    'permission_hierarchy entity has 1 validation rule'
);

SELECT is(
    (SELECT validation_rules->0->>'code' FROM entities WHERE table_name = 'permission_hierarchy'),
    'origin_immutable_hierarchy',
    'permission_hierarchy validation rule 0 is origin_immutable_hierarchy'
);

-- Verify source_module tag is set
SELECT is(
    (SELECT validation_rules->0->>'source_module' FROM entities WHERE table_name = 'roles'),
    'platform',
    'roles validation rules have source_module=platform'
);

SELECT is(
    (SELECT validation_rules->0->>'source_module' FROM entities WHERE table_name = 'permission_hierarchy'),
    'platform',
    'permission_hierarchy validation rules have source_module=platform'
);

-- =====================================================
-- §10.2 RULE ENFORCEMENT: roles.origin
-- =====================================================

-- INSERT with origin=user should succeed (default)
INSERT INTO roles (role_name, origin) VALUES ('Rule Test User Role', 'user');
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'Rule Test User Role'),
    'user',
    'INSERT role with origin=user succeeds'
);

-- UPDATE origin from user to model should succeed (auto-claim path)
UPDATE roles SET origin = 'model' WHERE role_name = 'Rule Test User Role';
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'Rule Test User Role'),
    'model',
    'UPDATE origin from user to model succeeds (auto-claim path)'
);

-- UPDATE origin from model to user should be blocked
SELECT throws_ok(
    $$UPDATE roles SET origin = 'user' WHERE role_name = 'Rule Test User Role'$$,
    '23514',
    NULL,
    'UPDATE origin from model to user is blocked by validation rule'
);

-- Test user -> model_master transition
INSERT INTO roles (role_name, origin) VALUES ('Rule Test MM Role', 'user');
UPDATE roles SET origin = 'model_master' WHERE role_name = 'Rule Test MM Role';
SELECT is(
    (SELECT origin FROM roles WHERE role_name = 'Rule Test MM Role'),
    'model_master',
    'UPDATE origin from user to model_master succeeds (auto-claim path)'
);

-- =====================================================
-- §10.2 RULE ENFORCEMENT: roles.slug immutability for system roles
-- =====================================================

-- Changing slug on a model-origin role should be blocked
SELECT throws_ok(
    $$UPDATE roles SET slug = 'changed_slug' WHERE role_name = 'Rule Test User Role'$$,
    '23514',
    NULL,
    'Changing slug on model-origin role is blocked'
);

-- Changing slug on a user-origin role should succeed
INSERT INTO roles (role_name, origin) VALUES ('Mutable Slug Role', 'user');
UPDATE roles SET slug = 'new_slug_value' WHERE role_name = 'Mutable Slug Role';
SELECT is(
    (SELECT slug FROM roles WHERE role_name = 'Mutable Slug Role'),
    'new_slug_value',
    'Changing slug on user-origin role succeeds'
);

-- =====================================================
-- §10.2 RULE ENFORCEMENT: permission_hierarchy.origin
-- =====================================================

-- UPDATE origin on permission_hierarchy should be blocked
SELECT throws_ok(
    $$UPDATE permission_hierarchy
      SET origin = 'model_master'
      WHERE id = (SELECT id FROM permission_hierarchy LIMIT 1)$$,
    '23514',
    NULL,
    'UPDATE origin on permission_hierarchy is blocked by validation rule'
);

SELECT * FROM finish();
ROLLBACK;
