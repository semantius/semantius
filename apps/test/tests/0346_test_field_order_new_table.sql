-- =====================================================
-- TEST: fields auto field_order on a brand-new table
-- =====================================================
-- Reproduces the bug where a new field on a freshly created table was assigned
-- a field_order of ~1,000,000+ instead of continuing the visible sequence.
--
-- A newly created managed table is seeded with:
--   id         -> field_order 10
--   <label>    -> field_order 20
--   created_at -> field_order 999998   (pinned to the end)
--   updated_at -> field_order 999999   (pinned to the end)
--
-- The auto-assign rule must be: field_order = 10 + MAX(field_order) over rows
-- whose field_order is < 900000. The pinned audit columns (999998/999999) sit
-- at/above that ceiling and must NOT inflate the running max, so the first
-- user-added field must land at 30 (10 + 20), keeping new fields sorted just
-- after the existing content and well before the pinned audit columns.

BEGIN;

SELECT plan(4);

-- Admin user (can write entities/fields and managed tables).
SELECT authenticate_as('user3');

-- =====================================================
-- Create a fresh managed entity
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('field_order_new', 'field_order_new', 'Field Order New', 'Field Order News', 'New-table field_order test', 1001, 'public:read', 'sales:manage', 'id', 'label');

SELECT has_table('public', 'field_order_new', 'field_order_new table should be created');

-- Sanity: the pinned audit columns are the only rows at/above the 900000 ceiling,
-- and the visible max below it is the label column at 20.
SELECT is(
    (SELECT MAX(field_order) FROM fields WHERE table_name = 'field_order_new' AND field_order < 900000),
    20,
    'max visible field_order (< 900000) on the new table is 20 (the label column)'
);

-- =====================================================
-- A new field WITHOUT a field_order must get 10 + max(< 900000) = 30
-- =====================================================
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('field_order_new', 'xxx', 'Xxx', 'text');

SELECT is(
    (SELECT field_order FROM fields WHERE table_name = 'field_order_new' AND field_name = 'xxx'),
    30,
    'first user-added field gets 10 + max(field_order < 900000) = 30, not a 1,000,000+ value'
);

-- A second new field continues the sequence: 10 + max(< 900000) = 40.
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('field_order_new', 'yyy', 'Yyy', 'text');

SELECT is(
    (SELECT field_order FROM fields WHERE table_name = 'field_order_new' AND field_name = 'yyy'),
    40,
    'second user-added field continues at 10 + max(field_order < 900000) = 40'
);

SELECT * FROM finish();

ROLLBACK;
