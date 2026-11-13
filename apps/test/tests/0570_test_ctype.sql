-- ctype, the core-column marker: coverage of the record-versioning
-- timestamps, and the lock that keeps ctype and core columns protected.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. ctype coverage for the record-versioning timestamps
--   2. ctype lock and core-column protection
--   3. the derived marker of a computed field
--   4. the label marker follows entities.label_column
BEGIN;

SELECT plan(38);

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

-- The ctype enum enumerates the b7 marker set, plus the derived markers:
-- rollup for a field the database aggregates (0440_rollup.sql), computed for
-- a field one of the entity's computed_fields writes (0210), the two managed
-- markers dd_ctype_is_core does not count as core, and computed_label for a
-- label column such a rule writes, which stays core like label.
SELECT is(
    (SELECT enum_value_list(enum_values) FROM fields WHERE table_name = 'fields' AND field_name = 'ctype'),
    '["", "id", "label", "audit", "core", "rollup", "computed", "computed_label"]'::jsonb,
    'fields.ctype enum_values are the b7 marker set plus rollup, computed and computed_label');

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

-- =====================================================
-- PART 3: the derived marker of a computed field
-- =====================================================
-- A field one of its entity's computed_fields names carries ctype 'computed',
-- and the label column 'computed_label' (zz_derive_computed_ctype,
-- 0210_computed_validation.sql). Every way into and out of the two markers:
-- the field created after its rule, the rule added after the field, the rule
-- removed, one rule change that moves several fields at once, a rename away
-- from the rule and back onto it, for a plain field and for the label column.
-- The marker is never set or cleared by hand, computed is not core,
-- computed_label keeps the label's protection, and input_type stays what the
-- author set.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, computed_fields)
VALUES ('cc_probe', 'cc_probe', 'CC Probe', 'CC Probes', 'computed ctype probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "label", "jsonlogic": {"cat": ["L", {"var": "qty"}]}},
      {"name": "total", "jsonlogic": {"*": [{"var": "qty"}, 2]}}]'::jsonb);
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type)
VALUES ('cc_probe', 'qty', 'Qty', 'int32', 10, 'default'),
       ('cc_probe', 'total', 'Total', 'int32', 20, 'readonly');

-- '' -> computed (field created after its rule), label -> computed_label (the
-- label column created with an entity whose rule names it).
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype || ':' || input_type, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'cc_probe' AND field_name IN ('label', 'qty', 'total')),
    'label:computed_label:required, qty::default, total:computed:readonly',
    'fields created after their rule are marked computed and computed_label, their input_type untouched; an unnamed field stays plain');

-- '' -> computed (rule added after the field).
UPDATE entities
   SET computed_fields = computed_fields || '[{"name": "qty", "jsonlogic": {"+": [{"var": "qty"}, 0]}}]'::jsonb
 WHERE table_name = 'cc_probe';
SELECT is(
    (SELECT ctype || ':' || input_type FROM fields WHERE table_name = 'cc_probe' AND field_name = 'qty'),
    'computed:default',
    'a rule added after the field marks it and leaves its input_type');

-- One rule change that moves three markers: computed_label -> label and
-- computed -> '' (rules removed), qty stays computed.
UPDATE entities
   SET computed_fields = '[{"name": "qty", "jsonlogic": {"+": [{"var": "qty"}, 0]}}]'::jsonb
 WHERE table_name = 'cc_probe';
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'cc_probe' AND field_name IN ('label', 'qty', 'total')),
    'label:label, qty:computed, total:',
    'removing the label and total rules returns them to label and plain in the same write; qty stays computed');

-- label -> computed_label and '' -> computed (rules added back), computed -> ''
-- (qty's rule removed), again in one write.
UPDATE entities
   SET computed_fields = '[{"name": "label", "jsonlogic": {"cat": ["L", {"var": "qty"}]}},
                           {"name": "total", "jsonlogic": {"*": [{"var": "qty"}, 2]}}]'::jsonb
 WHERE table_name = 'cc_probe';
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype || ':' || input_type, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'cc_probe' AND field_name IN ('label', 'qty', 'total')),
    'label:computed_label:required, qty::default, total:computed:readonly',
    'adding the rules back marks label and total again; qty, whose rule is gone, is plain with its input_type as before');

-- computed -> '' (renamed away from the rule), '' -> computed (renamed onto it).
UPDATE fields SET field_name = 'sum_total' WHERE table_name = 'cc_probe' AND field_name = 'total';
SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'cc_probe' AND field_name = 'sum_total'),
    '',
    'a field renamed away from its rule loses the marker (nothing rewrites computed_fields on a rename)');
UPDATE fields SET field_name = 'total' WHERE table_name = 'cc_probe' AND field_name = 'sum_total';
SELECT is(
    (SELECT ctype FROM fields WHERE table_name = 'cc_probe' AND field_name = 'total'),
    'computed',
    'a field renamed to a name a rule writes gains the marker');

-- computed_label -> label (the label renamed away from its rule), label ->
-- computed_label (renamed back onto it). label_column follows each rename.
UPDATE fields SET field_name = 'caption' WHERE table_name = 'cc_probe' AND field_name = 'label';
SELECT is(
    (SELECT e.label_column || ':' || f.ctype FROM entities e
       JOIN fields f ON f.table_name = e.table_name AND f.field_name = e.label_column
      WHERE e.table_name = 'cc_probe'),
    'caption:label',
    'a computed label renamed away from its rule stays the label, as label');
UPDATE fields SET field_name = 'label' WHERE table_name = 'cc_probe' AND field_name = 'caption';
SELECT is(
    (SELECT e.label_column || ':' || f.ctype FROM entities e
       JOIN fields f ON f.table_name = e.table_name AND f.field_name = e.label_column
      WHERE e.table_name = 'cc_probe'),
    'label:computed_label',
    'a label renamed to the name its rule writes becomes computed_label again');

-- Never by hand: not set on a plain field, not cleared, not swapped.
SELECT throws_ok(
    $$UPDATE fields SET ctype = 'computed' WHERE table_name = 'cc_probe' AND field_name = 'qty'$$,
    '90214', NULL,
    'the computed marker cannot be set by hand');
SELECT throws_ok(
    $$UPDATE fields SET ctype = 'computed_label' WHERE table_name = 'cc_probe' AND field_name = 'qty'$$,
    '90214', NULL,
    'the computed_label marker cannot be set by hand');
SELECT throws_ok(
    $$UPDATE fields SET ctype = 'label' WHERE table_name = 'cc_probe' AND field_name = 'label'$$,
    '90214', NULL,
    'a computed label cannot be turned back into label by hand');
SELECT throws_ok(
    $$UPDATE fields SET ctype = '' WHERE table_name = 'cc_probe' AND field_name = 'total'$$,
    '90214', NULL,
    'the computed marker cannot be cleared by hand');

-- computed_label keeps the label's protection; computed is not core.
SELECT throws_ok(
    $$DELETE FROM fields WHERE table_name = 'cc_probe' AND field_name = 'label'$$,
    '90217', NULL,
    'a computed label cannot be deleted');
SELECT throws_ok(
    $$UPDATE fields SET format = 'multiline' WHERE table_name = 'cc_probe' AND field_name = 'label'$$,
    '90219', NULL,
    'the format of a computed label cannot change');
SELECT lives_ok(
    $$UPDATE fields SET default_value = 'x' WHERE table_name = 'cc_probe' AND field_name = 'label'$$,
    'the default of a computed label may change, as on any label');
SELECT is(
    (SELECT jsonb_build_array(s -> 'label' ->> 'ctype', s -> 'label' ->> 'is_core',
                              s -> 'total' ->> 'ctype', s -> 'total' ->> 'is_core')
       FROM (SELECT public.get_schema('cc_probe')::jsonb -> 'properties' AS s) x),
    '["computed_label", "true", "computed", "false"]'::jsonb,
    'get_schema shows both markers: computed_label is core, computed is not');

-- =====================================================
-- PART 4: the label marker follows entities.label_column
-- =====================================================
-- Pointing label_column at another field moves the marker
-- (dd_label_marker_follow, 0160_dd_functions.sql): the field it leaves becomes
-- plain, or computed if a rule names it, and loses the label's protection; the
-- field it names becomes label, or computed_label if a rule names it. A field
-- that carries another marker (id, audit, core, rollup) cannot become the label
-- (90270). The search vector weights the label A, so it follows the move.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, computed_fields)
VALUES ('lm_probe', 'lm_probe', 'LM Probe', 'LM Probes', 'label marker probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "calc", "jsonlogic": {"cat": ["C-", {"var": "code"}]}}]'::jsonb),
       ('lm_child', 'lm_child', 'LM Child', 'LM Children', 'label marker rollup child',
    1, 'public:read', 'admin', 'id', 'label', '[]'::jsonb);
INSERT INTO fields (table_name, field_name, title, format, field_order, searchable)
VALUES ('lm_probe', 'code', 'Code', 'text', 10, TRUE),
       ('lm_probe', 'calc', 'Calc', 'text', 20, FALSE);
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lm_child', 'parent_id', 'Parent', 'parent', 10, 'lm_probe', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('lm_probe', 'kids', 'Kids', 'int64', 30, '{"link_field": "lm_child.parent_id", "function": "count"}');

-- label -> '' on the field left, '' -> label on the field named.
UPDATE entities SET label_column = 'code' WHERE table_name = 'lm_probe';
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'lm_probe' AND field_name IN ('label', 'code', 'calc')),
    'calc:computed, code:label, label:',
    'moving label_column to a plain field makes it the label and the old label plain');
SELECT ok(
    (SELECT pg_get_expr(d.adbin, d.adrelid)
       FROM pg_attrdef d
       JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      WHERE d.adrelid = 'public.lm_probe'::regclass AND a.attname = 'search_vector')
      ~ 'COALESCE\(code,[^)]*\)\), ''A''',
    'the search vector is rebuilt and weights the new label A');
SELECT is(
    (public.get_schema('lm_probe')::jsonb -> 'properties' -> 'label' ->> 'is_core'),
    'false',
    'the field label_column left is no longer core');

-- label -> '' on the field left, computed -> computed_label on the field named.
UPDATE entities SET label_column = 'calc' WHERE table_name = 'lm_probe';
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'lm_probe' AND field_name IN ('label', 'code', 'calc')),
    'calc:computed_label, code:, label:',
    'moving label_column to a computed field makes it computed_label');

-- computed_label -> computed on the field left, '' -> label on the field named.
UPDATE entities SET label_column = 'code' WHERE table_name = 'lm_probe';
SELECT is(
    (SELECT string_agg(field_name || ':' || ctype, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'lm_probe' AND field_name IN ('label', 'code', 'calc')),
    'calc:computed, code:label, label:',
    'moving label_column off a computed label leaves it computed');

-- A field with another marker cannot become the label, and nothing moves.
SELECT throws_ok(
    $$UPDATE entities SET label_column = 'id' WHERE table_name = 'lm_probe'$$,
    '90270', NULL,
    'label_column cannot name the id column');
SELECT throws_ok(
    $$UPDATE entities SET label_column = 'created_at' WHERE table_name = 'lm_probe'$$,
    '90270', NULL,
    'label_column cannot name an audit column');
SELECT throws_ok(
    $$UPDATE entities SET label_column = 'kids' WHERE table_name = 'lm_probe'$$,
    '90270', NULL,
    'label_column cannot name a rollup field');
SELECT is(
    (SELECT e.label_column || ':' || f.ctype FROM entities e
       JOIN fields f ON f.table_name = e.table_name AND f.field_name = e.label_column
      WHERE e.table_name = 'lm_probe'),
    'code:label',
    'a refused move leaves label_column and the marker where they were');

SELECT * FROM finish();
ROLLBACK;
