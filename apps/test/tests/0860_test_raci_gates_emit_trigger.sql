-- Test raci_gates_manage_emit_trigger and the installers it runs
-- (0370_raci.sql): the AFTER trigger on process_gates that keeps the RACI
-- triggers of the governed table in step with its gates. raci_emit_on_<entity>
-- is there while any gate for the entity has emits_events = TRUE; the gate
-- pair a_raci_gate_on_<entity> and raci_gate_on_<entity>, which runs before
-- and after the entity's rules, while any gate names a to_state and a state
-- column.
--
-- 0850 covers the emit trigger's runtime behavior and 0657 the gate's place
-- around the rules; this file covers the INSTALLER: install, idempotent
-- reinstall, keep-while-another-gate-needs-it, entity-move rerouting,
-- drop-on-delete, an entity rename, and the missing-table branch.
--
-- Fixtures (apps/test/migrations/0030_seed.once.sql): user3=admin.
BEGIN;

SELECT plan(14);

SELECT authenticate_as('user3');

-- Two governed DD entities (physical tables auto-created) + one process
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label,
                      description, module_id, view_permission, edit_permission,
                      id_column, label_column)
VALUES
    ('rgt_alpha', 'rgt_alpha', 'rgt_alphas', 'RGT Alpha', 'RGT Alphas',
     'raci gate installer test', 1, 'public:read', 'admin', 'id', 'label'),
    ('rgt_beta', 'rgt_beta', 'rgt_betas', 'RGT Beta', 'RGT Betas',
     'raci gate installer test', 1, 'public:read', 'admin', 'id', 'label');

INSERT INTO processes (name, process_key, module_id) VALUES ('rgt_process', 'rgt_process', 1);

CREATE TEMP TABLE _rgt AS
SELECT id AS pid FROM processes WHERE name = 'rgt_process';

-- The RACI triggers on a table, by name.
CREATE FUNCTION pg_temp.raci_triggers(p_table text) RETURNS text
LANGUAGE sql AS $$
    SELECT string_agg(t.tgname::text, ', ' ORDER BY t.tgname::text)
      FROM pg_trigger t
     WHERE t.tgrelid = to_regclass('public.' || p_table) AND t.tgname LIKE '%raci\_%'
$$;

-- Test 1: baseline
SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'baseline: no emit trigger on a fresh governed table');

-- Test 2: a FALSE gate does not install
INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT pid, 'rgt_alpha', 'transition', 'approved', 'status', FALSE FROM _rgt;

SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'a gate with emits_events = FALSE does not install the emit trigger');

-- Test 2b: but a gate with a to_state and a state column installs the gate pair
SELECT is(pg_temp.raci_triggers('rgt_alpha'), 'a_raci_gate_on_rgt_alpha, raci_gate_on_rgt_alpha',
    'a gate naming a to_state and a state column installs the gate before and after the rules, emitting or not');

-- Test 3: flipping the gate to TRUE installs
UPDATE process_gates SET emits_events = TRUE
 WHERE entity = 'rgt_alpha' AND to_state = 'approved';

SELECT has_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'emit trigger is installed when a gate turns emits_events = TRUE');

-- Test 4: a second TRUE gate reinstalls idempotently — still exactly one trigger
INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT pid, 'rgt_alpha', 'transition', 'rejected', 'status', TRUE FROM _rgt;

SELECT is(
    (SELECT count(*)::int FROM pg_trigger t
       JOIN pg_class c ON c.oid = t.tgrelid
      WHERE c.relname = 'rgt_alpha'
        AND t.tgname  = 'raci_emit_on_rgt_alpha'
        AND NOT t.tgisinternal),
    1,
    'a second TRUE gate reinstalls idempotently — exactly one trigger'
);

-- Test 5: turning one gate off keeps the trigger while the other still needs it
UPDATE process_gates SET emits_events = FALSE
 WHERE entity = 'rgt_alpha' AND to_state = 'approved';

SELECT has_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'trigger is kept while another TRUE gate remains for the entity');

-- Tests 6 + 7: moving the remaining TRUE gate to another entity reroutes the trigger
-- (exercises the OLD.entity IS DISTINCT FROM NEW.entity branch)
UPDATE process_gates SET entity = 'rgt_beta'
 WHERE entity = 'rgt_alpha' AND to_state = 'rejected';

SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'entity move: trigger is dropped from the old entity');

SELECT has_trigger('public', 'rgt_beta', 'raci_emit_on_rgt_beta',
    'entity move: trigger is installed on the new entity');

-- Test 7b: the gate pair follows the moved gate, and stays for the one left
SELECT is(pg_temp.raci_triggers('rgt_alpha') || ' | ' || pg_temp.raci_triggers('rgt_beta'),
    'a_raci_gate_on_rgt_alpha, raci_gate_on_rgt_alpha | a_raci_gate_on_rgt_beta, raci_emit_on_rgt_beta, raci_gate_on_rgt_beta',
    'entity move: the gate pair is installed on the new entity and kept for the gate left behind');

-- Test 8: deleting the last TRUE gate drops the trigger
DELETE FROM process_gates WHERE entity = 'rgt_beta' AND to_state = 'rejected';

SELECT is(pg_temp.raci_triggers('rgt_beta'), NULL,
    'every RACI trigger is dropped when the last gate is deleted');

-- Tests 9 + 10: a gate for a table that does not exist is accepted but installs nothing
-- (entity is a plain TEXT natural key, no FK — the installer must skip missing tables)
SELECT lives_ok(
    $$ INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
       SELECT pid, 'rgt_ghost', 'transition', 'approved', 'status', TRUE FROM _rgt $$,
    'a gate for a nonexistent table is accepted (installer skips missing tables)'
);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'raci_emit_on_rgt_ghost'),
    'no trigger is created for a nonexistent table'
);

-- Test 11: deleting a FALSE gate leaves the entity trigger-free
DELETE FROM process_gates WHERE entity = 'rgt_alpha' AND to_state = 'approved';

SELECT is(pg_temp.raci_triggers('rgt_alpha'), NULL,
    'deleting the last gate, emitting or not, leaves the entity without RACI triggers');

-- Test 12: a rename carries the gates and the triggers to the new name
INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT pid, 'rgt_beta', 'transition', 'approved', 'status', TRUE FROM _rgt;
UPDATE entities SET table_name = 'rgt_gamma' WHERE table_name = 'rgt_beta';

SELECT is(pg_temp.raci_triggers('rgt_gamma') || ' | '
          || (SELECT string_agg(DISTINCT entity, ', ') FROM process_gates WHERE process_id = (SELECT pid FROM _rgt)),
    'a_raci_gate_on_rgt_gamma, raci_emit_on_rgt_gamma, raci_gate_on_rgt_gamma | rgt_gamma, rgt_ghost',
    'entity rename: the gates and every RACI trigger move to the new name');

SELECT * FROM finish();
ROLLBACK;
