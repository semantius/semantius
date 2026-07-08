-- Test raci_gates_manage_emit_trigger / raci_install_or_drop_emit_trigger
-- (0210_raci.sql): the AFTER trigger on process_gates that installs the
-- raci_emit_on_<entity> trigger on the governed table while any gate for that
-- entity has emits_events = TRUE, and drops it when none do.
--
-- 0350 covers the emit trigger's runtime behavior; this file covers the
-- INSTALLER: install, idempotent reinstall, keep-while-another-gate-needs-it,
-- entity-move rerouting, drop-on-delete, and the missing-table branch.
--
-- Fixtures (0030_seed.sql): user3=admin.
BEGIN;

SELECT plan(11);

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

INSERT INTO processes (name, module_id) VALUES ('rgt_process', 1);

CREATE TEMP TABLE _rgt AS
SELECT id AS pid FROM processes WHERE name = 'rgt_process';

-- Test 1: baseline
SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'baseline: no emit trigger on a fresh governed table');

-- Test 2: a FALSE gate does not install
INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT pid, 'rgt_alpha', 'transition', 'approved', 'status', FALSE FROM _rgt;

SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'a gate with emits_events = FALSE does not install the emit trigger');

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

-- Test 8: deleting the last TRUE gate drops the trigger
DELETE FROM process_gates WHERE entity = 'rgt_beta' AND to_state = 'rejected';

SELECT hasnt_trigger('public', 'rgt_beta', 'raci_emit_on_rgt_beta',
    'trigger is dropped when the last TRUE gate is deleted');

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

SELECT hasnt_trigger('public', 'rgt_alpha', 'raci_emit_on_rgt_alpha',
    'deleting a FALSE gate keeps the entity trigger-free');

SELECT * FROM finish();
ROLLBACK;
