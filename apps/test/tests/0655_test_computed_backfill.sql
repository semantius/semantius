-- Applying a rule to the records that already exist: computed_backfill and
-- dd_backfill_mute (0210_computed_validation.sql), rollup_backfill (0440_rollup.sql).
-- Adding, changing and removing a rollup definition on existing records is
-- covered by 0555_test_rollup.sql.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. An upgrade through ensure_entities with no signed-in user, as a migration
--      runs it
--   2. A computed rule added, changed and removed, and what the pass leaves alone
--   3. A rule that names its field before the field exists, and an insert-only stamp
--   4. A record that cannot take its new value (90908)
--   5. Through rollups: a child's rule, a computed field over a rollup
--   6. is_a and has_a entities
BEGIN;

SELECT plan(44);

-- =====================================================
-- PART 1: An upgrade through ensure_entities
-- =====================================================
-- The records are loaded by one document and the rules arrive with the next, and
-- the second names a rollup over a computed field of an entity later in the file.
-- That is the shape of a .jsonc file that gains derived fields after its data was
-- loaded: the data file does not run again, so only the pass can fill them in.

SELECT is(rbac.user_id_or_null(), NULL, 'part 1 runs with no signed-in user, as a migration does');

SELECT public.ensure_entities('{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "bf_orders", "module_name": "_core", "singular_label": "BF Order", "plural_label": "BF Orders",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "fields": [{"field_name": "freight", "title": "Freight", "format": "number", "field_order": 10}]},
         "records": [{"id": 1, "label": "o1", "freight": 10.50}, {"id": 2, "label": "o2", "freight": 3.00}]},
        {"entity": {"table_name": "bf_lines", "module_name": "_core", "singular_label": "BF Line", "plural_label": "BF Lines",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "fields": [{"field_name": "order_id", "title": "Order", "format": "parent", "field_order": 10,
                                "reference_table": "bf_orders", "reference_delete_mode": "restrict"},
                               {"field_name": "qty", "title": "Qty", "format": "int32", "field_order": 20},
                               {"field_name": "price", "title": "Price", "format": "number", "field_order": 30}]},
         "records": [{"id": 1, "label": "l1", "order_id": 1, "qty": 2, "price": 5.00},
                     {"id": 2, "label": "l2", "order_id": 1, "qty": 1, "price": 2.50}]}
    ]}'::jsonb);

SELECT public.ensure_entities('{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "bf_orders", "module_name": "_core", "singular_label": "BF Order", "plural_label": "BF Orders",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "computed_fields": [{"name": "total", "jsonlogic": {"+": [{"var": "subtotal"}, {"var": "freight"}]}}],
                    "fields": [{"field_name": "total", "title": "Total", "format": "number", "field_order": 30},
                               {"field_name": "subtotal", "title": "Subtotal", "format": "number", "field_order": 20,
                                "rollup": {"link_field": "bf_lines.order_id", "function": "sum", "value_field": "amount"}}]}},
        {"entity": {"table_name": "bf_lines", "module_name": "_core", "singular_label": "BF Line", "plural_label": "BF Lines",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "computed_fields": [{"name": "amount", "jsonlogic": {"*": [{"var": "qty"}, {"var": "price"}]}}],
                    "fields": [{"field_name": "amount", "title": "Amount", "format": "number", "field_order": 40}]}}
    ]}'::jsonb);

SELECT is((SELECT string_agg(amount::text, ' ' ORDER BY id) FROM bf_lines), '10.00 2.50',
    'upgrade: existing lines hold their computed amount');
SELECT is((SELECT subtotal || ' ' || total FROM bf_orders WHERE id = 1), '12.50 23.00',
    'upgrade: an existing order holds its rollup and the computed field over it');
SELECT is((SELECT subtotal || ' ' || total FROM bf_orders WHERE id = 2), '0.00 3.00',
    'upgrade: an existing order without lines holds the empty rollup and its freight');

-- =====================================================
-- PART 2: A computed rule added, changed and removed
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('cb_orders', 'cb_order', 'CB Order', 'CB Orders', 'backfill probe', 1, 'public:read', 'admin', 'id', 'label', TRUE);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cb_orders', 'base', 'Base', 'int32', 10),
       ('cb_orders', 'calc', 'Calc', 'int32', 20);
INSERT INTO cb_orders (label, base) VALUES ('A', 5), ('B', 0);

-- Every write of this transaction carries the same CURRENT_TIMESTAMP, so the
-- records are first given an old updated_at as the owner, with the trigger off
-- for that one statement.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE cb_orders DISABLE TRIGGER update_cb_orders_updated_at;
UPDATE cb_orders SET updated_at = '2020-01-01 00:00:00+00';
ALTER TABLE cb_orders ENABLE TRIGGER update_cb_orders_updated_at;
INSERT INTO queues (queue_name) VALUES ('cb_q');
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'cb update', 'cb_orders', 'update' FROM queues WHERE queue_name = 'cb_q';
SELECT authenticate_as('user3');

CREATE TEMP TABLE cb_before ON COMMIT DROP AS SELECT label, ctid AS loc FROM cb_orders;
CREATE TEMP TABLE cb_audit ON COMMIT DROP AS
    SELECT count(*) AS n FROM audit_record_logs WHERE table_name = 'cb_orders';

UPDATE entities SET computed_fields = '[{"name": "calc", "jsonlogic": {"*": [{"var": "base"}, 2]}}]' WHERE table_name = 'cb_orders';

SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 10, 'a rule added: an existing record holds the computed value at once');
SELECT is((SELECT ctype FROM fields WHERE table_name = 'cb_orders' AND field_name = 'calc'), 'computed', 'and the field carries ctype computed');
SELECT is((SELECT count(*)::int FROM cb_orders o JOIN cb_before b ON b.label = o.label WHERE o.label = 'B' AND o.ctid <> b.loc), 0,
    'a record whose value does not move is not written');
SELECT is((SELECT updated_at FROM cb_orders WHERE label = 'A'), '2020-01-01 00:00:00+00'::timestamptz, 'the pass leaves updated_at alone');
SELECT is((SELECT count(*) FROM audit_record_logs WHERE table_name = 'cb_orders'), (SELECT n FROM cb_audit), 'and writes no audit row');
SELECT is(
    (SELECT count(*)::int FROM pg_trigger WHERE tgrelid = 'public.cb_orders'::regclass AND NOT tgisinternal AND tgenabled <> 'O'), 0,
    'and leaves every trigger enabled');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT count(*)::int FROM pgmq.read('cb_q', 0, 10)), 0, 'and sends no queue message');
SELECT authenticate_as('user3');

-- The same three side effects on an ordinary write prove the checks above can fail.
UPDATE cb_orders SET base = 6 WHERE label = 'A';
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 12, 'an ordinary write still runs the rule');
SELECT is((SELECT updated_at FROM cb_orders WHERE label = 'A'), CURRENT_TIMESTAMP, 'and bumps updated_at');
SELECT is((SELECT count(*) FROM audit_record_logs WHERE table_name = 'cb_orders'), (SELECT n + 1 FROM cb_audit), 'and writes an audit row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT count(*)::int FROM pgmq.read('cb_q', 0, 10)), 1, 'and sends a queue message');
SELECT authenticate_as('user3');

UPDATE entities SET computed_fields = '[{"name": "calc", "jsonlogic": {"*": [{"var": "base"}, 3]}}]' WHERE table_name = 'cb_orders';
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 18, 'a rule changed: an existing record holds the new value at once');

UPDATE entities SET computed_fields = '[]' WHERE table_name = 'cb_orders';
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 18, 'a rule removed: an existing record keeps the last value');
SELECT is((SELECT ctype FROM fields WHERE table_name = 'cb_orders' AND field_name = 'calc'), '', 'and the field loses ctype computed');
UPDATE cb_orders SET calc = 99 WHERE label = 'A';
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 99, 'and the value is ordinary data a write can change');

-- =====================================================
-- PART 3: A rule before its field, and an insert-only stamp
-- =====================================================
UPDATE entities SET computed_fields = '[{"name": "later", "jsonlogic": {"+": [{"var": "base"}, 1]}}]' WHERE table_name = 'cb_orders';
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('cb_orders', 'later', 'Later', 'int32', 30);
SELECT is((SELECT later FROM cb_orders WHERE label = 'A'), 7, 'a field added after the rule that names it is filled in at once');

INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('cb_orders', 'created_by', 'Created By', 'int64', 40);
UPDATE entities
   SET computed_fields = '[{"name": "created_by", "jsonlogic": {"if": [{"==": [{"var": "$mode"}, "insert"]}, {"var": "$user_id"}, {"var": "$old.created_by"}]}}]'
 WHERE table_name = 'cb_orders';
SELECT is((SELECT created_by FROM cb_orders WHERE label = 'A'), 0::bigint,
    'an insert-only stamp does not stamp existing records with the administrator who saved the rule');
INSERT INTO cb_orders (label, base) VALUES ('C', 1);
SELECT is((SELECT created_by FROM cb_orders WHERE label = 'C'), rbac.user_id_or_null(), 'and stamps a new record');

-- =====================================================
-- PART 4: A record that cannot take its new value
-- =====================================================
-- legacy breaks the validation rule added after it was written, which is not
-- retroactive, so it must block a rule change only when its own value moves.
UPDATE entities SET computed_fields = '[]' WHERE table_name = 'cb_orders';
UPDATE cb_orders SET calc = 0;
INSERT INTO cb_orders (label, base, calc) VALUES ('legacy', 1, 500);
UPDATE entities SET validation_rules = '[{"code": "99871", "message": "calc too high", "jsonlogic": {"<=": [{"var": "calc"}, 100]}}]'
 WHERE table_name = 'cb_orders';

SELECT lives_ok(
    $$UPDATE entities
         SET computed_fields = '[{"name": "calc", "jsonlogic": {"if": [{"==": [{"var": "label"}, "legacy"]}, {"var": "calc"}, {"*": [{"var": "base"}, 2]}]}}]'
       WHERE table_name = 'cb_orders'$$,
    'a record that breaks a validation rule does not block a change that leaves its value alone');
SELECT is((SELECT calc FROM cb_orders WHERE label = 'legacy'), 500, 'and it keeps its value');
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 12, 'while the other records take theirs');

CREATE FUNCTION pg_temp.cb_refused() RETURNS TEXT LANGUAGE sql AS $$
    SELECT $q$UPDATE entities
                 SET computed_fields = '[{"name": "calc", "jsonlogic": {"if": [{"==": [{"var": "label"}, "A"]}, {"*": [{"var": "base"}, 50]}, {"var": "calc"}]}}]'
               WHERE table_name = 'cb_orders'$q$
$$;

SELECT throws_ok(pg_temp.cb_refused(), '90908', NULL, '90908: a record whose new value breaks a validation rule refuses the change');
SELECT is(catch_error_hint(pg_temp.cb_refused()) ->> 'record_id', (SELECT id::text FROM cb_orders WHERE label = 'A'), 'the error names the record');
SELECT is(catch_error_hint(pg_temp.cb_refused()) ->> 'cause_code', '99871', 'and the rule''s own code');
SELECT is(catch_error_hint(pg_temp.cb_refused()) ->> 'problem', 'calc too high', 'and its message');
SELECT is((SELECT calc FROM cb_orders WHERE label = 'A'), 12, 'the record keeps its value');
SELECT ok((SELECT computed_fields::text LIKE '%legacy%' FROM entities WHERE table_name = 'cb_orders'), 'and the entity keeps the rule it had');
SELECT is(
    (SELECT count(*)::int FROM pg_trigger WHERE tgrelid = 'public.cb_orders'::regclass AND NOT tgisinternal AND tgenabled <> 'O'), 0,
    'and no trigger is left disabled');

-- =====================================================
-- PART 5: Through rollups
-- =====================================================
UPDATE entities SET computed_fields = '[]', validation_rules = '[]' WHERE table_name = 'cb_orders';
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cb_lines', 'cb_line', 'CB Line', 'CB Lines', 'backfill child', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('cb_lines', 'parent_id', 'Parent', 'parent', 10, 'cb_orders', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cb_lines', 'qty', 'Qty', 'int32', 20),
       ('cb_lines', 'amount', 'Amount', 'int32', 30),
       ('cb_orders', 'total', 'Total', 'int32', 50);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('cb_orders', 'subtotal', 'Subtotal', 'int32', 60, '{"link_field": "cb_lines.parent_id", "function": "sum", "value_field": "amount"}');
INSERT INTO cb_lines (label, parent_id, qty)
SELECT l, o.id, q FROM cb_orders o, (VALUES ('l1', 3), ('l2', 4)) v(l, q) WHERE o.label = 'A';
UPDATE entities SET computed_fields = '[{"name": "total", "jsonlogic": {"+": [{"var": "subtotal"}, {"var": "base"}]}}]' WHERE table_name = 'cb_orders';

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE cb_orders DISABLE TRIGGER update_cb_orders_updated_at;
UPDATE cb_orders SET updated_at = '2020-01-01 00:00:00+00';
ALTER TABLE cb_orders ENABLE TRIGGER update_cb_orders_updated_at;
SELECT pgmq.purge_queue('cb_q');
SELECT authenticate_as('user3');
UPDATE cb_audit SET n = (SELECT count(*) FROM audit_record_logs WHERE table_name = 'cb_orders');

UPDATE entities SET computed_fields = '[{"name": "amount", "jsonlogic": {"*": [{"var": "qty"}, 2]}}]' WHERE table_name = 'cb_lines';
SELECT is((SELECT subtotal || ' ' || total FROM cb_orders WHERE label = 'A'), '14 20',
    'a rule on a child moves the rollup above it and the computed field over that');
SELECT is((SELECT updated_at FROM cb_orders WHERE label = 'A'), '2020-01-01 00:00:00+00'::timestamptz, 'the parent''s updated_at stays');
SELECT is((SELECT count(*) FROM audit_record_logs WHERE table_name = 'cb_orders'), (SELECT n FROM cb_audit), 'the parent writes no audit row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT count(*)::int FROM pgmq.read('cb_q', 0, 10)), 0, 'and sends no queue message');
SELECT authenticate_as('user3');

UPDATE fields SET rollup = jsonb_set(rollup, '{function}', '"max"') WHERE table_name = 'cb_orders' AND field_name = 'subtotal';
SELECT is((SELECT subtotal || ' ' || total FROM cb_orders WHERE label = 'A'), '8 14',
    'a changed rollup definition moves the computed field over it');
SELECT is((SELECT updated_at FROM cb_orders WHERE label = 'A'), '2020-01-01 00:00:00+00'::timestamptz, 'and that pass leaves updated_at alone too');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT count(*)::int FROM pgmq.read('cb_q', 0, 10)), 0, 'and sends no queue message');
SELECT authenticate_as('user3');

-- =====================================================
-- PART 6: is_a and has_a entities
-- =====================================================
-- Their records span several tables, so the pass writes through the entity's view
-- and the root's dispatch rather than to a table of its own.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, edit_permission)
VALUES ('bf_accounts', 'Account', 'Accounts', 1, 'typeid', 'bfacc', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('bf_accounts', 'amount', 'Amount', 'int32', 30),
       ('bf_accounts', 'tag', 'Tag', 'text', 40);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity, edit_permission)
VALUES ('bf_premium', 'Premium', 'Premiums', 1, 'is_a', 'bfprm', 'bf_accounts', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('bf_premium', 'factor', 'Factor', 'int32', 30),
       ('bf_premium', 'level', 'Level', 'text', 40);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity, edit_permission)
VALUES ('bf_extras', 'Extra', 'Extras', 1, 'has_a', 'bf_accounts', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('bf_extras', 'bonus', 'Bonus', 'int32', 30),
       ('bf_extras', 'doubled', 'Doubled', 'int32', 40);

INSERT INTO bf_premium (label, factor) VALUES ('p1', 5);
INSERT INTO bf_accounts (label) VALUES ('a1');
INSERT INTO bf_extras (label, bonus) VALUES ('e1', 4);

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE bf_accounts DISABLE TRIGGER USER;
UPDATE bf_accounts SET updated_at = '2020-01-01 00:00:00+00';
ALTER TABLE bf_accounts ENABLE TRIGGER USER;
SELECT authenticate_as('user3');

UPDATE entities
   SET computed_fields = '[{"name": "level", "jsonlogic": {"cat": ["L", {"var": "factor"}]}},
                           {"name": "amount", "jsonlogic": {"*": [{"var": "factor"}, 10]}}]'
 WHERE table_name = 'bf_premium';
SELECT is((SELECT level FROM bf_premium WHERE label = 'p1'), 'L5', 'is_a: a rule added fills a column of the subtype');
SELECT is((SELECT amount FROM bf_accounts WHERE label = 'p1'), 50, 'is_a: and a column its root stores');
SELECT is((SELECT updated_at FROM bf_accounts WHERE label = 'p1'), '2020-01-01 00:00:00+00'::timestamptz, 'is_a: and the root''s updated_at stays');

UPDATE entities SET computed_fields = '[{"name": "tag", "jsonlogic": {"cat": ["T:", {"var": "label"}]}}]' WHERE table_name = 'bf_accounts';
SELECT is((SELECT string_agg(tag, ' ' ORDER BY label) FROM bf_accounts WHERE label IN ('a1', 'p1')), 'T:a1 T:p1',
    'is_a: a rule added on the root reaches its own records and the subtype''s');

UPDATE entities SET computed_fields = '[{"name": "doubled", "jsonlogic": {"*": [{"var": "bonus"}, 2]}}]' WHERE table_name = 'bf_extras';
SELECT is((SELECT doubled FROM bf_extras WHERE label = 'e1'), 8, 'has_a: a rule added fills a column of the extension');

SELECT * FROM finish();
ROLLBACK;
