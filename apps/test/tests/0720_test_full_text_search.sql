-- Test full-text search functionality
BEGIN;

SELECT plan(57);

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
        WHERE table_name = 'entities' AND column_name = 'searchable'
    )),
    'searchable column should exist on entities table'
);

-- =====================================================
-- TEST: Auto-created label field is searchable
-- =====================================================

-- Create a new table and verify its label column is searchable
INSERT INTO entities(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
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
INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description, searchable)
VALUES ('test_search_table', 'description', 'Description', 'text', FALSE, 10, 'default', 'w', 'Test description field', TRUE);

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
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'ImmediateSearchTest')) = 1,
    'Newly added searchable field should be immediately searchable after INSERT'
);

-- Update the same record with another unique keyword
UPDATE test_search_table SET description = 'UpdatedImmediately unique keyword' WHERE name = 'Test Immediate';

-- Verify the updated value is immediately searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'UpdatedImmediately')) = 1,
    'Updated value in newly added searchable field should be immediately searchable'
);

-- Verify old value is no longer found
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'ImmediateSearchTest')) = 0,
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
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'product')) = 2,
    'Search for "product" should find 2 records (in name and description)'
);

-- Test search for "alpha" (should match name)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'alpha')) = 1,
    'Search for "alpha" should find 1 record'
);

-- Test search for "service" (should match name)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'service')) = 1,
    'Search for "service" should find 1 record'
);

-- Test search for "quality" (should match description)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'quality')) = 1,
    'Search for "quality" should find 1 record (in description)'
);

-- Test search for "excellent" (should match description)
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'excellent')) = 1,
    'Search for "excellent" should find 1 record (in description)'
);

-- Test search spanning multiple columns - "alpha quality"
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'alpha & quality')) = 1,
    'Search for "alpha AND quality" should find 1 record (spanning name and description)'
);

-- =====================================================
-- TEST: Updating searchable field updates search results
-- =====================================================

-- Update a record's searchable field
UPDATE test_search_table SET description = 'Updated description with special keyword' WHERE name = 'Product Alpha';

-- Search should find the updated keyword
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'special')) = 1,
    'Search should find updated keyword in modified record'
);

-- Old keyword should not be found in that record anymore
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'high-quality')) = 0,
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
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'special')) = 0,
    'After making description non-searchable, keywords from description should not be found'
);

-- But name column should still be searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'product')) = 2,
    'Keywords from name column should still be searchable'
);

-- Make description searchable again
UPDATE fields SET searchable = TRUE WHERE table_name = 'test_search_table' AND field_name = 'description';

-- Now "special" should be found again
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'special')) = 1,
    'After making description searchable again, keywords should be found'
);

-- =====================================================
-- TEST: Deleting searchable field updates search_vector
-- =====================================================

-- Add another searchable field
INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description, searchable, default_value)
VALUES ('test_search_table', 'notes', 'Notes', 'text', FALSE, 20, 'default', 'w', 'Additional notes', TRUE, '''''');

-- Add notes to one record
UPDATE test_search_table SET notes = 'Notefield specific content here' WHERE name = 'Product Beta';

-- Verify notes content is searchable
SELECT ok(
    (SELECT COUNT(*) FROM test_search_table WHERE search_vector @@ to_tsquery('simple', 'Notefield')) = 1,
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
-- TEST: entities.searchable auto-maintenance
-- =====================================================

-- Verify table is marked as searchable (has searchable fields)
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table'),
    'entities.searchable should be TRUE when table has searchable fields'
);

-- Make all searchable fields non-searchable
UPDATE fields SET searchable = FALSE WHERE table_name = 'test_search_table' AND searchable = TRUE;

-- Verify table is now marked as non-searchable
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table') = FALSE,
    'entities.searchable should be FALSE when no fields are searchable'
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
    'entities.searchable should be TRUE after making a field searchable again'
);

-- =====================================================
-- TEST: Attempting to manually change entities.searchable is rejected
-- =====================================================

-- Try to manually set searchable to FALSE (should be overridden)
UPDATE entities SET searchable = FALSE WHERE table_name = 'test_search_table';

-- Verify it's still TRUE (recomputed from fields)
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'test_search_table'),
    'entities.searchable should be recomputed when manually changed (not allowed to override)'
);

-- =====================================================
-- TEST: managed=false tables don't execute DDL
-- =====================================================

-- Create a table with managed=false
INSERT INTO entities(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_unmanaged_search', 'test_unmanaged_search', 'Test Unmanaged', 'Test Unmanaged', 'Unmanaged table', 1, 'public:read', 'admin', 'id', 'title', FALSE);

-- Add a searchable field
INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description, searchable)
VALUES ('test_unmanaged_search', 'content', 'Content', 'text', FALSE, 10, 'default', 'w', 'Test content', TRUE);

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
    'entities.searchable should still be tracked for unmanaged tables (even though DDL not executed)'
);

-- =====================================================
-- TEST: nwind sample data has searchable fields marked
-- =====================================================

-- Verify customers table has searchable fields
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE table_name = 'customers' AND searchable = TRUE) >= 3,
    'customers table should have at least 3 searchable fields (company_name, customer_id, contact_name, city, country)'
);

-- Verify employees table has searchable fields
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE table_name = 'employees' AND searchable = TRUE) >= 3,
    'employees table should have at least 3 searchable fields (last_name, first_name, city, country)'
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

-- webhook_receiver_logs should be searchable because label (label_column) field is searchable
SELECT ok(
    (SELECT searchable FROM entities WHERE table_name = 'webhook_receiver_logs'),
    'webhook_receiver_logs table should be searchable (label field is searchable)'
);

SELECT ok(
    (SELECT searchable FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'label'),
    'webhook_receiver_logs label field should be searchable'
);

-- Verify ALL tables with searchable fields have entities.searchable=TRUE
SELECT is(
    (SELECT table_name 
     FROM entities t 
     WHERE t.searchable = FALSE 
       AND EXISTS (SELECT 1 FROM fields f WHERE f.table_name = t.table_name AND f.searchable = TRUE)
     LIMIT 1),
    NULL,
    'No table should have searchable=FALSE when it has searchable fields'
);

-- Verify ALL tables without searchable fields have entities.searchable=FALSE  
SELECT ok(
    NOT EXISTS (
        SELECT t.table_name 
        FROM entities t 
        WHERE t.searchable = TRUE 
          AND NOT EXISTS (SELECT 1 FROM fields f WHERE f.table_name = t.table_name AND f.searchable = TRUE)
    ),
    'No table should have searchable=TRUE when it has no searchable fields'
);

-- =====================================================
-- TEST: Core tables have search_vector column and FTS works
-- =====================================================

-- Test that modules table has search_vector column (core table with searchable fields)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'modules' AND column_name = 'search_vector'
    )),
    'modules core table should have search_vector column'
);

-- Test that modules GIN index exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE tablename = 'modules' AND indexname = 'modules_search_vector_idx'
    )),
    'modules core table should have GIN index on search_vector'
);

-- Test that roles table has search_vector column
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'roles' AND column_name = 'search_vector'
    )),
    'roles core table should have search_vector column'
);

-- Test that permissions table has search_vector column
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'permissions' AND column_name = 'search_vector'
    )),
    'permissions core table should have search_vector column'
);

-- Test that users table has search_vector column
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'users' AND column_name = 'search_vector'
    )),
    'users core table should have search_vector column'
);

-- Test that entities table has search_vector column
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'entities' AND column_name = 'search_vector'
    )),
    'entities core table should have search_vector column'
);

-- Test that fields table has search_vector column
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'fields' AND column_name = 'search_vector'
    )),
    'fields core table should have search_vector column'
);

-- Test FTS works on modules core table
SELECT ok(
    (SELECT COUNT(*) FROM modules WHERE search_vector @@ to_tsquery('simple', 'Northwind')) >= 1,
    'Full-text search should find "Northwind" in modules table'
);

-- Test FTS works on roles core table
SELECT ok(
    (SELECT COUNT(*) FROM roles WHERE search_vector @@ to_tsquery('simple', 'User')) >= 1,
    'Full-text search should find "User" in roles table'
);

-- Test FTS works on permissions core table
SELECT ok(
    (SELECT COUNT(*) FROM permissions WHERE search_vector @@ to_tsquery('simple', 'admin')) >= 1,
    'Full-text search should find "admin" in permissions table'
);

-- Test FTS works on users core table
SELECT ok(
    (SELECT COUNT(*) FROM users WHERE search_vector @@ to_tsquery('simple', 'user1')) >= 1,
    'Full-text search should find "user1" in users table (external_id field)'
);

-- Test FTS works on entities core table
SELECT ok(
    (SELECT COUNT(*) FROM entities WHERE search_vector @@ to_tsquery('simple', 'Customer')) >= 1,
    'Full-text search should find "Customer" in entities table'
);

-- Test FTS works on fields core table
SELECT ok(
    (SELECT COUNT(*) FROM fields WHERE search_vector @@ to_tsquery('simple', 'Email')) >= 1,
    'Full-text search should find "Email" in fields table'
);

-- Test that core tables without searchable fields do NOT have search_vector
-- user_roles, role_permissions, permission_hierarchy have no searchable fields
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'user_roles' AND column_name = 'search_vector'
    ),
    'user_roles core table (no searchable fields) should NOT have search_vector column'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'role_permissions' AND column_name = 'search_vector'
    ),
    'role_permissions core table (no searchable fields) should NOT have search_vector column'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'permission_hierarchy' AND column_name = 'search_vector'
    ),
    'permission_hierarchy core table (no searchable fields) should NOT have search_vector column'
);

-- =====================================================
-- TEST: rebuilds are skipped and coalesced (P11)
-- =====================================================
-- Rebuilding search_vector drops and re-adds the column, so every rebuild
-- leaves exactly one dropped-attribute placeholder behind in pg_attribute.
-- Counting those placeholders is a direct count of full table rewrites.

INSERT INTO entities(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('test_p11_rebuild', 'test_p11_rebuild', 'P11 Rebuild', 'P11 Rebuilds', 'Rebuild accounting for P11', 1, 'public:read', 'admin', 'id', 'name', TRUE);

CREATE TEMP TABLE p11_baseline AS
SELECT count(*) AS dropped
FROM pg_attribute
WHERE attrelid = 'test_p11_rebuild'::regclass AND attisdropped;

-- A non-text field can never appear in the generated expression, so switching
-- its searchable flag on must not rebuild anything.
INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description, searchable)
VALUES ('test_p11_rebuild', 'rank_value', 'Rank', 'int64', FALSE, 20, 'default', 'default', 'Numeric field', TRUE);

SELECT is(
    (SELECT count(*) FROM pg_attribute
      WHERE attrelid = 'test_p11_rebuild'::regclass AND attisdropped),
    (SELECT dropped FROM p11_baseline),
    'toggling searchable on a non-text field should not rebuild search_vector'
);

-- Two searchable text fields added by one statement must cost one rebuild.
INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description, searchable)
VALUES
    ('test_p11_rebuild', 'note_one', 'Note One', 'text', FALSE, 30, 'default', 'w', 'First note', TRUE),
    ('test_p11_rebuild', 'note_two', 'Note Two', 'text', FALSE, 40, 'default', 'w', 'Second note', TRUE);

SELECT is(
    (SELECT count(*) FROM pg_attribute
      WHERE attrelid = 'test_p11_rebuild'::regclass AND attisdropped),
    (SELECT dropped + 1 FROM p11_baseline),
    'two searchable fields added in one statement should rebuild search_vector once'
);

-- Both are in the vector afterwards, so the single rebuild used the final state.
INSERT INTO test_p11_rebuild (name, note_one, note_two)
VALUES ('P11 Row', 'Notefieldone content', 'Notefieldtwo content');

SELECT ok(
    (SELECT COUNT(*) FROM test_p11_rebuild
      WHERE search_vector @@ to_tsquery('simple', 'Notefieldone & Notefieldtwo')) = 1,
    'both fields added in the coalesced statement should be searchable'
);

SELECT * FROM finish();
ROLLBACK;
