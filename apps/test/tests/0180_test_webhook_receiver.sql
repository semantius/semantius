-- Test webhook_receivers and webhook_receiver_logs tables
BEGIN;

SELECT plan(33);

-- =====================================================
-- TEST: webhook_receivers table exists and has correct structure
-- =====================================================

-- Test 1: webhook_receivers table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'webhook_receivers')),
    'webhook_receivers table metadata should exist in tables'
);

-- Test 2: webhook_receivers table is created in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'webhook_receivers')),
    'webhook_receivers table should exist in database'
);

-- Test 3: webhook_receivers has table_name field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'table_name')),
    'webhook_receivers should have table_name field'
);

-- Test 4: table_name field has correct format
SELECT ok(
    (SELECT format = 'parent' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'table_name'),
    'table_name field should have parent format'
);

-- Test 5: webhook_receivers has description field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'description')),
    'webhook_receivers should have description field'
);

-- Test 6: description field has correct format
SELECT ok(
    (SELECT format = 'text' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'description'),
    'description field should have text format'
);

-- Test 7: webhook_receivers has auth_type field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'auth_type')),
    'webhook_receivers should have auth_type field'
);

-- Test 8: auth_type has enum values including header
SELECT ok(
    (SELECT enum_values @> '["none", "hmac", "header"]'::jsonb FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'auth_type'),
    'auth_type should have enum values: none, hmac, header'
);

-- Test 9: webhook_receivers has secret field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'secret')),
    'webhook_receivers should have secret field'
);

-- Test 10: webhook_receivers has header_name field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'header_name')),
    'webhook_receivers should have header_name field'
);

-- Test 11: webhook_receivers has header_value field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'header_value')),
    'webhook_receivers should have header_value field'
);

-- Test 12: webhook_receivers has jsonata field with jsonata format
SELECT ok(
    (SELECT format = 'jsonata' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'jsonata'),
    'webhook_receivers jsonata field should have jsonata format'
);

-- =====================================================
-- TEST: webhook_receiver_logs table exists and has correct structure
-- =====================================================

-- Test 13: webhook_receiver_logs table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'webhook_receiver_logs')),
    'webhook_receiver_logs table metadata should exist in tables'
);

-- Test 14: webhook_receiver_logs table is created in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'webhook_receiver_logs')),
    'webhook_receiver_logs table should exist in database'
);

-- Test 15: webhook_receiver_logs label_column should be label
SELECT ok(
    (SELECT label_column = 'label' FROM entities WHERE table_name = 'webhook_receiver_logs'),
    'webhook_receiver_logs label_column should be label'
);

-- Test 16: webhook_receiver_logs has webhook_receiver_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_receiver_id')),
    'webhook_receiver_logs should have webhook_receiver_id field'
);

-- Test 17: webhook_receiver_logs has webhook_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_id')),
    'webhook_receiver_logs should have webhook_id field'
);

-- Test 18: webhook_receiver_logs has webhook_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_timestamp')),
    'webhook_receiver_logs should have webhook_timestamp field'
);

-- Test 19: webhook_receiver_logs has received_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'received_timestamp')),
    'webhook_receiver_logs should have received_timestamp field'
);

-- Test 20: webhook_receiver_logs has payload field with json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'payload'),
    'webhook_receiver_logs payload field should have json format'
);

-- Test 21: webhook_receiver_logs has result field with enum values
SELECT ok(
    (SELECT enum_values @> '["10", "20", "90"]'::jsonb FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'result'),
    'webhook_receiver_logs result field should have enum values: 10, 20, 90'
);

-- Test 22: webhook_receiver_logs has error_message field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'error_message')),
    'webhook_receiver_logs should have error_message field'
);

-- =====================================================
-- TEST: Foreign key and index exist
-- =====================================================

-- Test 23: Foreign key constraint exists for table_name (created by DD trigger)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'webhook_receivers_table_name_fkey' 
        AND table_name = 'webhook_receivers'
        AND constraint_type = 'FOREIGN KEY'
    )),
    'Foreign key constraint should exist on webhook_receivers.table_name'
);

-- Test 24: Foreign key constraint exists for webhook_receiver_id (created by DD trigger)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'webhook_receiver_logs_webhook_receiver_id_fkey' 
        AND table_name = 'webhook_receiver_logs'
        AND constraint_type = 'FOREIGN KEY'
    )),
    'Foreign key constraint should exist on webhook_receiver_id'
);

-- Test 25: Index on webhook_id exists (created by DD trigger for parent format field)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'idx_webhook_receiver_logs_webhook_id'
    )),
    'Index on webhook_id should exist'
);

-- =====================================================
-- TEST: Sample data exists
-- =====================================================

-- Test 26: Sample webhook receivers exist
SELECT ok(
    (SELECT COUNT(*) >= 3 FROM webhook_receivers),
    'At least 3 sample webhook receivers should exist'
);

-- Test 27: Sample webhook receivers have table_name set
SELECT ok(
    (SELECT COUNT(*) >= 3 FROM webhook_receivers WHERE table_name IS NOT NULL AND table_name != ''),
    'Sample webhook receivers should have table_name set'
);

-- Test 28: Test new header authentication fields exist in database
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'webhook_receivers' AND column_name = 'header_name'
    )),
    'header_name column should exist in webhook_receivers table'
);

-- Test 29: Test header_value column exists in database
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'webhook_receivers' AND column_name = 'header_value'
    )),
    'header_value column should exist in webhook_receivers table'
);

-- Test 30: Test webhook_id column exists in webhook_receiver_logs table (as parent reference)
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'webhook_receiver_logs' AND column_name = 'webhook_id'
    )),
    'webhook_id column should exist in webhook_receiver_logs table'
);

-- Test 31: Verify format is 'parent' for webhook_id field
SELECT ok(
    (SELECT format = 'parent' FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_id'),
    'webhook_id field should have format=parent in webhook_receiver_logs'
);

-- Test 32: Sample webhook receiver logs exist
SELECT ok(
    (SELECT COUNT(*) >= 4 FROM webhook_receiver_logs),
    'At least 4 sample webhook receiver logs should exist'
);

-- Test 33: Verify auth_type description mentions custom header
SELECT ok(
    (SELECT description LIKE '%custom header%' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'auth_type'),
    'auth_type field description should mention custom header'
);

SELECT * FROM finish();
ROLLBACK;
