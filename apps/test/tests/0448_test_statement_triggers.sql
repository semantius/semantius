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
-- Fixtures: user3 = Administrator. shippers and regions are also mapped by
-- 0310_test_queue.sql, which is harmless: each test file runs in its own
-- transaction and rolls back, so the unique constraint on
-- queue_table_events.table_name is never seen by both at once.
BEGIN;

SELECT plan(25);

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
    '[{"code":"no_delete","message":"deletion is not allowed",
       "jsonlogic":{"!=":[{"var":"$mode"},"delete"]}}]'::jsonb);

INSERT INTO ctx_mode_literal (label) VALUES ('keep me');

SELECT throws_ok(
    $$ DELETE FROM ctx_mode_literal $$,
    '23514', NULL,
    '$mode guard blocks a DELETE when the rule names the variable'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_mode_computed', 'ctx_mode_computed_item', 'Ctx Mode Computed', 'Ctx Mode Computeds',
    'conditional context probe, computed key', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"no_delete","message":"deletion is not allowed",
       "jsonlogic":{"!=":[{"var":{"cat":["$mo","de"]}},"delete"]}}]'::jsonb);

INSERT INTO ctx_mode_computed (label) VALUES ('keep me too');

SELECT throws_ok(
    $$ DELETE FROM ctx_mode_computed $$,
    '23514', NULL,
    '$mode guard blocks a DELETE when the rule builds the variable name'
);

-- The same evasion against $old, where the context is genuinely conditional.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_old_computed', 'ctx_old_computed_item', 'Ctx Old Computed', 'Ctx Old Computeds',
    'conditional context probe, computed $old key', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"write_once","message":"label is write-once",
       "jsonlogic":{"or":[{"==":[{"var":"$old"},null]},
                          {"==":[{"var":{"cat":["$ol","d.label"]}},{"var":"label"}]}]}}]'::jsonb);

INSERT INTO ctx_old_computed (label) VALUES ('original');

SELECT throws_ok(
    $$ UPDATE ctx_old_computed SET label = 'changed' $$,
    '23514', NULL,
    '$old guard blocks an UPDATE when the rule builds the variable name'
);

-- The negative control: an entity whose rules never mention $old does not get
-- it, which is the whole point of the conditional build.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES ('ctx_no_old', 'ctx_no_old_item', 'Ctx No Old', 'Ctx No Olds',
    'conditional context probe, no old reference', 1, 'public:read', 'admin', 'id', 'label',
    '[{"code":"nonempty","message":"label required","jsonlogic":{"!=":[{"var":"label"},""]}}]'::jsonb);

SELECT is(
    (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'compute_validate_ctx_no_old'
       AND p.prosrc LIKE '%$old%'),
    0,
    'an entity whose rules never read $old does not build it'
);

SELECT * FROM finish();
ROLLBACK;
