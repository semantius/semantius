-- =====================================================
-- WEBHOOK RECEIVER TABLES
-- =====================================================
-- Create tables for webhook receiver and webhook receiver log
-- These tables are created by inserting into the tables and fields tables
-- =====================================================

-- =====================================================
-- CREATE webhook_receiver TABLE
-- =====================================================

INSERT INTO tables (
    table_name, 
    singular, 
    singular_label, 
    plural_label, 
    description, 
    module_id, 
    view_permission, 
    edit_permission, 
    id_column, 
    label_column
)
VALUES (
    'webhook_receiver',
    'webhook_receiver',
    'Webhook Receiver',
    'Webhook Receivers',
    'Configuration for webhook endpoints',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Add fields to webhook_receiver table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values)
VALUES 
    ('webhook_receiver', 'auth_type', 'Authentication Type', 'text', FALSE, FALSE, 10, 'default', 's', 'Type of authentication (none or hmac)', '''none''', '["none", "hmac"]'::jsonb),
    ('webhook_receiver', 'signature', 'Signature', 'text', FALSE, TRUE, 20, 'default', 'm', 'Signature for webhook authentication', NULL, NULL),
    ('webhook_receiver', 'jsonata', 'JSONata Expression', 'json', FALSE, TRUE, 30, 'default', 'w', 'Optional JSONata expression to transform incoming data', NULL, NULL);

-- =====================================================
-- CREATE webhook_receiver_log TABLE
-- =====================================================

INSERT INTO tables (
    table_name, 
    singular, 
    singular_label, 
    plural_label, 
    description, 
    module_id, 
    view_permission, 
    edit_permission, 
    id_column, 
    label_column
)
VALUES (
    'webhook_receiver_log',
    'webhook_receiver_log',
    'Webhook Receiver Log',
    'Webhook Receiver Logs',
    'Log of webhook receiver events',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Add fields to webhook_receiver_log table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values)
VALUES 
    ('webhook_receiver_log', 'webhook_receiver_id', 'Webhook Receiver', 'int32', FALSE, FALSE, 10, 'default', 's', 'Reference to webhook receiver configuration', NULL, NULL),
    ('webhook_receiver_log', 'webhook_id', 'Webhook ID', 'text', FALSE, FALSE, 20, 'default', 'm', 'External webhook identifier', NULL, NULL),
    ('webhook_receiver_log', 'webhook_timestamp', 'Webhook Timestamp', 'date-time', FALSE, TRUE, 30, 'default', 'm', 'Timestamp from webhook source', NULL, NULL),
    ('webhook_receiver_log', 'received_timestamp', 'Received Timestamp', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', 'Timestamp when webhook was received', 'CURRENT_TIMESTAMP', NULL),
    ('webhook_receiver_log', 'payload', 'Payload', 'json', FALSE, TRUE, 50, 'default', 'w', 'Webhook payload data', NULL, NULL),
    ('webhook_receiver_log', 'result', 'Result', 'int32', FALSE, FALSE, 60, 'default', 's', 'Processing result: 10=received, 20=processed, 90=failed', '10', '["10", "20", "90"]'::jsonb),
    ('webhook_receiver_log', 'error_message', 'Error Message', 'text', FALSE, TRUE, 70, 'default', 'w', 'Error message if processing failed', NULL, NULL);

-- =====================================================
-- ADD FOREIGN KEY AND INDEX
-- =====================================================
-- The dynamic table system creates tables automatically, so we need to add
-- the foreign key and index after the tables are created by triggers

-- Add foreign key constraint for webhook_receiver_id
ALTER TABLE webhook_receiver_log 
ADD CONSTRAINT fk_webhook_receiver_log_webhook_receiver_id 
FOREIGN KEY (webhook_receiver_id) 
REFERENCES webhook_receiver(id) 
ON DELETE CASCADE;

-- Create index on webhook_id for efficient lookups
CREATE INDEX idx_webhook_receiver_log_webhook_id 
ON webhook_receiver_log(webhook_id);

COMMENT ON INDEX idx_webhook_receiver_log_webhook_id IS 
'Index on webhook_id for efficient webhook log lookups';

-- =====================================================
-- SEED SAMPLE DATA
-- =====================================================

-- Sample webhook receivers
INSERT INTO webhook_receiver (label, auth_type, signature, jsonata)
VALUES 
    ('GitHub Webhook', 'hmac', 'sha256=your-secret-key', NULL),
    ('Stripe Webhook', 'hmac', 'whsec_test_secret', '{"event_type": "$event.type", "object_id": "$data.object.id"}'::jsonb),
    ('Simple Webhook', 'none', NULL, NULL);

-- Sample webhook receiver logs
INSERT INTO webhook_receiver_log (label, webhook_receiver_id, webhook_id, webhook_timestamp, received_timestamp, payload, result, error_message)
VALUES 
    ('GitHub Push Event', 1, 'gh-evt-12345', '2024-01-15 10:30:00'::timestamptz, '2024-01-15 10:30:01'::timestamptz, '{"action": "push", "ref": "refs/heads/main"}'::jsonb, 20, NULL),
    ('Stripe Payment Success', 2, 'evt_1ABC123', '2024-01-15 11:00:00'::timestamptz, '2024-01-15 11:00:01'::timestamptz, '{"type": "payment_intent.succeeded", "amount": 1000}'::jsonb, 20, NULL),
    ('Simple Webhook Test', 3, 'test-webhook-001', '2024-01-15 12:00:00'::timestamptz, '2024-01-15 12:00:01'::timestamptz, '{"message": "test"}'::jsonb, 10, NULL),
    ('Failed Webhook', 1, 'gh-evt-67890', '2024-01-15 13:00:00'::timestamptz, '2024-01-15 13:00:01'::timestamptz, '{"action": "invalid"}'::jsonb, 90, 'Invalid action type');
