-- =====================================================
-- NORTHWIND MODULE TESTS (0010)
-- =====================================================
-- The nwind module as a platform citizen: module row, permissions and
-- hierarchy, the Northwind Sales role, Administrator auto-grant, the
-- `events` queue + order-insert mapping, and the sample platform rows
-- (dashboard, RACI process/gate, webhook receiver + log). Also carries the
-- webhook enum coverage formerly in the central 0170 file and the
-- regression guards against the removed test seed (Sales User / sales:* /
-- CRM-HR-Inventory). Reads catalog tables as user3 (Administrator); pgmq
-- internals are read as the owner (RESET ROLE), as 0310 does.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(44);

SELECT authenticate_as('user3');

-- =====================================================
-- MODULE ROW
-- =====================================================

-- Test 1: Northwind module exists
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name = 'Northwind'),
    1,
    'Northwind module should exist'
);

-- Test 2: module_slug = nwind
SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'Northwind'),
    'nwind',
    'Northwind module should have module_slug = nwind'
);

-- Test 3: view_permission
SELECT is(
    (SELECT view_permission FROM modules WHERE module_slug = 'nwind'),
    'nwind:view',
    'Northwind module should have view_permission = nwind:view'
);

-- Test 4: home_page
SELECT is(
    (SELECT home_page FROM modules WHERE module_slug = 'nwind'),
    '/nwind',
    'Northwind module home_page should be /nwind'
);

-- Test 5: icon_name
SELECT is(
    (SELECT icon_name FROM modules WHERE module_slug = 'nwind'),
    'compass',
    'Northwind module icon_name should be compass'
);

-- Test 6: manage_permission_id points at nwind:manage
SELECT is(
    (SELECT p.permission_name
     FROM modules m JOIN permissions p ON p.id = m.manage_permission_id
     WHERE m.module_slug = 'nwind'),
    'nwind:manage',
    'Northwind module manage_permission_id should reference nwind:manage'
);

-- Test 7: default_manager_role_id points at northwind_sales
SELECT is(
    (SELECT r.slug
     FROM modules m JOIN roles r ON r.id = m.default_manager_role_id
     WHERE m.module_slug = 'nwind'),
    'northwind_sales',
    'Northwind module default_manager_role_id should reference role northwind_sales'
);

-- =====================================================
-- PERMISSIONS, HIERARCHY, ROLE
-- =====================================================

-- Test 8: the module owns exactly nwind:view and nwind:manage
SELECT set_eq(
    $$SELECT permission_name FROM permissions
      WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')$$,
    ARRAY['nwind:view', 'nwind:manage'],
    'Northwind module permissions should be exactly {nwind:view, nwind:manage}'
);

-- Test 9: nwind:manage implies nwind:view via permission hierarchy
SELECT is(
    (SELECT COUNT(*)::integer
     FROM permission_hierarchy ph
     JOIN permissions p ON p.id = ph.including_permission_id
     JOIN permissions c ON c.id = ph.included_permission_id
     WHERE p.permission_name = 'nwind:manage'
       AND c.permission_name = 'nwind:view'),
    1,
    'nwind:manage should imply nwind:view in permission hierarchy'
);

-- Test 10: role northwind_sales exists with the expected display name
SELECT is(
    (SELECT role_name FROM roles WHERE slug = 'northwind_sales'),
    'Northwind Sales',
    'Role northwind_sales should be named "Northwind Sales"'
);

-- Test 11: role origin is model
SELECT is(
    (SELECT origin FROM roles WHERE slug = 'northwind_sales'),
    'model',
    'Role northwind_sales should have origin = model'
);

-- Test 12: role belongs to the Northwind module
SELECT is(
    (SELECT module_id FROM roles WHERE slug = 'northwind_sales'),
    (SELECT id FROM modules WHERE module_slug = 'nwind'),
    'Role northwind_sales should belong to the Northwind module'
);

-- Test 13: role holds exactly nwind:view + nwind:manage
SELECT set_eq(
    $$SELECT p.permission_name
      FROM role_permissions rp
      JOIN roles r ON r.id = rp.role_id
      JOIN permissions p ON p.id = rp.permission_id
      WHERE r.slug = 'northwind_sales'$$,
    ARRAY['nwind:view', 'nwind:manage'],
    'Role northwind_sales should hold exactly {nwind:view, nwind:manage}'
);

-- Test 14: Administrator holds both nwind permissions (auto-grant)
SELECT set_eq(
    $$SELECT p.permission_name
      FROM role_permissions rp
      JOIN roles r ON r.id = rp.role_id
      JOIN permissions p ON p.id = rp.permission_id
      WHERE r.slug = 'administrator' AND p.permission_name LIKE 'nwind:%'$$,
    ARRAY['nwind:view', 'nwind:manage'],
    'Administrator should hold both nwind permissions via auto-grant'
);

-- Test 15: user2 (1002) is a member of northwind_sales
SELECT ok(
    EXISTS (
        SELECT 1 FROM user_roles ur
        JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = 1002 AND r.slug = 'northwind_sales'
    ),
    'user2 (1002) should be assigned the northwind_sales role'
);

-- =====================================================
-- REGRESSION GUARDS: the old test seed is gone
-- =====================================================

-- Test 16: no role "Sales User"
SELECT is(
    (SELECT COUNT(*)::integer FROM roles WHERE role_name = 'Sales User' OR slug = 'sales_user'),
    0,
    'Legacy role "Sales User" should not exist'
);

-- Test 17: no sales:* permissions
SELECT is(
    (SELECT COUNT(*)::integer FROM permissions WHERE permission_name LIKE 'sales:%'),
    0,
    'Legacy sales:* permissions should not exist'
);

-- Test 18: no CRM / HR / Inventory modules
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name IN ('CRM', 'HR', 'Inventory')),
    0,
    'Legacy CRM/HR/Inventory modules should not exist'
);

-- =====================================================
-- EVENTS QUEUE
-- =====================================================

-- Test 19: queues entity has the events queue
SELECT is(
    (SELECT COUNT(*)::integer FROM queues WHERE queue_name = 'events'),
    1,
    'Queue "events" should be registered in queues'
);

-- pgmq internals are owner-only
RESET ROLE;

-- Test 20: registered in pgmq.meta
SELECT ok(
    EXISTS (SELECT 1 FROM pgmq.meta WHERE queue_name = 'events'),
    'Queue "events" should be registered in pgmq.meta'
);

-- Test 21: pgmq queue table exists
SELECT has_table('pgmq', 'q_events', 'pgmq queue table q_events should exist');

SELECT authenticate_as('user3');

-- Test 22: order-insert mapping on the events queue
SELECT is(
    (SELECT COUNT(*)::integer
     FROM queue_table_events qte
     JOIN queues q ON q.id = qte.queue_id
     WHERE q.queue_name = 'events'
       AND qte.table_name = 'orders'
       AND qte.event_handler = 'insert'),
    1,
    'queue_table_events should map orders INSERT to the events queue'
);

-- =====================================================
-- DASHBOARD
-- =====================================================

-- Test 23: Northwind Overview dashboard in the nwind module
SELECT is(
    (SELECT COUNT(*)::integer FROM dashboards
     WHERE label = 'Northwind Overview'
       AND module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')),
    1,
    'Dashboard "Northwind Overview" should exist in the Northwind module'
);

-- Test 24: dashboard is visible to nwind:view holders
SELECT is(
    (SELECT view_permission FROM dashboards WHERE label = 'Northwind Overview'),
    (SELECT id FROM permissions WHERE permission_name = 'nwind:view'),
    'Dashboard "Northwind Overview" view_permission should be the id of nwind:view'
);

-- Test 25: dashboard config carries the orders count widget
SELECT ok(
    (SELECT config @> '{"widgets": [{"type": "count", "entity": "orders"}]}'::jsonb
     FROM dashboards WHERE label = 'Northwind Overview'),
    'Dashboard config should contain the orders count widget'
);

-- =====================================================
-- RACI REGISTRY: process + transition gate
-- =====================================================

-- Test 26: fulfill_order process in the nwind module
SELECT is(
    (SELECT COUNT(*)::integer FROM processes
     WHERE process_key = 'fulfill_order'
       AND module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')),
    1,
    'Process fulfill_order should exist in the Northwind module'
);

-- Test 27: its gate is a transition on orders.status -> shipped
SELECT set_eq(
    $$SELECT g.entity || '|' || g.gate_kind || '|' || g.to_state || '|' || g.state_column
      FROM process_gates g
      JOIN processes p ON p.id = g.process_id
      WHERE p.process_key = 'fulfill_order'$$,
    ARRAY['orders|transition|shipped|status'],
    'fulfill_order should have exactly one transition gate on orders.status -> shipped'
);

-- Test 28: the gate does not emit events (registry only)
SELECT is(
    (SELECT g.emits_events FROM process_gates g
     JOIN processes p ON p.id = g.process_id
     WHERE p.process_key = 'fulfill_order'),
    FALSE,
    'fulfill_order gate should have emits_events = FALSE'
);

-- =====================================================
-- WEBHOOK RECEIVER + LOG
-- =====================================================

-- Test 29: Order Intake receiver targets orders
SELECT is(
    (SELECT table_name FROM webhook_receivers WHERE label = 'Order Intake'),
    'orders',
    'Webhook receiver "Order Intake" should target the orders table'
);

-- Test 30: Order Intake uses hmac auth
SELECT is(
    (SELECT auth_type FROM webhook_receivers WHERE label = 'Order Intake'),
    'hmac',
    'Webhook receiver "Order Intake" should use auth_type = hmac'
);

-- Test 31: exactly one seeded log entry
SELECT set_eq(
    $$SELECT l.label FROM webhook_receiver_logs l
      JOIN webhook_receivers w ON w.id = l.webhook_receiver_id
      WHERE w.label = 'Order Intake'$$,
    ARRAY['ord-evt-0001'],
    'Order Intake should have exactly one seeded log entry (ord-evt-0001)'
);

-- Test 32: the log entry is processed (20) and references order 10248
SELECT ok(
    (SELECT l.result = '20' AND l.payload @> '{"order_id": 10248}'::jsonb
       AND l.webhook_id = l.webhook_receiver_id
     FROM webhook_receiver_logs l WHERE l.label = 'ord-evt-0001'),
    'Log ord-evt-0001 should have result 20, payload order_id 10248 and both FK columns set'
);

-- =====================================================
-- WEBHOOK ENUM COVERAGE (formerly central 0170)
-- =====================================================

-- Test 33: auth_type none
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (label, table_name, description, auth_type)
      VALUES ('Enum none', 'orders', 'Test webhook with none auth', 'none')$$,
    'Should allow valid enum value "none" for auth_type'
);

-- Test 34: auth_type hmac
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (label, table_name, description, auth_type)
      VALUES ('Enum hmac', 'orders', 'Test webhook with hmac auth', 'hmac')$$,
    'Should allow valid enum value "hmac" for auth_type'
);

-- Test 35: auth_type header
SELECT lives_ok(
    $$INSERT INTO webhook_receivers (label, table_name, description, auth_type)
      VALUES ('Enum header', 'orders', 'Test webhook with header auth', 'header')$$,
    'Should allow valid enum value "header" for auth_type'
);

-- Test 36: invalid auth_type on INSERT
SELECT throws_ok(
    $$INSERT INTO webhook_receivers (label, table_name, description, auth_type)
      VALUES ('Enum invalid', 'orders', 'Test webhook with invalid auth', 'invalid_value')$$,
    '23514',
    NULL,
    'Should reject invalid enum value "invalid_value" for auth_type'
);

-- Test 37: invalid auth_type on UPDATE of the seeded receiver (looked up by label)
SELECT throws_ok(
    $$UPDATE webhook_receivers SET auth_type = 'xxx' WHERE label = 'Order Intake'$$,
    '23514',
    NULL,
    'Should reject UPDATE to invalid enum value "xxx" for auth_type'
);

-- Test 38: value unchanged after the failed UPDATE
SELECT is(
    (SELECT auth_type FROM webhook_receivers WHERE label = 'Order Intake'),
    'hmac',
    'auth_type should remain hmac after failed UPDATE'
);

-- Test 39: result 10
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, label, webhook_timestamp, payload, result)
      SELECT w.id, w.id, 'enum-10', '2026-01-26 12:00:00'::timestamptz, '{}'::jsonb, '10'
      FROM webhook_receivers w WHERE w.label = 'Order Intake'$$,
    'Should allow valid enum value "10" for result'
);

-- Test 40: result 20
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, label, webhook_timestamp, payload, result)
      SELECT w.id, w.id, 'enum-20', '2026-01-26 12:01:00'::timestamptz, '{}'::jsonb, '20'
      FROM webhook_receivers w WHERE w.label = 'Order Intake'$$,
    'Should allow valid enum value "20" for result'
);

-- Test 41: result 90
SELECT lives_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, label, webhook_timestamp, payload, result)
      SELECT w.id, w.id, 'enum-90', '2026-01-26 12:02:00'::timestamptz, '{}'::jsonb, '90'
      FROM webhook_receivers w WHERE w.label = 'Order Intake'$$,
    'Should allow valid enum value "90" for result'
);

-- Test 42: invalid result
SELECT throws_ok(
    $$INSERT INTO webhook_receiver_logs (webhook_id, webhook_receiver_id, label, webhook_timestamp, payload, result)
      SELECT w.id, w.id, 'enum-99', '2026-01-26 12:03:00'::timestamptz, '{}'::jsonb, '99'
      FROM webhook_receivers w WHERE w.label = 'Order Intake'$$,
    '23514',
    NULL,
    'Should reject invalid enum value "99" for result'
);

-- Test 43: the three valid inserts landed on the seeded receiver
SELECT set_eq(
    $$SELECT l.label FROM webhook_receiver_logs l
      JOIN webhook_receivers w ON w.id = l.webhook_receiver_id
      WHERE w.label = 'Order Intake' AND l.label LIKE 'enum-%'$$,
    ARRAY['enum-10', 'enum-20', 'enum-90'],
    'The three valid result inserts should be attached to Order Intake'
);

-- Test 44: the three valid receivers exist and the invalid one does not
SELECT set_eq(
    $$SELECT auth_type FROM webhook_receivers WHERE label LIKE 'Enum %'$$,
    ARRAY['none', 'hmac', 'header'],
    'The three valid auth_type inserts should exist; the invalid one should not'
);

SELECT * FROM finish();
ROLLBACK;
