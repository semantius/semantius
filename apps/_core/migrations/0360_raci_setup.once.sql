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

-- One assignment per (process, role, letter), and one gate per (process,
-- entity, kind, state). Neither key starts with a reference column (raci and
-- to_state are a plain enum and text, and must stay so for this to hold): the
-- dictionary gives every reference its own index idx_<table>_<field>, and
-- builds it again whenever a fields edit rebuilds that reference's foreign
-- key, so a unique index that started with process_id would repeat
-- idx_raci_assignments_process_id or idx_process_gates_process_id. The gate
-- key starts with to_state and entity because the gate lookups in
-- 0370_raci.sql name both.
ALTER TABLE raci_assignments
    ADD CONSTRAINT raci_assignments_process_role_raci_key UNIQUE (raci, process_id, role_id);

ALTER TABLE process_gates
    ADD CONSTRAINT process_gates_process_entity_gate_state_key
    UNIQUE (to_state, entity, gate_kind, process_id);

-- process_gates.entity is a reference to entities, which the dictionary
-- creates as a nullable TEXT column with its index idx_process_gates_entity.
-- A gate without an entity means nothing, so the column is NOT NULL. Like
-- raci_events.entity it has no default: an insert that leaves it out is
-- refused as a missing value (23502), where a default would turn that into a
-- foreign key violation for a value nobody wrote.
ALTER TABLE process_gates ALTER COLUMN entity SET NOT NULL;

CREATE INDEX idx_process_gates_emit   ON process_gates(entity) WHERE emits_events = TRUE;

-- reference columns default to nullable in the DD model; target_role_id is mandatory
ALTER TABLE raci_events ALTER COLUMN target_role_id SET NOT NULL;

-- raci_events.entity is a reference to entities, which the dictionary creates
-- as a nullable TEXT column with its index idx_raci_events_entity. An event
-- without an entity means nothing, so the column is NOT NULL. Like
-- target_role_id it has no default: an insert that leaves it out is refused
-- as a missing value (23502), where a default would turn that into a foreign
-- key violation for a value nobody wrote. The lookups of a record's events
-- name the record, most of them with its entity, so they have an index of
-- their own on both. record_id comes first: entity is a reference and has the
-- dictionary's idx_raci_events_entity, which an index starting with entity
-- would repeat.
ALTER TABLE raci_events ALTER COLUMN entity SET NOT NULL;

CREATE INDEX idx_raci_events_entity_record ON raci_events(record_id, entity);
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
