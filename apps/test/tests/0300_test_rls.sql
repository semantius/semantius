-- Row-level security basics: the rbac context smoke test, the RLS policies
-- on the fields and _versions catalog tables, and which rows of entities and
-- fields each user reads.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. RLS / rbac context smoke test
--   2. RLS on fields and _versions
--   3. Catalog rows follow the entity's view and edit permission
--   4. Catalog rows of an is_a or has_a entity follow every level
--   5. Catalog rows for a holder of admin
--   6. A select_rule reader who holds neither permission
BEGIN;

SELECT plan(51);

-- =====================================================
-- PART 1: RLS / rbac context smoke test
-- =====================================================
-- Basic RLS / rbac context smoke test.
--
-- Fixtures: harness identities from apps/test (user1 = 1001, User role only;
-- user2 = 1002, User + Northwind Sales) and the persisted nwind module
-- (products = 77 rows, view_permission 'nwind:view').
-- Also hosts the read-only lookup asserts for rbac.get_user_by_external_id().

select authenticate_as('user1');

-- Test that will pass
SELECT has_table('public', 'users', 'Users table should exist');

-- Test rbac.user_id() returns 1001
SELECT is(
    rbac.user_id(),
    1001::bigint,
    'rbac.user_id() should return 1001'
);

-- Test rbac.uid() returns user1
SELECT is(
    rbac.uid(),
    'user1',
    'rbac.uid() should return user1'
);

-- Test webhook_receivers count - RLS should prevent access (requires admin permission), so count should be 0
SELECT is(
    (SELECT COUNT(*)::integer FROM webhook_receivers),
    0,
    'webhook_receivers table should contain 0 records (user1 lacks admin permission)'
);

-- Test that user1 has not nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    false,
    'user1 should not have nwind:view permission'
);

-- check that insert is blocked by RLS (roles requires admin permission).
-- module_id = 1 (_core) is a literal on purpose: user1 cannot see any module
-- row, so a slug subquery would resolve to NULL and the failure would no
-- longer isolate the RLS policy.
SELECT throws_ok(
    $$
    INSERT INTO roles (role_name, description, module_id)
    VALUES ('Should Fail', 'user1 lacks admin permission', 1);
    $$,
    '42501',
    NULL,
    'Insert into roles should fail because user1 lacks admin permission'
);

-- Read-only lookup helper (used by RLS in read-only transactions).
-- The subject is confined: user1 may look itself up, and anything else raises,
-- which is what stops a plain user from enumerating external ids. The whole rule,
-- including the administrator's view of it and the NULL-for-unknown answer they
-- still get, is in 0310_test_rbac_helpers.sql.
SELECT is(
    rbac.get_user_by_external_id('user1'),
    1001::bigint,
    'rbac.get_user_by_external_id should return 1001 for user1'
);

SELECT throws_ok(
    $$SELECT rbac.get_user_by_external_id('does_not_exist')$$,
    '42501',
    NULL,
    'rbac.get_user_by_external_id should refuse a subject that is not the caller'
);

select authenticate_as('user2');

-- Test rbac.uid() returns user2
SELECT is(
    rbac.uid(),
    'user2',
    'rbac.uid() should return user2'
);

-- Test product count - RLS should allow access (user2 holds nwind:view), so count should be 77
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    77,
    'Products table should contain 77 products for user2'
);

-- Test that user2 has nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    true,
    'user2 should have nwind:view permission'
);

-- Test that an unknown permission name is simply false
SELECT is(
    rbac.has_permission('nwind:NOTEXISTANT'),
    false,
    'user2 should not have nwind:NOTEXISTANT'
);

-- =====================================================
-- PART 2: RLS on fields and _versions
-- =====================================================
-- Test RLS policies for fields table and _versions table

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST FIELDS TABLE RLS
-- =====================================================

-- Test as user1 (non-admin, has public:read)
SELECT authenticate_as('user1');

-- Test that user1 can read fields
SELECT ok(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'entities') > 0,
    'user1 should be able to read fields table'
);

-- Test that user1 cannot modify fields (insert)
SELECT throws_ok(
    $$
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width)
    VALUES ('tables', 'test_field', 'Test Field', 'text', FALSE, 999, 'default', 'default');
    $$,
    '42501',
    NULL,
    'user1 should not be able to insert into fields table'
);

-- Test that user1 cannot modify fields (update)
-- Store the original title value and verify UPDATE affects 0 rows due to RLS
DO $$ 
DECLARE
    v_original_title TEXT;
    v_rows_affected INTEGER;
BEGIN
    -- First, verify the record exists and we can read it
    SELECT title INTO STRICT v_original_title FROM fields WHERE table_name = 'entities' AND field_name = 'table_name';
    
    -- Try to update (should be blocked by RLS)
    UPDATE fields SET title = 'Modified Title' WHERE table_name = 'entities' AND field_name = 'table_name';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the update (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'UPDATE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Verify value is unchanged
    IF (SELECT title FROM fields WHERE table_name = 'entities' AND field_name = 'table_name') != v_original_title THEN
        RAISE EXCEPTION 'Title was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user1 cannot update fields table (verified data unchanged)');

-- Test that user1 cannot modify fields (delete)
-- Verify DELETE affects 0 rows due to RLS
DO $$
DECLARE
    v_count_before INTEGER;
    v_rows_affected INTEGER;
    v_record_exists BOOLEAN;
BEGIN
    -- Verify the record exists that we're trying to delete (use 'description' field which exists for entities)
    SELECT EXISTS(SELECT 1 FROM fields WHERE table_name = 'entities' AND field_name = 'description') INTO STRICT v_record_exists;
    IF NOT v_record_exists THEN
        RAISE EXCEPTION 'Test setup error: record to delete does not exist';
    END IF;
    
    -- Get count before delete attempt
    SELECT COUNT(*) INTO v_count_before FROM fields WHERE table_name = 'entities';
    IF v_count_before = 0 THEN
        RAISE EXCEPTION 'Test setup error: no fields found for entities table';
    END IF;
    
    -- Try to delete (should be blocked by RLS)
    DELETE FROM fields WHERE table_name = 'entities' AND field_name = 'description';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the delete (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'DELETE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Double-check count didn't change
    IF (SELECT COUNT(*) FROM fields WHERE table_name = 'entities') != v_count_before THEN
        RAISE EXCEPTION 'Record count changed when it should not have';
    END IF;
END $$;

SELECT ok(true, 'user1 cannot delete from fields table (verified data unchanged)');

-- =====================================================
-- TEST _VERSIONS TABLE RLS - user1 (non-admin)
-- =====================================================

-- Test that user1 cannot query _versions
SELECT is(
    (SELECT COUNT(*)::integer FROM _versions),
    0,
    'user1 should not be able to read _versions table (RLS should return 0 rows)'
);

-- =====================================================
-- TEST _VERSIONS TABLE RLS - user3 (admin)
-- =====================================================

-- Switch to user3 (admin)
SELECT authenticate_as('user3');

-- Test that user3 can query _versions
SELECT ok(
    (SELECT COUNT(*)::integer FROM _versions) > 0,
    'user3 (admin) should be able to read _versions table'
);

-- Test that user3 cannot insert into _versions
SELECT throws_ok(
    $$
    INSERT INTO _versions (name) VALUES ('test_version');
    $$,
    '42501',
    NULL,
    'user3 (admin) should not be able to insert into _versions table'
);

-- Test that user3 cannot update _versions
-- Verify UPDATE affects 0 rows due to RLS
DO $$
DECLARE
    v_original_name TEXT;
    v_rows_affected INTEGER;
BEGIN
    -- Verify the record exists
    SELECT name INTO STRICT v_original_name FROM _versions WHERE name = '_core.0010_core.sql';
    
    -- Try to update (should be blocked by RLS)
    UPDATE _versions SET name = 'modified_name' WHERE name = '_core.0010_core.sql';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the update (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'UPDATE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Verify name is unchanged
    IF NOT EXISTS (SELECT 1 FROM _versions WHERE name = '_core.0010_core.sql') THEN
        RAISE EXCEPTION 'Name was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user3 (admin) cannot update _versions table (verified data unchanged)');

-- =====================================================
-- PART 3: Catalog rows follow the entity's view and edit permission
-- =====================================================
-- An entity's row in entities, and every row of that entity in fields, is
-- visible to a user who holds the entity's view_permission or its
-- edit_permission, and to no other user. The edit permission counts as well
-- because an editor has to find the entity and its fields to write its
-- records. A user who holds neither learns nothing about the entity from the
-- catalog, not even that it exists. Holding a permission means what
-- rbac.has_permission answers: a grant through a role, a direct grant, or a
-- permission that includes it through permission_hierarchy.
--
-- Every read below runs as the request role and asks the way a client does:
-- the entity's row by table_name and its fields rows by table_name. The
-- expected rows come from a snapshot taken on the owner connection, which RLS
-- does not filter, so a row a user reads is compared with the row as stored.
--
-- Fixtures, created as user3:
--   permissions  rlsdd:view and rlsdd:edit; rlsdd:stray, which no
--                permission_hierarchy row names
--   entities     rls_dd_guarded  view rlsdd:view,    edit rlsdd:edit
--                rls_dd_ruled    view rlsdd:view,    edit rlsdd:edit, with a
--                                select_rule that admits only admin
--                rls_dd_party    typeid base, view public:read, edit admin
--                rls_dd_org      is_a rls_dd_party,  view rlsdd:view, edit rlsdd:edit
--   users        one per permission set, each with the User role
--                (public:read, user:read) that every user gets:
--                rls_dd_viewer (rlsdd:view), rls_dd_editor (rlsdd:edit),
--                rls_dd_stray (rlsdd:stray)
-- user1 holds the User role alone. user3 is the Administrator: its role is
-- granted each permission as the permission is created, rlsdd:* included.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('rlsdd:view',        'Views the guarded catalog probes',          1),
    ('rlsdd:edit',        'Edits the guarded catalog probes',          1),
    ('rlsdd:stray',       'Guards nothing and is in no hierarchy row', 1);

INSERT INTO entities (table_name, singular_label, plural_label, module_id,
                      view_permission, edit_permission, select_rule)
VALUES
    ('rls_dd_guarded', 'Guarded Probe', 'Guarded Probes', 1, 'rlsdd:view',   'rlsdd:edit',   '{}'),
    ('rls_dd_ruled',   'Ruled Probe',   'Ruled Probes',   1, 'rlsdd:view',   'rlsdd:edit',
     '{"has_permission": "admin"}');

INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES
    ('rls_dd_guarded', 'note', 'Note', 'text', 30),
    ('rls_dd_ruled',   'note', 'Note', 'text', 30);

-- An is_a or has_a entity is an entity of its own, with its own permissions
-- and its own fields rows: its key, its own fields and the audit fields. The
-- fields of the base stay rows of the base. The base is readable with
-- public:read, so a holder of rlsdd:view may read every level and user1 the
-- base alone.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('rls_dd_party', 'Party Probe', 'Party Probes', 1, 'typeid', 'rlsddpty');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rls_dd_party', 'city', 'City', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      id_refentity, view_permission, edit_permission)
VALUES ('rls_dd_org', 'Organization Probe', 'Organization Probes', 1, 'is_a', 'rlsddorg',
        'rls_dd_party', 'rlsdd:view', 'rlsdd:edit');
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES
    ('rls_dd_org', 'vat', 'VAT', 'text', 30);

INSERT INTO users (external_id, email, display_name) VALUES
    ('rls_dd_viewer',        'rls_dd_viewer@test.com',        'Catalog Viewer'),
    ('rls_dd_editor',        'rls_dd_editor@test.com',        'Catalog Editor'),
    ('rls_dd_stray',         'rls_dd_stray@test.com',         'Catalog Stray Holder');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, g.permission_name
  FROM (VALUES ('rls_dd_viewer',        'rlsdd:view'),
               ('rls_dd_editor',        'rlsdd:edit'),
               ('rls_dd_stray',         'rlsdd:stray')) AS g(external_id, permission_name)
  JOIN users AS u ON u.external_id = g.external_id;

-- The snapshot of the whole catalog, taken on the owner connection, which RLS
-- does not filter. The request role reads it as the stored rows to compare with.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TEMP TABLE rls_dd_entities AS SELECT * FROM entities;
CREATE TEMP TABLE rls_dd_fields AS SELECT * FROM fields;
GRANT SELECT ON rls_dd_entities, rls_dd_fields TO semantius_user;

-- ---------------------------------------------------------------------------
-- The view permission alone
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_viewer');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, view permission only: entities WHERE table_name = rls_dd_guarded returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, view permission only: fields WHERE table_name = rls_dd_guarded returns every stored field row');

-- ---------------------------------------------------------------------------
-- The edit permission alone
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_editor');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, edit permission only: entities WHERE table_name = rls_dd_guarded returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, edit permission only: fields WHERE table_name = rls_dd_guarded returns every stored field row');

-- ---------------------------------------------------------------------------
-- Neither permission: user1 holds public:read and user:read, like every user
-- ---------------------------------------------------------------------------
SELECT authenticate_as('user1');

SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, neither permission: entities WHERE table_name = rls_dd_guarded returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, neither permission: fields WHERE table_name = rls_dd_guarded returns no row');

-- ---------------------------------------------------------------------------
-- is_a entities follow their own view and edit permission
-- ---------------------------------------------------------------------------
SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_org'$$,
    'catalog, is_a entity, plain user: entities WHERE table_name = rls_dd_org returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_org'$$,
    'catalog, is_a entity, plain user: fields WHERE table_name = rls_dd_org returns no row');

-- ---------------------------------------------------------------------------
-- An entity with a select_rule: the rule decides which records of its table a
-- user reads, the view and edit permission decide who sees it in the catalog.
-- The rule of rls_dd_ruled admits only admin, so rls_dd_viewer reads none of
-- its records and still sees its catalog rows.
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_viewer');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_ruled'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_ruled'$$,
    'catalog, entity with a select_rule, view permission: entities WHERE table_name = rls_dd_ruled returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_ruled'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_ruled'$$,
    'catalog, entity with a select_rule, view permission: fields WHERE table_name = rls_dd_ruled returns every stored field row');

-- ---------------------------------------------------------------------------
-- Every entity of the catalog, the shipped ones included: the RBAC tables,
-- the unmanaged audit logs, the nwind module. What a user reads of entities
-- and fields is exactly the rows of the entities whose view or edit
-- permission it holds, the rule evaluated as that user over the snapshot.
-- user1 holds the User role.
-- ---------------------------------------------------------------------------
SELECT authenticate_as('user1');

SELECT set_eq(
    $$SELECT table_name FROM entities$$,
    $$SELECT table_name FROM rls_dd_entities
       WHERE rbac.has_permission(view_permission) OR rbac.has_permission(edit_permission)$$,
    'catalog, every entity, user1: entities returns exactly the entities whose view or edit permission it holds');
SELECT set_eq(
    $$SELECT DISTINCT table_name FROM fields$$,
    $$SELECT DISTINCT f.table_name FROM rls_dd_fields AS f
        JOIN rls_dd_entities AS e ON e.table_name = f.table_name
       WHERE rbac.has_permission(e.view_permission) OR rbac.has_permission(e.edit_permission)$$,
    'catalog, every entity, user1: fields returns rows of exactly those entities');

-- =====================================================
-- PART 4: Catalog rows of an is_a or has_a entity follow every level
-- =====================================================
-- A record of an is_a or has_a entity is stored at every level of its chain,
-- so the entity's rows in entities and fields are visible only to a user who
-- may see every level: the entity itself and each base, each through its view
-- permission, its edit permission or admin. Holding the entity's own
-- permission does not show the entity while one of its bases stays hidden;
-- holding that base's permission as well does. The derived entity of PART 3
-- sits on rls_dd_party, which every user views with public:read, so this part
-- adds bases a user can be kept from.
--
-- Fixtures, created as user3:
--   permissions  rlsdd:base and rlsdd:base_edit, which view and edit the bases
--   entities     rls_dd_site         typeid base, view rlsdd:base, edit rlsdd:base_edit
--                rls_dd_site_org     is_a rls_dd_site,      view rlsdd:view, edit rlsdd:edit
--                rls_dd_site_vendor  has_a rls_dd_site,     view rlsdd:view, edit rlsdd:edit
--                rls_dd_party_mid    is_a rls_dd_party,     view rlsdd:base, edit rlsdd:base_edit
--                rls_dd_party_leaf   is_a rls_dd_party_mid, view rlsdd:view, edit rlsdd:edit
--   users        rls_dd_base_viewer (rlsdd:view and rlsdd:base),
--                rls_dd_base_editor (rlsdd:edit and rlsdd:base_edit)
-- rls_dd_party_leaf has three levels, and every user sees its root: what hides
-- it from rls_dd_viewer is the middle level, so a check of the entity and its
-- root alone would show it.
--
-- The snapshot of PART 3 is taken again, so it holds the new rows.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('rlsdd:base',      'Views the hidden base probes', 1),
    ('rlsdd:base_edit', 'Edits the hidden base probes', 1);

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      view_permission, edit_permission)
VALUES ('rls_dd_site', 'Site Probe', 'Site Probes', 1, 'typeid', 'rlsddsit', 'rlsdd:base', 'rlsdd:base_edit');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rls_dd_site', 'region', 'Region', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      id_refentity, view_permission, edit_permission)
VALUES ('rls_dd_site_org', 'Site Organization Probe', 'Site Organization Probes', 1, 'is_a', 'rlsddsor',
        'rls_dd_site', 'rlsdd:view', 'rlsdd:edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type,
                      id_refentity, view_permission, edit_permission)
VALUES ('rls_dd_site_vendor', 'Site Vendor Probe', 'Site Vendor Probes', 1, 'has_a',
        'rls_dd_site', 'rlsdd:view', 'rlsdd:edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      id_refentity, view_permission, edit_permission)
VALUES ('rls_dd_party_mid', 'Middle Party Probe', 'Middle Party Probes', 1, 'is_a', 'rlsddmid',
        'rls_dd_party', 'rlsdd:base', 'rlsdd:base_edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      id_refentity, view_permission, edit_permission)
VALUES ('rls_dd_party_leaf', 'Leaf Party Probe', 'Leaf Party Probes', 1, 'is_a', 'rlsddlf',
        'rls_dd_party_mid', 'rlsdd:view', 'rlsdd:edit');
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES
    ('rls_dd_site_org',    'vat',    'VAT',    'text',  30),
    ('rls_dd_site_vendor', 'rating', 'Rating', 'int32', 30),
    ('rls_dd_party_mid',   'tier',   'Tier',   'text',  30),
    ('rls_dd_party_leaf',  'badge',  'Badge',  'text',  30);

INSERT INTO users (external_id, email, display_name) VALUES
    ('rls_dd_base_viewer', 'rls_dd_base_viewer@test.com', 'Catalog Base Viewer'),
    ('rls_dd_base_editor', 'rls_dd_base_editor@test.com', 'Catalog Base Editor');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, g.permission_name
  FROM (VALUES ('rls_dd_base_viewer', 'rlsdd:view'),
               ('rls_dd_base_viewer', 'rlsdd:base'),
               ('rls_dd_base_editor', 'rlsdd:edit'),
               ('rls_dd_base_editor', 'rlsdd:base_edit')) AS g(external_id, permission_name)
  JOIN users AS u ON u.external_id = g.external_id;

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

TRUNCATE rls_dd_entities, rls_dd_fields;
INSERT INTO rls_dd_entities SELECT * FROM entities;
INSERT INTO rls_dd_fields SELECT * FROM fields;

-- ---------------------------------------------------------------------------
-- The view permission of the entity, not of its base
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_viewer');

SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_site_org'$$,
    'catalog, is_a entity, own view permission, base hidden: entities WHERE table_name = rls_dd_site_org returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_site_org'$$,
    'catalog, is_a entity, own view permission, base hidden: fields WHERE table_name = rls_dd_site_org returns no row');

SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_site_vendor'$$,
    'catalog, has_a entity, own view permission, base hidden: entities WHERE table_name = rls_dd_site_vendor returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_site_vendor'$$,
    'catalog, has_a entity, own view permission, base hidden: fields WHERE table_name = rls_dd_site_vendor returns no row');

SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, own view permission, middle level hidden: entities WHERE table_name = rls_dd_party_leaf returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, own view permission, middle level hidden: fields WHERE table_name = rls_dd_party_leaf returns no row');

-- ---------------------------------------------------------------------------
-- The view permission of every level
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_base_viewer');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_site_vendor'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_site_vendor'$$,
    'catalog, has_a entity, view permission of every level: entities WHERE table_name = rls_dd_site_vendor returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_site_vendor'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_site_vendor'$$,
    'catalog, has_a entity, view permission of every level: fields WHERE table_name = rls_dd_site_vendor returns every stored field row');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_party_leaf'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, view permission of every level: entities WHERE table_name = rls_dd_party_leaf returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_party_leaf'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, view permission of every level: fields WHERE table_name = rls_dd_party_leaf returns every stored field row');

-- ---------------------------------------------------------------------------
-- The edit permission of every level
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_base_editor');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_party_leaf'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, edit permission of every level: entities WHERE table_name = rls_dd_party_leaf returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_party_leaf'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_party_leaf'$$,
    'catalog, three-level is_a entity, edit permission of every level: fields WHERE table_name = rls_dd_party_leaf returns every stored field row');

-- =====================================================
-- PART 5: Catalog rows for a holder of admin
-- =====================================================
-- A holder of admin sees the catalog rows of every entity, also of one whose
-- view and edit permission it does not hold, at every level. user3 cannot
-- show that, because its Administrator role is granted every permission as
-- the permission is created. rls_dd_admin holds admin as a direct grant, and
-- through permission_hierarchy public:read, and nothing else.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

INSERT INTO users (external_id, email, display_name)
VALUES ('rls_dd_admin', 'rls_dd_admin@test.com', 'Catalog Administrator');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, 'admin' FROM users AS u WHERE u.external_id = 'rls_dd_admin';

-- ---------------------------------------------------------------------------
-- admin as a direct grant
-- ---------------------------------------------------------------------------
SELECT authenticate_as('rls_dd_admin');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, admin without the entity''s permissions: entities WHERE table_name = rls_dd_guarded returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_guarded'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_guarded'$$,
    'catalog, admin without the entity''s permissions: fields WHERE table_name = rls_dd_guarded returns every stored field row');

SELECT results_eq(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_site_org'$$,
    $$SELECT * FROM rls_dd_entities WHERE table_name = 'rls_dd_site_org'$$,
    'catalog, admin without the permissions of any level: entities WHERE table_name = rls_dd_site_org returns its stored row');
SELECT set_eq(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_site_org'$$,
    $$SELECT * FROM rls_dd_fields WHERE table_name = 'rls_dd_site_org'$$,
    'catalog, admin without the permissions of any level: fields WHERE table_name = rls_dd_site_org returns every stored field row');

-- =====================================================
-- PART 6: A select_rule reader who holds neither permission
-- =====================================================
-- A select_rule takes the place of the view permission for the entity's
-- records, so a user the rule admits reads them without holding the view or
-- the edit permission. The catalog rows follow the view and edit permission
-- and admin, never the rule, so that user reads the records and sees no
-- metadata of the entity: neither its rows in entities and fields nor its
-- schema.
--
-- Fixture, created as user3: rls_dd_rule_open, viewed with rlsdd:view and
-- edited with rlsdd:edit, whose select_rule admits a holder of rlsdd:stray,
-- with one record. rls_dd_stray (PART 3) holds rlsdd:stray and neither
-- rlsdd:view nor rlsdd:edit.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id,
                      view_permission, edit_permission, select_rule)
VALUES ('rls_dd_rule_open', 'Rule Reader Probe', 'Rule Reader Probes', 1, 'rlsdd:view', 'rlsdd:edit',
        '{"has_permission": "rlsdd:stray"}');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rls_dd_rule_open', 'note', 'Note', 'text', 30);
INSERT INTO rls_dd_rule_open (label, note) VALUES ('Rule reader record', 'read through the rule');

SELECT authenticate_as('rls_dd_stray');

SELECT is((SELECT count(*)::int FROM rls_dd_rule_open), 1,
    'catalog, select_rule reader without view or edit permission: the rule admits it to the record');

SELECT is_empty(
    $$SELECT * FROM entities WHERE table_name = 'rls_dd_rule_open'$$,
    'catalog, select_rule reader without view or edit permission: entities WHERE table_name = rls_dd_rule_open returns no row');
SELECT is_empty(
    $$SELECT * FROM fields WHERE table_name = 'rls_dd_rule_open'$$,
    'catalog, select_rule reader without view or edit permission: fields WHERE table_name = rls_dd_rule_open returns no row');

SELECT * FROM finish();
ROLLBACK;
