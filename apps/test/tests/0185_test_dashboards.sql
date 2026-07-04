-- Test the dashboards entity. dashboards lived in the separate `cloud` app and
-- had no test coverage; folding cloud into `_core` brings it under the suite.
-- Asserts the entity is registered + managed, its field metadata, the DD-built
-- foreign keys (and their ON DELETE behavior), the get_schema contract, and a
-- positive FK insert.
BEGIN;

SELECT plan(13);

SELECT authenticate_as('user3');

-- Test 1: dashboards entity metadata exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'dashboards')),
    'dashboards entity metadata should exist'
);

-- Test 2: dashboards is a managed entity (so the DD machinery builds its FKs/RLS)
SELECT ok(
    (SELECT managed FROM entities WHERE table_name = 'dashboards'),
    'dashboards entity should be managed=TRUE'
);

-- Test 3: dashboards table is created in the database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'dashboards')),
    'dashboards table should exist in database'
);

-- Test 4: config field has json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'dashboards' AND field_name = 'config'),
    'dashboards.config should have json format'
);

-- Test 5: position field has int32 format
SELECT ok(
    (SELECT format = 'int32' FROM fields WHERE table_name = 'dashboards' AND field_name = 'position'),
    'dashboards.position should have int32 format'
);

-- Test 6: module_id references the modules entity
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'dashboards' AND field_name = 'module_id'),
    'modules',
    'dashboards.module_id should reference modules'
);

-- Test 7: module_id uses cascade delete mode
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'dashboards' AND field_name = 'module_id'),
    'cascade',
    'dashboards.module_id reference_delete_mode should be cascade'
);

-- Test 8: view_permission references the permissions entity
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'dashboards' AND field_name = 'view_permission'),
    'permissions',
    'dashboards.view_permission should reference permissions'
);

-- Test 9: view_permission uses clear delete mode
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'dashboards' AND field_name = 'view_permission'),
    'clear',
    'dashboards.view_permission reference_delete_mode should be clear'
);

-- Test 10: DD trigger built the module_id FK with ON DELETE CASCADE
SELECT is(
    (SELECT rc.delete_rule
       FROM information_schema.referential_constraints rc
      WHERE rc.constraint_name = 'dashboards_module_id_fkey'),
    'CASCADE',
    'dashboards.module_id FK should be ON DELETE CASCADE'
);

-- Test 11: DD trigger built the view_permission FK with ON DELETE SET NULL (clear)
SELECT is(
    (SELECT rc.delete_rule
       FROM information_schema.referential_constraints rc
      WHERE rc.constraint_name = 'dashboards_view_permission_fkey'),
    'SET NULL',
    'dashboards.view_permission FK should be ON DELETE SET NULL'
);

-- Test 12: get_schema('dashboards') exposes all four declared properties
SELECT ok(
    (public.get_schema('dashboards')::jsonb)->'properties'
        ?& ARRAY['config', 'position', 'module_id', 'view_permission'],
    'get_schema(dashboards) should expose config/position/module_id/view_permission'
);

-- Test 13: a valid row inserts (module_id -> existing _core module, nullable view_permission)
SELECT lives_ok(
    $$INSERT INTO dashboards (label, config, position, module_id, view_permission)
      VALUES ('Test Dashboard', '{"widgets": []}'::jsonb, 0, 1, NULL)$$,
    'Inserting a dashboard with a valid module_id should succeed'
);

SELECT * FROM finish();
ROLLBACK;
