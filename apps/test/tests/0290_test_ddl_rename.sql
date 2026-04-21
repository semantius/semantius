-- Tests for DDL rename support.
--
-- Uses deliberately unique / unmistakable names:
--   table  : qwertz1  (renamed to qwertz2)
--   field  : rtzup2   (renamed to rtzup3)
--
-- After each rename the postgres catalog is scanned end-to-end so that any
-- forgotten artifact (sequence, PK constraint, FK constraint, FK index, check
-- constraint, unique index, trigger, RLS policy, GIN index, …) is caught as a
-- test failure rather than silent leftover noise.
BEGIN;

SELECT plan(21);

SELECT authenticate_as('user3');

-- =====================================================
-- SETUP
-- Create entity "qwertz1" with several fields so that
-- the rename exercise covers all catalog object types:
--   • label column  (searchable)  → GIN search_vector index
--   • reference field "rtzup2"    → FK constraint + FK index
--   • plain text field "other_col"
--   • email field "contact_field" (for format-change tests)
--   • text field "type_chg_field" (for incompatible format-change test)
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'qwertz1', 'item', 'Item', 'Items',
    'Catalog-scan rename test entity',
    1001, 'public:read', 'sales:manage', 'id', 'item_name'
);

-- reference field → creates qwertz1_rtzup2_fkey + idx_qwertz1_rtzup2
INSERT INTO fields (
    table_name, field_name, title, format, reference_table, reference_delete_mode,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'qwertz1', 'rtzup2', 'Region', 'reference', 'regions_test', 'restrict',
    TRUE, 10, 'default', 'default', ''
);

INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'qwertz1', 'other_col', 'Other Column', 'text',
    FALSE, 20, 'default', 'default', ''
);

INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'qwertz1', 'contact_field', 'Contact', 'email',
    FALSE, 30, 'default', 'default', ''
);

INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'qwertz1', 'type_chg_field', 'Type Change', 'text',
    FALSE, 40, 'default', 'default', ''
);

-- =====================================================
-- TEST 1: field rename rtzup2 → rtzup3 succeeds
-- =====================================================

SELECT lives_ok(
    $$UPDATE fields SET field_name = 'rtzup3'
      WHERE table_name = 'qwertz1' AND field_name = 'rtzup2'$$,
    'Renaming field rtzup2 → rtzup3 should succeed'
);

-- =====================================================
-- TEST 2: no trace of rtzup2 in the catalog for qwertz1
--
-- Checks pg_attribute (column names), pg_constraint (constraint names),
-- and pg_indexes (index names) for the table qwertz1.
-- =====================================================

SELECT is_empty(
    $$
    SELECT 'pg_attribute: ' || attname AS artifact
    FROM   pg_attribute a
    JOIN   pg_class c ON a.attrelid = c.oid
    WHERE  c.relname = 'qwertz1'
      AND  c.relnamespace = 'public'::regnamespace
      AND  a.attname LIKE '%rtzup2%'
      AND  a.attnum > 0
    UNION ALL
    SELECT 'pg_constraint: ' || conname
    FROM   pg_constraint c
    JOIN   pg_class t ON c.conrelid = t.oid
    WHERE  t.relname = 'qwertz1'
      AND  t.relnamespace = 'public'::regnamespace
      AND  c.conname LIKE '%rtzup2%'
    UNION ALL
    SELECT 'pg_indexes: ' || indexname
    FROM   pg_indexes
    WHERE  schemaname = 'public'
      AND  tablename  = 'qwertz1'
      AND  indexname LIKE '%rtzup2%'
    $$,
    'No trace of rtzup2 should remain in the catalog for qwertz1 after field rename'
);

-- Renamed column should exist under the new name
SELECT has_column(
    'public', 'qwertz1', 'rtzup3',
    'Column rtzup3 should exist after field rename'
);

-- =====================================================
-- TEST 3: table rename qwertz1 → qwertz2 succeeds
-- =====================================================

SELECT has_table('public', 'qwertz1', 'qwertz1 should exist before table rename');

SELECT lives_ok(
    $$UPDATE entities SET table_name = 'qwertz2'
      WHERE table_name = 'qwertz1'$$,
    'Renaming entity qwertz1 → qwertz2 should succeed'
);

SELECT hasnt_table('public', 'qwertz1', 'qwertz1 should not exist after table rename');
SELECT has_table('public', 'qwertz2', 'qwertz2 should exist after table rename');

-- =====================================================
-- TEST 4: no trace of qwertz1 anywhere in the public schema catalog
--
-- Checks pg_class (table, sequence, index names),
--        pg_trigger (trigger names),
--        pg_policy (RLS policy names),
--        pg_constraint (constraint names).
-- Any row returned here is a forgotten rename artifact.
-- =====================================================

SELECT is_empty(
    $$
    SELECT 'pg_class: ' || relname AS artifact
    FROM   pg_class
    WHERE  relnamespace = 'public'::regnamespace
      AND  relname LIKE '%qwertz1%'
    UNION ALL
    SELECT 'pg_trigger: ' || t.tgname
    FROM   pg_trigger t
    JOIN   pg_class c ON t.tgrelid = c.oid
    WHERE  c.relnamespace = 'public'::regnamespace
      AND  t.tgname LIKE '%qwertz1%'
    UNION ALL
    SELECT 'pg_policy: ' || p.polname
    FROM   pg_policy p
    JOIN   pg_class c ON p.polrelid = c.oid
    WHERE  c.relnamespace = 'public'::regnamespace
      AND  p.polname LIKE '%qwertz1%'
    UNION ALL
    SELECT 'pg_constraint: ' || c.conname
    FROM   pg_constraint c
    JOIN   pg_class t ON c.conrelid = t.oid
    WHERE  t.relnamespace = 'public'::regnamespace
      AND  c.conname LIKE '%qwertz1%'
    $$,
    'No trace of qwertz1 should remain anywhere in the public schema catalog after table rename'
);

-- Metadata should be updated to reference the new name
SELECT ok(
    (SELECT count(*) FROM fields WHERE table_name = 'qwertz2') > 0,
    'fields rows should reference qwertz2 after table rename'
);

SELECT is(
    (SELECT count(*)::integer FROM fields WHERE table_name = 'qwertz1'),
    0,
    'No fields rows should reference qwertz1 after table rename'
);

-- =====================================================
-- TEST 5: table rename — FAILURE
-- Renaming to an already-existing table name must fail.
-- =====================================================

SELECT throws_ok(
    $$UPDATE entities SET table_name = 'customers_test'
      WHERE table_name = 'qwertz2'$$,
    NULL,
    NULL,
    'Renaming to an already-existing table name should fail'
);

SELECT has_table(
    'public', 'qwertz2',
    'qwertz2 should still exist after failed rename attempt'
);

-- =====================================================
-- TEST 6: field rename — SUCCESS (plain column)
-- =====================================================

SELECT has_column('public', 'qwertz2', 'other_col',
    'other_col should exist before rename');

SELECT lives_ok(
    $$UPDATE fields SET field_name = 'other_col_new'
      WHERE table_name = 'qwertz2' AND field_name = 'other_col'$$,
    'Renaming other_col → other_col_new should succeed'
);

SELECT hasnt_column('public', 'qwertz2', 'other_col',
    'other_col should not exist after rename');

SELECT has_column('public', 'qwertz2', 'other_col_new',
    'other_col_new should exist after rename');

-- =====================================================
-- TEST 7: field rename — FAILURE
-- Renaming to an already-existing column name must fail.
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET field_name = 'other_col_new'
      WHERE table_name = 'qwertz2' AND field_name = 'contact_field'$$,
    NULL,
    NULL,
    'Renaming to an already-existing column name should fail'
);

SELECT has_column('public', 'qwertz2', 'contact_field',
    'contact_field should still exist after failed column rename');

-- =====================================================
-- TEST 8: format change — SUCCESS (same data type)
-- email → hostname: both map to TEXT, change is allowed.
-- =====================================================

SELECT lives_ok(
    $$UPDATE fields SET format = 'hostname'
      WHERE table_name = 'qwertz2' AND field_name = 'contact_field'$$,
    'Changing format from email to hostname (both TEXT) should succeed'
);

-- =====================================================
-- TEST 9: format change — FAILURE (incompatible data type)
-- text → int32: TEXT ≠ INTEGER, must be rejected.
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET format = 'int32'
      WHERE table_name = 'qwertz2' AND field_name = 'type_chg_field'$$,
    'P0001',
    NULL,
    'Changing format from text to int32 (TEXT→INTEGER) should be rejected'
);

SELECT is(
    (SELECT format FROM fields
     WHERE table_name = 'qwertz2' AND field_name = 'type_chg_field'),
    'text',
    'format should remain text after rejected incompatible format change'
);

SELECT * FROM finish();
ROLLBACK;

