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

-- =====================================================
-- STEP 1: agent identity
-- =====================================================
-- An agent is a service principal: a user that authenticates, holds
-- roles, and is audited.
-- Repeatable. The entities are defined in 0350_raci.jsonc, their constraints,
-- indexes and the raci_notify queue in 0360_raci_setup.once.sql.

-- An agent never authenticates at an identity provider, so nothing supplies
-- its external_id - and external_id is the identity: an API key resolves to
-- users.id, and the JWT minted from it carries this column as its sub. An
-- agent inserted without one, or with an empty one, gets a generated identity
-- here. A user gets nothing: a user's identity is the provider's sub, supplied
-- through get_userinfo(), and a user row saved without one is refused by NOT
-- NULL and users_external_id_not_empty (0060_rbac_schema.once.sql). INSERT only, on purpose:
-- regenerating on UPDATE would rotate an agent's identity on an ordinary save
-- and invalidate every token minted for it, so blanking it is refused instead.
CREATE OR REPLACE FUNCTION assign_agent_external_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_agent AND (NEW.external_id IS NULL OR btrim(NEW.external_id) = '') THEN
        NEW.external_id := 'agent:' || gen_random_uuid()::text;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION assign_agent_external_id IS
'Trigger function: gives an agent (is_agent) inserted without an external_id, or with an empty one, a generated agent:<uuid>. Users are left alone and refused by the column constraints.';

CREATE OR REPLACE TRIGGER assign_agent_external_id_trigger
    BEFORE INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION assign_agent_external_id();

COMMENT ON TRIGGER assign_agent_external_id_trigger ON users IS
'Generates agent:<uuid> as external_id for an agent inserted without one.';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION assign_agent_external_id() FROM PUBLIC;

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
-- record's process, AND the caller participates in that process (b9 caller-scope).

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
DECLARE
    v_user_id INTEGER;
BEGIN
    PERFORM rbac.uid();
    PERFORM rbac.ensure_context_initialized();

    -- Caller-scope (b9): has_consultation is GRANTed to the request role and exposed as
    -- /rpc/has_consultation, so without a caller gate it is a record-existence oracle — any user
    -- could probe any record's consultation state. Restrict it to PARTICIPANTS of the governing
    -- process: the caller must hold a role that carries some RACI assignment on the process that
    -- governs (entity, to_state). A consulted-gate is always evaluated by an actor who is a RACI
    -- participant (R/A initiating the transition), so legitimate use is unaffected; a non-
    -- participant probe fails closed (FALSE), indistinguishable from "not yet consulted".
    v_user_id := NULLIF(current_setting('app.current_user_id', TRUE), '')::INTEGER;
    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM   process_gates    pg
        JOIN   raci_assignments ra ON ra.process_id = pg.process_id
        JOIN   user_roles       ur ON ur.role_id    = ra.role_id
        WHERE  pg.entity   = p_entity
          AND  pg.to_state = p_to_state
          AND  ur.user_id  = v_user_id
    ) THEN
        RETURN FALSE;
    END IF;

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
'Returns TRUE when an acted consulted raci_events row exists for the record under (entity, to_state) AND the caller participates in the governing process (holds a role with a RACI assignment on it). A non-participant gets FALSE rather than the true answer: this function is granted to the request role and reachable over RPC, where a record-scoped answer would tell any signed-in user whether a record exists in a given state. It reports whether consultation happened; it does not itself hold anything back - raci_gate_trigger_fn does that, and reads consult_mode, which this does not. Usable as a JsonLogic operator: {"has_consultation": ["table_name", "state", {"var":"id"}]}.';

REVOKE EXECUTE ON FUNCTION has_consultation(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION has_consultation(TEXT, TEXT, TEXT) TO semantius_user;

-- =====================================================
-- STEP 7: user_process_raci view — governance reads
-- =====================================================

CREATE OR REPLACE VIEW user_process_raci WITH (security_invoker = true) AS
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
-- STEP 8: Generic emit trigger — process_gates driven
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

-- =====================================================
-- STEP 8b: A blocking consultation holds the process
-- =====================================================
-- consult_mode is the opt-in, and until this existed nothing read it: read
-- (passive), notify (push) and block (gate) all behaved identically, because the
-- column was stored and displayed and consulted by no predicate anywhere. Only
-- block reaches this code; read and notify observe and never hold anything.
--
-- What a blocking consultation blocks is the PROCESS, not the writer. A record
-- with an unacted blocking consultation keeps accepting writes; what it will not
-- do is change a state column a gate governs. An editor can still correct a
-- field on the record, and only the transition waits. Refusing the statement
-- instead would cost that editor every other change in it, over a consultation
-- that is not theirs and that they cannot complete.
--
-- Which transition it holds follows from where the events come from. The
-- consultation is raised BY entering to_state (raci_emit_trigger_fn above), so a
-- blocking consultation gates the record's next move rather than the one that
-- asked for it: entering 'approved' asks the consulted roles to respond, and the
-- record stays in 'approved' until they have. There is no other reading the
-- event flow supports - an event that does not exist yet cannot hold anything
-- back.
--
-- A held transition is not remembered. Once the last blocking consultation is
-- acted the same write succeeds, and nothing replays the one that was held. The
-- pending raci_events rows are what a client reads to explain why a save left
-- the state where it was; this trigger deliberately writes no explanation of its
-- own onto the record, because that would mean a column on every governed table.

-- The question is about the record, never about the caller. is_raci_actor and
-- has_consultation are caller-scoped on purpose - they are granted to the
-- request role and reachable over RPC, where a record-scoped answer is an
-- existence oracle - but a gate that consulted the caller would let a writer
-- outside the process walk through it. This one is not reachable from outside:
-- SECURITY INVOKER, so it reads raci_events past RLS only because its caller is
-- the SECURITY DEFINER trigger below, where current_user is the owner, and
-- EXECUTE is taken away from the request role at the end of this file. Reached
-- any other way it sees nothing and reports nothing blocking, which fails toward
-- the write landing rather than toward a record nobody can move.
CREATE OR REPLACE FUNCTION raci_blocking_consultation_pending(
    p_entity    TEXT,
    p_record_id TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM   raci_events      re
        JOIN   raci_assignments ra ON  ra.process_id = re.process_id
                                   AND ra.role_id    = re.target_role_id
        WHERE  re.entity       = p_entity
          AND  re.record_id    = p_record_id
          AND  re.raci         = 'consulted'
          AND  re.status      <> 'acted'
          AND  ra.raci         = 'consulted'
          AND  ra.consult_mode = 'block'
    );
$$;

COMMENT ON FUNCTION raci_blocking_consultation_pending IS
'TRUE while the record has a consulted raci_events row that is not acted and whose assignment carries consult_mode = block. Ignores the caller: a gate that asked who is writing would let a writer outside the process past it.';

-- Not reachable by the request role: answering about the record rather than the
-- caller is exactly the existence oracle the caller-scope on has_consultation
-- exists to close, and over RPC that is what this would be.
REVOKE EXECUTE ON FUNCTION raci_blocking_consultation_pending(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION raci_blocking_consultation_pending(TEXT, TEXT) FROM semantius_user;

-- BEFORE UPDATE, because holding a transition means rewriting NEW - an AFTER
-- trigger could only raise, which is the refusal this is here to avoid. UPDATE
-- only: a row being inserted has no state to be held at, and no consultation of
-- its own can be pending before it exists.
--
-- It sorts after compute_validate_trigger, so computed fields and validation
-- rules have already run against the state the writer asked for. That is the
-- right way round: validation judges the request, and the gate then decides
-- whether the process may carry it out.
CREATE OR REPLACE FUNCTION raci_gate_trigger_fn()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_gate      RECORD;
    v_new_jsonb JSONB;
    v_old_jsonb JSONB;
    v_new_state TEXT;
    v_old_state TEXT;
    v_id_col    TEXT;
    v_record_id TEXT;
BEGIN
    v_new_jsonb := to_jsonb(NEW);
    v_old_jsonb := to_jsonb(OLD);

    SELECT COALESCE(id_column, 'id') INTO v_id_col
    FROM   entities WHERE table_name = TG_TABLE_NAME;
    v_id_col    := COALESCE(v_id_col, 'id');
    v_record_id := COALESCE(v_new_jsonb ->> v_id_col, '');

    -- Asked once rather than once per gate: the answer is a property of the
    -- record, and the common answer is no, which leaves this trigger costing one
    -- indexed EXISTS on a write that changes no state at all.
    IF NOT raci_blocking_consultation_pending(TG_TABLE_NAME, v_record_id) THEN
        RETURN NEW;
    END IF;

    FOR v_gate IN
        SELECT DISTINCT pg.state_column
        FROM   process_gates pg
        WHERE  pg.entity        = TG_TABLE_NAME
          AND  pg.to_state     != ''
          AND  pg.state_column != ''
    LOOP
        v_new_state := v_new_jsonb ->> v_gate.state_column;
        v_old_state := v_old_jsonb ->> v_gate.state_column;

        -- Put the stored value back. Every other column the statement wrote is
        -- left exactly as the writer set it.
        IF v_new_state IS DISTINCT FROM v_old_state THEN
            NEW := jsonb_populate_record(
                NEW, jsonb_build_object(v_gate.state_column, v_old_state));
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION raci_gate_trigger_fn IS
'Per-row BEFORE UPDATE trigger function on a governed table: while a blocking consultation on the record is unacted, any state column a process gate governs is written back to its stored value. Other columns are untouched and the statement succeeds.';

REVOKE EXECUTE ON FUNCTION raci_gate_trigger_fn() FROM PUBLIC;

-- Installed for any entity that has a gate at all, not only one that emits
-- events, so the state columns a gate names are governed whatever the emit
-- setting is. The blocking test is made at write time, so a consult_mode edit
-- needs no reinstall - which is why this hangs off process_gates alone and not
-- off raci_assignments too.
CREATE OR REPLACE FUNCTION raci_install_or_drop_gate_trigger(p_entity TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_needs        BOOLEAN;
BEGIN
    v_trigger_name := 'raci_gate_on_' || p_entity;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE  table_schema = 'public' AND table_name = p_entity
    ) THEN
        RETURN;
    END IF;

    v_needs := EXISTS (
        SELECT 1 FROM process_gates
        WHERE  entity = p_entity AND to_state != '' AND state_column != ''
    );

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_entity);

    IF v_needs THEN
        EXECUTE format(
            'CREATE TRIGGER %I
                BEFORE UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION raci_gate_trigger_fn()',
            v_trigger_name, p_entity
        );
    END IF;
END;
$$;

COMMENT ON FUNCTION raci_install_or_drop_gate_trigger IS
'Installs or drops the raci_gate_on_<entity> trigger depending on whether any process_gates row for that entity names a state column and a to_state.';

REVOKE EXECUTE ON FUNCTION raci_install_or_drop_gate_trigger(TEXT) FROM PUBLIC;

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
BEGIN
    -- Determine affected entity (handle UPDATE that changes entity)
    IF TG_OP = 'UPDATE' AND OLD.entity IS DISTINCT FROM NEW.entity THEN
        -- Handle old entity
        PERFORM raci_install_or_drop_emit_trigger(OLD.entity);
        PERFORM raci_install_or_drop_gate_trigger(OLD.entity);
        -- Handle new entity
        PERFORM raci_install_or_drop_emit_trigger(NEW.entity);
        PERFORM raci_install_or_drop_gate_trigger(NEW.entity);
        RETURN NEW;
    END IF;

    v_entity := CASE WHEN TG_OP = 'DELETE' THEN OLD.entity ELSE NEW.entity END;
    PERFORM raci_install_or_drop_emit_trigger(v_entity);
    PERFORM raci_install_or_drop_gate_trigger(v_entity);

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
    v_needs := EXISTS (
        SELECT 1 FROM process_gates
        WHERE  entity = p_entity AND emits_events = TRUE
    );

    -- Check whether the physical table exists (skip for unregistered tables)
    v_table_exists := EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE  table_schema = 'public'
          AND  table_name   = p_entity
    );

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

COMMENT ON FUNCTION raci_gates_manage_emit_trigger() IS
'Trigger function on process_gates that (re)runs raci_install_or_drop_emit_trigger and raci_install_or_drop_gate_trigger for the affected entity/entities, so the raci_emit_on_<entity> and raci_gate_on_<entity> triggers follow the gates as they change.';

-- Wire the installer to process_gates
CREATE OR REPLACE TRIGGER raci_gates_manage_emit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON process_gates
    FOR EACH ROW
    EXECUTE FUNCTION raci_gates_manage_emit_trigger();
