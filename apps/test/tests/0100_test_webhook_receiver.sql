-- Test webhook_receivers and webhook_receiver_logs tables
BEGIN;

SELECT plan(25);

-- =====================================================
-- TEST: webhook_receivers table exists and has correct structure
-- =====================================================

-- Test 1: webhook_receivers table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'webhook_receivers')),
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
    (SELECT format = 'text' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'table_name'),
    'table_name field should have text format'
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

-- Test 8: auth_type has enum values
SELECT ok(
    (SELECT enum_values @> '["none", "hmac"]'::jsonb FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'auth_type'),
    'auth_type should have enum values: none, hmac'
);

-- Test 9: webhook_receivers has secret field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'secret')),
    'webhook_receivers should have secret field'
);

-- Test 10: webhook_receivers has jsonata field with json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'webhook_receivers' AND field_name = 'jsonata'),
    'webhook_receivers jsonata field should have json format'
);

-- =====================================================
-- TEST: webhook_receiver_logs table exists and has correct structure
-- =====================================================

-- Test 11: webhook_receiver_logs table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'webhook_receiver_logs')),
    'webhook_receiver_logs table metadata should exist in tables'
);

-- Test 12: webhook_receiver_logs table is created in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'webhook_receiver_logs')),
    'webhook_receiver_logs table should exist in database'
);

-- Test 13: webhook_receiver_logs has webhook_receiver_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_receiver_id')),
    'webhook_receiver_logs should have webhook_receiver_id field'
);

-- Test 14: webhook_receiver_logs has webhook_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_id')),
    'webhook_receiver_logs should have webhook_id field'
);

-- Test 15: webhook_receiver_logs has webhook_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'webhook_timestamp')),
    'webhook_receiver_logs should have webhook_timestamp field'
);

-- Test 16: webhook_receiver_logs has received_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'received_timestamp')),
    'webhook_receiver_logs should have received_timestamp field'
);

-- Test 17: webhook_receiver_logs has payload field with json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'payload'),
    'webhook_receiver_logs payload field should have json format'
);

-- Test 18: webhook_receiver_logs has result field with enum values
SELECT ok(
    (SELECT enum_values @> '["10", "20", "90"]'::jsonb FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'result'),
    'webhook_receiver_logs result field should have enum values: 10, 20, 90'
);

-- Test 19: webhook_receiver_logs has error_message field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_logs' AND field_name = 'error_message')),
    'webhook_receiver_logs should have error_message field'
);

-- =====================================================
-- TEST: Foreign key and index exist
-- =====================================================

-- Test 20: Foreign key constraint exists for table_name
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'fk_webhook_receivers_table_name' 
        AND table_name = 'webhook_receivers'
        AND constraint_type = 'FOREIGN KEY'
    )),
    'Foreign key constraint should exist on webhook_receivers.table_name'
);

-- Test 21: Foreign key constraint exists for webhook_receiver_id
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'fk_webhook_receiver_logs_webhook_receiver_id' 
        AND table_name = 'webhook_receiver_logs'
        AND constraint_type = 'FOREIGN KEY'
    )),
    'Foreign key constraint should exist on webhook_receiver_id'
);

-- Test 22: Index on webhook_id exists
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

-- Test 23: Sample webhook receivers exist
SELECT ok(
    (SELECT COUNT(*) >= 3 FROM webhook_receivers),
    'At least 3 sample webhook receivers should exist'
);

-- Test 24: Sample webhook receivers have table_name set
SELECT ok(
    (SELECT COUNT(*) >= 3 FROM webhook_receivers WHERE table_name IS NOT NULL AND table_name != ''),
    'Sample webhook receivers should have table_name set'
);

-- Test 25: Sample webhook receiver logs exist
SELECT ok(
    (SELECT COUNT(*) >= 4 FROM webhook_receiver_logs),
    'At least 4 sample webhook receiver logs should exist'
);

SELECT * FROM finish();
ROLLBACK;
