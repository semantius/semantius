-- Test managed flag functionality for tables and fields
BEGIN;

SELECT plan(13);

-- Authenticate as admin user
SELECT authenticate_as('user3');

-- =====================================================
-- TEST: Tables with managed=true (default behavior)
-- =====================================================

-- Test 1: Create a table with managed=true (default)
INSERT INTO tables(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_managed_true', 'test_managed_true', 'Test Managed True', 'Test Managed True', 'Test table with managed=true', 1, 'public:read', 'admin', 'id', 'label', TRUE);

SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_managed_true')),
    'Table with managed=true should be created in database'
);

-- Test 2: Add a field to managed=true table
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
VALUES ('test_managed_true', 'test_field', 'Test Field', 'int32', FALSE, FALSE, 10, 'default', 'm', 'Test field');

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_managed_true' AND column_name = 'test_field'
    )),
    'Field should be added to managed=true table in database'
);

-- Test 3: Update field nullable constraint in managed=true table (allow NULL)
UPDATE fields SET is_nullable = TRUE WHERE table_name = 'test_managed_true' AND field_name = 'test_field';

SELECT ok(
    (SELECT is_nullable = 'YES' FROM information_schema.columns 
     WHERE table_name = 'test_managed_true' AND column_name = 'test_field'),
    'Field nullable constraint change should be applied to managed=true table in database'
);

-- Test 4: Delete field from managed=true table
DELETE FROM fields WHERE table_name = 'test_managed_true' AND field_name = 'test_field';

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_managed_true' AND column_name = 'test_field'
    ),
    'Field should be removed from managed=true table in database'
);

-- Test 5: Delete managed=true table
DELETE FROM entities WHERE table_name = 'test_managed_true';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_managed_true'),
    'Managed=true table should be dropped from database'
);

-- =====================================================
-- TEST: Tables with managed=false (no DDL execution)
-- =====================================================

-- Test 6: Create a table with managed=false (should not create in DB)
INSERT INTO tables(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_managed_false', 'test_managed_false', 'Test Managed False', 'Test Managed False', 'Test table with managed=false', 1, 'public:read', 'admin', 'id', 'label', FALSE);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_managed_false'),
    'Table with managed=false should NOT be created in database'
);

-- Test 7: Table metadata should still exist in tables table
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'test_managed_false')),
    'Table metadata should exist in tables table even when managed=false'
);

-- Test 8: Verify managed flag is set correctly
SELECT ok(
    (SELECT managed = FALSE FROM entities WHERE table_name = 'test_managed_false'),
    'Managed flag should be FALSE for test_managed_false table'
);

-- Test 9: Add a field to managed=false table (should not add column in DB)
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
VALUES ('test_managed_false', 'test_field_unmanaged', 'Test Field', 'text', FALSE, FALSE, 10, 'default', 'm', 'Test field for unmanaged table');

SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'test_managed_false' AND field_name = 'test_field_unmanaged')),
    'Field metadata should exist in fields table for managed=false table'
);

-- Test 10: Field should not be added to database (table doesn't exist)
-- This test passes because the table doesn't exist in the database
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_managed_false' AND column_name = 'test_field_unmanaged'
    ),
    'Field should NOT be added to database for managed=false table'
);

-- Test 11: Update field in managed=false table (should not execute DDL)
UPDATE fields SET format = 'int32' WHERE table_name = 'test_managed_false' AND field_name = 'test_field_unmanaged';

SELECT ok(
    (SELECT format = 'int32' FROM fields WHERE table_name = 'test_managed_false' AND field_name = 'test_field_unmanaged'),
    'Field metadata should be updated in fields table for managed=false table'
);

-- Test 12: Delete field from managed=false table (should not execute DDL)
DELETE FROM fields WHERE table_name = 'test_managed_false' AND field_name = 'test_field_unmanaged';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM fields WHERE table_name = 'test_managed_false' AND field_name = 'test_field_unmanaged'),
    'Field metadata should be deleted from fields table for managed=false table'
);

-- Test 13: Delete managed=false table (should not drop from DB since it wasn't created)
DELETE FROM entities WHERE table_name = 'test_managed_false';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'test_managed_false'),
    'Table metadata should be deleted from tables table for managed=false'
);

SELECT * FROM finish();
ROLLBACK;
