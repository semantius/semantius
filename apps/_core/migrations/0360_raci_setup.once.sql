-- =====================================================
-- RACI SYSTEM - constraints, indexes, notification queue
-- =====================================================
-- Runs once. The entities are defined in 0350_raci.jsonc, the functions,
-- view and triggers in 0370_raci.sql.

ALTER TABLE processes ADD CONSTRAINT valid_process_key
    CHECK (process_key = '' OR process_key ~ '^[a-z_][a-z0-9_]*$');

-- process_key is unique within a module; the NULL-module case needs its own
-- partial index since NULLs don't collide in a composite unique.
CREATE UNIQUE INDEX idx_processes_module_key
    ON processes(module_id, process_key)
    WHERE module_id IS NOT NULL AND process_key != '';
CREATE UNIQUE INDEX idx_processes_global_key
    ON processes(process_key)
    WHERE module_id IS NULL AND process_key != '';

-- reference columns default to nullable in the DD model; role_id is mandatory
ALTER TABLE raci_assignments ALTER COLUMN role_id SET NOT NULL;

-- Invariant: at most one accountable per process (enforced on every write)
CREATE UNIQUE INDEX idx_raci_one_accountable
    ON raci_assignments(process_id)
    WHERE raci = 'accountable';

-- One assignment per (process, role, letter)
ALTER TABLE raci_assignments
    ADD CONSTRAINT raci_assignments_process_role_raci_key UNIQUE (process_id, role_id, raci);

ALTER TABLE process_gates
    ADD CONSTRAINT process_gates_process_entity_gate_state_key
    UNIQUE (process_id, entity, gate_kind, to_state);

CREATE INDEX idx_process_gates_entity ON process_gates(entity);
CREATE INDEX idx_process_gates_emit   ON process_gates(entity) WHERE emits_events = TRUE;

-- reference columns default to nullable in the DD model; target_role_id is mandatory
ALTER TABLE raci_events ALTER COLUMN target_role_id SET NOT NULL;

CREATE INDEX idx_raci_events_entity ON raci_events(entity, record_id);
CREATE INDEX idx_raci_events_status ON raci_events(status) WHERE status != 'acted';

-- =====================================================
-- STEP 9: Queue wiring — raci_notify
-- =====================================================
-- Table → queue is pure configuration: insert a queue and a
-- queue_table_events row. No new trigger code is required.
-- Runs as the database owner (BYPASSRLS) — no role switching needed.

INSERT INTO queues (queue_name) VALUES ('raci_notify');

-- Wire new raci_events rows to the raci_notify queue so the
-- consumer (email/webhook dispatcher) can read and process them.
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'raci event insert', 'raci_events', 'insert'
FROM   queues WHERE queue_name = 'raci_notify';
