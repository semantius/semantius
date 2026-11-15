-- Test the statement-level audit and queue triggers.
--
-- Audit logs INSERT and DELETE once per statement over a transition table, and
-- keeps UPDATE row-level because an update entry needs the before and after
-- image of the same row and a transition table offers no way to pair them that
-- survives a primary key changing. The queue enqueues once per statement with
-- pgmq.send_batch for the same reason the audit does: the queue lookup and the
-- acting user are constant for the whole statement.
--
-- What this file is really guarding is subtler than "the triggers fire". Both
-- trigger functions are generic - one function body serves every audited or
-- queued table - and each reads a transition table through a statement whose
-- plan PL/pgSQL caches per function rather than per relation. If that cached
-- plan ever stopped re-resolving the row type, the failure would be either a
-- cached-plan type error or, worse, silently wrong rows. The two-tables-in-one-
-- session cases below are the standing check on that, and they are the reason
-- the trigger bodies can use plain static statements instead of dynamic SQL.
--
-- MERGE fires the statement triggers of each action it names, so groups 9 to 11
-- check that an audited table, a queue-mapped table and the child of a rollup
-- see the insert, update and delete actions of one MERGE as they see the three
-- separate statements.
--
-- Fixtures: user3 = Administrator. shippers and regions are also mapped by
-- 0840_test_queue.sql, which is harmless: each test file runs in its own
-- transaction and rolls back, so the unique constraint on
-- queue_table_events.table_name is never seen by both at once.
BEGIN;

SELECT plan(44);

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: the trigger shapes
-- =====================================================
-- An audited table carries four triggers: two statement-level, one row-level
-- for UPDATE alone, and the truncate trigger.
SELECT is(
    (SELECT array_agg(tgname::text ORDER BY tgname)
     FROM pg_trigger
     WHERE tgrelid = 'public.users'::regclass
       AND starts_with(tgname::text, 'audit_')),
    ARRAY['audit_d', 'audit_i', 'audit_i_u_d', 'audit_t'],
    'an audited table carries audit_i, audit_d, audit_i_u_d and audit_t'
);

-- tgtype bit 0x01 = FOR EACH ROW (see pg_trigger.h TRIGGER_TYPE_ROW).
SELECT is(
    (SELECT bool_and((tgtype & 1) = 0)
     FROM pg_trigger
     WHERE tgrelid = 'public.users'::regclass
       AND tgname::text IN ('audit_i', 'audit_d')),
    TRUE,
    'audit_i and audit_d are statement-level'
);

-- audit_i_u_d must fire on UPDATE and nothing else: bits 0x04 INSERT,
-- 0x08 DELETE, 0x10 UPDATE. Asserting the events directly rather than through a
-- PK-changing update, which passes either way while UPDATE stays row-level.
SELECT is(
    (SELECT (tgtype & 1) <> 0 AND (tgtype & 16) <> 0
        AND (tgtype & 4) = 0 AND (tgtype & 8) = 0
     FROM pg_trigger
     WHERE tgrelid = 'public.users'::regclass AND tgname::text = 'audit_i_u_d'),
    TRUE,
    'audit_i_u_d is a row trigger for UPDATE only'
);

-- =====================================================
-- GROUP 2: audit content, one statement at a time
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('stmt_audit_a', 'stmt_audit_a_item', 'Stmt Audit A', 'Stmt Audit As',
    'statement trigger probe', 1, 'public:read', 'admin', 'id', 'label', TRUE);

INSERT INTO stmt_audit_a (label) VALUES ('a1'), ('a2'), ('a3');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'),
    3,
    'a 3-row INSERT writes 3 audit rows'
);

SELECT is(
    (SELECT count(DISTINCT record_pk)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'),
    3,
    'each audit row carries its own record_pk, not the same one three times'
);

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'
       AND record_id IS NOT NULL
       AND old_record_id IS NULL
       AND record IS NOT NULL
       AND old_record IS NULL
       AND user_id = rbac.user_id()),
    3,
    'INSERT audit rows satisfy the op CHECK constraints and carry the acting user'
);

UPDATE stmt_audit_a SET label = 'a1 edited' WHERE label = 'a1';

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'UPDATE'
       AND record_id IS NOT NULL AND old_record_id IS NOT NULL
       AND record IS NOT NULL AND old_record IS NOT NULL),
    1,
    'an UPDATE still writes both images, which is why it stays row-level'
);

DELETE FROM stmt_audit_a;

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'DELETE'
       AND record_id IS NULL
       AND old_record_id IS NOT NULL
       AND record IS NULL
       AND old_record IS NOT NULL),
    3,
    'a 3-row DELETE writes 3 audit rows with only the old image'
);

-- A statement that matches nothing must not write an audit row, and must not
-- fail: a statement trigger fires whether or not any row was affected.
INSERT INTO stmt_audit_a (label) SELECT 'never' WHERE FALSE;

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'),
    3,
    'a zero-row INSERT writes no audit row and does not raise'
);

-- =====================================================
-- GROUP 3: two audited tables of different shapes, one session
-- =====================================================
-- The generic audit function serves both. A plan that cached the first table's
-- row type would either raise here or write the wrong columns.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('stmt_audit_b', 'stmt_audit_b_item', 'Stmt Audit B', 'Stmt Audit Bs',
    'statement trigger probe, second shape', 1, 'public:read', 'admin', 'id', 'label', TRUE);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('stmt_audit_b', 'extra_col', 'Extra Col', 'string', 30);

INSERT INTO stmt_audit_b (label, extra_col) VALUES ('b1', 'x'), ('b2', 'y');
INSERT INTO stmt_audit_a (label) VALUES ('a4');
INSERT INTO stmt_audit_b (label, extra_col) VALUES ('b3', 'z');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_b' AND op = 'INSERT'
       AND record ? 'extra_col'),
    3,
    'the second table logs its own columns, interleaved with the first'
);

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'
       AND record ? 'extra_col'),
    0,
    'the first table does not acquire the second table columns'
);

-- A column added to an audited table mid-transaction must appear in the audit
-- rows written afterwards, even though the trigger has already fired once.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('stmt_audit_a', 'late_col', 'Late Col', 'string', 40);

INSERT INTO stmt_audit_a (label, late_col) VALUES ('a5', 'late');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
     WHERE table_name = 'stmt_audit_a' AND op = 'INSERT'
       AND record ->> 'late_col' = 'late'),
    1,
    'a column added mid-transaction reaches the audit row written after it'
);

-- =====================================================
-- GROUP 4: disable_tracking removes all four
-- =====================================================
UPDATE entities SET audit_log = FALSE WHERE table_name = 'stmt_audit_b';

SELECT is(
    (SELECT count(*)::int FROM pg_trigger
     WHERE tgrelid = 'public.stmt_audit_b'::regclass
       AND starts_with(tgname::text, 'audit_')),
    0,
    'disabling audit removes every audit trigger, not only audit_i_u_d'
);

-- =====================================================
-- GROUP 5: the queue, statement-level
-- =====================================================
-- Switch to owner for queue operations (pgmq needs schema access). Everything
-- below runs as the owner, not as user3.
RESET ROLE;

INSERT INTO queues (queue_name) VALUES ('stmt_q');

INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'shipper change event', 'shippers', 'change'
FROM queues WHERE queue_name = 'stmt_q';

INSERT INTO shippers (company_name) VALUES ('S1'), ('S2'), ('S3');

SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers' AND message ->> 'op' = 'INSERT'),
    3,
    'a 3-row INSERT enqueues exactly 3 messages'
);

SELECT is(
    (SELECT count(DISTINCT message ->> 'id_value')::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers' AND message ->> 'op' = 'INSERT'),
    3,
    'each message carries its own id_value'
);

-- event_type is the mapping handler, not the DML verb: a consumer subscribed to
-- 'change' expects that label whichever statement produced the message.
SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers'
       AND message ->> 'event_type' = 'change'
       AND message ->> 'message_type' = 'entity_event'),
    3,
    'event_type comes from the mapping handler, not from the DML operation'
);

-- pgmq refuses an empty batch, so a statement that matched nothing has to be
-- guarded rather than sent.
INSERT INTO shippers (company_name) SELECT 'never' WHERE FALSE;

SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers'),
    3,
    'a zero-row INSERT enqueues nothing and does not raise'
);

UPDATE shippers SET company_name = 'S1 edited' WHERE company_name = 'S1';
DELETE FROM shippers WHERE company_name = 'S2';

SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers' AND message ->> 'op' IN ('UPDATE', 'DELETE')),
    2,
    'UPDATE and DELETE enqueue with their own op'
);

-- =====================================================
-- GROUP 6: two queued tables of different shapes, one session
-- =====================================================
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'region insert event', 'regions', 'insert'
FROM queues WHERE queue_name = 'stmt_q';

INSERT INTO regions (region_description) VALUES ('R1'), ('R2');
INSERT INTO shippers (company_name) VALUES ('S4');

SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'regions'),
    2,
    'a second queued table of a different shape enqueues its own rows'
);

SELECT is(
    (SELECT count(*)::int FROM pgmq.read('stmt_q', 0, 100)
     WHERE message ->> 'table' = 'shippers'),
    6,
    'the first queued table keeps enqueuing correctly after the second is added'
);

-- =====================================================
-- GROUP 7: mapping teardown
-- =====================================================
DELETE FROM queue_table_events WHERE table_name = 'shippers';

SELECT is(
    (SELECT count(*)::int FROM pg_trigger
     WHERE tgrelid = 'public.shippers'::regclass
       AND starts_with(tgname::text, 'queue_')),
    0,
    'deleting a change mapping removes all three of its triggers'
);

-- =====================================================
-- GROUP 8: the conditional $old/$mode context
-- =====================================================
-- $old and $mode are omitted from the generated context when no rule reads
-- them. A rule that does read one must still get it, including when the
-- reference is not literal: the interpreter evaluates a var's argument, so a
-- computed key resolves to $mode with the name nowhere in the rule text. A
-- context key that goes missing does not raise - the variable reads as null and
-- the guard silently passes - so both forms are asserted by behavior.
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_mode_literal', 'ctx_mode_literal_item', 'Ctx Mode Literal', 'Ctx Mode Literals',
    'conditional context probe', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"99501","message":"deletion is not allowed",
       "jsonlogic":{"!=":[{"var":"$mode"},"delete"]}}]'::jsonb);

INSERT INTO ctx_mode_literal (label) VALUES ('keep me');

SELECT throws_ok(
    $$ DELETE FROM ctx_mode_literal $$,
    '99501', NULL,
    '$mode guard blocks a DELETE when the rule names the variable'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_mode_computed', 'ctx_mode_computed_item', 'Ctx Mode Computed', 'Ctx Mode Computeds',
    'conditional context probe, computed key', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"99501","message":"deletion is not allowed",
       "jsonlogic":{"!=":[{"var":{"cat":["$mo","de"]}},"delete"]}}]'::jsonb);

INSERT INTO ctx_mode_computed (label) VALUES ('keep me too');

SELECT throws_ok(
    $$ DELETE FROM ctx_mode_computed $$,
    '99501', NULL,
    '$mode guard blocks a DELETE when the rule builds the variable name'
);

-- The same evasion against $old, where the context is genuinely conditional.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_old_computed', 'ctx_old_computed_item', 'Ctx Old Computed', 'Ctx Old Computeds',
    'conditional context probe, computed $old key', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"99502","message":"label is write-once",
       "jsonlogic":{"or":[{"==":[{"var":"$old"},null]},
                          {"==":[{"var":{"cat":["$ol","d.label"]}},{"var":"label"}]}]}}]'::jsonb);

INSERT INTO ctx_old_computed (label) VALUES ('original');

SELECT throws_ok(
    $$ UPDATE ctx_old_computed SET label = 'changed' $$,
    '99502', NULL,
    '$old guard blocks an UPDATE when the rule builds the variable name'
);

-- The negative control: an entity whose rules never mention $old does not get
-- it, which is the whole point of the conditional build.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_no_old', 'ctx_no_old_item', 'Ctx No Old', 'Ctx No Olds',
    'conditional context probe, no old reference', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"99503","message":"label required","jsonlogic":{"!=":[{"var":"label"},""]}}]'::jsonb);

SELECT is(
    (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'compute_validate_ctx_no_old'
       AND p.prosrc LIKE '%$old%'),
    0,
    'an entity whose rules never read $old does not build it'
);

-- =====================================================
-- GROUP 6: what one field insert costs
-- =====================================================
-- Adding a field to an entity used to cost three audit rows, a full rebuild of
-- the entity's label functions and an unconditional entities UPDATE whose only
-- effect was to fire a dozen more triggers. What is left is the irreducible
-- part plus one deliberate extra: the fields row itself, and the modules row
-- whose version has to move because a field is part of the model. The counts
-- below are the standing check on that - they fail if either the label rebuild
-- or the no-op entities UPDATE comes back.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('field_cost', 'field_cost_item', 'Field Cost', 'Field Costs',
    'per-field trigger cost probe', 1, 'public:read', 'admin', 'id', 'label', TRUE);

CREATE TEMP TABLE field_cost_base AS
SELECT (SELECT count(*) FROM audit_record_logs)                    AS records,
       (SELECT count(*) FROM audit_record_logs WHERE table_name = 'entities') AS entity_rows,
       (SELECT count(*) FROM audit_ddl_logs)                       AS ddl;

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('field_cost', 'plain_one', 'Plain One', 'string', 30);

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs) - (SELECT records::int FROM field_cost_base),
    2,
    'a plain field insert writes two audit rows: the field, and the module version bump'
);

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'entities')
        - (SELECT entity_rows::int FROM field_cost_base),
    0,
    'a plain field insert does not touch the entities row'
);

-- The two DDL events are the ALTER TABLE that adds the column and the schema
-- reload that follows it. A label rebuild would add several more.
SELECT cmp_ok(
    (SELECT count(*)::int FROM audit_ddl_logs) - (SELECT ddl::int FROM field_cost_base),
    '<=',
    2,
    'a plain field insert emits no label-rebuild DDL'
);

-- =====================================================
-- GROUP 9: MERGE against an audited table
-- =====================================================
-- MERGE fires the statement triggers of every action it names and the row
-- triggers of every row an action touches, so the insert, update and delete
-- actions of one MERGE are audited as the same three statements would be.
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('merge_audit', 'merge_audit_item', 'Merge Audit', 'Merge Audits',
    'MERGE audit probe', 1, 'public:read', 'admin', 'id', 'label', TRUE);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('merge_audit', 'qty', 'Qty', 'int32', 30);

INSERT INTO merge_audit (label, qty) VALUES ('keep', 1), ('change', 2), ('remove', 3);
DELETE FROM audit_record_logs WHERE table_name = 'merge_audit';

SELECT lives_ok($$
    MERGE INTO merge_audit t
    USING (VALUES ('change', 20, 'update'), ('remove', 0, 'delete'), ('fresh', 4, 'insert')) AS s(label, qty, act)
    ON t.label = s.label
    WHEN MATCHED AND s.act = 'update' THEN UPDATE SET qty = s.qty
    WHEN MATCHED AND s.act = 'delete' THEN DELETE
    WHEN NOT MATCHED THEN INSERT (label, qty) VALUES (s.label, s.qty)
$$, 'a MERGE with an insert, an update and a delete action succeeds');

SELECT is(
    (SELECT array_agg(op::text || ':' || coalesce(record ->> 'label', old_record ->> 'label') ORDER BY op::text)
       FROM audit_record_logs WHERE table_name = 'merge_audit'),
    ARRAY['DELETE:remove', 'INSERT:fresh', 'UPDATE:change'],
    'each action of the MERGE is audited once, with its own operation');

SELECT is(
    (SELECT jsonb_build_array(old_record ->> 'qty', record ->> 'qty')
       FROM audit_record_logs WHERE table_name = 'merge_audit' AND op = 'UPDATE'),
    '["2", "20"]'::jsonb,
    'the update action logs the row before and after');

SELECT is(
    (SELECT record IS NULL AND old_record ->> 'label' = 'remove'
       FROM audit_record_logs WHERE table_name = 'merge_audit' AND op = 'DELETE'),
    TRUE,
    'the delete action logs only the old image');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs
      WHERE table_name = 'merge_audit' AND user_id = rbac.user_id()),
    3,
    'and every row carries the acting user');

-- All three statement triggers fire for a MERGE that touches no row, and must
-- neither fail nor log.
SELECT lives_ok($$
    MERGE INTO merge_audit t
    USING (SELECT 'nobody'::text AS label WHERE FALSE) s
    ON t.label = s.label
    WHEN MATCHED AND t.qty > 100 THEN DELETE
    WHEN MATCHED THEN UPDATE SET qty = 0
    WHEN NOT MATCHED THEN INSERT (label) VALUES (s.label)
$$, 'a MERGE that touches no row succeeds');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'merge_audit'),
    3,
    'and writes no audit row');

-- =====================================================
-- GROUP 10: MERGE against a queue-mapped table
-- =====================================================
-- The mapping is 'change', so all three statement triggers are installed and
-- each MERGE action enqueues under the mapping's event_type.
RESET ROLE;

INSERT INTO queues (queue_name) VALUES ('merge_q');

INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'shipper merge event', 'shippers', 'change'
FROM queues WHERE queue_name = 'merge_q';

INSERT INTO shippers (company_name) VALUES ('Merge keep'), ('Merge change'), ('Merge remove');

CREATE TEMP TABLE merge_shippers AS
SELECT id, company_name FROM shippers WHERE company_name LIKE 'Merge %';

-- The setup inserts enqueued three messages of their own.
SELECT pgmq.purge_queue('merge_q');

SELECT lives_ok($$
    MERGE INTO shippers t
    USING (VALUES ('Merge change', 'update'), ('Merge remove', 'delete'), ('Merge fresh', 'insert')) AS s(name, act)
    ON t.company_name = s.name
    WHEN MATCHED AND s.act = 'update' THEN UPDATE SET phone = '555'
    WHEN MATCHED AND s.act = 'delete' THEN DELETE
    WHEN NOT MATCHED THEN INSERT (company_name) VALUES (s.name)
$$, 'a MERGE with an insert, an update and a delete action succeeds on a mapped table');

SELECT is(
    (SELECT array_agg((q.message ->> 'op') || ':' || n.company_name ORDER BY q.message ->> 'op')
       FROM pgmq.q_merge_q q
       JOIN (SELECT id, company_name FROM merge_shippers
             UNION
             SELECT id, company_name FROM shippers WHERE company_name = 'Merge fresh') n
         ON n.id = (q.message ->> 'id_value')::bigint),
    ARRAY['DELETE:Merge remove', 'INSERT:Merge fresh', 'UPDATE:Merge change'],
    'each action enqueues one message, with its own operation and the id of the row it touched');

SELECT is(
    (SELECT array_agg(DISTINCT message ->> 'event_type') FROM pgmq.q_merge_q),
    ARRAY['change'],
    'and every message carries the mapping''s event_type');

SELECT lives_ok($$
    MERGE INTO shippers t
    USING (SELECT 'nobody'::text AS name WHERE FALSE) s
    ON t.company_name = s.name
    WHEN MATCHED AND t.phone = 'never' THEN DELETE
    WHEN MATCHED THEN UPDATE SET phone = '000'
    WHEN NOT MATCHED THEN INSERT (company_name) VALUES (s.name)
$$, 'a MERGE that touches no row succeeds on a mapped table');

SELECT is((SELECT count(*)::int FROM pgmq.q_merge_q), 3,
    'and enqueues nothing');

-- =====================================================
-- GROUP 11: MERGE against a rollup child
-- =====================================================
-- The rollup triggers on the child are statement-level over transition tables,
-- like the queue's. A MERGE that inserts, updates, deletes and re-parents rows
-- must leave every parent's totals equal to a fresh aggregate over its children.
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('merge_parent', 'merge_parent', 'Merge Parent', 'Merge Parents', 'MERGE rollup parent',
        1, 'public:read', 'admin', 'id', 'label'),
       ('merge_child', 'merge_child', 'Merge Child', 'Merge Children', 'MERGE rollup child',
        1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('merge_child', 'parent_id', 'Parent', 'parent', 10, 'merge_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('merge_child', 'amount', 'Amount', 'number', 20);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup) VALUES
    ('merge_parent', 'total', 'Total', 'number', 10,
     '{"link_field": "merge_child.parent_id", "function": "sum", "value_field": "amount"}'),
    ('merge_parent', 'line_count', 'Lines', 'int64', 20,
     '{"link_field": "merge_child.parent_id", "function": "count"}');

INSERT INTO merge_parent (label) VALUES ('P1'), ('P2');
INSERT INTO merge_child (label, parent_id, amount) VALUES
    ('c1', (SELECT id FROM merge_parent WHERE label = 'P1'), 1),
    ('c2', (SELECT id FROM merge_parent WHERE label = 'P1'), 2),
    ('c3', (SELECT id FROM merge_parent WHERE label = 'P1'), 4);

SELECT is(
    (SELECT jsonb_object_agg(label, jsonb_build_array(total, line_count)) FROM merge_parent),
    '{"P1": [7, 3], "P2": [0, 0]}'::jsonb,
    'fixture: the totals follow the three inserted children');

SELECT lives_ok($$
    MERGE INTO merge_child t
    USING (VALUES ('c1', 10, 'update'), ('c2', 0, 'delete'), ('c3', 0, 'move'), ('c4', 8, 'insert')) AS s(label, amount, act)
    ON t.label = s.label
    WHEN MATCHED AND s.act = 'update' THEN UPDATE SET amount = s.amount
    WHEN MATCHED AND s.act = 'delete' THEN DELETE
    WHEN MATCHED AND s.act = 'move' THEN UPDATE SET parent_id = (SELECT id FROM merge_parent WHERE label = 'P2')
    WHEN NOT MATCHED THEN INSERT (label, parent_id, amount)
         VALUES (s.label, (SELECT id FROM merge_parent WHERE label = 'P2'), s.amount)
$$, 'a MERGE that updates, deletes, re-parents and inserts children succeeds');

SELECT is(
    (SELECT jsonb_object_agg(label, jsonb_build_array(total, line_count)) FROM merge_parent),
    '{"P1": [10, 1], "P2": [12, 2]}'::jsonb,
    'P1 keeps c1 at its new amount; P2 gains the re-parented c3 and the inserted c4');

SELECT is(
    (SELECT jsonb_object_agg(label, jsonb_build_array(total, line_count)) FROM merge_parent),
    (SELECT jsonb_object_agg(label, jsonb_build_array(t, n))
       FROM (SELECT p.label, coalesce(sum(c.amount), 0) AS t, count(c.id) AS n
               FROM merge_parent p LEFT JOIN merge_child c ON c.parent_id = p.id
              GROUP BY p.label) x),
    'and every total equals a fresh aggregate over the children');

SELECT * FROM finish();
ROLLBACK;
