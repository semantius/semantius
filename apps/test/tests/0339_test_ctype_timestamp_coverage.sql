-- Test (b6): ctype coverage for the managed system timestamps.
--
-- spec v2 I6 identifies a core column by `ctype <> ''`. created_at / updated_at are DD-managed
-- core columns, so they must carry a non-empty ctype ('created_at' / 'updated_at') — both in the
-- valid_ctype CHECK / fields.ctype enum and on every actual field row (bootstrap + newly created
-- tables). This readies them for the b7 trigger, which keys core protection on ctype, not is_core.
--
-- Fixtures: user3 = Administrator.
BEGIN;

SELECT plan(7);

SELECT authenticate_as('user3');

-- ── The allowed-value set (CHECK + enum) includes the timestamp ctypes ────────
SELECT is(
    (SELECT count(*)::int FROM fields
     WHERE field_name IN ('created_at', 'updated_at')
       AND ctype IS DISTINCT FROM field_name),
    0,
    'every existing created_at/updated_at field row has ctype = its field_name (backfill complete)');

SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'fields' AND field_name = 'ctype'),
    '["", "id", "label", "created_at", "updated_at"]'::jsonb,
    'fields.ctype enum_values enumerate the timestamp ctypes');

-- ── valid_ctype CHECK accepts the new values and rejects an unknown one ───────
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('ct_probe', 'ct_probe', 'CT Probe', 'CT Probes', 'ctype coverage probe',
    1, 'public:read', 'admin', 'id', 'label');

-- A freshly created managed table's auto-inserted timestamps carry the ctype.
SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'ct_probe' AND field_name = 'created_at'),
    'created_at',
    'create_dd_table stamps created_at with ctype = created_at');
SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'ct_probe' AND field_name = 'updated_at'),
    'updated_at',
    'create_dd_table stamps updated_at with ctype = updated_at');

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype)
      VALUES ('ct_probe', 'ts_marker', 'TS Marker', 'date-time', 50, 'default', 'default', 'created_at')$$,
    'valid_ctype CHECK accepts ctype = created_at');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype)
      VALUES ('ct_probe', 'bogus_marker', 'Bogus', 'text', 60, 'default', 'default', 'bogus_ctype')$$,
    '23514',
    NULL,
    'valid_ctype CHECK rejects an unknown ctype value');

-- ── managed F→T path (enable_dd_table) also stamps the timestamps ─────────────
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('ct_enable_probe', 'ct_enable', 'CT Enable', 'CT Enables', 'enable ctype probe',
    1, 'public:read', 'admin', 'id', 'label', FALSE);

UPDATE entities SET managed = TRUE WHERE table_name = 'ct_enable_probe';

SELECT is(
    (SELECT count(*)::int FROM fields
     WHERE table_name = 'ct_enable_probe'
       AND field_name IN ('created_at', 'updated_at')
       AND ctype = field_name),
    2,
    'enable_dd_table stamps both timestamp ctypes on the F→T toggle');

SELECT * FROM finish();
ROLLBACK;
