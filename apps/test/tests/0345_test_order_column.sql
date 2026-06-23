-- =====================================================
-- TEST: entities.order_column — fixed per-entity row ordering
-- =====================================================
-- Covers (migration 0270):
--   • Assigning order_column to a brand-new entity provisions the physical
--     INTEGER column + auto-assign BEFORE INSERT trigger.
--   • Records inserted WITHOUT a value get MAX(order below 9000000)+10 (or 10
--     for the first row); records inserted WITH a value keep it.
--   • Clearing order_column drops the column and its trigger.
--   • order_column is surfaced in get_schema()'s `table` object and `properties`.
--   • The `fields` entity (order_column = 'field_order') still auto-assigns
--     field_order for a new field added to an existing table.

BEGIN;

SELECT plan(18);

-- Admin user (can write entities/fields and managed tables).
SELECT authenticate_as('user3');

-- =====================================================
-- Create a fresh managed entity to exercise order_column
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('order_test', 'order_test', 'Order Test', 'Order Tests', 'Row-order test table', 1001, 'public:read', 'sales:manage', 'id', 'label');

SELECT has_table('public', 'order_test', 'order_test table should be created');

-- order_column not set yet -> the order column does not exist
SELECT pgtap.hasnt_column('public', 'order_test', 'sort_order',
    'sort_order column should not exist before order_column is set');

-- The `table` object reports an empty order_column by default
SELECT is(
    (public.get_schema('order_test')::jsonb)->'table'->>'order_column',
    '',
    'get_schema().table.order_column defaults to empty string'
);

-- =====================================================
-- Assign order_column -> column + auto-assign trigger provisioned
-- =====================================================
UPDATE entities SET order_column = 'sort_order' WHERE table_name = 'order_test';

SELECT pgtap.has_column('public', 'order_test', 'sort_order',
    'sort_order column should be created when order_column is set');

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'public.order_test'::regclass
          AND tgname = 'zz_auto_order_order_test'
          AND NOT tgisinternal
    ),
    'auto-assign trigger should be installed on order_test'
);

SELECT is(
    (public.get_schema('order_test')::jsonb)->'table'->>'order_column',
    'sort_order',
    'get_schema().table.order_column reflects the assigned column'
);

-- =====================================================
-- Inserts without a value auto-assign; with a value are preserved
-- =====================================================
INSERT INTO order_test (label) VALUES ('A');
SELECT is(
    (SELECT sort_order FROM order_test WHERE label = 'A'),
    10,
    'first auto-assigned row gets order 10'
);

INSERT INTO order_test (label) VALUES ('B');
SELECT is(
    (SELECT sort_order FROM order_test WHERE label = 'B'),
    20,
    'second auto-assigned row gets order 20 (max+10)'
);

-- Explicit value is respected (not overwritten)
INSERT INTO order_test (label, sort_order) VALUES ('C', 5);
SELECT is(
    (SELECT sort_order FROM order_test WHERE label = 'C'),
    5,
    'explicitly provided order value is preserved'
);

-- Next auto row uses MAX (which is 20, since 5 < 20) + 10 = 30
INSERT INTO order_test (label) VALUES ('D');
SELECT is(
    (SELECT sort_order FROM order_test WHERE label = 'D'),
    30,
    'auto-assigned row uses current max below 9000000 (+10)'
);

-- =====================================================
-- Clearing order_column drops the column and the trigger
-- =====================================================
UPDATE entities SET order_column = '' WHERE table_name = 'order_test';

SELECT pgtap.hasnt_column('public', 'order_test', 'sort_order',
    'sort_order column should be dropped when order_column is cleared');

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'public.order_test'::regclass
          AND tgname = 'zz_auto_order_order_test'
          AND NOT tgisinternal
    ),
    'auto-assign trigger should be removed when order_column is cleared'
);

-- =====================================================
-- order_column is exposed as a property of the entities entity itself
-- =====================================================
SELECT ok(
    (public.get_schema('entities')::jsonb)->'properties' ? 'order_column',
    'get_schema(entities) properties should include order_column'
);

-- =====================================================
-- fields entity: order_column = 'field_order' (replaces auto_set_field_order)
-- =====================================================
-- The legacy trigger/function are gone...
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'auto_set_field_order'),
    'legacy auto_set_field_order() function should be removed'
);

-- ...and the fields entity now declares field_order as its order column.
SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'fields'),
    'field_order',
    'fields entity should declare field_order as its order column'
);

-- A new field added to an EXISTING table still auto-assigns field_order to
-- max(field_order below 9000000)+10.
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('customers_test', 'sort_probe_1', 'Sort Probe 1', 'int32');

SELECT is(
    (SELECT field_order FROM fields WHERE table_name = 'customers_test' AND field_name = 'sort_probe_1'),
    (SELECT MAX(field_order) + 10 FROM fields WHERE field_order < 9000000 AND field_name NOT LIKE 'sort_probe%'),
    'new field on an existing table auto-assigns field_order to max(below 9000000)+10'
);

-- A second new field continues the sequence (+10 from the previous max).
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('customers_test', 'sort_probe_2', 'Sort Probe 2', 'int32');

SELECT is(
    (SELECT field_order FROM fields WHERE table_name = 'customers_test' AND field_name = 'sort_probe_2'),
    (SELECT field_order FROM fields WHERE table_name = 'customers_test' AND field_name = 'sort_probe_1') + 10,
    'a further new field increments field_order by 10 from the previous max'
);

-- An explicitly provided field_order is preserved (auto-assign only fills 0/blank).
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('customers_test', 'sort_probe_3', 'Sort Probe 3', 'int32', 7);

SELECT is(
    (SELECT field_order FROM fields WHERE table_name = 'customers_test' AND field_name = 'sort_probe_3'),
    7,
    'explicitly provided field_order is preserved'
);

SELECT * FROM finish();

ROLLBACK;
