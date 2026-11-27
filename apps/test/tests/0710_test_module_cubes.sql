-- The Cube model readers: public.get_module_cubes() and
-- public.get_user_cubes().
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. get_module_cubes()
--   2. get_user_cubes()
--   3. get_module_cubes() and get_user_cubes() follow the catalog's visibility rule
BEGIN;

SELECT plan(17);

-- =====================================================
-- PART 1: get_module_cubes()
-- =====================================================
-- Test public.get_module_cubes() function
--
-- Part 1 uses the persisted nwind module (slug 'nwind', 11 entities; every
-- reference_table points inside the module) as user2 (nwind:view).
-- Part 2 creates an in-transaction module 'cube_probe' with two entities, the
-- second referencing the first, to pin down dedup and exact cardinality.

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

-- =====================================================
-- PART 2: get_user_cubes()
-- =====================================================
-- Test public.get_user_cubes() function

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST 1: user1 cannot see role_permissions
-- user1 has user:read and public:read permissions only.
-- role_permissions requires 'admin' permission, so it must not appear.
-- =====================================================

SELECT authenticate_as('user1');

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public.get_user_cubes() AS s
        WHERE s->'table'->>'table_name' = 'role_permissions'
    ),
    'user1 should not see role_permissions (requires admin permission)'
);

-- =====================================================
-- TEST 2: user3 can see role_permissions
-- user3 has the Administrator role which includes 'admin' permission.
-- role_permissions requires 'admin', so it must appear.
-- =====================================================

SELECT authenticate_as('user3');

SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_user_cubes() AS s
        WHERE s->'table'->>'table_name' = 'role_permissions'
    ),
    'user3 should see role_permissions (has admin permission)'
);

-- =====================================================
-- PART 3: get_module_cubes() and get_user_cubes() follow the catalog's visibility rule
-- =====================================================
-- The cube of a module holds the schema of every entity of the module that
-- the caller sees in the catalog (0300_test_rls.sql, 0700_test_get_schema.sql):
-- through its view permission, its edit permission or admin, and for an is_a
-- or has_a entity on every level of its chain. An entity the caller may not
-- see is left out. The cubes of a user hold the same schemas, those of every
-- entity the caller sees.
--
-- Fixtures, created as user3: the module cube_vis, viewed with public:read,
-- with the entities
--   cubev_open     view public:read, edit admin
--   cubev_guarded  view cubev:view,  edit cubev:edit
--   cubev_root     typeid base, view cubev:base, edit admin
--   cubev_org      is_a cubev_root, view cubev:view, edit cubev:edit
-- and the users cubev_editor (cubev:edit), cubev_base_editor (cubev:edit and
-- cubev:base) and cubev_admin (admin), each with the User role every user
-- gets. user1 holds none of the cubev permissions.
--
-- pg_temp.cubev_tables lists the tables of the cube_vis cube, and
-- pg_temp.cubev_user_tables the cube_vis tables among the user's cubes, or the
-- SQLSTATE of a refusal, so a refusal shows up in the assertion and does not
-- abort the file.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.cubev_tables() RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(
        (SELECT string_agg(s #>> '{table,table_name}', ', ' ORDER BY s #>> '{table,table_name}' COLLATE "C")
           FROM public.get_module_cubes('cube_vis') AS s),
        '');
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.cubev_user_tables() RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(
        (SELECT string_agg(s #>> '{table,table_name}', ', ' ORDER BY s #>> '{table,table_name}' COLLATE "C")
           FROM public.get_user_cubes() AS s
          WHERE s #>> '{table,table_name}' LIKE 'cubev\_%'),
        '');
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

SELECT authenticate_as('user3');

INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Cube Visibility Probe', 'cube_vis', 'Ephemeral module for the cube visibility tests', 'public:read');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('cubev:view', 'Views the guarded cube probes', 1),
    ('cubev:edit', 'Edits the guarded cube probes', 1),
    ('cubev:base', 'Views the hidden cube base',    1);

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
SELECT v.table_name, v.singular_label, v.plural_label, m.id, v.view_permission, v.edit_permission
  FROM (VALUES ('cubev_open',    'Open Cube Probe',    'Open Cube Probes',    'public:read', 'admin'),
               ('cubev_guarded', 'Guarded Cube Probe', 'Guarded Cube Probes', 'cubev:view',  'cubev:edit'))
       AS v(table_name, singular_label, plural_label, view_permission, edit_permission)
  CROSS JOIN modules AS m
 WHERE m.module_slug = 'cube_vis';
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix,
                      view_permission, edit_permission)
SELECT 'cubev_root', 'Root Cube Probe', 'Root Cube Probes', m.id, 'typeid', 'cubevrt', 'cubev:base', 'admin'
  FROM modules AS m WHERE m.module_slug = 'cube_vis';
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix,
                      id_refentity, view_permission, edit_permission)
SELECT 'cubev_org', 'Organization Cube Probe', 'Organization Cube Probes', m.id, 'is_a', 'cubevorg',
       'cubev_root', 'cubev:view', 'cubev:edit'
  FROM modules AS m WHERE m.module_slug = 'cube_vis';

INSERT INTO users (external_id, email, display_name) VALUES
    ('cubev_editor',      'cubev_editor@test.com',      'Cube Editor'),
    ('cubev_base_editor', 'cubev_base_editor@test.com', 'Cube Base Editor'),
    ('cubev_admin',       'cubev_admin@test.com',       'Cube Administrator');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, g.permission_name
  FROM (VALUES ('cubev_editor',      'cubev:edit'),
               ('cubev_base_editor', 'cubev:edit'),
               ('cubev_base_editor', 'cubev:base'),
               ('cubev_admin',       'admin')) AS g(external_id, permission_name)
  JOIN users AS u ON u.external_id = g.external_id;

SELECT authenticate_as('user1');
SELECT is(pg_temp.cubev_tables(), 'cubev_open',
    'cube visibility, neither permission: the cube holds only the entity viewed with public:read');

SELECT authenticate_as('cubev_editor');
SELECT is(pg_temp.cubev_tables(), 'cubev_guarded, cubev_open',
    'cube visibility, edit permission only: the cube holds the edited entity');
SELECT is(pg_temp.cubev_user_tables(), 'cubev_guarded, cubev_open',
    'cube visibility, edit permission only: the user''s cubes hold the edited entity and not the is_a entity on the hidden base');

SELECT authenticate_as('cubev_base_editor');
SELECT is(pg_temp.cubev_tables(), 'cubev_guarded, cubev_open, cubev_org, cubev_root',
    'cube visibility, edit permission of the is_a entity and view permission of its base: the cube holds every entity');

SELECT authenticate_as('cubev_admin');
SELECT is(pg_temp.cubev_tables(), 'cubev_guarded, cubev_open, cubev_org, cubev_root',
    'cube visibility, admin without the entities'' permissions: the cube holds every entity');

SELECT * FROM finish();
ROLLBACK;
