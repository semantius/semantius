-- Test (b7): ctype coverage for the managed record-versioning timestamps.
--
-- spec v2 I6 identifies a core column by `ctype <> ''`. created_at / updated_at are DD-managed
-- record-versioning columns, grouped under the single ctype 'audit' (room for created_by/
-- updated_by later). They must carry ctype='audit' both in the valid_ctype CHECK / fields.ctype
-- enum and on every actual field row (bootstrap + newly created tables). Protection (the b7
-- guards) keys on ctype, and is_core is derived as (ctype <> '').
--
-- Fixtures: user3 = Administrator.
BEGIN;

SELECT plan(6);

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

SELECT * FROM finish();
ROLLBACK;
