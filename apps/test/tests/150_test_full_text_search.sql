-- Test full-text search functionality
BEGIN;

SELECT plan(39);

-- Authenticate as admin user
SELECT authenticate_as('user3');

-- =====================================================
-- TEST: searchable column exists on fields and tables
-- =====================================================

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'fields' AND column_name = 'searchable'
    )),
    'searchable column should exist on fields table'
);

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'tables' AND column_name = 'searchable'
    )),
    'searchable column should exist on tables table'
);

-- =====================================================
-- TEST: Auto-created label field is searchable
-- =====================================================

-- Create a new table and verify its label column is searchable
INSERT INTO tables(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_search_table', 'test_search_table', 'Test Search Table', 'Test Search Tables', 'Test table for full-text search', 1, 'public:read', 'admin', 'id', 'name', TRUE);

SELECT ok(
    (SELECT searchable FROM fields WHERE table_name = 'test_search_table' AND field_name = 'name'),
    'Auto-created label field (name) should be searchable=TRUE'
);

-- =====================================================
-- TEST: search_vector column and index creation
-- =====================================================

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_search_table' AND column_name = 'search_vector'
    )),
    'search_vector column should be created for table with searchable fields'
);

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE tablename = 'test_search_table' AND indexname = 'test_search_table_search_vector_idx'
    )),
    'GIN index on search_vector should be created'
);

-- =====================================================
-- TEST: Adding searchable fields updates search_vector
-- =====================================================

-- Add a searchable field
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, searchable)
VALUES ('test_search_table', 'description', 'Description', 'text', FALSE, FALSE, 10, 'default', 'w', 'Test description field', TRUE);

-- Verify search_vector column still exists (should be recreated with new field)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_search_table' AND column_name = 'search_vector'
    )),
    'search_vector column should still exist after adding searchable field'
);

-- =====================================================
-- TEST: Newly added searchable field is immediately searchable
-- =====================================================

-- Insert a record with a unique value in the newly added description field
INSERT INTO test_search_table (name, description) 
VALUES ('Test Immediate', 'ImmediateSearchTest unique keyword');

-- Immediately search for the unique keyword to verify field is searchable right away
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'ImmediateSearchTest')) = 1,
    'Newly added searchable field should be immediately searchable after INSERT'
);

-- Update the same record with another unique keyword
UPDATE test_search_table SET description = 'UpdatedImmediately unique keyword' WHERE name = 'Test Immediate';

-- Verify the updated value is immediately searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'UpdatedImmediately')) = 1,
    'Updated value in newly added searchable field should be immediately searchable'
);

-- Verify old value is no longer found
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'ImmediateSearchTest')) = 0,
    'Old value should not be found after update'
);

-- Insert test data
INSERT INTO test_search_table (name, description) 
VALUES 
    ('Product Alpha', 'This is a high-quality product for testing'),
    ('Product Beta', 'Another excellent product for verification'),
    ('Service Gamma', 'Premium service offering');

-- =====================================================
-- TEST: Full-text search across multiple columns
-- =====================================================

-- Test search for "product" (should match both name and description)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'product')) = 2,
    'Search for "product" should find 2 records (in name and description)'
);

-- Test search for "alpha" (should match name)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'alpha')) = 1,
    'Search for "alpha" should find 1 record'
);

-- Test search for "service" (should match name)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'service')) = 1,
    'Search for "service" should find 1 record'
);

-- Test search for "quality" (should match description)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'quality')) = 1,
    'Search for "quality" should find 1 record (in description)'
);

-- Test search for "excellent" (should match description)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'excellent')) = 1,
    'Search for "excellent" should find 1 record (in description)'
);

-- Test search spanning multiple columns - "alpha quality"
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'alpha & quality')) = 1,
    'Search for "alpha AND quality" should find 1 record (spanning name and description)'
);

-- =====================================================
-- TEST: Updating searchable field updates search results
-- =====================================================

-- Update a record's searchable field
UPDATE test_search_table SET description = 'Updated description with special keyword' WHERE name = 'Product Alpha';

-- Search should find the updated keyword
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'special')) = 1,
    'Search should find updated keyword in modified record'
);

-- Old keyword should not be found in that record anymore
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'high-quality')) = 0,
    'Search should not find old keyword after update'
);

-- =====================================================
-- TEST: Changing field searchable flag updates search_vector
-- =====================================================

-- Make description field non-searchable
UPDATE fields SET searchable = FALSE WHERE table_name = 'test_search_table' AND field_name = 'description';

-- After making description non-searchable, search should only match name column
-- "special" was only in description, so it should not be found
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'special')) = 0,
    'After making description non-searchable, keywords from description should not be found'
);

-- But name column should still be searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'product')) = 2,
    'Keywords from name column should still be searchable'
);

-- Make description searchable again
UPDATE fields SET searchable = TRUE WHERE table_name = 'test_search_table' AND field_name = 'description';

-- Now "special" should be found again
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'special')) = 1,
    'After making description searchable again, keywords should be found'
);

-- =====================================================
-- TEST: Deleting searchable field updates search_vector
-- =====================================================

-- Add another searchable field
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, searchable, default_value)
VALUES ('test_search_table', 'notes', 'Notes', 'text', FALSE, FALSE, 20, 'default', 'w', 'Additional notes', TRUE, '''''');

-- Add notes to one record
UPDATE test_search_table SET notes = 'Notefield specific content here' WHERE name = 'Product Beta';

-- Verify notes content is searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('english', 'Notefield')) = 1,
    'Newly added searchable field should be included in search'
);

-- Delete the notes field (non-core field)
DELETE FROM fields WHERE table_name = 'test_search_table' AND field_name = 'notes';

-- Verify search_vector still exists but doesn't include deleted field
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_search_table' AND column_name = 'search_vector'
    )),
    'search_vector column should still exist after deleting a searchable field'
);

-- =====================================================
-- TEST: tables.searchable auto-maintenance
-- =====================================================

-- Verify table is marked as searchable (has searchable fields)
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table'),
    'tables.searchable should be TRUE when table has searchable fields'
);

-- Make all searchable fields non-searchable
UPDATE fields SET searchable = FALSE WHERE table_name = 'test_search_table' AND searchable = TRUE;

-- Verify table is now marked as non-searchable
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table') = FALSE,
    'tables.searchable should be FALSE when no fields are searchable'
);

-- Verify search_vector column is removed when no searchable fields
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_search_table' AND column_name = 'search_vector'
    ),
    'search_vector column should be removed when no searchable fields remain'
);

-- Verify index is also removed
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE tablename = 'test_search_table' AND indexname = 'test_search_table_search_vector_idx'
    ),
    'GIN index should be removed when no searchable fields remain'
);

-- Make description searchable again
UPDATE fields SET searchable = TRUE WHERE table_name = 'test_search_table' AND field_name = 'description';

-- Verify table is marked as searchable again
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table'),
    'tables.searchable should be TRUE after making a field searchable again'
);

-- =====================================================
-- TEST: Attempting to manually change tables.searchable is rejected
-- =====================================================

-- Try to manually set searchable to FALSE (should be overridden)
UPDATE entities SET searchable = FALSE WHERE table_name = 'test_search_table';

-- Verify it's still TRUE (recomputed from fields)
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table'),
    'tables.searchable should be recomputed when manually changed (not allowed to override)'
);

-- =====================================================
-- TEST: managed=false tables don't execute DDL
-- =====================================================

-- Create a table with managed=false
INSERT INTO tables(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_unmanaged_search', 'test_unmanaged_search', 'Test Unmanaged', 'Test Unmanaged', 'Unmanaged table', 1, 'public:read', 'admin', 'id', 'title', FALSE);

-- Add a searchable field
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, searchable)
VALUES ('test_unmanaged_search', 'content', 'Content', 'text', FALSE, FALSE, 10, 'default', 'w', 'Test content', TRUE);

-- Verify search_vector was NOT created (table doesn't exist, managed=false)
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_unmanaged_search' AND column_name = 'search_vector'
    ),
    'search_vector should NOT be created for unmanaged tables'
);

-- Verify table metadata still tracks searchable correctly
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_unmanaged_search'),
    'tables.searchable should still be tracked for unmanaged tables (even though DDL not executed)'
);

-- =====================================================
-- TEST: Seed data has searchable fields marked
-- =====================================================

-- Verify customers table has searchable fields
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE table_name = 'customers' AND searchable = TRUE) >= 3,
    'customers table should have at least 3 searchable fields (email, company, phone, etc.)'
);

-- Verify employees table has searchable fields  
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE table_name = 'employees' AND searchable = TRUE) >= 3,
    'employees table should have at least 3 searchable fields (email, department, position)'
);

-- Verify products table has searchable fields
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE table_name = 'products' AND searchable = TRUE) >= 3,
    'products table should have at least 3 searchable fields (sku, description, category)'
);

-- =====================================================
-- TEST: Core tables have correct searchable flag
-- =====================================================

-- webhook_receivers should be searchable because label field is searchable
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'webhook_receivers'),
    'webhook_receivers table should be searchable (label field is searchable)'
);

SELECT ok(
    (SELECT searchable FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'label'),
    'webhook_receivers label field should be searchable'
);

-- webhook_receiver_logs should be searchable because webhook_id (label) field is searchable
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'webhook_receiver_logs'),
    'webhook_receiver_logs table should be searchable (webhook_id label field is searchable)'
);

SELECT ok(
    (SELECT searchable FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_id'),
    'webhook_receiver_logs webhook_id field should be searchable'
);

-- Verify ALL tables with searchable fields have tables.searchable=TRUE
SELECT is(
    (SELECT table_name 
     FROM entities t 
     WHERE t.searchable = FALSE 
       AND EXISTS (SELECT 1 FROM fields f WHERE f.table_name = t.table_name AND f.searchable = TRUE)
     LIMIT 1),
    NULL,
    'No table should have searchable=FALSE when it has searchable fields'
);

-- Verify ALL tables without searchable fields have tables.searchable=FALSE  
SELECT ok(
    NOT EXISTS (
        SELECT t.table_name 
        FROM entities t 
        WHERE t.searchable = TRUE 
          AND NOT EXISTS (SELECT 1 FROM fields f WHERE f.table_name = t.table_name AND f.searchable = TRUE)
    ),
    'No table should have searchable=TRUE when it has no searchable fields'
);

SELECT * FROM finish();
ROLLBACK;
