-- =====================================================
-- WEBHOOK RECEIVER TABLES
-- =====================================================
-- Create tables for webhook receivers and webhook receiver logs
-- These tables are created by inserting into the tables and fields tables
-- =====================================================

-- =====================================================
-- CREATE webhook_receivers TABLE
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
    'webhook_receivers',
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

-- Add fields to webhook_receivers table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values)
VALUES 
    ('webhook_receivers', 'table_name', 'Table', 'text', FALSE, FALSE, 10, 'default', 's', 'Target table for webhook data', '''''', NULL),
    ('webhook_receivers', 'description', 'Description', 'text', FALSE, FALSE, 20, 'default', 'w', 'Description of webhook receiver purpose', '''''', NULL),
    ('webhook_receivers', 'auth_type', 'Authentication Type', 'text', FALSE, FALSE, 30, 'default', 's', 'Type of authentication (none or hmac)', '''none''', '["none", "hmac"]'::jsonb),
    ('webhook_receivers', 'secret', 'Secret', 'text', FALSE, TRUE, 40, 'default', 'm', 'Secret for webhook authentication', NULL, NULL),
    ('webhook_receivers', 'jsonata', 'JSONata Expression', 'json', FALSE, TRUE, 50, 'default', 'w', 'Optional JSONata expression to transform incoming data', NULL, NULL);

-- =====================================================
-- CREATE webhook_receiver_logs TABLE
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
    'webhook_receiver_logs',
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

-- Add fields to webhook_receiver_logs table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values)
VALUES 
    ('webhook_receiver_logs', 'webhook_receiver_id', 'Webhook Receiver', 'int32', FALSE, FALSE, 10, 'default', 's', 'Reference to webhook receiver configuration', NULL, NULL),
    ('webhook_receiver_logs', 'webhook_id', 'Webhook ID', 'text', FALSE, FALSE, 20, 'default', 'm', 'External webhook identifier', NULL, NULL),
    ('webhook_receiver_logs', 'webhook_timestamp', 'Webhook Timestamp', 'date-time', FALSE, TRUE, 30, 'default', 'm', 'Timestamp from webhook source', NULL, NULL),
    ('webhook_receiver_logs', 'received_timestamp', 'Received Timestamp', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', 'Timestamp when webhook was received', 'CURRENT_TIMESTAMP', NULL),
    ('webhook_receiver_logs', 'payload', 'Payload', 'json', FALSE, TRUE, 50, 'default', 'w', 'Webhook payload data', NULL, NULL),
    ('webhook_receiver_logs', 'result', 'Result', 'int32', FALSE, FALSE, 60, 'default', 's', 'Processing result: 10=received, 20=processed, 90=failed', '10', '["10", "20", "90"]'::jsonb),
    ('webhook_receiver_logs', 'error_message', 'Error Message', 'text', FALSE, TRUE, 70, 'default', 'w', 'Error message if processing failed', NULL, NULL);

-- =====================================================
-- ADD FOREIGN KEY AND INDEX
-- =====================================================
-- The dynamic table system creates tables automatically, so we need to add
-- the foreign key and index after the tables are created by triggers

-- Add foreign key constraint for table_name
ALTER TABLE webhook_receivers 
ADD CONSTRAINT fk_webhook_receivers_table_name 
FOREIGN KEY (table_name) 
REFERENCES tables(table_name) 
ON DELETE CASCADE;

-- Add foreign key constraint for webhook_receiver_id
ALTER TABLE webhook_receiver_logs 
ADD CONSTRAINT fk_webhook_receiver_logs_webhook_receiver_id 
FOREIGN KEY (webhook_receiver_id) 
REFERENCES webhook_receivers(id) 
ON DELETE CASCADE;

-- Create index on webhook_id for efficient lookups
CREATE INDEX idx_webhook_receiver_logs_webhook_id 
ON webhook_receiver_logs(webhook_id);

COMMENT ON INDEX idx_webhook_receiver_logs_webhook_id IS 
'Index on webhook_id for efficient webhook log lookups';
