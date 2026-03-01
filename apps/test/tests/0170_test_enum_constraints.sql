-- Test enum field CHECK constraints
-- Verify that fields with format='enum' properly enforce enum_values constraints
BEGIN;

SELECT plan(12);

-- Set context as admin user to bypass RLS
SELECT rbac.set_request_context('{"sub": "user3"}');

-- =====================================================
-- TEST: webhook_receivers.auth_type enum constraint
-- =====================================================

-- Test 1: Insert valid enum value 'none' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (table_name, description, auth_type) 
      VALUES ('products', 'Test webhook with none auth', 'none')$$,
    'Should allow valid enum value "none" for auth_type'
);

-- Test 2: Insert valid enum value 'hmac' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (table_name, description, auth_type) 
      VALUES ('products', 'Test webhook with hmac auth', 'hmac')$$,
    'Should allow valid enum value "hmac" for auth_type'
);

-- Test 3: Insert valid enum value 'header' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (table_name, description, auth_type) 
      VALUES ('products', 'Test webhook with header auth', 'header')$$,
    'Should allow valid enum value "header" for auth_type'
);

-- Test 4: Insert invalid enum value should fail
SELECT throws_ok(
    $$INSERT INTO webhook_receivers (table_name, description, auth_type) 
      VALUES ('products', 'Test webhook with invalid auth', 'invalid_value')$$,
    '23514',
    NULL,
    'Should reject invalid enum value "invalid_value" for auth_type'
);

-- Test 5: Update to invalid enum value should fail
SELECT throws_ok(
    $$UPDATE webhook_receivers SET auth_type = 'xxx' WHERE id = 3$$,
    '23514',
    NULL,
    'Should reject UPDATE to invalid enum value "xxx" for auth_type'
);

-- Test 6: Verify auth_type is still valid after failed update
SELECT is(
    (SELECT auth_type FROM webhook_receivers WHERE id = 3),
    'none',
    'auth_type should remain unchanged after failed UPDATE'
);

-- =====================================================
-- TEST: webhook_receiver_logs.result enum constraint
-- =====================================================

-- Test 7: Insert valid enum value '10' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, webhook_timestamp, payload, result) 
      VALUES (1, 1, '2026-01-26 12:00:00'::timestamptz, '{}'::jsonb, '10')$$,
    'Should allow valid enum value "10" for result'
);

-- Test 8: Insert valid enum value '20' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, webhook_timestamp, payload, result) 
      VALUES (1, 1, '2026-01-26 12:01:00'::timestamptz, '{}'::jsonb, '20')$$,
    'Should allow valid enum value "20" for result'
);

-- Test 9: Insert valid enum value '90' should succeed
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, webhook_timestamp, payload, result) 
      VALUES (1, 1, '2026-01-26 12:02:00'::timestamptz, '{}'::jsonb, '90')$$,
    'Should allow valid enum value "90" for result'
);

-- Test 10: Insert invalid enum value should fail
SELECT throws_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, webhook_timestamp, payload, result) 
      VALUES (1, 1, '2026-01-26 12:03:00'::timestamptz, '{}'::jsonb, '99')$$,
    '23514',
    NULL,
    'Should reject invalid enum value "99" for result'
);

-- =====================================================
-- TEST: customers.status enum constraint
-- =====================================================

-- Test 11: Insert valid enum value 'pending' should succeed
SELECT lives_ok(
    $$INSERT INTO customers (email, company, phone, status) 
      VALUES ('test@example.com', 'Test Company', '555-1234', 'pending')$$,
    'Should allow valid enum value "pending" for status'
);

-- Test 12: Insert invalid enum value should fail
SELECT throws_ok(
    $$INSERT INTO customers (email, company, phone, status) 
      VALUES ('test2@example.com', 'Test Company 2', '555-5678', 'unknown_status')$$,
    '23514',
    NULL,
    'Should reject invalid enum value "unknown_status" for status'
);

SELECT * FROM finish();
ROLLBACK;
