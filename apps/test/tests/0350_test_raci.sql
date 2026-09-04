-- =====================================================
-- RACI System Tests (0350)
-- =====================================================
-- Validates the RACI catalog entities, SQL functions,
-- JsonLogic operators, emit trigger, and queue wiring.
-- All operations run as admin (user3) unless noted.
--
-- Fixtures: the governed entity is an ephemeral DD entity `raci_probe` created
-- in-tx (module 1, public:read / admin) with a declared `status` enum field
-- (draft | approved | rejected, default 'draft') — no raw ALTER TABLE, no owner
-- dance. Three rows are inserted and their ids captured in a TEMP table:
-- probe_a (manually inserted events), probe_b (emit-trigger transitions),
-- probe_c (queue wiring). RACI roles: R/C = Northwind Sales (apps/nwind),
-- A = Administrator, I = User. The emit-trigger INSTALLER (install/drop on the
-- emits_events toggle) is covered by 0400_test_raci_gates_emit_trigger.sql.
BEGIN;

SELECT plan(66);

-- Authenticate as admin for all RACI setup
SELECT authenticate_as('user3');

-- =====================================================
-- FIXTURES: governed DD entity (ephemeral, rolled back)
-- =====================================================
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label,
                      description, module_id, view_permission, edit_permission,
                      id_column, label_column)
VALUES ('raci_probe', 'raci_probe', 'raci_probes', 'RACI Probe', 'RACI Probes',
        'raci runtime test entity', 1, 'public:read', 'admin', 'id', 'name');

INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('raci_probe', 'status', 'Status', 'enum', 'required',
        '["draft", "approved", "rejected"]'::jsonb, 'draft');

INSERT INTO raci_probe (name) VALUES ('probe_a'), ('probe_b'), ('probe_c');

CREATE TEMP TABLE _rp ON COMMIT DROP AS
SELECT (SELECT id FROM raci_probe WHERE name = 'probe_a') AS a_id,
       (SELECT id FROM raci_probe WHERE name = 'probe_b') AS b_id,
       (SELECT id FROM raci_probe WHERE name = 'probe_c') AS c_id;

-- =====================================================
-- GROUP 1: users.is_agent column
-- =====================================================

-- Test 1
SELECT has_column('public', 'users', 'is_agent',
    'users.is_agent column should exist');

-- Test 2: defaults to FALSE
SELECT is(
    (SELECT is_agent FROM users WHERE external_id = 'user1'),
    FALSE,
    'users.is_agent should default to FALSE for existing users'
);

-- Test 3: registered in fields
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'users' AND field_name = 'is_agent')),
    'is_agent should be registered in fields metadata'
);

-- Test 4: can be set to TRUE
UPDATE users SET is_agent = TRUE WHERE external_id = 'user1';
SELECT is(
    (SELECT is_agent FROM users WHERE external_id = 'user1'),
    TRUE,
    'users.is_agent can be set to TRUE'
);
UPDATE users SET is_agent = FALSE WHERE external_id = 'user1';

-- =====================================================
-- GROUP 2: Schema existence
-- =====================================================

-- Test 5: processes entity metadata
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'processes')),
    'processes entity metadata should exist'
);

-- Test 6: processes physical table
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'processes'
    )),
    'processes physical table should exist'
);

-- Test 8: raci_assignments entity metadata
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'raci_assignments')),
    'raci_assignments entity metadata should exist'
);

-- Test 9: raci_assignments physical table
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'raci_assignments'
    )),
    'raci_assignments physical table should exist'
);

-- Test 10: process_gates entity metadata
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'process_gates')),
    'process_gates entity metadata should exist'
);

-- Test 11: process_gates physical table
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'process_gates'
    )),
    'process_gates physical table should exist'
);

-- Test 12: raci_events entity metadata
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'raci_events')),
    'raci_events entity metadata should exist'
);

-- Test 13: raci_events physical table
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'raci_events'
    )),
    'raci_events physical table should exist'
);

-- Test 14: processes RLS enabled
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'processes'),
    'processes should have RLS enabled'
);

-- Test 15: raci_events RLS enabled
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'raci_events'),
    'raci_events should have RLS enabled'
);

-- =====================================================
-- GROUP 3: processes constraints and fields
-- =====================================================

-- Test 16: id_column and label_column
SELECT is(
    (SELECT id_column FROM entities WHERE table_name = 'processes'),
    'id',
    'processes id_column should be id'
);

-- Test 17
SELECT is(
    (SELECT label_column FROM entities WHERE table_name = 'processes'),
    'name',
    'processes label_column should be name'
);

-- Test 18: field count
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'processes'),
    8,
    'processes should have 8 registered fields'
);

-- Test 19: Insert a process (admin can)
INSERT INTO processes (module_id, process_key, name, description, ordering)
VALUES (1, 'make_offer', 'Make Offer', 'Job offer approval process', 10);

SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM processes WHERE process_key = 'make_offer')),
    'Admin can insert a process'
);

-- Test 20: Duplicate process_key within same module rejected
SELECT throws_ok(
    $$INSERT INTO processes (module_id, process_key, name) VALUES (1, 'make_offer', 'Dup')$$,
    '23505',
    NULL,
    'Duplicate process_key within the same module should be rejected'
);

-- Test 21: invalid process_key (not snake_case) rejected
SELECT throws_ok(
    $$INSERT INTO processes (module_id, process_key, name) VALUES (1, 'Bad Key!', 'Bad')$$,
    '23514',
    NULL,
    'process_key must match snake_case pattern'
);

-- =====================================================
-- GROUP 4: raci_assignments constraints
-- =====================================================

-- Test 22: raci enum validated
SELECT throws_ok(
    $$INSERT INTO raci_assignments (process_id, raci, role_id)
      SELECT id, 'bad_letter', (SELECT id FROM roles WHERE role_name = 'Administrator')
      FROM processes WHERE process_key = 'make_offer'$$,
    '23514',
    NULL,
    'raci must be a valid RACI letter'
);

-- Test 23: field count
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'raci_assignments'),
    9,
    'raci_assignments should have 9 registered fields'
);

-- Insert the RACI matrix for make_offer
INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'responsible', r.id, 'read'
FROM   processes p, roles r
WHERE  p.process_key = 'make_offer' AND r.role_name = 'Northwind Sales';

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'accountable', r.id, 'read'
FROM   processes p, roles r
WHERE  p.process_key = 'make_offer' AND r.role_name = 'Administrator';

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'consulted', r.id, 'block'
FROM   processes p, roles r
WHERE  p.process_key = 'make_offer' AND r.role_name = 'Northwind Sales';

-- Informed is held by `User` (role id 1) — deliberately a DIFFERENT role from
-- Consulted (`Northwind Sales`) and Accountable (`Administrator`) so the emit
-- tests below can assert C and I in isolation (a bug emitting two consulted /
-- zero informed would otherwise pass when C and I share a role).
INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'informed', r.id, 'read'
FROM   processes p, roles r
WHERE  p.process_key = 'make_offer' AND r.role_name = 'User';

-- Test 24: Assignments were inserted
SELECT is(
    (SELECT COUNT(*)::integer FROM raci_assignments ra
     JOIN processes p ON p.id = ra.process_id
     WHERE p.process_key = 'make_offer'),
    4,
    'Four RACI assignments (R/A/C/I) should be inserted'
);

-- Test 24b: computed `name` label mirrors the raci enum value
SELECT is(
    (SELECT ra.name FROM raci_assignments ra
     JOIN processes p ON p.id = ra.process_id
     WHERE p.process_key = 'make_offer' AND ra.raci = 'accountable'),
    'accountable',
    'raci_assignments.name (computed) should mirror the raci letter'
);

-- Test 25: Accountable uniqueness invariant
SELECT throws_ok(
    $$INSERT INTO raci_assignments (process_id, raci, role_id)
      SELECT p.id, 'accountable', r.id
      FROM   processes p, roles r
      WHERE  p.process_key = 'make_offer' AND r.role_name = 'Northwind Sales'$$,
    '23505',
    NULL,
    'At most one accountable per process should be enforced'
);

-- Test 26: consult_mode validation
SELECT throws_ok(
    $$UPDATE raci_assignments SET consult_mode = 'bad_mode'
      WHERE raci = 'consulted'
        AND process_id = (SELECT id FROM processes WHERE process_key = 'make_offer')$$,
    '23514',
    NULL,
    'consult_mode must be read, notify, or block'
);

-- Test 27: idx_raci_one_accountable partial index exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'raci_assignments'
          AND indexname = 'idx_raci_one_accountable'
    )),
    'idx_raci_one_accountable partial unique index should exist'
);

-- =====================================================
-- GROUP 5: process_gates
-- =====================================================

-- Test 28: gate_kind validation
SELECT throws_ok(
    $$INSERT INTO process_gates (process_id, entity, gate_kind, to_state)
      SELECT id, 'raci_probe', 'bad_kind', 'approved'
      FROM processes WHERE process_key = 'make_offer'$$,
    '23514',
    NULL,
    'gate_kind must be a valid enum value'
);

-- Test 29: Insert a valid process_gate
INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'raci_probe', 'approval', 'approved', 'status', FALSE
FROM   processes WHERE process_key = 'make_offer';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM process_gates
        WHERE entity = 'raci_probe' AND to_state = 'approved' AND emits_events = FALSE
    )),
    'process_gate should be insertable for admin'
);

-- Test 29b: computed `name` label mirrors the gate_kind enum value
SELECT is(
    (SELECT name FROM process_gates
     WHERE entity = 'raci_probe' AND to_state = 'approved'),
    'approval',
    'process_gates.name (computed) should mirror gate_kind'
);

-- Test 30: emits_events defaults FALSE
SELECT is(
    (SELECT emits_events FROM process_gates
     WHERE entity = 'raci_probe' AND to_state = 'approved'),
    FALSE,
    'emits_events should default to FALSE'
);

-- Test 31: state_column defaults to status
SELECT is(
    (SELECT state_column FROM process_gates
     WHERE entity = 'raci_probe' AND to_state = 'approved'),
    'status',
    'state_column should default to status'
);

-- Test 32: field count
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'process_gates'),
    10,
    'process_gates should have 10 registered fields'
);

-- =====================================================
-- GROUP 6: raci_events
-- =====================================================

-- Test 33: raci field restricted to consulted/informed
SELECT throws_ok(
    $$INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
      SELECT p.id, 'raci_probe', (SELECT a_id::text FROM _rp), 'accountable', r.id, 'pending'
      FROM processes p, roles r
      WHERE p.process_key = 'make_offer' AND r.role_name = 'Administrator'$$,
    '23514',
    NULL,
    'raci_events.raci must be consulted or informed'
);

-- Test 34: status validation
SELECT throws_ok(
    $$INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
      SELECT p.id, 'raci_probe', (SELECT a_id::text FROM _rp), 'consulted', r.id, 'bad_status'
      FROM processes p, roles r
      WHERE p.process_key = 'make_offer' AND r.role_name = 'Administrator'$$,
    '23514',
    NULL,
    'raci_events.status must be pending, sent, or acted'
);

-- Test 35: Insert a valid raci_event manually (for probe_a)
INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
SELECT p.id, 'raci_probe', (SELECT a_id::text FROM _rp), 'consulted', r.id, 'pending'
FROM   processes p, roles r
WHERE  p.process_key = 'make_offer' AND r.role_name = 'Administrator';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM raci_events
        WHERE entity = 'raci_probe' AND record_id = (SELECT a_id::text FROM _rp) AND raci = 'consulted'
    )),
    'Valid raci_event should be insertable'
);

-- Test 36: acted_at is nullable by default
SELECT ok(
    (SELECT acted_at IS NULL FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT a_id::text FROM _rp)),
    'raci_events.acted_at should be NULL by default'
);

-- Test 37: field count
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'raci_events'),
    10,
    'raci_events should have 10 registered fields'
);

-- =====================================================
-- GROUP 7: is_raci_actor SQL function
-- =====================================================

-- Test 38: Function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'is_raci_actor' AND n.nspname = 'public'
    )),
    'is_raci_actor function should exist in public schema'
);

-- Test 39: Returns TRUE for user3 (Administrator = accountable for make_offer/approved)
SELECT is(
    is_raci_actor('raci_probe', 'approved', 'accountable'),
    TRUE,
    'is_raci_actor should return TRUE for user3 as accountable'
);

-- Test 40: Returns FALSE for wrong letter
SELECT is(
    is_raci_actor('raci_probe', 'approved', 'responsible'),
    FALSE,
    'is_raci_actor should return FALSE when user does not hold that letter'
);

-- Test 41: Returns FALSE for unknown entity/state
SELECT is(
    is_raci_actor('nonexistent_table', 'nonexistent_state', 'accountable'),
    FALSE,
    'is_raci_actor should return FALSE for unknown entity/state'
);

-- =====================================================
-- GROUP 8: has_consultation SQL function
-- =====================================================

-- Test 42: Function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'has_consultation' AND n.nspname = 'public'
    )),
    'has_consultation function should exist in public schema'
);

-- Test 43: Returns FALSE when event is still pending
SELECT is(
    has_consultation('raci_probe', 'approved', (SELECT a_id::text FROM _rp)),
    FALSE,
    'has_consultation should return FALSE when consulted event is pending'
);

-- Test 44: Returns TRUE after event is acted
UPDATE raci_events
SET    status = 'acted', acted_at = CURRENT_TIMESTAMP
WHERE  entity = 'raci_probe' AND record_id = (SELECT a_id::text FROM _rp) AND raci = 'consulted';

SELECT is(
    has_consultation('raci_probe', 'approved', (SELECT a_id::text FROM _rp)),
    TRUE,
    'has_consultation should return TRUE after consulted event is acted'
);

-- =====================================================
-- GROUP 9: user_process_raci view
-- =====================================================

-- Test 45: View exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.views
        WHERE table_schema = 'public' AND table_name = 'user_process_raci'
    )),
    'user_process_raci view should exist'
);

-- Test 46: View returns rows for user3 as accountable for make_offer
SELECT ok(
    (SELECT COUNT(*) > 0
     FROM user_process_raci upr
     JOIN users u ON u.id = upr.user_id
     WHERE u.external_id = 'user3'
       AND upr.process_key = 'make_offer'
       AND upr.raci = 'accountable'),
    'user_process_raci should show user3 as accountable for make_offer'
);

-- =====================================================
-- GROUP 10: JsonLogic operators
-- =====================================================

-- Test 47: is_raci_actor operator returns true
SELECT is(
    evaluate_json_logic(
        '{"is_raci_actor": ["raci_probe", "approved", "accountable"]}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'is_raci_actor JsonLogic operator should return true for accountable user'
);

-- Test 48: is_raci_actor operator returns false
SELECT is(
    evaluate_json_logic(
        '{"is_raci_actor": ["raci_probe", "approved", "responsible"]}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'is_raci_actor JsonLogic operator should return false when not responsible'
);

-- Test 49: has_consultation operator returns true (event acted above)
SELECT is(
    evaluate_json_logic(
        jsonb_build_object('has_consultation',
            jsonb_build_array('raci_probe', 'approved', (SELECT a_id::text FROM _rp))),
        '{}'::jsonb
    ),
    'true'::jsonb,
    'has_consultation JsonLogic operator should return true after consultation acted'
);

-- Test 50: has_consultation operator returns false for unknown record
SELECT is(
    evaluate_json_logic(
        '{"has_consultation": ["raci_probe", "approved", "999"]}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'has_consultation JsonLogic operator should return false for record with no acted event'
);

-- Test 51: is_raci_actor composable inside if expression
SELECT is(
    evaluate_json_logic(
        '{"if": [
            {"is_raci_actor": ["raci_probe", "approved", "accountable"]},
            "yes",
            "no"
         ]}'::jsonb,
        '{}'::jsonb
    ),
    '"yes"'::jsonb,
    'is_raci_actor should be composable inside JsonLogic if'
);

-- =====================================================
-- GROUP 11: Emit trigger (runtime behavior)
-- =====================================================
-- raci_probe already has the declared `status` column (enum, default 'draft').
-- Enable emit for the gate; the installer puts raci_emit_on_raci_probe on the
-- table (install/drop on the toggle is asserted in 0400, not here).
UPDATE process_gates
SET    emits_events = TRUE
WHERE  entity = 'raci_probe' AND to_state = 'approved';

-- Test 53: raci_emit_trigger_fn function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'raci_emit_trigger_fn' AND n.nspname = 'public'
    )),
    'raci_emit_trigger_fn trigger function should exist'
);

-- Clean any existing events for probe_b before transition tests
DELETE FROM raci_events WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp);

-- Transition probe_b → 'approved': emit trigger should fire
UPDATE raci_probe SET status = 'approved' WHERE id = (SELECT b_id FROM _rp);

-- Test 54: Events created for C/I actors
SELECT ok(
    (SELECT COUNT(*) >= 1
     FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'),
    'Emit trigger should insert raci_events on status transition to approved'
);

-- Test 55: Only C/I events created (no R or A)
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM raci_events
        WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp)
          AND raci NOT IN ('consulted', 'informed')
    )),
    'Emit trigger should only insert events for consulted/informed actors'
);

-- Test 56: Exact count matches C/I assignment count for this process
SELECT is(
    (SELECT COUNT(*)::integer FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'),
    (SELECT COUNT(*)::integer FROM raci_assignments ra
     JOIN processes p ON p.id = ra.process_id
     WHERE p.process_key = 'make_offer' AND ra.raci IN ('consulted', 'informed')),
    'Number of raci_events should match C/I assignment count'
);

-- Test 56b: exactly ONE consulted event, targeting the Consulted role (Northwind Sales).
-- With C and I on distinct roles this isolates the consulted letter — a bug that
-- emitted two consulted events (or mislabelled informed as consulted) fails here.
SELECT is(
    (SELECT COUNT(*)::integer FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'
       AND raci = 'consulted'
       AND target_role_id = (SELECT id FROM roles WHERE role_name = 'Northwind Sales')),
    1,
    'Emit should create exactly one consulted event targeting the Northwind Sales role'
);

-- Test 56c: exactly ONE informed event, targeting the Informed role (User).
-- Proves informed is emitted on its own letter to its own role, not collapsed
-- into the consulted count.
SELECT is(
    (SELECT COUNT(*)::integer FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'
       AND raci = 'informed'
       AND target_role_id = (SELECT id FROM roles WHERE role_name = 'User')),
    1,
    'Emit should create exactly one informed event targeting the User role'
);

-- Test 57: Re-entering the same state does NOT create duplicate events
UPDATE raci_probe SET status = 'approved' WHERE id = (SELECT b_id FROM _rp);   -- already approved → no re-emit

SELECT is(
    (SELECT COUNT(*)::integer FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'),
    (SELECT COUNT(*)::integer FROM raci_assignments ra
     JOIN processes p ON p.id = ra.process_id
     WHERE p.process_key = 'make_offer' AND ra.raci IN ('consulted', 'informed')),
    'Re-entering same state should not create duplicate raci_events'
);

-- Test 58: Transitioning away then back DOES emit again
DELETE FROM raci_events WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp);
UPDATE raci_probe SET status = 'draft'    WHERE id = (SELECT b_id FROM _rp);
UPDATE raci_probe SET status = 'approved' WHERE id = (SELECT b_id FROM _rp);

SELECT ok(
    (SELECT COUNT(*) >= 1
     FROM raci_events
     WHERE entity = 'raci_probe' AND record_id = (SELECT b_id::text FROM _rp) AND status = 'pending'),
    'Transitioning back to approved should create new raci_events'
);

-- =====================================================
-- GROUP 12: Queue wiring
-- =====================================================

-- Test 60: raci_notify queue exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM queues WHERE queue_name = 'raci_notify')),
    'raci_notify queue should exist'
);

-- Test 61: queue_table_events entry for raci_events → raci_notify
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM queue_table_events qte
        JOIN queues q ON q.id = qte.queue_id
        WHERE q.queue_name = 'raci_notify'
          AND qte.table_name = 'raci_events'
          AND qte.event_handler = 'insert'
    )),
    'raci_events should be wired to raci_notify queue via queue_table_events'
);

-- Test 62: Inserting a raci_event triggers a queue message
-- (the gate is still emits_events = TRUE from group 11)

-- Purge any existing messages from earlier steps
RESET ROLE;
SELECT pgmq.delete('raci_notify', msg_id)
FROM   pgmq.read('raci_notify', 0, 100);

-- Re-authenticate as admin
SET ROLE semantius_user;
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'user3', true);

-- Clear old events and trigger a fresh transition on probe_c
DELETE FROM raci_events WHERE entity = 'raci_probe' AND record_id = (SELECT c_id::text FROM _rp);
UPDATE raci_probe SET status = 'draft'    WHERE id = (SELECT c_id FROM _rp);
UPDATE raci_probe SET status = 'approved' WHERE id = (SELECT c_id FROM _rp);

-- Read the queue ONCE as owner (pgmq requires elevated access; a second read in
-- this txn would hit the visibility timeout) and capture the messages so several
-- properties can be asserted against the same enqueued payloads.
RESET ROLE;
CREATE TEMP TABLE _raci_notify_msgs ON COMMIT DROP AS
SELECT message FROM pgmq.read('raci_notify', 0, 20);

-- Test 62: a raci_events INSERT enqueues a raci_notify message
SELECT ok(
    (SELECT COUNT(*) > 0
     FROM _raci_notify_msgs
     WHERE message->>'table' = 'raci_events'
       AND message->>'op'    = 'INSERT'),
    'Inserting raci_events should enqueue a message in raci_notify'
);

-- Test 62b: the enqueued messages carry message_type = 'entity_event'
SELECT ok(
    (SELECT bool_and(message->>'message_type' = 'entity_event')
     FROM _raci_notify_msgs
     WHERE message->>'table' = 'raci_events'),
    'raci_notify messages for raci_events should have message_type=entity_event'
);

-- Test 62c: each message's id_value matches an actually-inserted raci_events row
-- (the C/I events emitted for the probe_c transition), proving the payload
-- identifies the real row, not a placeholder.
SELECT ok(
    (SELECT bool_and(
                (message->>'id_value')::integer IN (
                    SELECT id FROM raci_events
                    WHERE entity = 'raci_probe' AND record_id = (SELECT c_id::text FROM _rp)
                ))
     FROM _raci_notify_msgs
     WHERE message->>'table' = 'raci_events'),
    'each raci_notify message id_value should match an inserted raci_events row id'
);

-- =====================================================
-- GROUP 13: Catalog is admin-write-gated (negative RLS)
-- =====================================================
-- Every write above ran as admin (user3). Prove the RACI catalog rejects a
-- write from a non-privileged user behaviorally, not just by policy shape.
-- Stash valid ids as admin so the attempt fails ONLY on RLS (42501), not a bad FK.
SELECT authenticate_as('user3');
CREATE TEMP TABLE _raci_rls_ids ON COMMIT DROP AS
SELECT (SELECT id FROM processes WHERE process_key = 'make_offer') AS process_id,
       (SELECT id FROM roles     WHERE role_name   = 'User')        AS role_id;

-- Test 63: user1 (non-admin) cannot INSERT into raci_assignments
SELECT authenticate_as('user1');
SELECT throws_ok(
    $$ INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
       SELECT process_id, 'informed', role_id, 'read' FROM _raci_rls_ids $$,
    '42501', NULL,
    'Non-admin user1 must not be able to INSERT into raci_assignments (RLS 42501)'
);

-- Restore the admin role for any subsequent steps.
SELECT authenticate_as('user3');

-- =====================================================
-- Finish
-- =====================================================
SELECT * FROM finish();
ROLLBACK;
