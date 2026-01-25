-- Test managed flag functionality for tables and fields
BEGIN;

SELECT plan(24);

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
VALUES ('test_managed_true', 'test_field', 'Test Field', 'text', FALSE, FALSE, 10, 'default', 'm', 'Test field');

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_managed_true' AND column_name = 'test_field'
    )),
    'Field should be added to managed=true table in database'
);

-- Test 3: Update field in managed=true table (change format)
UPDATE fields SET format = 'int32' WHERE table_name = 'test_managed_true' AND field_name = 'test_field';

SELECT ok(
    (SELECT data_type = 'integer' FROM information_schema.columns 
     WHERE table_name = 'test_managed_true' AND column_name = 'test_field'),
    'Field format change should be applied to managed=true table in database'
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
DELETE FROM tables WHERE table_name = 'test_managed_true';

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
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'test_managed_false')),
    'Table metadata should exist in tables table even when managed=false'
);

-- Test 8: Verify managed flag is set correctly
SELECT ok(
    (SELECT managed = FALSE FROM tables WHERE table_name = 'test_managed_false'),
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
DELETE FROM tables WHERE table_name = 'test_managed_false';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM tables WHERE table_name = 'test_managed_false'),
    'Table metadata should be deleted from tables table for managed=false'
);

-- =====================================================
-- TEST: Switching managed flag from false to true
-- =====================================================

-- Test 14: Create table with managed=false, then switch to true
INSERT INTO tables(table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed) 
VALUES ('test_switch_managed', 'test_switch_managed', 'Test Switch', 'Test Switch', 'Test switching managed flag', 1, 'public:read', 'admin', 'id', 'label', FALSE);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_switch_managed'),
    'Table with managed=false initially should NOT be created in database'
);

-- Test 15: Manually create the table in database (simulating existing table)
CREATE TABLE test_switch_managed (
    id SERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Enable RLS on the manually created table
ALTER TABLE test_switch_managed ENABLE ROW LEVEL SECURITY;

SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_switch_managed')),
    'Manually created table should exist in database'
);

-- Test 16: Switch managed to true
UPDATE tables SET managed = TRUE WHERE table_name = 'test_switch_managed';

SELECT ok(
    (SELECT managed = TRUE FROM tables WHERE table_name = 'test_switch_managed'),
    'Managed flag should be TRUE after update'
);

-- Test 17: Add a field after switching to managed=true (should now execute DDL)
INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
VALUES ('test_switch_managed', 'new_field', 'New Field', 'text', FALSE, FALSE, 10, 'default', 'm', 'Field added after enabling managed');

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_switch_managed' AND column_name = 'new_field'
    )),
    'Field should be added to database after switching managed to true'
);

-- Test 18: Update field after switching to managed=true
UPDATE fields SET format = 'int32' WHERE table_name = 'test_switch_managed' AND field_name = 'new_field';

SELECT ok(
    (SELECT data_type = 'integer' FROM information_schema.columns 
     WHERE table_name = 'test_switch_managed' AND column_name = 'new_field'),
    'Field format change should be applied after switching managed to true'
);

-- Test 19: Delete field after switching to managed=true
DELETE FROM fields WHERE table_name = 'test_switch_managed' AND field_name = 'new_field';

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'test_switch_managed' AND column_name = 'new_field'
    ),
    'Field should be removed after switching managed to true'
);

-- Test 20: Delete table after switching to managed=true
DELETE FROM tables WHERE table_name = 'test_switch_managed';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_switch_managed'),
    'Table should be dropped after switching managed to true'
);

-- =====================================================
-- TEST: Modules table (existing table with managed toggling)
-- =====================================================

-- Test 21: Modules table should have metadata in tables table
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'modules')),
    'Modules table metadata should exist in tables table'
);

-- Test 22: Modules table should have managed=true after initialization
SELECT ok(
    (SELECT managed = TRUE FROM tables WHERE table_name = 'modules'),
    'Modules table should have managed=true after initialization'
);

-- Test 23: Modules table should have fields metadata
SELECT ok(
    (SELECT COUNT(*) > 0 FROM fields WHERE table_name = 'modules'),
    'Modules table should have field metadata records'
);

-- Test 24: Modules table exists in database (created in earlier migration)
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'modules')),
    'Modules table should exist in database'
);

SELECT * FROM finish();
ROLLBACK;
