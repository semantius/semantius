-- Tests for DDL rename support:
--   1. entities.table_name rename  → physical table renamed
--      Also renames: updated_at trigger, RLS policies, GIN search_vector index
--   2. fields.field_name rename    → physical column renamed
--      Also renames: FK constraints, indexes, check constraints
--   3. fields.format change        → rejected when data type would change
--
-- Both success and failure cases are covered for each scenario.
BEGIN;

SELECT plan(24);

SELECT authenticate_as('user3');

-- =====================================================
-- SETUP: Create a throw-away entity and some fields
-- to use throughout this test.
-- The label column (item_name) is searchable so a search_vector
-- column and GIN index get created for this table.
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'rename_test_entity', 'item', 'Item', 'Items',
    'Temporary entity for rename tests',
    1001, 'public:read', 'sales:manage', 'id', 'item_name'
);

-- Add a plain text field
INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'rename_test_entity', 'old_col', 'Old Column', 'text',
    FALSE, 10, 'default', 'default', ''
);

-- Add a same-type format pair: email (TEXT) → hostname (TEXT)
INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'rename_test_entity', 'contact_field', 'Contact', 'email',
    FALSE, 20, 'default', 'default', ''
);

-- Add a field that will be used to test incompatible format change (text → int32)
INSERT INTO fields (
    table_name, field_name, title, format,
    is_nullable, field_order, input_type, width, default_value
) VALUES (
    'rename_test_entity', 'type_change_field', 'Type Change', 'text',
    FALSE, 30, 'default', 'default', ''
);

-- =====================================================
-- TEST 1: entities.table_name rename — SUCCESS
-- The physical table should be renamed in the database,
-- along with its trigger, RLS policies, and GIN index.
-- =====================================================

-- Confirm table exists under the original name
SELECT has_table(
    'public',
    'rename_test_entity',
    'rename_test_entity table should exist before rename'
);

-- Perform the rename
SELECT lives_ok(
    $$UPDATE entities SET table_name = 'renamed_entity'
      WHERE table_name = 'rename_test_entity'$$,
    'Renaming entities.table_name should succeed'
);

-- Original table should no longer exist
SELECT hasnt_table(
    'public',
    'rename_test_entity',
    'rename_test_entity should not exist after rename'
);

-- New table should exist
SELECT has_table(
    'public',
    'renamed_entity',
    'renamed_entity should exist after rename'
);

-- Columns should still be present in the renamed table
SELECT has_column(
    'public', 'renamed_entity', 'old_col',
    'old_col column should still exist in renamed table'
);

-- Fields metadata should reference the new table name
SELECT ok(
    (SELECT count(*) FROM fields WHERE table_name = 'renamed_entity') > 0,
    'fields rows should reference renamed_entity'
);

SELECT is(
    (SELECT count(*)::integer FROM fields WHERE table_name = 'rename_test_entity'),
    0,
    'No fields rows should reference old table name rename_test_entity'
);

-- Updated_at trigger should have the new name
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'renamed_entity'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'update_renamed_entity_updated_at'
    ),
    'Trigger update_renamed_entity_updated_at should exist after table rename'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'renamed_entity'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'update_rename_test_entity_updated_at'
    ),
    'Trigger update_rename_test_entity_updated_at should not exist after table rename'
);

-- RLS policies should have the new names
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policy p
        JOIN pg_class c ON p.polrelid = c.oid
        WHERE c.relname = 'renamed_entity'
          AND c.relnamespace = 'public'::regnamespace
          AND p.polname = 'renamed_entity_select_policy'
    ),
    'RLS policy renamed_entity_select_policy should exist after table rename'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_policy p
        JOIN pg_class c ON p.polrelid = c.oid
        WHERE c.relname = 'renamed_entity'
          AND c.relnamespace = 'public'::regnamespace
          AND p.polname = 'rename_test_entity_select_policy'
    ),
    'Old RLS policy rename_test_entity_select_policy should not exist after table rename'
);

-- GIN search_vector index should have the new name
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'renamed_entity'
          AND indexname = 'renamed_entity_search_vector_idx'
    ),
    'GIN index renamed_entity_search_vector_idx should exist after table rename'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexname = 'rename_test_entity_search_vector_idx'
    ),
    'Old GIN index rename_test_entity_search_vector_idx should not exist after table rename'
);

-- =====================================================
-- TEST 2: entities.table_name rename — FAILURE
-- Renaming to an already-existing table name should fail
-- because ALTER TABLE RENAME fails.
-- =====================================================

SELECT throws_ok(
    $$UPDATE entities SET table_name = 'customers_test'
      WHERE table_name = 'renamed_entity'$$,
    NULL,
    NULL,
    'Renaming to an already-existing table name should fail'
);

-- The entity should still exist under its pre-failed-rename name
SELECT has_table(
    'public',
    'renamed_entity',
    'renamed_entity should still exist after failed rename'
);

-- =====================================================
-- TEST 3: fields.field_name rename — SUCCESS
-- The physical column should be renamed in the database.
-- =====================================================

SELECT has_column(
    'public', 'renamed_entity', 'old_col',
    'old_col column should exist before field rename'
);

SELECT lives_ok(
    $$UPDATE fields SET field_name = 'new_col'
      WHERE table_name = 'renamed_entity' AND field_name = 'old_col'$$,
    'Renaming fields.field_name should succeed'
);

-- Old column should no longer exist
SELECT hasnt_column(
    'public', 'renamed_entity', 'old_col',
    'old_col column should not exist after rename'
);

-- New column should exist
SELECT has_column(
    'public', 'renamed_entity', 'new_col',
    'new_col column should exist after rename'
);

-- =====================================================
-- TEST 4: fields.field_name rename — FAILURE
-- Renaming to a column name that already exists should fail.
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET field_name = 'new_col'
      WHERE table_name = 'renamed_entity' AND field_name = 'contact_field'$$,
    NULL,
    NULL,
    'Renaming to an already-existing column name should fail'
);

-- Original column should still exist under its original name
SELECT has_column(
    'public', 'renamed_entity', 'contact_field',
    'contact_field should still exist after failed rename'
);

-- =====================================================
-- TEST 5: fields.format change — SUCCESS (same data type)
-- Changing email → hostname is allowed (both map to TEXT).
-- =====================================================

SELECT lives_ok(
    $$UPDATE fields SET format = 'hostname'
      WHERE table_name = 'renamed_entity' AND field_name = 'contact_field'$$,
    'Changing format from email to hostname (both TEXT) should succeed'
);

-- =====================================================
-- TEST 6: fields.format change — FAILURE (different data type)
-- Changing text → int32 must be rejected (TEXT ≠ INTEGER).
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET format = 'int32'
      WHERE table_name = 'renamed_entity' AND field_name = 'type_change_field'$$,
    'P0001',
    NULL,
    'Changing format from text to int32 (TEXT→INTEGER) should be rejected'
);

-- Field format should be unchanged after failed update
SELECT is(
    (SELECT format FROM fields
     WHERE table_name = 'renamed_entity' AND field_name = 'type_change_field'),
    'text',
    'format should remain text after rejected change'
);

SELECT * FROM finish();
ROLLBACK;

