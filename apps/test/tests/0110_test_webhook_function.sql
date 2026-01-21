-- Test webhook processing function
BEGIN;

SELECT plan(22);

-- =====================================================
-- TEST SETUP: Create test webhook receiver
-- =====================================================

-- Insert a test webhook receiver for HMAC testing
DO $$
DECLARE
    v_test_receiver_hmac_id INTEGER;
    v_test_receiver_none_id INTEGER;
BEGIN
    INSERT INTO webhook_receivers (label, table_name, description, auth_type, secret)
    VALUES ('Test HMAC Webhook', 'products', 'Test webhook with HMAC auth', 'hmac', 'test-secret-key')
    RETURNING id INTO v_test_receiver_hmac_id;
    
    -- Insert a test webhook receiver for no-auth testing
    INSERT INTO webhook_receivers (label, table_name, description, auth_type, secret)
    VALUES ('Test None Webhook', 'products', 'Test webhook with no auth', 'none', NULL)
    RETURNING id INTO v_test_receiver_none_id;
    
    -- Store IDs in a temporary table for other tests to use
    CREATE TEMP TABLE test_webhook_receivers (
        hmac_id INTEGER,
        none_id INTEGER
    );
    
    INSERT INTO test_webhook_receivers VALUES (v_test_receiver_hmac_id, v_test_receiver_none_id);
END;
$$;

-- =====================================================
-- TEST 1: Invalid request - missing webhook_receiver_id
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
BEGIN
    BEGIN
        v_result := public.process_webhook(
            NULL,
            '{"webhook-id": "test-001", "webhook-timestamp": "1234567890"}'::jsonb,
            '{"test": "data"}',
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%webhook_receiver_id is required%' THEN
                -- Test passed
                PERFORM ok(true, 'Missing webhook_receiver_id should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 2: Invalid request - missing headers
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
BEGIN
    BEGIN
        v_result := public.process_webhook(
            1,
            NULL,
            '{"test": "data"}',
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%headers is required%' THEN
                PERFORM ok(true, 'Missing headers should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 3: Invalid request - missing body
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
BEGIN
    BEGIN
        v_result := public.process_webhook(
            1,
            '{"webhook-id": "test-001"}'::jsonb,
            NULL,
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%body is required%' THEN
                PERFORM ok(true, 'Missing body should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 4: Invalid request - missing payload
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
BEGIN
    BEGIN
        v_result := public.process_webhook(
            1,
            '{"webhook-id": "test-001"}'::jsonb,
            '{"test": "data"}',
            NULL
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%payload is required%' THEN
                PERFORM ok(true, 'Missing payload should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 5: webhook_receiver_id not found
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
BEGIN
    BEGIN
        v_result := public.process_webhook(
            99999,
            '{"webhook-id": "test-001", "webhook-timestamp": "1234567890"}'::jsonb,
            '{"test": "data"}',
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%not found%' THEN
                PERFORM ok(true, 'Non-existent webhook_receiver_id should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 6: HMAC signature validation - missing signature
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
    v_receiver_id INTEGER;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    BEGIN
        v_result := public.process_webhook(
            v_receiver_id,
            '{"webhook-id": "test-sig-001", "webhook-timestamp": "1234567890"}'::jsonb,
            '{"test": "data"}',
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%webhook-signature header is required%' THEN
                PERFORM ok(true, 'Missing webhook-signature should raise error for HMAC auth');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 7: HMAC signature validation - invalid signature
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_error TEXT;
    v_receiver_id INTEGER;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    BEGIN
        v_result := public.process_webhook(
            v_receiver_id,
            '{"webhook-id": "test-sig-002", "webhook-timestamp": "1234567890", "webhook-signature": "v1,invalid-signature"}'::jsonb,
            '{"test": "data"}',
            '{"test": "data"}'::jsonb
        );
        RAISE EXCEPTION 'Expected exception not raised';
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
            IF v_error LIKE '%Signature verification failed%' THEN
                PERFORM ok(true, 'Invalid signature should raise error');
            ELSE
                PERFORM ok(false, 'Wrong error message: ' || v_error);
            END IF;
    END;
END;
$$;

-- =====================================================
-- TEST 8: Successful insert with valid HMAC signature
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-success-001';
    v_timestamp TEXT := '1234567890';
    v_body TEXT := '{"product_name": "Webhook Product", "sku": "WH-001", "price": 99.99}';
    v_payload JSONB := '{"product_name": "Webhook Product", "sku": "WH-001", "price": 99.99}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
    v_log_count INTEGER;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature
    v_signed_content := v_webhook_id || '.' || v_timestamp || '.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- Call the function
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify result
    PERFORM ok(
        (v_result->>'success')::boolean = true,
        'Valid HMAC webhook should be processed successfully'
    );
    
    -- Verify log record exists
    SELECT COUNT(*) INTO v_log_count
    FROM webhook_receiver_logs
    WHERE webhook_receiver_id = v_receiver_id
      AND webhook_id = v_webhook_id
      AND result = 20;
    
    PERFORM ok(
        v_log_count = 1,
        'Successful webhook should create log record with result=20'
    );
END;
$$;

-- =====================================================
-- TEST 9: Duplicate request detection
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-duplicate-001';
    v_timestamp TEXT := '1234567890';
    v_body TEXT := '{"product_name": "Duplicate Product", "sku": "DUP-001", "price": 49.99}';
    v_payload JSONB := '{"product_name": "Duplicate Product", "sku": "DUP-001", "price": 49.99}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature
    v_signed_content := v_webhook_id || '.' || v_timestamp || '.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- First call - should succeed
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Second call - should be ignored as duplicate
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify duplicate was detected
    PERFORM ok(
        v_result->>'message' = 'Duplicate request ignored',
        'Duplicate request should be ignored'
    );
END;
$$;

-- =====================================================
-- TEST 10: auth_type=none should still process
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-none-001';
BEGIN
    -- Get the none test receiver ID
    SELECT none_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Call without signature
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', '1234567890'
        ),
        '{"product_name": "None Auth Product", "sku": "NA-001", "price": 29.99}',
        '{"product_name": "None Auth Product", "sku": "NA-001", "price": 29.99}'::jsonb
    );
    
    -- Verify processed successfully
    PERFORM ok(
        (v_result->>'success')::boolean = true,
        'Webhook with auth_type=none should be processed without signature'
    );
END;
$$;

-- =====================================================
-- TEST 11: auth_type=none should still deduplicate
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-none-dedup-001';
BEGIN
    -- Get the none test receiver ID
    SELECT none_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- First call
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', '1234567890'
        ),
        '{"product_name": "Dedup Test", "sku": "DD-001", "price": 19.99}',
        '{"product_name": "Dedup Test", "sku": "DD-001", "price": 19.99}'::jsonb
    );
    
    -- Second call - should be duplicate
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', '1234567890'
        ),
        '{"product_name": "Dedup Test", "sku": "DD-001", "price": 19.99}',
        '{"product_name": "Dedup Test", "sku": "DD-001", "price": 19.99}'::jsonb
    );
    
    -- Verify duplicate detected
    PERFORM ok(
        v_result->>'message' = 'Duplicate request ignored',
        'Webhook with auth_type=none should still deduplicate'
    );
END;
$$;

-- =====================================================
-- TEST 12: Invalid payload - data type mismatch
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-type-error-001';
    v_timestamp TEXT := '1234567890';
    v_body TEXT := '{"product_name": "Type Error Product", "sku": "TE-001", "price": "not-a-number"}';
    v_payload JSONB := '{"product_name": "Type Error Product", "sku": "TE-001", "price": "not-a-number"}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
    v_log_record RECORD;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature
    v_signed_content := v_webhook_id || '.' || v_timestamp || '.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- Call the function
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify failure
    PERFORM ok(
        (v_result->>'success')::boolean = false,
        'Invalid data type should cause processing to fail'
    );
    
    -- Verify log record has error message
    SELECT * INTO v_log_record
    FROM webhook_receiver_logs
    WHERE webhook_receiver_id = v_receiver_id
      AND webhook_id = v_webhook_id;
    
    PERFORM ok(
        v_log_record.result = 90 AND v_log_record.error_message IS NOT NULL,
        'Failed webhook should create log record with result=90 and error_message'
    );
END;
$$;

-- =====================================================
-- TEST 13: Missing webhook-id uses signature as idempotency_key
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_timestamp TEXT := '1234567890';
    v_body TEXT := '{"product_name": "No ID Product", "sku": "NID-001", "price": 39.99}';
    v_payload JSONB := '{"product_name": "No ID Product", "sku": "NID-001", "price": 39.99}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature (with empty webhook-id)
    v_signed_content := '.' || v_timestamp || '.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- Call the function without webhook-id
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify success
    PERFORM ok(
        (v_result->>'success')::boolean = true,
        'Webhook without webhook-id should use signature as idempotency_key'
    );
    
    -- Call again with same data - should be duplicate
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    PERFORM ok(
        v_result->>'message' = 'Duplicate request ignored',
        'Duplicate request without webhook-id should still be detected'
    );
END;
$$;

-- =====================================================
-- TEST 14: Default timestamp when missing
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-default-ts-001';
    v_body TEXT := '{"product_name": "Default TS Product", "sku": "DTS-001", "price": 59.99}';
    v_payload JSONB := '{"product_name": "Default TS Product", "sku": "DTS-001", "price": 59.99}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature with default timestamp
    v_signed_content := v_webhook_id || '.1234567890.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- Call without webhook-timestamp
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify success
    PERFORM ok(
        (v_result->>'success')::boolean = true,
        'Webhook without timestamp should use default 1234567890'
    );
END;
$$;

-- =====================================================
-- TEST 15: auth_type=none without secret uses body hash for idempotency
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_body TEXT := '{"product_name": "Body Hash Test", "sku": "BHT-001", "price": 69.99}';
    v_payload JSONB := '{"product_name": "Body Hash Test", "sku": "BHT-001", "price": 69.99}'::jsonb;
BEGIN
    -- Get the none test receiver ID (has no secret)
    SELECT none_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Call without webhook-id
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object('webhook-timestamp', '1234567890'),
        v_body,
        v_payload
    );
    
    -- Verify success
    PERFORM ok(
        (v_result->>'success')::boolean = true,
        'Webhook without webhook-id and no secret should use body hash'
    );
    
    -- Call again - should be duplicate
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object('webhook-timestamp', '1234567890'),
        v_body,
        v_payload
    );
    
    PERFORM ok(
        v_result->>'message' = 'Duplicate request ignored',
        'Duplicate request should be detected using body hash'
    );
END;
$$;

-- =====================================================
-- TEST 16: Verify successful insert creates product record
-- =====================================================

DO $$
DECLARE
    v_result JSONB;
    v_receiver_id INTEGER;
    v_webhook_id TEXT := 'test-verify-insert-001';
    v_timestamp TEXT := '1234567890';
    v_body TEXT := '{"product_name": "Verify Insert Product", "sku": "VIP-001", "price": 79.99}';
    v_payload JSONB := '{"product_name": "Verify Insert Product", "sku": "VIP-001", "price": 79.99}'::jsonb;
    v_signed_content TEXT;
    v_signature TEXT;
    v_product_count INTEGER;
BEGIN
    -- Get the HMAC test receiver ID
    SELECT hmac_id INTO v_receiver_id FROM test_webhook_receivers;
    
    -- Compute valid signature
    v_signed_content := v_webhook_id || '.' || v_timestamp || '.' || v_body;
    v_signature := 'v1,' || encode(hmac(v_signed_content, 'test-secret-key', 'sha256'), 'base64');
    
    -- Call the function
    v_result := public.process_webhook(
        v_receiver_id,
        jsonb_build_object(
            'webhook-id', v_webhook_id,
            'webhook-timestamp', v_timestamp,
            'webhook-signature', v_signature
        ),
        v_body,
        v_payload
    );
    
    -- Verify product was inserted
    SELECT COUNT(*) INTO v_product_count
    FROM products
    WHERE sku = 'VIP-001';
    
    PERFORM ok(
        v_product_count = 1,
        'Successful webhook should insert record into target table'
    );
END;
$$;

-- =====================================================
-- TEST 17: Function exists and has correct signature
-- =====================================================

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.proname = 'process_webhook'
    )),
    'process_webhook function should exist in public schema'
);

-- =====================================================
-- TEST 18: Function has SECURITY DEFINER
-- =====================================================

SELECT ok(
    (SELECT prosecdef FROM pg_proc p
     JOIN pg_namespace n ON p.pronamespace = n.oid
     WHERE n.nspname = 'public' AND p.proname = 'process_webhook'
     LIMIT 1),
    'process_webhook function should have SECURITY DEFINER'
);

SELECT * FROM finish();
ROLLBACK;
