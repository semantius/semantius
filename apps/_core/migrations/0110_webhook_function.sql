-- =====================================================
-- WEBHOOK PROCESSING FUNCTION
-- =====================================================
-- Public RPC function to process incoming webhooks
-- Follows standard webhooks specification
-- =====================================================

-- =====================================================
-- PROCESS WEBHOOK
-- =====================================================
-- Process incoming webhook data with signature verification
-- and idempotency handling
CREATE OR REPLACE FUNCTION public.process_webhook(
    p_webhook_receiver_id INTEGER,
    p_headers JSONB,
    p_body TEXT,
    p_payload JSONB
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_webhook_receiver RECORD;
    v_webhook_id TEXT;
    v_webhook_timestamp TEXT;
    v_webhook_signature TEXT;
    v_idempotency_key TEXT;
    v_computed_signature TEXT;
    v_signed_content TEXT;
    v_existing_log_id INTEGER;
    v_insert_result INTEGER;
    v_error_message TEXT;
    v_log_id INTEGER;
    v_table_name TEXT;
    v_insert_sql TEXT;
    v_json_keys TEXT[];
    v_json_values TEXT[];
    v_key TEXT;
BEGIN
    -- Step 1: Validate required fields
    IF p_webhook_receiver_id IS NULL THEN
        RAISE EXCEPTION 'webhook_receiver_id is required';
    END IF;
    
    IF p_headers IS NULL THEN
        RAISE EXCEPTION 'headers is required';
    END IF;
    
    IF p_body IS NULL THEN
        RAISE EXCEPTION 'body is required';
    END IF;
    
    IF p_payload IS NULL THEN
        RAISE EXCEPTION 'payload is required';
    END IF;
    
    -- Step 2: Extract headers
    v_webhook_id := p_headers->>'webhook-id';
    v_webhook_timestamp := p_headers->>'webhook-timestamp';
    v_webhook_signature := p_headers->>'webhook-signature';
    
    -- Step 3: Use default timestamp if missing
    IF v_webhook_timestamp IS NULL OR v_webhook_timestamp = '' THEN
        v_webhook_timestamp := '1234567890';
    END IF;
    
    -- Step 4: Set idempotency_key from webhook-id
    v_idempotency_key := v_webhook_id;
    
    -- Step 5: Find webhook_receivers record
    SELECT * INTO v_webhook_receiver
    FROM webhook_receivers
    WHERE id = p_webhook_receiver_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'webhook_receiver_id % not found', p_webhook_receiver_id;
    END IF;
    
    -- Step 6: Compute webhook standard signature: webhook-id.webhook-timestamp.body
    v_signed_content := COALESCE(v_webhook_id, '') || '.' || v_webhook_timestamp || '.' || p_body;
    
    -- Compute HMAC-SHA256 signature
    IF v_webhook_receiver.secret IS NOT NULL THEN
        v_computed_signature := 'v1,' || encode(
            hmac(v_signed_content, v_webhook_receiver.secret, 'sha256'),
            'base64'
        );
    END IF;
    
    -- Step 7: Validate HMAC signature if auth_type is hmac
    IF v_webhook_receiver.auth_type = 'hmac' THEN
        IF v_webhook_signature IS NULL OR v_webhook_signature = '' THEN
            RAISE EXCEPTION 'webhook-signature header is required for HMAC authentication';
        END IF;
        
        IF v_computed_signature IS NULL OR v_computed_signature != v_webhook_signature THEN
            RAISE EXCEPTION 'Signature verification failed';
        END IF;
    END IF;
    
    -- Step 8: If idempotency_key is empty, use signature value
    IF v_idempotency_key IS NULL OR v_idempotency_key = '' THEN
        IF v_computed_signature IS NOT NULL THEN
            v_idempotency_key := v_computed_signature;
        ELSE
            -- For auth_type=none, compute signature anyway for idempotency
            IF v_webhook_receiver.secret IS NOT NULL THEN
                v_idempotency_key := 'v1,' || encode(
                    hmac(v_signed_content, v_webhook_receiver.secret, 'sha256'),
                    'base64'
                );
            ELSE
                -- Use hash of the body as idempotency key
                v_idempotency_key := 'body_hash,' || encode(
                    digest(p_body, 'sha256'),
                    'hex'
                );
            END IF;
        END IF;
    END IF;
    
    -- Step 9: Check for existing log record with same webhook_receiver_id and webhook_id
    SELECT id INTO v_existing_log_id
    FROM webhook_receiver_logs
    WHERE webhook_receiver_id = p_webhook_receiver_id
      AND webhook_id = v_idempotency_key;
    
    IF v_existing_log_id IS NOT NULL THEN
        -- Duplicate request, return success
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Duplicate request ignored',
            'log_id', v_existing_log_id
        );
    END IF;
    
    -- Step 10: Try to insert new record to target table
    v_table_name := v_webhook_receiver.table_name;
    v_insert_result := 20; -- Default to processed
    v_error_message := NULL;
    
    BEGIN
        -- Build dynamic INSERT statement
        -- Extract keys and values from payload
        SELECT array_agg(key), array_agg(value::text)
        INTO v_json_keys, v_json_values
        FROM jsonb_each_text(p_payload);
        
        -- Build INSERT SQL
        v_insert_sql := format(
            'INSERT INTO %I (%s) VALUES (%s)',
            v_table_name,
            (SELECT string_agg(quote_ident(k), ', ') FROM unnest(v_json_keys) AS k),
            (SELECT string_agg(quote_literal(v), ', ') FROM unnest(v_json_values) AS v)
        );
        
        -- Execute the INSERT
        EXECUTE v_insert_sql;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Capture error message
            v_insert_result := 90; -- Failed
            v_error_message := SQLERRM;
    END;
    
    -- Step 11: Insert log record
    INSERT INTO webhook_receiver_logs (
        label,
        webhook_receiver_id,
        webhook_id,
        webhook_timestamp,
        received_timestamp,
        payload,
        result,
        error_message
    )
    VALUES (
        'Webhook ' || v_idempotency_key,
        p_webhook_receiver_id,
        v_idempotency_key,
        to_timestamp(v_webhook_timestamp::bigint),
        CURRENT_TIMESTAMP,
        p_payload,
        v_insert_result,
        v_error_message
    )
    RETURNING id INTO v_log_id;
    
    -- Return result
    IF v_insert_result = 20 THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Webhook processed successfully',
            'log_id', v_log_id
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Webhook processing failed',
            'error', v_error_message,
            'log_id', v_log_id
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.process_webhook IS 
'Process incoming webhook data with signature verification and idempotency handling. Follows standard webhooks specification.';

-- Grant execute permission to public (since it has SECURITY DEFINER)
GRANT EXECUTE ON FUNCTION public.process_webhook(INTEGER, JSONB, TEXT, JSONB) TO PUBLIC;
