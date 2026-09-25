-- Test public.get_module_cubes() function
--
-- Part 1 uses the persisted nwind module (slug 'nwind', 11 entities; every
-- reference_table points inside the module) as user2 (nwind:view).
-- Part 2 creates an in-transaction module 'cube_probe' with two entities, the
-- second referencing the first, to pin down dedup and exact cardinality.
BEGIN;

SELECT plan(10);

select authenticate_as('user2');

-- =====================================================
-- TEST: get_module_cubes() returns schemas for the nwind cube entities
-- =====================================================

-- Test 1: get_module_cubes() returns at least one row for a known module (slug-based lookup)
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cubes('nwind')),
    'get_module_cubes(''nwind'') should return at least one row'
);

-- Test 2: the cube covers exactly the 11 nwind entities (set equality)
SELECT set_eq(
    $$SELECT s->'table'->>'table_name' FROM public.get_module_cubes('nwind') AS s$$,
    ARRAY['categories', 'customers', 'employee_territories', 'employees', 'order_details',
          'orders', 'products', 'regions', 'shippers', 'suppliers', 'territories'],
    'nwind module cube should contain exactly the 11 nwind entity schemas'
);

-- Test 3: no entity appears twice (every reference_table is itself a module entity)
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('nwind')),
    11,
    'nwind module cube should have exactly 11 schemas (no duplicates for referenced entities)'
);

-- Test 4: get_module_cubes() does NOT match by module_name — only by module_slug.
-- The Northwind module has slug 'nwind'; passing 'Northwind' (the name) must return no rows.
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('Northwind')),
    0,
    'get_module_cubes(''Northwind'') should return 0 rows because lookup is by slug, not name'
);

-- Test 5: get_module_cubes() returns empty set for unknown module slug
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('nonexistent_module')),
    0,
    'get_module_cubes() should return empty set for unknown module slug'
);

-- =====================================================
-- SETUP: in-transaction module with two entities
--   cube_probe_item  – standalone
--   cube_probe_entry – references cube_probe_item (reference field)
-- =====================================================

select authenticate_as('user3');

INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Cube Probe', 'cube_probe', 'Ephemeral module for get_module_cubes tests', 'public:read');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column
) VALUES (
    'cube_probe_item', 'item', 'Cube Probe Item', 'Cube Probe Items', 'Referenced entity',
    (SELECT id FROM modules WHERE module_slug = 'cube_probe'), 'public:read', 'admin', 'id', 'item_name'
);

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column
) VALUES (
    'cube_probe_entry', 'entry', 'Cube Probe Entry', 'Cube Probe Entries', 'Referencing entity',
    (SELECT id FROM modules WHERE module_slug = 'cube_probe'), 'public:read', 'admin', 'id', 'entry_name'
);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('cube_probe_entry', 'item_ref', 'Item', 'reference', 'cube_probe_item', 'restrict', 10);

-- =====================================================
-- TEST: dedup + exact cardinality on the probe module
-- =====================================================

-- Test 6: exactly 2 schemas
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('cube_probe')),
    2,
    'cube_probe module cube should have exactly 2 schemas (cube_probe_item and cube_probe_entry)'
);

-- Test 7: the two schemas are the two module entities
SELECT set_eq(
    $$SELECT s->'table'->>'table_name' FROM public.get_module_cubes('cube_probe') AS s$$,
    ARRAY['cube_probe_item', 'cube_probe_entry'],
    'cube_probe module cube should contain cube_probe_item and cube_probe_entry'
);

-- Test 8: the referenced entity appears exactly once although it is both a module
-- entity and the reference_table of cube_probe_entry.item_ref
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('cube_probe') AS s
     WHERE s->'table'->>'table_name' = 'cube_probe_item'),
    1,
    'cube_probe_item should appear exactly once in the cube even though it is referenced'
);

-- Test 9: the referencing entity appears exactly once too
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('cube_probe') AS s
     WHERE s->'table'->>'table_name' = 'cube_probe_entry'),
    1,
    'cube_probe_entry should appear exactly once in the cube'
);

-- Test 10: the probe module is public:read, so a plain user (user1) sees both schemas as well
select authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('cube_probe')),
    2,
    'user1 should see both cube_probe schemas (module and entities are public:read)'
);

SELECT * FROM finish();
ROLLBACK;
