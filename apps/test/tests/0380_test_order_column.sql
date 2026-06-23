-- Tests for order_column feature:
--   1. Creating a table with order_column adds the column and trigger
--   2. Clearing order_column drops the column and trigger
--   3. Inserting rows without a value auto-assigns order (max < 900000 + 10)
--   4. Inserting rows with a value preserves it
--   5. Fields table still gets correct field_order via generic row order
--   6. get_schema includes order_column in table object

BEGIN;

SELECT plan(20);

SELECT authenticate_as('user3');  -- admin

-- =====================================================
-- TEST 1: Create a table with order_column set
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, order_column
) VALUES (
    'oc_tasks', 'oc_task', 'OC Task', 'OC Tasks',
    'Order column test table',
    1, 'public:read', 'admin', 'id', 'task_name', 'sort_order'
);

-- Verify the order column exists on the physical table
SELECT has_column(
    'public', 'oc_tasks', 'sort_order',
    'oc_tasks should have sort_order column after order_column is set'
);

-- Verify order_column is stored in entities
SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'oc_tasks'),
    'sort_order',
    'entities.order_column should be sort_order for oc_tasks'
);

-- =====================================================
-- TEST 2: Insert rows without sort_order value -> auto-assigned
-- =====================================================

INSERT INTO oc_tasks (task_name) VALUES ('First task');
INSERT INTO oc_tasks (task_name) VALUES ('Second task');
INSERT INTO oc_tasks (task_name) VALUES ('Third task');

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'First task'),
    10,
    'First task should get sort_order = 10'
);

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'Second task'),
    20,
    'Second task should get sort_order = 20'
);

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'Third task'),
    30,
    'Third task should get sort_order = 30'
);

-- =====================================================
-- TEST 3: Insert row WITH explicit sort_order value
-- =====================================================

INSERT INTO oc_tasks (task_name, sort_order) VALUES ('Pinned task', 500);

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'Pinned task'),
    500,
    'Pinned task should keep explicit sort_order = 500'
);

-- Next auto-assigned should be max(< 900000) + 10 = 510
INSERT INTO oc_tasks (task_name) VALUES ('After pinned');

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'After pinned'),
    510,
    'Auto-assigned after pinned should be 510'
);

-- =====================================================
-- TEST 4: Rows above 900000 threshold are excluded from max
-- =====================================================

INSERT INTO oc_tasks (task_name, sort_order) VALUES ('High row', 999999);

INSERT INTO oc_tasks (task_name) VALUES ('Normal after high');

SELECT is(
    (SELECT sort_order FROM oc_tasks WHERE task_name = 'Normal after high'),
    520,
    'Auto-assigned should ignore rows >= 900000, so next is 520'
);

-- =====================================================
-- TEST 5: get_schema includes order_column in table object
-- =====================================================

SELECT is(
    (public.get_schema('oc_tasks')::jsonb)->'table'->>'order_column',
    'sort_order',
    'get_schema() table object should include order_column'
);

-- =====================================================
-- TEST 6: Clear order_column -> column and trigger removed
-- =====================================================

UPDATE entities SET order_column = '' WHERE table_name = 'oc_tasks';

SELECT hasnt_column(
    'public', 'oc_tasks', 'sort_order',
    'sort_order column should be dropped when order_column is cleared'
);

SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'oc_tasks'),
    '',
    'entities.order_column should be empty after clearing'
);

-- =====================================================
-- TEST 7: Re-enable order_column with a different name
-- =====================================================

UPDATE entities SET order_column = 'priority' WHERE table_name = 'oc_tasks';

SELECT has_column(
    'public', 'oc_tasks', 'priority',
    'priority column should exist after setting order_column to priority'
);

-- Existing rows should have 0 in the new column (DEFAULT 0)
SELECT is(
    (SELECT priority FROM oc_tasks WHERE task_name = 'First task'),
    0,
    'Existing rows should have 0 in the new priority column'
);

-- New inserts should auto-assign
INSERT INTO oc_tasks (task_name) VALUES ('Priority task');

SELECT is(
    (SELECT priority FROM oc_tasks WHERE task_name = 'Priority task'),
    10,
    'New insert with priority=0 should auto-assign 10 (max of existing 0s, filtered < 900000, + 10 = 10)'
);

-- =====================================================
-- TEST 8: fields table uses order_column = field_order
-- =====================================================

SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'fields'),
    'field_order',
    'fields entity should have order_column = field_order'
);

-- =====================================================
-- TEST 9: New field for existing table gets correct field_order
-- =====================================================

-- Add a new field to oc_tasks
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('oc_tasks', 'notes', 'Notes', 'text');

SELECT ok(
    (SELECT field_order FROM fields WHERE table_name = 'oc_tasks' AND field_name = 'notes') > 0,
    'New field on oc_tasks should get auto-assigned field_order > 0'
);

-- Add another field and verify it gets a higher order
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('oc_tasks', 'due_date', 'Due Date', 'date');

SELECT ok(
    (SELECT field_order FROM fields WHERE table_name = 'oc_tasks' AND field_name = 'due_date')
    > (SELECT field_order FROM fields WHERE table_name = 'oc_tasks' AND field_name = 'notes'),
    'Second new field should have higher field_order than first'
);

-- =====================================================
-- TEST 10: get_schema for entities includes order_column field
-- =====================================================

SELECT ok(
    (public.get_schema('entities')::jsonb)->'table' ? 'order_column',
    'get_schema(entities) table object should include order_column key'
);

SELECT ok(
    (public.get_schema('entities')::jsonb)->'properties' ? 'order_column',
    'get_schema(entities) properties should include order_column'
);

-- =====================================================
-- TEST 11: order_column in get_schema for oc_tasks is empty after clear+re-set
-- =====================================================

SELECT is(
    (public.get_schema('oc_tasks')::jsonb)->'table'->>'order_column',
    'priority',
    'get_schema(oc_tasks) should show current order_column = priority'
);

SELECT * FROM finish();
ROLLBACK;
