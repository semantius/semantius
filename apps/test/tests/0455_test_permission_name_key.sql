-- permissions.permission_name is the primary key, and every column that names a
-- permission is a foreign key to it.
--
-- Before this, the five name columns (entities.view_permission/edit_permission,
-- modules.view_permission, queues.view_permission/manage_permission) were plain
-- text checked on INSERT by a trigger and not at all on UPDATE, so deleting a
-- permission that was still named left a name has_permission() answers FALSE
-- for - locking everyone out of the entity, administrators included, with
-- nothing in the schema recording why. The foreign keys make that state
-- unreachable and make a rename propagate instead of breaking.
--
-- Fixtures: user3 = Administrator (writing modules, permissions and entities is
-- admin-gated). The nwind module supplies an entity that names nwind:view.
BEGIN;

SELECT plan(31);

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: a permission something still names cannot be deleted
-- =====================================================

-- An entity: every nwind entity names nwind:view. RESTRICT reports 23001
-- (restrict_violation); the deferred NO ACTION on modules below reports the
-- ordinary 23503, which is the only externally visible difference between the
-- two modes here.
SELECT throws_ok(
    $$DELETE FROM permissions WHERE permission_name = 'nwind:view'$$,
    '23001', NULL,
    'a permission an entity names cannot be deleted');

-- A queue. The two permission columns are dictionary-created references, so
-- their foreign keys come from add_dd_field rather than hand-written DDL.
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnk:queue', 'queue fixture', 1);
INSERT INTO queues (queue_name, view_permission) VALUES ('pnk_q', 'pnk:queue');

SELECT throws_ok(
    $$DELETE FROM permissions WHERE permission_name = 'pnk:queue'$$,
    '23001', NULL,
    'a permission a queue names cannot be deleted');

-- A module. modules.view_permission is the one deferred constraint in the
-- schema, so the check has to be forced to run before commit; see GROUP 4.
INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Pnk Module', 'pnkm', 'permission key fixture', 'user:read');
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnkm:view', 'module fixture', (SELECT id FROM modules WHERE module_slug = 'pnkm'));
UPDATE modules SET view_permission = 'pnkm:view' WHERE module_slug = 'pnkm';
SET CONSTRAINTS modules_view_permission_fkey IMMEDIATE;

SELECT throws_ok(
    $$DELETE FROM permissions WHERE permission_name = 'pnkm:view'$$,
    '23503', NULL,
    'a permission a module names cannot be deleted');

SET CONSTRAINTS modules_view_permission_fkey DEFERRED;

-- =====================================================
-- GROUP 2: deleting a module still takes its own world with it
-- =====================================================
-- The one case the foreign keys must NOT refuse: a module delete cascades to
-- its permissions AND to its entities, and those entities name those very
-- permissions. Referential actions queue their checks after the remaining
-- cascades, so by the time RESTRICT is evaluated the naming rows are gone too.

INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Pnk Cascade', 'pnkc', 'cascade fixture', 'user:read');
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('pnkc:view', 'cascade fixture view', (SELECT id FROM modules WHERE module_slug = 'pnkc')),
    ('pnkc:edit', 'cascade fixture edit', (SELECT id FROM modules WHERE module_slug = 'pnkc'));
UPDATE modules SET view_permission = 'pnkc:view' WHERE module_slug = 'pnkc';
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      module_id, view_permission, edit_permission)
VALUES ('pnkc_thing', 'pnkc_thing', 'Thing', 'Things', 'cascade fixture entity',
        (SELECT id FROM modules WHERE module_slug = 'pnkc'), 'pnkc:view', 'pnkc:edit');

SELECT lives_ok(
    $$DELETE FROM modules WHERE module_slug = 'pnkc'$$,
    'deleting a module whose entities name its own permissions succeeds');

SELECT is(
    (SELECT count(*)::int FROM entities WHERE table_name = 'pnkc_thing'),
    0,
    'the module delete took its entity with it');

SELECT is(
    (SELECT count(*)::int FROM permissions WHERE permission_name LIKE 'pnkc:%'),
    0,
    'the module delete took its permissions with it');

SELECT is(
    (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'pnkc_thing'),
    0,
    'the module delete dropped the physical table');

-- =====================================================
-- GROUP 3: a rename propagates, policies and all
-- =====================================================
-- ON UPDATE CASCADE rewrites entities.view_permission, and a cascaded UPDATE
-- fires row-level triggers, so the generated SELECT policy is rebuilt around
-- the new literal. Without that the entity would keep a policy naming a
-- permission nobody holds.

INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnkr:alpha', 'rename fixture', 1);
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      module_id, view_permission, edit_permission)
VALUES ('pnkr_thing', 'pnkr_thing', 'Thing', 'Things', 'rename fixture entity',
        1, 'pnkr:alpha', 'admin');

UPDATE permissions SET permission_name = 'pnkr:beta' WHERE permission_name = 'pnkr:alpha';

SELECT is(
    (SELECT view_permission FROM entities WHERE table_name = 'pnkr_thing'),
    'pnkr:beta',
    'renaming a permission cascades into entities.view_permission');

SELECT ok(
    (SELECT qual LIKE '%pnkr:beta%' FROM pg_policies
      WHERE tablename = 'pnkr_thing' AND policyname = 'pnkr_thing_select_policy'),
    'the entity SELECT policy is rebuilt around the new permission name');

SELECT ok(
    (SELECT qual NOT LIKE '%pnkr:alpha%' FROM pg_policies
      WHERE tablename = 'pnkr_thing' AND policyname = 'pnkr_thing_select_policy'),
    'the entity SELECT policy no longer names the old permission');

-- =====================================================
-- GROUP 4: modules.view_permission is deferred, and has to be
-- =====================================================
-- A module and its view_permission point at each other: the permission's
-- module_id names the module, so the module row has to exist first. An
-- immediate check would fail on every module seed there is.

INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Pnk Deferred', 'pnkd', 'deferred fixture', 'pnkd:view');
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnkd:view', 'deferred fixture', (SELECT id FROM modules WHERE module_slug = 'pnkd'));

SELECT is(
    (SELECT view_permission FROM modules WHERE module_slug = 'pnkd'),
    'pnkd:view',
    'a module can name a permission that is only inserted later in the transaction');

-- And the constraint is real. It cannot be shown by committing - every test
-- file rolls back, and releasing a savepoint does not run deferred checks - so
-- the pending check is forced to run instead.
INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Pnk Ghost', 'pnkg', 'ghost fixture', 'pnkg:never');

SELECT throws_ok(
    $$SET CONSTRAINTS modules_view_permission_fkey IMMEDIATE$$,
    '23503', NULL,
    'a module naming a permission that never appears is refused when the check runs');

DELETE FROM modules WHERE module_slug = 'pnkg';

-- =====================================================
-- GROUP 5: the name alphabet
-- =====================================================
-- Whitespace and commas would make a name ungrantable through an OAuth scope
-- (scopes are split on both), and a dot would make permission_hierarchy's
-- generated key ambiguous. Those three are the whole of it: the alphabet is
-- otherwise the one module_slug accepts, so a scaffold can mint <slug>:<verb>
-- from any legal slug.

SELECT throws_ok(
    $$INSERT INTO permissions (permission_name, description, module_id)
      VALUES ('pnk bad', 'space', 1)$$,
    '23514', NULL,
    'a permission name containing a space is refused');

SELECT throws_ok(
    $$INSERT INTO permissions (permission_name, description, module_id)
      VALUES ('pnk,bad', 'comma', 1)$$,
    '23514', NULL,
    'a permission name containing a comma is refused');

SELECT throws_ok(
    $$INSERT INTO permissions (permission_name, description, module_id)
      VALUES ('pnk.bad', 'dot', 1)$$,
    '23514', NULL,
    'a permission name containing a dot is refused');

-- A hyphen is legal in a module_slug, so it has to be legal here: the scaffold
-- derives <slug>:<verb>, and a module slugged service-catalog would otherwise
-- be unable to name its own permissions.
SELECT lives_ok(
    $$INSERT INTO permissions (permission_name, description, module_id)
      VALUES ('service-catalog:view', 'hyphenated slug', 1)$$,
    'a permission name over the module_slug alphabet is accepted');

-- The leading character is constrained the same way module_slug constrains it.
SELECT throws_ok(
    $$INSERT INTO permissions (permission_name, description, module_id)
      VALUES ('-bad:view', 'leading hyphen', 1)$$,
    '23514', NULL,
    'a permission name starting with a hyphen is refused');

-- =====================================================
-- GROUP 6: the dictionary types a reference after the key it references
-- =====================================================
-- Both columns below are created by add_dd_field from a `reference` field row.
-- Typing them from the format alone would make them INTEGER, the foreign key
-- would fail to install, and get_schema would call them integers and raise on
-- the first text default it met.

SELECT is(
    (SELECT format_type(a.atttypid, a.atttypmod)
       FROM pg_attribute a
      WHERE a.attrelid = 'dashboards'::regclass AND a.attname = 'view_permission'),
    'text',
    'dashboards.view_permission is TEXT, typed after the key it references');

SELECT is(
    (SELECT format_type(a.atttypid, a.atttypmod)
       FROM pg_attribute a
      WHERE a.attrelid = 'queues'::regclass AND a.attname = 'view_permission'),
    'text',
    'queues.view_permission is TEXT, typed after the key it references');

SELECT is(
    (SELECT confrelid::regclass::text
       FROM pg_constraint WHERE conname = 'dashboards_view_permission_fkey'),
    'permissions',
    'dashboards.view_permission carries a foreign key to permissions');

SELECT is(
    (SELECT confrelid::regclass::text
       FROM pg_constraint WHERE conname = 'queues_view_permission_fkey'),
    'permissions',
    'queues.view_permission carries a foreign key to permissions');

SELECT is(
    public.get_schema('queues')->'properties'->'view_permission'->>'type',
    'string',
    'get_schema types a reference to a text-keyed entity as string');

SELECT is(
    public.get_schema('queues')->'properties'->'view_permission'->>'default',
    'admin',
    'get_schema returns the reference default as a string, not an integer cast');

SELECT is(
    public.get_schema('entities')->'properties'->'view_permission'->>'type',
    'string',
    'entities.view_permission is typed string now that it is a reference');

-- A reference to an integer-keyed entity is unchanged: the rule is the key's
-- type, not a list of tables that happen to be text-keyed.
SELECT is(
    public.get_schema('entities')->'properties'->'module_id'->>'type',
    'integer',
    'a reference to an integer-keyed entity is still typed integer');

-- The fallback arm. An entity with no physical table cannot be looked up in the
-- catalog, and the answer has to stay what it was before the resolver existed:
-- INTEGER, so the ADD CONSTRAINT that follows fails on the missing relation
-- rather than on a type nobody chose. Both resolvers are LANGUAGE sql, so a
-- profiler reports no statements for them and only an assertion like this one
-- reaches the arm.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      module_id, view_permission, edit_permission, managed)
VALUES ('pnkx_ghost', 'pnkx_ghost', 'Ghost', 'Ghosts', 'unmanaged fixture',
        1, 'public:read', 'admin', FALSE);

-- Both resolvers are revoked from the request role - they are DDL machinery,
-- not RPC - so these two assertions run as the owner.
RESET ROLE;

SELECT is(
    field_data_type('reference', NULL, 'pnkx_ghost'),
    'INTEGER',
    'a reference to an entity with no physical table falls back to the format');

-- field_data_type and field_json_type read different sources - the catalog for
-- one, the referenced key field's declared format for the other - and nothing
-- would notice if they drifted apart. They have to agree about which references
-- are text-shaped, because one types the column and the other describes it.
SELECT is(
    (SELECT COALESCE(string_agg(f.table_name || '.' || f.field_name, ', ' ORDER BY f.table_name, f.field_name), '')
       FROM fields f
      WHERE f.format IN ('reference', 'parent')
        AND COALESCE(f.reference_table, '') <> ''
        AND (field_data_type(f.format, f."precision", f.reference_table) = 'TEXT')
            IS DISTINCT FROM
            (field_json_type(f.format, f.reference_table)::text = '"string"')),
    '',
    'every reference is typed the same way by field_data_type and field_json_type');

SELECT authenticate_as('user3');

-- The third delete mode. RESTRICT and CASCADE are covered above; `clear` is what
-- the two module columns and dashboards use, and it must null the column out
-- rather than refuse or cascade.
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnkn:clear', 'set null fixture', 1);
UPDATE modules SET manage_permission = 'pnkn:clear' WHERE module_slug = 'pnkm';
DELETE FROM permissions WHERE permission_name = 'pnkn:clear';

SELECT is(
    (SELECT manage_permission FROM modules WHERE module_slug = 'pnkm'),
    NULL,
    'deleting a permission a module merely points at clears the column (SET NULL)');

-- A rename reaches the dictionary-created columns too, not just the
-- hand-written ones GROUP 3 covers.
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('pnkq:alpha', 'queue rename fixture', 1);
UPDATE queues SET manage_permission = 'pnkq:alpha' WHERE queue_name = 'pnk_q';
UPDATE permissions SET permission_name = 'pnkq:beta' WHERE permission_name = 'pnkq:alpha';

SELECT is(
    (SELECT manage_permission FROM queues WHERE queue_name = 'pnk_q'),
    'pnkq:beta',
    'a rename cascades into a dictionary-created reference column too');

-- The format-change guard has to use the same rule, or it refuses the very
-- conversion this typing makes legal. It is a BEFORE UPDATE trigger on fields
-- and it runs ahead of the one in update_dd_field, so if it judges a reference
-- by its format alone it is the one the caller hits: text -> reference is TEXT
-- to TEXT when the target is `permissions` and must be allowed, TEXT to INTEGER
-- when the target is `users` and must not.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      module_id, view_permission, edit_permission)
VALUES ('pnkf_thing', 'pnkf_thing', 'Thing', 'Things', 'format change fixture',
        1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
VALUES ('pnkf_thing', 'perm', 'Perm', 'text', 10, 'admin'),
       ('pnkf_thing', 'owner', 'Owner', 'text', 20, '');

SELECT lives_ok(
    $$UPDATE fields SET format = 'reference', reference_table = 'permissions',
                        reference_delete_mode = 'restrict'
       WHERE table_name = 'pnkf_thing' AND field_name = 'perm'$$,
    'a text column can become a reference to a text-keyed entity');

SELECT throws_like(
    $$UPDATE fields SET format = 'reference', reference_table = 'users',
                        reference_delete_mode = 'clear'
       WHERE table_name = 'pnkf_thing' AND field_name = 'owner'$$,
    '%would require changing the column type%',
    'a text column still cannot become a reference to an integer-keyed entity');

SELECT * FROM finish();
ROLLBACK;
