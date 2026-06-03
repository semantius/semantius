-- =====================================================
-- RACI SYSTEM
-- =====================================================
-- Responsible, Accountable, Consulted, Informed (RACI)
-- as first-class, live-enforced concept in the platform.
--
-- Design:
--   • Storage: processes, raci_assignments, process_gates, raci_events
--   • Enforcement: two SQL functions (is_raci_actor, has_consultation)
--                  surfaced as JsonLogic operators
--   • Emit:    generic trigger on governed entities fires when a row
--              transitions to a state listed in process_gates with
--              emits_events = true; inserts raci_events rows for
--              Consulted / Informed actors
--   • Queue:   raci_notify queue wired to raci_events via the
--              existing queue_table_events mechanism (no new code)
--
-- All RACI tables are created with full DDL here; entities are
-- registered with managed=FALSE so the DD system does not try to
-- re-create or alter them. Field metadata is inserted so the UI and
-- schema tooling can reflect the RACI schema correctly.

-- =====================================================
-- STEP 1: users.is_agent — additive agent-identity flag
-- =====================================================
-- An agent is a service principal: a user that authenticates, holds
-- roles, and is audited. Flagging via is_agent (default FALSE) means
-- no behaviour change for existing rows.

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_agent BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN users.is_agent IS
'When TRUE, this user is a service principal (agent) rather than a human. Default FALSE — zero behaviour change for existing rows.';

-- Register is_agent in the data-dictionary so UI and schema tooling
-- see it. The users entity is managed=FALSE (pre-existing table), so
-- inserting into fields only adds metadata; no DDL is executed.
INSERT INTO fields (
    table_name, field_name, title, format,
    field_order, input_type, description, default_value,
    reference_table, reference_delete_mode
) VALUES (
    'users', 'is_agent', 'Is Agent', 'boolean',
    100, 'default', 'When TRUE this user is a service principal (agent)', 'false',
    '', ''
) ON CONFLICT (table_name, field_name) DO NOTHING;

-- =====================================================
-- STEP 2: processes — the RACI process catalog
-- =====================================================

CREATE TABLE processes (
    id          SERIAL PRIMARY KEY,
    module_id   INTEGER REFERENCES modules(id) ON DELETE SET NULL,
    process_key TEXT NOT NULL DEFAULT '',
    name        TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    ordering    INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_process_key CHECK (
        process_key = '' OR process_key ~ '^[a-z_][a-z0-9_]*$'
    )
);

COMMENT ON TABLE processes IS 'RACI process catalog. Each row represents a governed process with a stable process_key.';
COMMENT ON COLUMN processes.module_id IS 'Owning module. NULL = cross-module or unowned process.';
COMMENT ON COLUMN processes.process_key IS 'Stable snake_case identifier, unique within module.';
COMMENT ON COLUMN processes.ordering IS 'Optional display ordering.';

-- Unique process_key within module (NULL module_id handled via partial indexes)
CREATE UNIQUE INDEX idx_processes_module_key
    ON processes(module_id, process_key)
    WHERE module_id IS NOT NULL AND process_key != '';

CREATE UNIQUE INDEX idx_processes_global_key
    ON processes(process_key)
    WHERE module_id IS NULL AND process_key != '';

CREATE INDEX idx_processes_module ON processes(module_id);

CREATE TRIGGER update_processes_updated_at
    BEFORE UPDATE ON processes
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

ALTER TABLE processes ENABLE ROW LEVEL SECURITY;

CREATE POLICY processes_select_policy ON processes
    FOR SELECT TO semantius_user USING (rbac.has_permission('admin'));
CREATE POLICY processes_insert_policy ON processes
    FOR INSERT TO semantius_user WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY processes_update_policy ON processes
    FOR UPDATE TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY processes_delete_policy ON processes
    FOR DELETE TO semantius_user USING (rbac.has_permission('admin'));

-- Entity metadata (managed=FALSE — physical table was created above)
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, managed
) VALUES (
    'processes', 'process', 'processes', 'Process', 'Processes',
    'RACI process catalog',
    (SELECT id FROM modules WHERE module_name = '_core'),
    'admin', 'admin', 'id', 'name', FALSE
);

-- Field metadata for processes (managed=FALSE → no DDL executed on insert)
INSERT INTO fields (
    table_name, field_name, title, format, is_pk,
    field_order, input_type, description,
    ctype, is_core,
    reference_table, reference_delete_mode
) VALUES
    ('processes', 'id',          'Id',          'int32',     TRUE,   1,      'readonly', 'Primary key',                                              'id',    TRUE,  '', ''),
    ('processes', 'name',        'Name',        'text',      FALSE,  10,     'required', 'Display name of the process',                              'label', TRUE,  '', ''),
    ('processes', 'module_id',   'Module',      'reference', FALSE,  20,     'default',  'Owning module',                                            '',      FALSE, 'modules',  'clear'),
    ('processes', 'process_key', 'Process Key', 'text',      FALSE,  30,     'required', 'Stable snake_case identifier, unique within module',       '',      FALSE, '', ''),
    ('processes', 'description', 'Description', 'multiline', FALSE,  40,     'default',  'Detailed description of the process',                      '',      FALSE, '', ''),
    ('processes', 'ordering',    'Ordering',    'integer',   FALSE,  50,     'default',  'Optional display ordering',                                '',      FALSE, '', ''),
    ('processes', 'created_at',  'Created At',  'date-time', FALSE,  999998, 'disabled', 'Creation timestamp',                                       '',      TRUE,  '', ''),
    ('processes', 'updated_at',  'Updated At',  'date-time', FALSE,  999999, 'disabled', 'Last update timestamp',                                    '',      TRUE,  '', '');

-- =====================================================
-- STEP 3: raci_assignments — the RACI matrix
-- =====================================================
-- Invariant: at most one accountable per process.
-- Enforced via a partial unique index so it holds on every write.

CREATE TABLE raci_assignments (
    id          SERIAL PRIMARY KEY,
    process_id  INTEGER NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    raci        TEXT    NOT NULL DEFAULT '',
    role_id     INTEGER NOT NULL REFERENCES roles(id)     ON DELETE CASCADE,
    consult_mode TEXT   NOT NULL DEFAULT 'read',
    origin      TEXT    NOT NULL DEFAULT 'user',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_raci CHECK (raci IN ('responsible', 'accountable', 'consulted', 'informed')),
    CONSTRAINT valid_consult_mode CHECK (consult_mode IN ('read', 'notify', 'block')),
    CONSTRAINT valid_raci_origin CHECK (origin IN ('system', 'user')),
    UNIQUE (process_id, role_id, raci)
);

-- Invariant: at most one accountable per process (enforced on every write)
CREATE UNIQUE INDEX idx_raci_one_accountable
    ON raci_assignments(process_id)
    WHERE raci = 'accountable';

COMMENT ON TABLE raci_assignments IS 'RACI matrix: maps roles to processes with a responsibility letter (R/A/C/I).';
COMMENT ON COLUMN raci_assignments.raci IS 'Responsibility letter: responsible, accountable, consulted, or informed.';
COMMENT ON COLUMN raci_assignments.consult_mode IS 'Applies only when raci=consulted: read (passive), notify (push), block (gate).';
COMMENT ON COLUMN raci_assignments.origin IS 'How this row was created: system (generated) or user (hand-edited).';

CREATE INDEX idx_raci_assignments_process ON raci_assignments(process_id);
CREATE INDEX idx_raci_assignments_role    ON raci_assignments(role_id);

CREATE TRIGGER update_raci_assignments_updated_at
    BEFORE UPDATE ON raci_assignments
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

ALTER TABLE raci_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY raci_assignments_select_policy ON raci_assignments
    FOR SELECT TO semantius_user USING (rbac.has_permission('admin'));
CREATE POLICY raci_assignments_insert_policy ON raci_assignments
    FOR INSERT TO semantius_user WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY raci_assignments_update_policy ON raci_assignments
    FOR UPDATE TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY raci_assignments_delete_policy ON raci_assignments
    FOR DELETE TO semantius_user USING (rbac.has_permission('admin'));

-- Entity metadata
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, managed
) VALUES (
    'raci_assignments', 'raci_assignment', 'raci_assignments',
    'RACI Assignment', 'RACI Assignments',
    'RACI matrix rows assigning roles to processes',
    (SELECT id FROM modules WHERE module_name = '_core'),
    'admin', 'admin', 'id', 'raci', FALSE
);

-- Field metadata
INSERT INTO fields (
    table_name, field_name, title, format, is_pk,
    field_order, input_type, description,
    ctype, is_core,
    enum_values,
    reference_table, reference_delete_mode
) VALUES
    ('raci_assignments', 'id',           'Id',           'int32',     TRUE,   1,      'readonly', 'Primary key',                                          'id',    TRUE,  NULL,                                                              '', ''),
    ('raci_assignments', 'process_id',   'Process',      'parent',    FALSE,  10,     'required', 'The governed process',                                  '',      FALSE, NULL,                                                              'processes', 'cascade'),
    ('raci_assignments', 'role_id',      'Role',         'reference', FALSE,  20,     'required', 'The persona role assigned this letter',                 '',      FALSE, NULL,                                                              'roles', 'cascade'),
    ('raci_assignments', 'raci',         'RACI',         'enum',      FALSE,  30,     'required', 'Responsibility letter',                                 'label', FALSE, '["responsible","accountable","consulted","informed"]'::jsonb, '', ''),
    ('raci_assignments', 'consult_mode', 'Consult Mode', 'enum',      FALSE,  40,     'default',  'Consultation mode (only for raci=consulted)',           '',      FALSE, '["read","notify","block"]'::jsonb,                            '', ''),
    ('raci_assignments', 'origin',       'Origin',       'enum',      FALSE,  50,     'default',  'How this row was created',                             '',      FALSE, '["system","user"]'::jsonb,                                    '', ''),
    ('raci_assignments', 'created_at',   'Created At',   'date-time', FALSE,  999998, 'disabled', 'Creation timestamp',                                    '',      TRUE,  NULL,                                                              '', ''),
    ('raci_assignments', 'updated_at',   'Updated At',   'date-time', FALSE,  999999, 'disabled', 'Last update timestamp',                                 '',      TRUE,  NULL,                                                              '', '');

-- =====================================================
-- STEP 4: process_gates — governance registry + emit driver
-- =====================================================
-- Binds (entity, to_state) to a process.
-- emits_events = TRUE → the generic emit trigger inserts raci_events
-- for C/I actors when a row transitions to to_state.
-- state_column names which column in the governed table holds the
-- lifecycle state (defaults to 'status').

CREATE TABLE process_gates (
    id           SERIAL PRIMARY KEY,
    process_id   INTEGER NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    entity       TEXT    NOT NULL DEFAULT '',
    gate_kind    TEXT    NOT NULL DEFAULT '',
    to_state     TEXT    NOT NULL DEFAULT '',
    state_column TEXT    NOT NULL DEFAULT 'status',
    emits_events BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_gate_kind CHECK (
        gate_kind IN ('approval', 'submit_lock', 'ownership', 'create', 'transition')
    ),
    UNIQUE (process_id, entity, gate_kind, to_state)
);

COMMENT ON TABLE process_gates IS 'Governance registry: maps (entity, gate_kind, to_state) to a process. When emits_events=TRUE the generic emit trigger inserts raci_events on transition.';
COMMENT ON COLUMN process_gates.entity IS 'Governed table name (mirrors entities.table_name).';
COMMENT ON COLUMN process_gates.gate_kind IS 'Type of governance gate: approval, submit_lock, ownership, create, or transition.';
COMMENT ON COLUMN process_gates.to_state IS 'Lifecycle target state (empty string for gates that are not state-targeted).';
COMMENT ON COLUMN process_gates.state_column IS 'Column in the governed table that holds the lifecycle state. Default: status.';
COMMENT ON COLUMN process_gates.emits_events IS 'When TRUE, entering to_state inserts raci_events for C/I actors (drives the emit trigger).';

CREATE INDEX idx_process_gates_process ON process_gates(process_id);
CREATE INDEX idx_process_gates_entity  ON process_gates(entity);
CREATE INDEX idx_process_gates_emit    ON process_gates(entity) WHERE emits_events = TRUE;

CREATE TRIGGER update_process_gates_updated_at
    BEFORE UPDATE ON process_gates
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

ALTER TABLE process_gates ENABLE ROW LEVEL SECURITY;

CREATE POLICY process_gates_select_policy ON process_gates
    FOR SELECT TO semantius_user USING (rbac.has_permission('admin'));
CREATE POLICY process_gates_insert_policy ON process_gates
    FOR INSERT TO semantius_user WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY process_gates_update_policy ON process_gates
    FOR UPDATE TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY process_gates_delete_policy ON process_gates
    FOR DELETE TO semantius_user USING (rbac.has_permission('admin'));

-- Entity metadata
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, managed
) VALUES (
    'process_gates', 'process_gate', 'process_gates',
    'Process Gate', 'Process Gates',
    'Governance registry: maps entity transitions to processes',
    (SELECT id FROM modules WHERE module_name = '_core'),
    'admin', 'admin', 'id', 'gate_kind', FALSE
);

-- Field metadata
INSERT INTO fields (
    table_name, field_name, title, format, is_pk,
    field_order, input_type, description,
    ctype, is_core,
    enum_values,
    reference_table, reference_delete_mode
) VALUES
    ('process_gates', 'id',           'Id',           'int32',     TRUE,   1,      'readonly', 'Primary key',                                              'id',    TRUE,  NULL,                                                                                 '', ''),
    ('process_gates', 'process_id',   'Process',      'parent',    FALSE,  10,     'required', 'The governed process',                                      '',      FALSE, NULL,                                                                                 'processes', 'cascade'),
    ('process_gates', 'entity',       'Entity',       'reference', FALSE,  20,     'required', 'Governed table name',                                       '',      FALSE, NULL,                                                                                 'entities', 'cascade'),
    ('process_gates', 'gate_kind',    'Gate Kind',    'enum',      FALSE,  30,     'required', 'Type of governance gate',                                   'label', FALSE, '["approval","submit_lock","ownership","create","transition"]'::jsonb,               '', ''),
    ('process_gates', 'to_state',     'To State',     'text',      FALSE,  40,     'default',  'Target lifecycle state (empty for non-state-targeted gates)','',      FALSE, NULL,                                                                                 '', ''),
    ('process_gates', 'state_column', 'State Column', 'text',      FALSE,  50,     'default',  'Column that holds the lifecycle state in the governed table','',      FALSE, NULL,                                                                                 '', ''),
    ('process_gates', 'emits_events', 'Emits Events', 'boolean',   FALSE,  60,     'default',  'When TRUE, entering to_state inserts raci_events',          '',      FALSE, NULL,                                                                                 '', ''),
    ('process_gates', 'created_at',   'Created At',   'date-time', FALSE,  999998, 'disabled', 'Creation timestamp',                                        '',      TRUE,  NULL,                                                                                 '', ''),
    ('process_gates', 'updated_at',   'Updated At',   'date-time', FALSE,  999999, 'disabled', 'Last update timestamp',                                     '',      TRUE,  NULL,                                                                                 '', '');

-- =====================================================
-- STEP 5: raci_events — notify/consult audit log
-- =====================================================
-- First-class table so notifications/consultations are queryable,
-- audited, and retryable. record_id is TEXT (deliberate: entity PKs
-- need not be integer serials — mirrors entities.id_column handling).

CREATE TABLE raci_events (
    id             SERIAL PRIMARY KEY,
    process_id     INTEGER NOT NULL REFERENCES processes(id)  ON DELETE CASCADE,
    entity         TEXT    NOT NULL DEFAULT '',
    record_id      TEXT    NOT NULL DEFAULT '',
    raci           TEXT    NOT NULL DEFAULT '',
    target_role_id INTEGER NOT NULL REFERENCES roles(id)      ON DELETE CASCADE,
    status         TEXT    NOT NULL DEFAULT 'pending',
    acted_at       TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_raci_event_raci   CHECK (raci   IN ('consulted', 'informed')),
    CONSTRAINT valid_raci_event_status CHECK (status IN ('pending', 'sent', 'acted'))
);

COMMENT ON TABLE raci_events IS 'Notify/consult log: one row per C/I actor per governed record transition.';
COMMENT ON COLUMN raci_events.record_id IS 'Governed record PK as text — entity IDs need not be integer serials.';
COMMENT ON COLUMN raci_events.raci IS 'Only consulted or informed actors generate events.';
COMMENT ON COLUMN raci_events.status IS 'pending → sent → acted (acted = consultation input received).';
COMMENT ON COLUMN raci_events.acted_at IS 'Timestamp when the consulted party responded (NULL until acted).';

CREATE INDEX idx_raci_events_process   ON raci_events(process_id);
CREATE INDEX idx_raci_events_entity    ON raci_events(entity, record_id);
CREATE INDEX idx_raci_events_role      ON raci_events(target_role_id);
CREATE INDEX idx_raci_events_status    ON raci_events(status) WHERE status != 'acted';

CREATE TRIGGER update_raci_events_updated_at
    BEFORE UPDATE ON raci_events
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

ALTER TABLE raci_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY raci_events_select_policy ON raci_events
    FOR SELECT TO semantius_user USING (rbac.has_permission('admin'));
CREATE POLICY raci_events_insert_policy ON raci_events
    FOR INSERT TO semantius_user WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY raci_events_update_policy ON raci_events
    FOR UPDATE TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));
CREATE POLICY raci_events_delete_policy ON raci_events
    FOR DELETE TO semantius_user USING (rbac.has_permission('admin'));

-- Entity metadata
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, managed
) VALUES (
    'raci_events', 'raci_event', 'raci_events',
    'RACI Event', 'RACI Events',
    'Notify/consult audit log for RACI-governed record transitions',
    (SELECT id FROM modules WHERE module_name = '_core'),
    'admin', 'admin', 'id', 'record_id', FALSE
);

-- Field metadata
INSERT INTO fields (
    table_name, field_name, title, format, is_pk,
    field_order, input_type, description,
    ctype, is_core,
    enum_values,
    reference_table, reference_delete_mode
) VALUES
    ('raci_events', 'id',             'Id',             'int32',     TRUE,   1,      'readonly', 'Primary key',                                              'id',    TRUE,  NULL,                                         '', ''),
    ('raci_events', 'process_id',     'Process',        'parent',    FALSE,  10,     'required', 'The governed process',                                      '',      FALSE, NULL,                                         'processes', 'cascade'),
    ('raci_events', 'entity',         'Entity',         'text',      FALSE,  20,     'required', 'Governed table name',                                       '',      FALSE, NULL,                                         '', ''),
    ('raci_events', 'record_id',      'Record Id',      'text',      FALSE,  30,     'required', 'Governed record PK (text for non-integer PKs)',             'label', FALSE, NULL,                                         '', ''),
    ('raci_events', 'raci',           'RACI',           'enum',      FALSE,  40,     'required', 'consulted or informed',                                     '',      FALSE, '["consulted","informed"]'::jsonb,            '', ''),
    ('raci_events', 'target_role_id', 'Target Role',    'reference', FALSE,  50,     'required', 'Role to be notified or consulted',                          '',      FALSE, NULL,                                         'roles', 'cascade'),
    ('raci_events', 'status',         'Status',         'enum',      FALSE,  60,     'required', 'pending → sent → acted',                                    '',      FALSE, '["pending","sent","acted"]'::jsonb,          '', ''),
    ('raci_events', 'acted_at',       'Acted At',       'date-time', FALSE,  70,     'disabled', 'When the consulted party responded (NULL until acted)',      '',      FALSE, NULL,                                         '', ''),
    ('raci_events', 'created_at',     'Created At',     'date-time', FALSE,  999998, 'disabled', 'Creation timestamp',                                        '',      TRUE,  NULL,                                         '', ''),
    ('raci_events', 'updated_at',     'Updated At',     'date-time', FALSE,  999999, 'disabled', 'Last update timestamp',                                     '',      TRUE,  NULL,                                         '', '');

-- =====================================================
-- STEP 6: SQL functions — RACI operators
-- =====================================================

-- is_raci_actor(entity, to_state, letter) → boolean
-- Returns TRUE if the current user holds a role assigned the given
-- RACI letter for the process that governs (entity, to_state).
-- Calls rbac.uid() to authenticate and resolve the current user;
-- joins user_roles ⋈ raci_assignments.

CREATE OR REPLACE FUNCTION is_raci_actor(
    p_entity   TEXT,
    p_to_state TEXT,
    p_letter   TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    PERFORM rbac.uid();
    PERFORM rbac.ensure_context_initialized();
    v_user_id := NULLIF(current_setting('app.current_user_id', TRUE), '')::INTEGER;
    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;
    RETURN EXISTS (
        SELECT 1
        FROM   process_gates pg
        JOIN   raci_assignments ra ON ra.process_id = pg.process_id
        JOIN   user_roles ur       ON ur.role_id    = ra.role_id
        WHERE  pg.entity    = p_entity
          AND  pg.to_state  = p_to_state
          AND  ra.raci      = p_letter
          AND  ur.user_id   = v_user_id
    );
END;
$$;

COMMENT ON FUNCTION is_raci_actor IS
'Returns TRUE when the current user holds a role with the given RACI letter for the process governing (entity, to_state). Usable as a JsonLogic operator: {"is_raci_actor": ["table_name", "state", "accountable"]}.';

REVOKE EXECUTE ON FUNCTION is_raci_actor(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION is_raci_actor(TEXT, TEXT, TEXT) TO semantius_user;

-- has_consultation(entity, to_state, record_id) → boolean
-- Returns TRUE when an "acted" consulted raci_events row exists for the
-- record's process. Used to back C-block gates.
-- Calls rbac.uid() to authenticate the caller (result not used here since
-- consultation checks are record-scoped, not caller-scoped).

CREATE OR REPLACE FUNCTION has_consultation(
    p_entity    TEXT,
    p_to_state  TEXT,
    p_record_id TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM rbac.uid();
    PERFORM rbac.ensure_context_initialized();
    RETURN EXISTS (
        SELECT 1
        FROM   raci_events  re
        JOIN   process_gates pg ON pg.process_id = re.process_id
        WHERE  pg.entity    = p_entity
          AND  pg.to_state  = p_to_state
          AND  re.record_id = p_record_id
          AND  re.raci      = 'consulted'
          AND  re.status    = 'acted'
    );
END;
$$;

COMMENT ON FUNCTION has_consultation IS
'Returns TRUE when an acted consulted raci_events row exists for the record under (entity, to_state). Backs C-block gates. Usable as a JsonLogic operator: {"has_consultation": ["table_name", "state", {"var":"id"}]}.';

REVOKE EXECUTE ON FUNCTION has_consultation(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION has_consultation(TEXT, TEXT, TEXT) TO semantius_user;

-- =====================================================
-- STEP 7: user_process_raci view — governance reads
-- =====================================================

CREATE OR REPLACE VIEW user_process_raci AS
SELECT
    ur.user_id,
    p.id            AS process_id,
    p.process_key,
    p.name          AS process_name,
    ra.raci,
    ra.role_id,
    ra.consult_mode
FROM user_roles ur
JOIN raci_assignments ra ON ra.role_id   = ur.role_id
JOIN processes        p  ON p.id         = ra.process_id;

COMMENT ON VIEW user_process_raci IS
'Flat projection of user → role → raci_assignment → process for governance reads and diagnostic queries.';

REVOKE ALL ON user_process_raci FROM PUBLIC;
GRANT  SELECT ON user_process_raci TO semantius_user;

-- =====================================================
-- STEP 8: JsonLogic operators for is_raci_actor / has_consultation
-- =====================================================
-- Extend evaluate_json_logic with two new RACI operators so that
-- skills can author gate validation_rules using the same syntax as
-- has_permission / require_permission.

CREATE OR REPLACE FUNCTION evaluate_json_logic(rule jsonb, data jsonb)
RETURNS jsonb AS $$
DECLARE
    op text;
    vals jsonb;
    arr_len int;
    i int;
    current_val jsonb;
    a jsonb; b jsonb; c jsonb;
    num_a numeric; num_b numeric; num_c numeric;
    result jsonb;
    scoped_data jsonb;
    scoped_logic jsonb;
    initial_val jsonb;
    -- for var
    var_key text;
    sub_props text[];
    nav jsonb;
    -- for missing
    missing_arr jsonb;
    keys_arr jsonb;
    key_val text;
    looked_up jsonb;
    -- for merge
    merge_result jsonb;
    elem jsonb;
    j int;
    -- for substr
    src text;
    start_pos int;
    end_len int;
    temp_str text;
    -- for text ops
    txt_a text; txt_b text;
BEGIN
    -- Handle NULL rule
    IF rule IS NULL THEN RETURN 'null'::jsonb; END IF;

    -- Arrays with possible logic inside: recursively evaluate each element
    IF jsonb_typeof(rule) = 'array' THEN
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(rule) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(rule -> i, data));
        END LOOP;
        RETURN result;
    END IF;

    -- Not an object or multi-key object => pass through (primitive)
    IF jsonb_typeof(rule) <> 'object' THEN RETURN rule; END IF;
    -- Must have exactly one key to be logic
    SELECT key INTO op FROM jsonb_object_keys(rule) AS key LIMIT 1;
    IF (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1 THEN RETURN rule; END IF;

    vals := rule -> op;
    -- Normalize: if vals is not an array, wrap it
    IF jsonb_typeof(vals) <> 'array' THEN
        vals := jsonb_build_array(vals);
    END IF;
    arr_len := jsonb_array_length(vals);

    -- ===================== if / ?: =====================
    IF op = 'if' OR op = '?:' THEN
        i := 0;
        WHILE i < arr_len - 1 LOOP
            IF jl_truthy(evaluate_json_logic(vals -> i, data)) THEN
                RETURN evaluate_json_logic(vals -> (i + 1), data);
            END IF;
            i := i + 2;
        END LOOP;
        -- Remaining single element = else clause
        IF arr_len = i + 1 THEN
            RETURN evaluate_json_logic(vals -> i, data);
        END IF;
        RETURN 'null'::jsonb;
    END IF;

    -- ===================== and =====================
    IF op = 'and' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF NOT jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== or =====================
    IF op = 'or' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== filter =====================
    IF op = 'filter' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                result := result || jsonb_build_array(scoped_data -> i);
            END IF;
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== map =====================
    IF op = 'map' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(scoped_logic, scoped_data -> i));
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== reduce =====================
    IF op = 'reduce' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF arr_len >= 3 THEN
            initial_val := evaluate_json_logic(vals -> 2, data);
        ELSE
            initial_val := 'null'::jsonb;
        END IF;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN initial_val;
        END IF;
        current_val := initial_val;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            current_val := evaluate_json_logic(
                scoped_logic,
                jsonb_build_object('current', scoped_data -> i, 'accumulator', current_val)
            );
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== all =====================
    IF op = 'all' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF NOT jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== none =====================
    IF op = 'none' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'true'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== some =====================
    IF op = 'some' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'true'::jsonb;
            END IF;
        END LOOP;
        RETURN 'false'::jsonb;
    END IF;

    -- ===================== let =====================
    -- Binds a named variable into data and evaluates a logic expression.
    -- Usage: {"let":["name", value, logic]}
    IF op = 'let' THEN
        var_key := vals ->> 0;
        result := evaluate_json_logic(vals -> 1, data);
        RETURN evaluate_json_logic(vals -> 2, data || jsonb_build_object(var_key, result));
    END IF;

    -- ===================== set_record =====================
    -- Loads an entity record by id and stores it in data under the given name.
    -- Usage: {"set_record":["varName", "entityName", idExpression, logic]}
    -- Calls get_record_by_id(entityName, id) and stores the result like let.
    IF op = 'set_record' THEN
        var_key := vals ->> 0;
        txt_a := vals ->> 1;
        result := evaluate_json_logic(vals -> 2, data);
        nav := get_record_by_id(txt_a, jl_to_number(result)::integer);
        RETURN evaluate_json_logic(vals -> 3, data || jsonb_build_object(var_key, COALESCE(nav, 'null'::jsonb)));
    END IF;

    -- =====================================================
    -- All remaining operators: depth-first evaluate arguments
    -- =====================================================
    -- Evaluate all arguments first
    result := '[]'::jsonb;
    FOR i IN 0 .. arr_len - 1 LOOP
        result := result || jsonb_build_array(evaluate_json_logic(vals -> i, data));
    END LOOP;
    vals := result;
    arr_len := jsonb_array_length(vals);

    -- Get convenience references
    a := vals -> 0;
    IF arr_len > 1 THEN b := vals -> 1; ELSE b := NULL; END IF;
    IF arr_len > 2 THEN c := vals -> 2; ELSE c := NULL; END IF;

    -- ===================== var =====================
    IF op = 'var' THEN
        -- a = the key/path, b = default value
        -- If a is undefined/null/empty string, return data itself
        IF a IS NULL OR jsonb_typeof(a) = 'null' OR (jsonb_typeof(a) = 'string' AND a #>> '{}' = '') THEN
            RETURN data;
        END IF;
        var_key := jl_to_text(a);
        sub_props := string_to_array(var_key, '.');
        nav := data;
        FOR i IN 1 .. array_length(sub_props, 1) LOOP
            IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
                -- not found, return default
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
            -- Try object key or array index
            IF jsonb_typeof(nav) = 'array' THEN
                BEGIN
                    nav := nav -> sub_props[i]::int;
                EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
                    IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
                END;
            ELSE
                nav := nav -> sub_props[i];
            END IF;
            IF nav IS NULL THEN
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
        END LOOP;
        RETURN nav;
    END IF;

    -- ===================== missing =====================
    IF op = 'missing' THEN
        -- Arguments can be individual keys or a single array of keys
        IF arr_len = 1 AND jsonb_typeof(a) = 'array' THEN
            keys_arr := a;
        ELSE
            keys_arr := vals;
        END IF;
        missing_arr := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(keys_arr) - 1 LOOP
            key_val := keys_arr ->> i;
            looked_up := evaluate_json_logic(jsonb_build_object('var', keys_arr -> i), data);
            IF jsonb_typeof(looked_up) = 'null' OR (jsonb_typeof(looked_up) = 'string' AND looked_up #>> '{}' = '') THEN
                missing_arr := missing_arr || jsonb_build_array(keys_arr -> i);
            END IF;
        END LOOP;
        RETURN missing_arr;
    END IF;

    -- ===================== missing_some =====================
    IF op = 'missing_some' THEN
        -- a = need_count, b = array of keys
        num_a := jl_to_number(a);
        -- Compute missing using the missing operator
        missing_arr := evaluate_json_logic(jsonb_build_object('missing', b), data);
        IF jsonb_array_length(b) - jsonb_array_length(missing_arr) >= num_a THEN
            RETURN '[]'::jsonb;
        ELSE
            RETURN missing_arr;
        END IF;
    END IF;

    -- ===================== == =====================
    IF op = '==' THEN
        RETURN to_jsonb(jl_loose_eq(a, b));
    END IF;

    -- ===================== === =====================
    IF op = '===' THEN
        -- Strict equality: types must match
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'false'::jsonb; END IF;
        RETURN to_jsonb(a = b);
    END IF;

    -- ===================== != =====================
    IF op = '!=' THEN
        RETURN to_jsonb(NOT jl_loose_eq(a, b));
    END IF;

    -- ===================== !== =====================
    IF op = '!==' THEN
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'true'::jsonb; END IF;
        RETURN to_jsonb(a <> b);
    END IF;

    -- ===================== ! =====================
    IF op = '!' THEN
        RETURN to_jsonb(NOT jl_truthy(a));
    END IF;

    -- ===================== !! =====================
    IF op = '!!' THEN
        RETURN to_jsonb(jl_truthy(a));
    END IF;

    -- ===================== > =====================
    IF op = '>' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a > num_b);
    END IF;

    -- ===================== >= =====================
    IF op = '>=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a >= num_b);
    END IF;

    -- ===================== < =====================
    IF op = '<' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a < num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a < num_b AND num_b < num_c);
        END IF;
    END IF;

    -- ===================== <= =====================
    IF op = '<=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a <= num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a <= num_b AND num_b <= num_c);
        END IF;
    END IF;

    -- ===================== % =====================
    IF op = '%' THEN
        RETURN to_jsonb(jl_to_number(a) % jl_to_number(b));
    END IF;

    -- ===================== + =====================
    IF op = '+' THEN
        num_a := 0;
        FOR i IN 0 .. arr_len - 1 LOOP
            num_a := num_a + jl_to_number(vals -> i);
        END LOOP;
        -- Return integer if result is integer
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== * =====================
    IF op = '*' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_a := num_a * jl_to_number(vals -> i);
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== - =====================
    IF op = '-' THEN
        IF arr_len = 1 THEN
            num_a := -jl_to_number(a);
        ELSE
            num_a := jl_to_number(a) - jl_to_number(b);
        END IF;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== / =====================
    IF op = '/' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF num_b = 0 THEN RETURN 'null'::jsonb; END IF;
        num_c := num_a / num_b;
        IF num_c = trunc(num_c) THEN
            RETURN to_jsonb(num_c::bigint);
        ELSE
            RETURN to_jsonb(num_c);
        END IF;
    END IF;

    -- ===================== max =====================
    IF op = 'max' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b > num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== min =====================
    IF op = 'min' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b < num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== in =====================
    IF op = 'in' THEN
        IF b IS NULL THEN RETURN 'false'::jsonb; END IF;
        IF jsonb_typeof(b) = 'array' THEN
            -- Check if a is in the array
            FOR i IN 0 .. jsonb_array_length(b) - 1 LOOP
                IF a = b -> i THEN
                    RETURN 'true'::jsonb;
                END IF;
            END LOOP;
            RETURN 'false'::jsonb;
        ELSIF jsonb_typeof(b) = 'string' THEN
            -- Substring check
            txt_a := jl_to_text(a);
            txt_b := jl_to_text(b);
            RETURN to_jsonb(position(txt_a in txt_b) > 0);
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== cat =====================
    IF op = 'cat' THEN
        txt_a := '';
        FOR i IN 0 .. arr_len - 1 LOOP
            txt_a := txt_a || jl_to_text(vals -> i);
        END LOOP;
        RETURN to_jsonb(txt_a);
    END IF;

    -- ===================== substr =====================
    IF op = 'substr' THEN
        src := jl_to_text(a);
        start_pos := jl_to_number(b)::int;
        -- Handle negative start: count from end
        IF start_pos < 0 THEN
            start_pos := length(src) + start_pos;
            IF start_pos < 0 THEN start_pos := 0; END IF;
        END IF;
        IF arr_len >= 3 THEN
            end_len := jl_to_number(c)::int;
            IF end_len < 0 THEN
                -- Negative length: from start_pos, take chars until end_len from end
                temp_str := substring(src FROM start_pos + 1);
                RETURN to_jsonb(substring(temp_str FROM 1 FOR length(temp_str) + end_len));
            ELSE
                RETURN to_jsonb(substring(src FROM start_pos + 1 FOR end_len));
            END IF;
        ELSE
            RETURN to_jsonb(substring(src FROM start_pos + 1));
        END IF;
    END IF;

    -- ===================== merge =====================
    IF op = 'merge' THEN
        merge_result := '[]'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            elem := vals -> i;
            IF jsonb_typeof(elem) = 'array' THEN
                -- Concatenate array elements
                FOR j IN 0 .. jsonb_array_length(elem) - 1 LOOP
                    merge_result := merge_result || jsonb_build_array(elem -> j);
                END LOOP;
            ELSE
                merge_result := merge_result || jsonb_build_array(elem);
            END IF;
        END LOOP;
        RETURN merge_result;
    END IF;

    -- ===================== log =====================
    IF op = 'log' THEN
        RAISE NOTICE 'jsonlogic log: %', a;
        RETURN a;
    END IF;

    -- ===================== has_permission =====================
    -- Calls rbac.has_permission with the given permission name.
    -- Returns true when the user has the permission; false otherwise.
    IF op = 'has_permission' THEN
        IF rbac.has_permission(jl_to_text(a)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== require_permission =====================
    -- Calls rbac.require_permission with the given permission name.
    -- Returns true when the user has the permission; throws an error otherwise.
    IF op = 'require_permission' THEN
        PERFORM rbac.require_permission(jl_to_text(a));
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== value_changed =====================
    -- Checks if a field value has changed compared to $old.
    -- When $old is missing or null in data, always returns true (new record).
    -- When $old is present, compares $old.<field> with current <field>.
    IF op = 'value_changed' THEN
        var_key := jl_to_text(a);
        nav := data -> '$old';
        -- If $old is absent or null, treat as new record => always changed
        IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
            RETURN 'true'::jsonb;
        END IF;
        -- Compare old value with current value
        IF (nav -> var_key) IS DISTINCT FROM (data -> var_key) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== concat =====================
    -- Concatenates all arguments into a single string.
    -- Like SQL CONCAT: NULL/null → empty string, accepts all types.
    -- Non-string types are converted via their JSON text representation.
    -- Usage: {"concat":["Hello ", {"var":"name"}, " #", {"var":"id"}]}
    IF op = 'concat' THEN
        txt_a := '';
        FOR i IN 0 .. arr_len - 1 LOOP
            elem := vals -> i;
            IF elem IS NULL OR jsonb_typeof(elem) = 'null' THEN
                -- NULL/null → empty string
                CONTINUE;
            ELSIF jsonb_typeof(elem) = 'string' THEN
                txt_a := txt_a || (elem #>> '{}');
            ELSE
                -- numbers, booleans, arrays, objects → JSON text
                txt_a := txt_a || elem::text;
            END IF;
        END LOOP;
        RETURN to_jsonb(txt_a);
    END IF;

    -- ===================== is_match =====================
    -- Tests whether a string value matches a regular expression pattern.
    -- Returns true when the value matches, false otherwise.
    -- Null values always return false.
    -- Usage: {"is_match":[{"var":"email"}, "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"]}
    IF op = 'is_match' THEN
        txt_a := jl_to_text(a);
        txt_b := jl_to_text(b);
        IF txt_a IS NULL OR txt_b IS NULL THEN
            RETURN 'false'::jsonb;
        END IF;
        RETURN to_jsonb(regexp_match(txt_a, txt_b) IS NOT NULL);
    END IF;

    -- ===================== throw_error =====================
    -- Raises an exception with the given message.
    -- Usage: {"throw_error":"message"}
    IF op = 'throw_error' THEN
        RAISE EXCEPTION '%', jl_to_text(a) USING ERRCODE = '23514';
    END IF;

    -- ===================== is_raci_actor =====================
    -- Returns true when the current user holds a role with the given
    -- RACI letter for the process governing (entity, to_state).
    -- Usage: {"is_raci_actor": ["table_name", "state", "accountable"]}
    IF op = 'is_raci_actor' THEN
        IF is_raci_actor(jl_to_text(a), jl_to_text(b), jl_to_text(c)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== has_consultation =====================
    -- Returns true when an acted consulted raci_events row exists for
    -- the record under (entity, to_state). Backs C-block gates.
    -- Usage: {"has_consultation": ["table_name", "state", {"var":"id"}]}
    IF op = 'has_consultation' THEN
        IF has_consultation(jl_to_text(a), jl_to_text(b), jl_to_text(c)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- Unknown operator
    RAISE EXCEPTION 'Unrecognized operation: %', op;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- =====================================================
-- STEP 9: Generic emit trigger — process_gates driven
-- =====================================================
-- raci_emit_trigger_fn fires AFTER INSERT OR UPDATE on any governed
-- table. For each process_gates row where emits_events=TRUE and the
-- row has just entered to_state, it inserts raci_events rows for
-- every C/I actor in raci_assignments for that process.
--
-- The trigger is installed / uninstalled dynamically by
-- raci_gates_manage_emit_trigger (a trigger on process_gates).
-- This mirrors the queue_table_events pattern.

CREATE OR REPLACE FUNCTION raci_emit_trigger_fn()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_gate       RECORD;
    v_new_jsonb  JSONB;
    v_old_jsonb  JSONB;
    v_new_state  TEXT;
    v_old_state  TEXT;
    v_id_col     TEXT;
    v_record_id  TEXT;
BEGIN
    v_new_jsonb := to_jsonb(NEW);
    v_old_jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END;

    -- Resolve the entity's id_column for record_id capture
    SELECT COALESCE(id_column, 'id') INTO v_id_col
    FROM   entities WHERE table_name = TG_TABLE_NAME;
    v_id_col    := COALESCE(v_id_col, 'id');
    v_record_id := COALESCE(v_new_jsonb ->> v_id_col, '');

    FOR v_gate IN
        SELECT pg.*
        FROM   process_gates pg
        WHERE  pg.entity       = TG_TABLE_NAME
          AND  pg.emits_events = TRUE
          AND  pg.to_state    != ''
    LOOP
        v_new_state := v_new_jsonb ->> v_gate.state_column;
        v_old_state := CASE
            WHEN v_old_jsonb IS NOT NULL THEN v_old_jsonb ->> v_gate.state_column
            ELSE NULL
        END;

        -- Transition detected: row has entered to_state
        IF v_new_state = v_gate.to_state
           AND (v_old_state IS NULL OR v_old_state IS DISTINCT FROM v_gate.to_state)
        THEN
            INSERT INTO raci_events (
                process_id, entity, record_id, raci, target_role_id, status
            )
            SELECT
                v_gate.process_id,
                TG_TABLE_NAME,
                v_record_id,
                ra.raci,
                ra.role_id,
                'pending'
            FROM raci_assignments ra
            WHERE ra.process_id = v_gate.process_id
              AND ra.raci       IN ('consulted', 'informed');
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION raci_emit_trigger_fn IS
'Generic AFTER INSERT OR UPDATE trigger function. For each process_gates row with emits_events=TRUE, detects state transitions and inserts raci_events rows for Consulted/Informed actors.';

REVOKE EXECUTE ON FUNCTION raci_emit_trigger_fn() FROM PUBLIC;

-- Trigger installer / uninstaller: fires when process_gates changes.
-- Installs the emit trigger on the entity table when any gate for
-- that entity has emits_events=TRUE; drops it when none do.

CREATE OR REPLACE FUNCTION raci_gates_manage_emit_trigger()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_entity       TEXT;
    v_trigger_name TEXT;
    v_needs        BOOLEAN;
BEGIN
    -- Determine affected entity (handle UPDATE that changes entity)
    IF TG_OP = 'UPDATE' AND OLD.entity IS DISTINCT FROM NEW.entity THEN
        -- Handle old entity
        PERFORM raci_install_or_drop_emit_trigger(OLD.entity);
        -- Handle new entity
        PERFORM raci_install_or_drop_emit_trigger(NEW.entity);
        RETURN NEW;
    END IF;

    v_entity := CASE WHEN TG_OP = 'DELETE' THEN OLD.entity ELSE NEW.entity END;
    PERFORM raci_install_or_drop_emit_trigger(v_entity);

    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE EXECUTE ON FUNCTION raci_gates_manage_emit_trigger() FROM PUBLIC;

-- Helper: install or drop the emit trigger for a given entity.
-- Called by raci_gates_manage_emit_trigger after every INSERT/UPDATE/DELETE.

CREATE OR REPLACE FUNCTION raci_install_or_drop_emit_trigger(p_entity TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_needs        BOOLEAN;
    v_table_exists BOOLEAN;
BEGIN
    v_trigger_name := 'raci_emit_on_' || p_entity;

    -- Check if any process_gates row for this entity needs the trigger
    SELECT EXISTS (
        SELECT 1 FROM process_gates
        WHERE  entity = p_entity AND emits_events = TRUE
    ) INTO v_needs;

    -- Check whether the physical table exists (skip for unregistered tables)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE  table_schema = 'public'
          AND  table_name   = p_entity
    ) INTO v_table_exists;

    IF NOT v_table_exists THEN
        RETURN;
    END IF;

    IF v_needs THEN
        -- Install (idempotent: drop first, then recreate)
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_entity);
        EXECUTE format(
            'CREATE TRIGGER %I
                AFTER INSERT OR UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION raci_emit_trigger_fn()',
            v_trigger_name, p_entity
        );
    ELSE
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_entity);
    END IF;
END;
$$;

COMMENT ON FUNCTION raci_install_or_drop_emit_trigger IS
'Installs or drops the raci_emit_on_<entity> trigger depending on whether any process_gates row for that entity has emits_events=TRUE.';

REVOKE EXECUTE ON FUNCTION raci_install_or_drop_emit_trigger(TEXT) FROM PUBLIC;

-- Wire the installer to process_gates
CREATE TRIGGER raci_gates_manage_emit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON process_gates
    FOR EACH ROW
    EXECUTE FUNCTION raci_gates_manage_emit_trigger();

-- =====================================================
-- STEP 10: Queue wiring — raci_notify
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
