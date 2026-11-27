-- =====================================================
-- PLATFORM SAMPLE ROWS
-- =====================================================
-- Sample rows that show how platform features attach to a module. Runs once:
-- these tables are shared with every other module, so their rows are found by
-- name (module slug, queue name, process key, role slug, order number)
-- rather than by an id, which would depend on what other modules inserted
-- first.

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

-- Sample tasks: two on each of the three oldest and the three newest orders,
-- open and waiting in the queue of the Northwind Sales role, with no assignee,
-- and fixed due dates. The tasks take their keys from the counter, as any
-- other task does, so they never collide with tasks created before this
-- module; inserted in the order listed, they are TASK-1 to TASK-12 on a fresh
-- install. Each is linked to its order through the row the insert returns,
-- matched on the title, priority and due date it inserted (status and role
-- are the same for all): the title and the due date alone repeat ("Confirm
-- ship date" on 2026-05-08). A migration has no user, so created_by stays
-- empty.
WITH sample (n, title, priority, due_at, order_number) AS (
    VALUES
        (1, 'Send invoice', 'high', '2024-07-17 17:00:00+00'::timestamptz, 'SO-10248'),
        (2, 'Confirm delivery', 'normal', '2024-07-23 17:00:00+00'::timestamptz, 'SO-10248'),
        (3, 'Send invoice', 'normal', '2024-07-12 17:00:00+00'::timestamptz, 'SO-10249'),
        (4, 'Collect payment', 'high', '2024-08-16 17:00:00+00'::timestamptz, 'SO-10249'),
        (5, 'Send invoice', 'low', '2024-07-15 17:00:00+00'::timestamptz, 'SO-10250'),
        (6, 'Follow up on freight charges', 'low', '2024-08-05 17:00:00+00'::timestamptz, 'SO-10250'),
        (7, 'Confirm ship date', 'high', '2026-05-08 17:00:00+00'::timestamptz, 'SO-11075'),
        (8, 'Pick and pack items', 'normal', '2026-05-20 17:00:00+00'::timestamptz, 'SO-11075'),
        (9, 'Confirm ship date', 'normal', '2026-05-08 17:00:00+00'::timestamptz, 'SO-11076'),
        (10, 'Book the carrier', 'normal', '2026-05-25 17:00:00+00'::timestamptz, 'SO-11076'),
        (11, 'Check stock', 'high', '2026-05-10 17:00:00+00'::timestamptz, 'SO-11077'),
        (12, 'Confirm ship date', 'low', '2026-05-12 17:00:00+00'::timestamptz, 'SO-11077')
), inserted AS (
    INSERT INTO tasks (title, status, priority, due_at, assigned_role)
    SELECT s.title, 'open', s.priority, s.due_at, r.id
      FROM sample s
      JOIN roles r ON r.slug = 'northwind_sales'
     ORDER BY s.n
    RETURNING id, title, priority, due_at
)
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT i.id, 'orders:' || o.id
  FROM inserted i
  JOIN sample s ON s.title = i.title AND s.priority = i.priority AND s.due_at = i.due_at
  JOIN orders o ON o.label = s.order_number;

-- Queue mapping: every new order enqueues an entity_event on the 'events' queue.
-- Created after the data load so the import itself does not enqueue 830 messages.
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT q.id, 'Order created', 'orders', 'insert'
FROM queues q WHERE q.queue_name = 'events';
