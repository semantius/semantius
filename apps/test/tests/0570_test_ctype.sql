-- ctype, the core-column marker: coverage of the record-versioning
-- timestamps, and the lock that keeps ctype and core columns protected.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. ctype coverage for the record-versioning timestamps
--   2. ctype lock and core-column protection
BEGIN;

SELECT plan(13);

-- =====================================================
-- PART 1: ctype coverage for the record-versioning timestamps
-- =====================================================
-- Test (b7): ctype coverage for the managed record-versioning timestamps.
--
-- spec v2 I6 identifies a core column by `ctype <> ''`. created_at / updated_at are DD-managed
-- record-versioning columns, grouped under the single ctype 'audit' (room for created_by/
-- updated_by later). They must carry ctype='audit' both in the valid_ctype CHECK / fields.ctype
-- enum and on every actual field row (bootstrap + newly created tables). Protection (the b7
-- guards) keys on ctype, and is_core is derived as (ctype <> '').
--
-- Fixtures: user3 = Administrator.

SELECT authenticate_as('user3');

-- Every existing created_at/updated_at field row carries ctype='audit'.
SELECT is(
    (SELECT count(*)::int FROM fields
     WHERE field_name IN ('created_at', 'updated_at')
       AND ctype IS DISTINCT FROM 'audit'),
    0,
    'every created_at/updated_at field row has ctype = audit');

-- The ctype enum enumerates the b7 marker set.
SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'fields' AND field_name = 'ctype'),
    '["", "id", "label", "audit", "core"]'::jsonb,
    'fields.ctype enum_values are the b7 marker set');

-- A freshly created managed table's auto-inserted timestamps carry ctype='audit'.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('ct_probe', 'ct_probe', 'CT Probe', 'CT Probes', 'ctype coverage probe',
    1, 'public:read', 'admin', 'id', 'label');

SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'ct_probe' AND field_name = 'created_at'),
    'audit',
    'create_dd_table stamps created_at with ctype = audit');
SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'ct_probe' AND field_name = 'updated_at'),
    'audit',
    'create_dd_table stamps updated_at with ctype = audit');

-- The id/label structural cores get their own ctypes (not audit/core).
SELECT is(
    (SELECT string_agg(ctype, ',' ORDER BY field_name) FROM fields
     WHERE table_name = 'ct_probe' AND field_name IN ('id', 'label')),
    'id,label',
    'create_dd_table stamps id->id and label->label');

-- managed F→T path (enable_dd_table) also stamps the timestamps with ctype='audit'.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('ct_enable_probe', 'ct_enable', 'CT Enable', 'CT Enables', 'enable ctype probe',
    1, 'public:read', 'admin', 'id', 'label', FALSE);

UPDATE entities SET managed = TRUE WHERE table_name = 'ct_enable_probe';

SELECT is(
    (SELECT count(*)::int FROM fields
     WHERE table_name = 'ct_enable_probe'
       AND field_name IN ('created_at', 'updated_at')
       AND ctype = 'audit'),
    2,
    'enable_dd_table stamps both timestamp ctypes (audit) on the F→T toggle');

-- =====================================================
-- PART 2: ctype lock and core-column protection
-- =====================================================
-- Test (b7): ctype is the single, un-tamperable core marker.
--
-- is_core was dropped; protection (no rename/format/default/delete of a core column) now keys on
-- `ctype <> ''`. For that to be sound, ctype must be settable ONLY by privileged DD code and
-- immutable thereafter — otherwise a tenant admin (who holds the fields edit permission 'admin')
-- could mint a ctype on a field, or clear the id column's ctype to "free" it for deletion.
-- The fields_ctype_lock trigger enforces this: non-privileged (NOBYPASSRLS) callers get ctype
-- forced to '' on INSERT and a hard rejection on any UPDATE that changes ctype. is_core is
-- derived in get_schema as (ctype <> '').
--
-- Fixtures: user3 = Administrator (holds 'admin' = the fields edit permission, yet still cannot
-- set/clear ctype because the lock keys on BYPASSRLS, not on app permissions).

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

-- An entity created via the DD (create_dd_table runs SECURITY DEFINER = privileged) gets its
-- structural ctypes stamped (id/label/audit) — that privileged path is covered in 0339.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lk_probe', 'lk_probe', 'Lock Probe', 'Lock Probes', 'ctype lock probe',
    1, 'public:read', 'admin', 'id', 'label');

-- ── Lock on INSERT: a user cannot mint a ctype ───────────────────────────────
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype)
VALUES ('lk_probe', 'sneaky', 'Sneaky', 'text', 50, 'default', 'default', 'core');

SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'lk_probe' AND field_name = 'sneaky'),
    '',
    'user-supplied ctype is forced to empty on INSERT (cannot mint a core marker)');

-- ── Lock on UPDATE: ctype is immutable for users ─────────────────────────────
SELECT throws_ok(
    $$UPDATE fields SET ctype = 'core' WHERE table_name = 'lk_probe' AND field_name = 'sneaky'$$,
    '90214',
    NULL,
    'user cannot set ctype on an existing field (immutable)');

SELECT throws_ok(
    $$UPDATE fields SET ctype = '' WHERE table_name = 'lk_probe' AND field_name = 'id'$$,
    '90214',
    NULL,
    'user cannot clear the id column''s ctype to escape protection');

-- ── Protection keys on ctype: a 'core' metadata column cannot be deleted ──────
-- user3 holds 'admin' (the fields edit permission) so RLS permits the DELETE; the all-roles
-- delete guard blocks it because entities.view_permission carries ctype='core'.
SELECT throws_ok(
    $$DELETE FROM fields WHERE table_name = 'entities' AND field_name = 'view_permission'$$,
    '90217',
    NULL,
    'a core (ctype=core) metadata column cannot be deleted');

-- ── is_core derived from ctype in get_schema ─────────────────────────────────
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width)
VALUES ('lk_probe', 'note', 'Note', 'text', 60, 'default', 'default');

SELECT is(
    (public.get_schema('lk_probe')::jsonb->'properties'->'id'->>'is_core'),
    'true',
    'get_schema derives is_core=true for a core column (id)');

SELECT is(
    (public.get_schema('lk_probe')::jsonb->'properties'->'note'->>'is_core'),
    'false',
    'get_schema derives is_core=false for a normal (ctype empty) column');

-- ── Not over-protected: a normal field (ctype empty) is freely deletable ──────
SELECT lives_ok(
    $$DELETE FROM fields WHERE table_name = 'lk_probe' AND field_name = 'sneaky'$$,
    'a normal field (empty ctype) is deletable — protection is scoped to core columns');

SELECT * FROM finish();
ROLLBACK;
