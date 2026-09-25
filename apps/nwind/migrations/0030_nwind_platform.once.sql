-- =====================================================
-- PLATFORM SAMPLE ROWS
-- =====================================================
-- Sample rows that show how platform features attach to a module. Runs once:
-- these tables are shared with every other module, so their rows are found by
-- name (module slug, queue name, process key) rather than by an id, which
-- would depend on what other modules inserted first.

-- A general-purpose "events" queue for the entity change events of the
-- Northwind module.
INSERT INTO queues (queue_name) VALUES ('events');

-- Webhook receiver: inbound order intake, plus one successful log entry
INSERT INTO webhook_receivers (label, table_name, description, auth_type, secret, header_name, header_value)
VALUES ('Order Intake', 'orders', 'Inbound order webhook', 'hmac', 'nwind-demo-secret', '', '');

INSERT INTO webhook_receiver_logs (webhook_receiver_id, message_id, label, webhook_timestamp, received_timestamp, payload, result, error_message)
SELECT w.id, 'msg_ord-evt-0001', 'ord-evt-0001', '2026-01-01 12:34:00'::timestamptz, '2026-01-01 12:34:01'::timestamptz, '{"order_id": 10248}'::jsonb, '10', ''
FROM webhook_receivers w WHERE w.label = 'Order Intake';

-- Dashboard for the module landing page (visible to nwind:view holders)
INSERT INTO dashboards (label, config, position, module_id, view_permission)
VALUES ('Northwind Overview',
        '{"widgets": [{"type": "count", "entity": "orders"}]}'::jsonb,
        10,
        (SELECT id FROM modules WHERE module_slug = 'nwind'),
        'nwind:view');

-- RACI registry: the order fulfillment process with a transition gate on orders.status.
-- Registry only (no raci_assignments / validation_rules), so writes are not gated.
INSERT INTO processes (name, process_key, description, ordering, module_id)
VALUES ('Fulfill Order', 'fulfill_order', 'Ship a pending order', 10,
        (SELECT id FROM modules WHERE module_slug = 'nwind'));

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT p.id, 'orders', 'transition', 'shipped', 'status', FALSE
FROM processes p WHERE p.process_key = 'fulfill_order';

-- Queue mapping: every new order enqueues an entity_event on the 'events' queue.
-- Created after the data load so the import itself does not enqueue 830 messages.
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT q.id, 'Order created', 'orders', 'insert'
FROM queues q WHERE q.queue_name = 'events';
