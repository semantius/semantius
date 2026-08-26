-- Test reference_delete_mode validation
-- ===========================================
-- Also covers the fields validation rules for reference_table and format:
--   Rule 1: reference_table set (non-empty) => format must be 'reference' or 'parent'
--           (check constraint reference_table_requires_reference_format, 23514)
--   Rule 2: format 'reference' or 'parent' => reference_table must be non-empty
--           (check constraint reference_requires_table, 23514)
-- plus enum_values defaulting/normalisation. All entities here are managed=FALSE
-- (no DDL is executed; the checks live on the fields table itself).

BEGIN;

SELECT plan(26);

-- =====================================================
-- TEST 1: reference_delete_mode can be empty when reference_table is empty
-- =====================================================

-- Create test table first
INSERT INTO entities (table_name, singular_label, managed, module_id)
VALUES ('test_table', 'Test Table', FALSE, 1);

-- Test that we CAN insert a field with reference_delete_mode='' when reference_table is empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field1', 'Test Field 1', 'text', 10, '', '')$$,
    'Can insert field with reference_delete_mode=empty string when reference_table is empty'
);

-- Clean up test field
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_field1';

-- =====================================================
-- TEST 2: reference_delete_mode can be 'restrict' when reference_table is empty (meaningless but allowed)
-- =====================================================

-- Test that we CAN insert a field with reference_delete_mode='restrict' when reference_table is empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field2', 'Test Field 2', 'text', 10, '', 'restrict')$$,
    'Can insert field with reference_delete_mode=restrict when reference_table is empty (value ignored)'
);

-- Clean up test field
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_field2';

-- =====================================================
-- TEST 3: reference_delete_mode can be 'restrict' when reference_table is non-empty
-- =====================================================

-- First, create a test table to reference
INSERT INTO entities (table_name, singular_label, managed, module_id)
VALUES ('test_ref_table', 'Test Ref Table', FALSE, 1);

-- Test that we CAN insert a field with reference_delete_mode='restrict' when reference_table is non-empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field1', 'Test Ref Field 1', 'reference', 20, 'test_ref_table', 'restrict')$$,
    'Can insert field with reference_delete_mode=restrict when reference_table is non-empty'
);

-- Verify the field was inserted correctly
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'test_table' AND field_name = 'test_ref_field1'),
    'restrict',
    'Field with reference_table has reference_delete_mode=restrict'
);

-- Clean up
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_ref_field1';

-- =====================================================
-- TEST 4: reference_delete_mode can be 'clear' when reference_table is non-empty
-- =====================================================

-- Test that we CAN insert a field with reference_delete_mode='clear' when reference_table is non-empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field2', 'Test Ref Field 2', 'reference', 30, 'test_ref_table', 'clear')$$,
    'Can insert field with reference_delete_mode=clear when reference_table is non-empty'
);

-- Verify the field was inserted correctly
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'test_table' AND field_name = 'test_ref_field2'),
    'clear',
    'Field with reference_table has reference_delete_mode=clear'
);

-- Clean up
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_ref_field2';

-- =====================================================
-- TEST 5: reference_delete_mode cannot be invalid value with non-empty reference_table
-- =====================================================

-- Test that we CANNOT insert a field with invalid reference_delete_mode='xxx' when reference_table is non-empty
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field3', 'Test Ref Field 3', 'reference', 40, 'test_ref_table', 'xxx')$$,
    23514, -- CHECK constraint violation
    NULL,
    'Cannot insert field with reference_delete_mode=xxx when reference_table is non-empty'
);

-- =====================================================
-- TEST 6: reference_delete_mode cannot be invalid value with empty reference_table
-- =====================================================

-- Test that we CANNOT insert a field with invalid reference_delete_mode='xxx' when reference_table is empty
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field3', 'Test Field 3', 'text', 50, '', 'xxx')$$,
    23514, -- CHECK constraint violation
    NULL,
    'Cannot insert field with reference_delete_mode=xxx when reference_table is empty'
);

-- =====================================================
-- TEST 7: Verify DEFAULT value is 'restrict' for new field without explicit value
-- =====================================================

-- Insert a field without specifying reference_delete_mode to test DEFAULT
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table)
VALUES ('test_table', 'test_default_field', 'Test Default Field', 'reference', 60, 'test_ref_table');

-- Verify DEFAULT is 'restrict'
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'test_table' AND field_name = 'test_default_field'),
    'restrict',
    'Field without explicit reference_delete_mode defaults to restrict'
);

-- Clean up
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_default_field';

-- =====================================================
-- TEST 8: Verify empty string behaves like 'restrict' in generated foreign keys
-- =====================================================

-- Test that we CAN insert a field with reference_delete_mode='' when reference_table is non-empty
-- Empty string should be treated as 'restrict' when generating foreign key SQL
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_empty_mode', 'Test Empty Mode', 'reference', 70, 'test_ref_table', '')$$,
    'Can insert field with reference_delete_mode=empty string when reference_table is non-empty (treated as restrict)'
);

-- Clean up
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_empty_mode';
DELETE FROM entities WHERE table_name = 'test_ref_table';

-- =====================================================
-- TEST 9: reference_delete_mode can be 'cascade' with reference format
-- =====================================================

INSERT INTO entities (table_name, singular_label, managed, module_id)
VALUES ('test_ref_table2', 'Test Ref Table 2', FALSE, 1);

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_cascade_field', 'Test Cascade Field', 'reference', 80, 'test_ref_table2', 'cascade')$$,
    'Can insert field with reference_delete_mode=cascade'
);

SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'test_table' AND field_name = 'test_cascade_field'),
    'cascade',
    'Field with reference_delete_mode=cascade is stored correctly'
);

DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_cascade_field';

-- =====================================================
-- TEST 10 (was 8 position): parent format requires reference_table
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_parent_no_ref', 'Test Parent No Ref', 'parent', 90, '', 'cascade')$$,
    23514, -- CHECK constraint violation (reference_requires_table)
    NULL,
    'Cannot insert parent format field without reference_table'
);

-- =====================================================
-- TEST 11: parent format with valid reference_table
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_parent_field', 'Test Parent Field', 'parent', 95, 'test_ref_table2', 'cascade')$$,
    'Can insert field with parent format and cascade delete mode'
);

SELECT is(
    (SELECT format FROM fields WHERE table_name = 'test_table' AND field_name = 'test_parent_field'),
    'parent',
    'Parent format field is stored correctly'
);

-- =====================================================
-- TEST 12: is_child flag on entities is updated for parent format
-- =====================================================

SELECT is(
    (SELECT is_child FROM entities WHERE table_name = 'test_table'),
    TRUE,
    'entities.is_child should be TRUE when a parent format field exists'
);

DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_parent_field';

SELECT is(
    (SELECT is_child FROM entities WHERE table_name = 'test_table'),
    FALSE,
    'entities.is_child should be FALSE after parent format field is removed'
);

-- =====================================================
-- TEST 13: INSERT validation - reference_table without matching format
-- Rule 1: reference_table set => format must be 'reference' or 'parent'
-- =====================================================

-- Insert field with reference_table set but format='text' should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table)
      VALUES ('test_table', 'bad_ref_field', 'Bad Ref Field', 'text', 100, 'test_ref_table2')$$,
    23514,
    NULL,
    'Should reject INSERT when reference_table is set but format is not "reference" or "parent"'
);

-- Insert field with reference_table set but format='integer' should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table)
      VALUES ('test_table', 'bad_ref_field2', 'Bad Ref Field 2', 'integer', 100, 'test_ref_table2')$$,
    23514,
    NULL,
    'Should reject INSERT when reference_table is set but format is "integer" (not reference/parent)'
);

-- =====================================================
-- TEST 14: INSERT validation - reference format without reference_table
-- Rule 2: format=reference => reference_table must be non-empty
-- (the 'parent' variant is TEST 10 above)
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order)
      VALUES ('test_table', 'bad_ref_field3', 'Bad Ref Field 3', 'reference', 100)$$,
    23514,
    NULL,
    'Should reject INSERT when format is "reference" but reference_table is empty (default)'
);

-- =====================================================
-- TEST 15: UPDATE validation on existing text / reference fields
-- =====================================================

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('test_table', 'val_text_field', 'Validation Text Field', 'text', 110);

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('test_table', 'val_ref_field', 'Validation Ref Field', 'reference', 120, 'test_ref_table2', 'restrict');

-- Rule 1: adding a reference_table to a text field should fail
SELECT throws_ok(
    $$UPDATE fields SET reference_table = 'test_ref_table2'
      WHERE table_name = 'test_table' AND field_name = 'val_text_field'$$,
    23514,
    NULL,
    'Should reject UPDATE when reference_table is set on a field with non-reference/parent format'
);

-- Rule 2: clearing the reference_table of a reference field should fail
SELECT throws_ok(
    $$UPDATE fields SET reference_table = ''
      WHERE table_name = 'test_table' AND field_name = 'val_ref_field'$$,
    23514,
    NULL,
    'Should reject UPDATE when reference_table is cleared on a field with format "reference"'
);

DELETE FROM fields WHERE table_name = 'test_table' AND field_name IN ('val_text_field', 'val_ref_field');

-- =====================================================
-- TEST 16: enum_values default and normalization
-- =====================================================

-- Insert field without enum_values => column default is NULL
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order)
      VALUES ('test_table', 'test_no_enum_val', 'No Enum Val', 'text', 130)$$,
    'Insert text field without enum_values should succeed'
);

SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'test_table' AND field_name = 'test_no_enum_val'),
    NULL::jsonb,
    'enum_values should default to NULL when not provided'
);

-- Insert field with enum_values='{}' (JSON object) => coerced to NULL by lock_field_ctype trigger
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, enum_values)
      VALUES ('test_table', 'test_obj_enum_val', 'Obj Enum Val', 'text', 140, '{}'::jsonb)$$,
    'Insert field with enum_values=''{}''.jsonb should succeed (coerced to NULL)'
);

SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'test_table' AND field_name = 'test_obj_enum_val'),
    NULL::jsonb,
    'enum_values=''{}''.jsonb should be coerced to NULL by the BEFORE INSERT trigger'
);

DELETE FROM fields WHERE table_name = 'test_table' AND field_name IN ('test_no_enum_val', 'test_obj_enum_val');

-- Clean up
DELETE FROM entities WHERE table_name = 'test_ref_table2';

SELECT * FROM finish();
ROLLBACK;
