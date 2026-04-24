-- Test fields validation rules for reference_table and format
-- Rule 1: When reference_table is set (non-empty), format must be 'reference' or 'parent'
--         Enforced by: check constraint reference_table_requires_reference_format (23514)
--                  and AFTER trigger add_dd_field / update_dd_field (P0001)
-- Rule 2: When format is 'reference' or 'parent', reference_table must be non-empty
--         Enforced by: existing check constraint reference_requires_table (23514)
BEGIN;

SELECT plan(8);

-- Authenticate as admin user
SELECT authenticate_as('user3');

-- =====================================================
-- TEST: INSERT validation - reference_table without matching format
-- Rule 1: reference_table set => format must be 'reference' or 'parent'
-- Caught by check constraint reference_table_requires_reference_format (23514)
-- =====================================================

-- Test 1: Insert field with reference_table set but format='text' should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype, reference_table)
      VALUES ('customers_test', 'bad_ref_field', 'Bad Ref Field', 'text', 99, 'default', 'default', '', 'regions_test')$$,
    '23514',
    NULL,
    'Should reject INSERT when reference_table is set but format is not "reference" or "parent"'
);

-- Test 2: Insert field with reference_table set but format='integer' should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype, reference_table)
      VALUES ('customers_test', 'bad_ref_field2', 'Bad Ref Field 2', 'integer', 99, 'default', 'default', '', 'regions_test')$$,
    '23514',
    NULL,
    'Should reject INSERT when reference_table is set but format is "integer" (not reference/parent)'
);

-- =====================================================
-- TEST: INSERT validation - reference/parent format without reference_table
-- Rule 2: format=reference or parent => reference_table must be non-empty
-- Caught by existing check constraint reference_requires_table (23514)
-- =====================================================

-- Test 3: Insert field with format='reference' but no reference_table (empty string default) should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype)
      VALUES ('customers_test', 'bad_ref_field3', 'Bad Ref Field 3', 'reference', 99, 'default', 'default', '')$$,
    '23514',
    NULL,
    'Should reject INSERT when format is "reference" but reference_table is empty (default)'
);

-- Test 4: Insert field with format='parent' but no reference_table (empty string default) should fail
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype)
      VALUES ('regions_test', 'bad_parent_field', 'Bad Parent Field', 'parent', 99, 'default', 'default', '')$$,
    '23514',
    NULL,
    'Should reject INSERT when format is "parent" but reference_table is empty (default)'
);

-- =====================================================
-- TEST: INSERT validation - valid reference and parent fields succeed
-- =====================================================

-- Test 5: Insert field with format='reference' and valid reference_table should succeed
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, ctype, reference_table, reference_delete_mode)
      VALUES ('customers_test', 'test_valid_ref', 'Test Valid Ref', 'reference', 99, 'default', 'default', '', 'regions_test', 'restrict')$$,
    'Should allow INSERT when format is "reference" and reference_table is set'
);

-- =====================================================
-- TEST: UPDATE validation - adding reference_table to a non-reference/parent field
-- Rule 1: reference_table set => format must be 'reference' or 'parent'
-- Caught by check constraint reference_table_requires_reference_format (23514)
-- =====================================================

-- Test 6: Update a text field to add a reference_table should fail
SELECT throws_ok(
    $$UPDATE fields SET reference_table = 'regions_test'
      WHERE table_name = 'customers_test' AND field_name = 'customer_name'$$,
    '23514',
    NULL,
    'Should reject UPDATE when reference_table is set on a field with non-reference/parent format'
);

-- =====================================================
-- TEST: UPDATE validation - removing reference_table from a reference/parent field
-- Rule 2: format=reference or parent => reference_table must be non-empty
-- Caught by existing check constraint reference_requires_table (23514)
-- =====================================================

-- Test 7: Update a reference field to clear its reference_table (to empty string) should fail
SELECT throws_ok(
    $$UPDATE fields SET reference_table = ''
      WHERE table_name = 'customers_test' AND field_name = 'test_valid_ref'$$,
    '23514',
    NULL,
    'Should reject UPDATE when reference_table is cleared on a field with format "reference"'
);

-- Test 8: Update a reference field to change format to text (while reference_table remains set) should fail.
-- The BEFORE UPDATE trigger rejects this first (type change: INTEGER → TEXT, error P0001)
-- before the check constraint (23514) can fire.
SELECT throws_ok(
    $$UPDATE fields SET format = 'text'
      WHERE table_name = 'customers_test' AND field_name = 'test_valid_ref'$$,
    'P0001',
    NULL,
    'Should reject UPDATE when format is changed from "reference" to "text" (type change INTEGER→TEXT)'
);

SELECT * FROM finish();
ROLLBACK;
