-- Test webhook_receiver and webhook_receiver_log tables
BEGIN;

SELECT plan(19);

-- =====================================================
-- TEST: webhook_receiver table exists and has correct structure
-- =====================================================

-- Test 1: webhook_receiver table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'webhook_receiver')),
    'webhook_receiver table metadata should exist in tables'
);

-- Test 2: webhook_receiver table is created in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'webhook_receiver')),
    'webhook_receiver table should exist in database'
);

-- Test 3: webhook_receiver has auth_type field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver' AND field_name = 'auth_type')),
    'webhook_receiver should have auth_type field'
);

-- Test 4: auth_type has enum values
SELECT ok(
    (SELECT enum_values @> '["none", "hmac"]'::jsonb FROM fields WHERE table_name = 'webhook_receiver' AND field_name = 'auth_type'),
    'auth_type should have enum values: none, hmac'
);

-- Test 5: webhook_receiver has signature field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver' AND field_name = 'signature')),
    'webhook_receiver should have signature field'
);

-- Test 6: webhook_receiver has jsonata field with json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'webhook_receiver' AND field_name = 'jsonata'),
    'webhook_receiver jsonata field should have json format'
);

-- =====================================================
-- TEST: webhook_receiver_log table exists and has correct structure
-- =====================================================

-- Test 7: webhook_receiver_log table exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM tables WHERE table_name = 'webhook_receiver_log')),
    'webhook_receiver_log table metadata should exist in tables'
);

-- Test 8: webhook_receiver_log table is created in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'webhook_receiver_log')),
    'webhook_receiver_log table should exist in database'
);

-- Test 9: webhook_receiver_log has webhook_receiver_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'webhook_receiver_id')),
    'webhook_receiver_log should have webhook_receiver_id field'
);

-- Test 10: webhook_receiver_log has webhook_id field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'webhook_id')),
    'webhook_receiver_log should have webhook_id field'
);

-- Test 11: webhook_receiver_log has webhook_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'webhook_timestamp')),
    'webhook_receiver_log should have webhook_timestamp field'
);

-- Test 12: webhook_receiver_log has received_timestamp field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'received_timestamp')),
    'webhook_receiver_log should have received_timestamp field'
);

-- Test 13: webhook_receiver_log has payload field with json format
SELECT ok(
    (SELECT format = 'json' FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'payload'),
    'webhook_receiver_log payload field should have json format'
);

-- Test 14: webhook_receiver_log has result field with enum values
SELECT ok(
    (SELECT enum_values @> '["10", "20", "90"]'::jsonb FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'result'),
    'webhook_receiver_log result field should have enum values: 10, 20, 90'
);

-- Test 15: webhook_receiver_log has error_message field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'webhook_receiver_log' AND field_name = 'error_message')),
    'webhook_receiver_log should have error_message field'
);

-- =====================================================
-- TEST: Foreign key and index exist
-- =====================================================

-- Test 16: Foreign key constraint exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'fk_webhook_receiver_log_webhook_receiver_id' 
        AND table_name = 'webhook_receiver_log'
        AND constraint_type = 'FOREIGN KEY'
    )),
    'Foreign key constraint should exist on webhook_receiver_id'
);

-- Test 17: Index on webhook_id exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'idx_webhook_receiver_log_webhook_id'
    )),
    'Index on webhook_id should exist'
);

-- =====================================================
-- TEST: Sample data exists
-- =====================================================

-- Test 18: Sample webhook receivers exist
SELECT ok(
    (SELECT COUNT(*) >= 3 FROM webhook_receiver),
    'At least 3 sample webhook receivers should exist'
);

-- Test 19: Sample webhook receiver logs exist
SELECT ok(
    (SELECT COUNT(*) >= 4 FROM webhook_receiver_log),
    'At least 4 sample webhook receiver logs should exist'
);

SELECT * FROM finish();
ROLLBACK;
