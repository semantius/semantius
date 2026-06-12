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
BEGIN;

SELECT plan(7);

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
    '42501',
    NULL,
    'user cannot set ctype on an existing field (immutable)');

SELECT throws_ok(
    $$UPDATE fields SET ctype = '' WHERE table_name = 'lk_probe' AND field_name = 'id'$$,
    '42501',
    NULL,
    'user cannot clear the id column''s ctype to escape protection');

-- ── Protection keys on ctype: a 'core' metadata column cannot be deleted ──────
-- user3 holds 'admin' (the fields edit permission) so RLS permits the DELETE; the all-roles
-- delete guard blocks it because entities.view_permission carries ctype='core'.
SELECT throws_ok(
    $$DELETE FROM fields WHERE table_name = 'entities' AND field_name = 'view_permission'$$,
    'P0001',
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
