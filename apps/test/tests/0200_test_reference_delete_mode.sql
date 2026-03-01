-- Test reference_delete_mode validation
-- ===========================================

BEGIN;

SELECT plan(17);

-- =====================================================
-- TEST 1: reference_delete_mode can be empty when reference_table is empty
-- =====================================================

-- Create test table first
INSERT INTO entities (table_name, singular_label, managed)
VALUES ('test_table', 'Test Table', FALSE);

-- Test that we CAN insert a field with reference_delete_mode='' when reference_table is empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field1', 'Test Field 1', 'text', FALSE, 10, '', '')$$,
    'Can insert field with reference_delete_mode=empty string when reference_table is empty'
);

-- Clean up test field
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_field1';

-- =====================================================
-- TEST 2: reference_delete_mode can be 'restrict' when reference_table is empty (meaningless but allowed)
-- =====================================================

-- Test that we CAN insert a field with reference_delete_mode='restrict' when reference_table is empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field2', 'Test Field 2', 'text', FALSE, 10, '', 'restrict')$$,
    'Can insert field with reference_delete_mode=restrict when reference_table is empty (value ignored)'
);

-- Clean up test field
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_field2';

-- =====================================================
-- TEST 3: reference_delete_mode can be 'restrict' when reference_table is non-empty
-- =====================================================

-- First, create a test table to reference
INSERT INTO entities (table_name, singular_label, managed)
VALUES ('test_ref_table', 'Test Ref Table', FALSE);

-- Test that we CAN insert a field with reference_delete_mode='restrict' when reference_table is non-empty
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field1', 'Test Ref Field 1', 'reference', FALSE, 20, 'test_ref_table', 'restrict')$$,
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
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field2', 'Test Ref Field 2', 'reference', FALSE, 30, 'test_ref_table', 'clear')$$,
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
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_ref_field3', 'Test Ref Field 3', 'reference', FALSE, 40, 'test_ref_table', 'xxx')$$,
    23514, -- CHECK constraint violation
    NULL,
    'Cannot insert field with reference_delete_mode=xxx when reference_table is non-empty'
);

-- =====================================================
-- TEST 6: reference_delete_mode cannot be invalid value with empty reference_table
-- =====================================================

-- Test that we CANNOT insert a field with invalid reference_delete_mode='xxx' when reference_table is empty
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_field3', 'Test Field 3', 'text', FALSE, 50, '', 'xxx')$$,
    23514, -- CHECK constraint violation
    NULL,
    'Cannot insert field with reference_delete_mode=xxx when reference_table is empty'
);

-- =====================================================
-- TEST 7: Verify DEFAULT value is 'restrict' for new field without explicit value
-- =====================================================

-- Insert a field without specifying reference_delete_mode to test DEFAULT
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table)
VALUES ('test_table', 'test_default_field', 'Test Default Field', 'reference', FALSE, 60, 'test_ref_table');

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
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_empty_mode', 'Test Empty Mode', 'reference', FALSE, 70, 'test_ref_table', '')$$,
    'Can insert field with reference_delete_mode=empty string when reference_table is non-empty (treated as restrict)'
);

-- Clean up
DELETE FROM fields WHERE table_name = 'test_table' AND field_name = 'test_empty_mode';
DELETE FROM entities WHERE table_name = 'test_ref_table';

-- =====================================================
-- TEST 9: reference_delete_mode can be 'cascade' with reference format
-- =====================================================

INSERT INTO entities (table_name, singular_label, managed)
VALUES ('test_ref_table2', 'Test Ref Table 2', FALSE);

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_cascade_field', 'Test Cascade Field', 'reference', FALSE, 80, 'test_ref_table2', 'cascade')$$,
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
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_parent_no_ref', 'Test Parent No Ref', 'parent', FALSE, 90, '', 'cascade')$$,
    23514, -- CHECK constraint violation (reference_requires_table)
    NULL,
    'Cannot insert parent format field without reference_table'
);

-- =====================================================
-- TEST 11: parent format with valid reference_table
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, reference_table, reference_delete_mode) 
      VALUES ('test_table', 'test_parent_field', 'Test Parent Field', 'parent', FALSE, 95, 'test_ref_table2', 'cascade')$$,
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

-- Clean up
DELETE FROM entities WHERE table_name = 'test_ref_table2';

SELECT * FROM finish();
ROLLBACK;
