-- =====================================================
-- AUDIT LOG SYSTEM
-- =====================================================
-- Provides comprehensive audit logging for DML operations (INSERT, UPDATE,
-- DELETE, TRUNCATE) on managed entity tables and DDL schema changes.
--
-- Based on the supa_audit pattern (https://github.com/supabase/supa_audit)
-- but integrated directly into _core rather than as an extension.
--
-- Features:
--   1. Per-table DML audit: enabled/disabled via entities.audit_log toggle
--   2. DDL audit: captures schema changes via event trigger
--   3. Automatic audit trigger management when entities are created/deleted
--   4. Audit trigger renamed when entities are renamed

-- =====================================================
-- STEP 1: Create audit schema and types
-- =====================================================

CREATE SCHEMA IF NOT EXISTS audit;

ALTER DEFAULT PRIVILEGES IN SCHEMA audit
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMENT ON SCHEMA audit IS 'Audit logging schema for DML and DDL change tracking';

-- Create enum type for SQL operations to reduce disk/memory usage vs text
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE t.typname = 'operation' AND n.nspname = 'audit') THEN
        CREATE TYPE audit.operation AS ENUM (
            'INSERT',
            'UPDATE',
            'DELETE',
            'TRUNCATE'
        );
    END IF;
END $$;

-- =====================================================
-- STEP 2: Create DML audit table (record_version)
-- =====================================================

CREATE TABLE IF NOT EXISTS audit.record_version (
    id             BIGSERIAL PRIMARY KEY,
    record_id      UUID,
    old_record_id  UUID,
    op             audit.operation NOT NULL,
    ts             TIMESTAMPTZ NOT NULL DEFAULT now(),
    table_oid      OID NOT NULL,
    table_schema   NAME NOT NULL,
    table_name     NAME NOT NULL,
    record         JSONB,
    old_record     JSONB,

    -- at least one of record_id or old_record_id is populated, except for truncates
    CHECK (COALESCE(record_id, old_record_id) IS NOT NULL OR op = 'TRUNCATE'),
    -- record_id must be populated for insert and update
    CHECK ((op IN ('INSERT', 'UPDATE')) = (record_id IS NOT NULL)),
    CHECK ((op IN ('INSERT', 'UPDATE')) = (record IS NOT NULL)),
    -- old_record must be populated for update and delete
    CHECK ((op IN ('UPDATE', 'DELETE')) = (old_record_id IS NOT NULL)),
    CHECK ((op IN ('UPDATE', 'DELETE')) = (old_record IS NOT NULL))
);

COMMENT ON TABLE audit.record_version IS
'Stores DML audit records for entity tables with audit_log enabled.
Each row captures the operation type, the full record (new/old), and metadata.';

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS record_version_record_id
    ON audit.record_version(record_id)
    WHERE record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS record_version_old_record_id
    ON audit.record_version(old_record_id)
    WHERE old_record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS record_version_ts
    ON audit.record_version
    USING BRIN(ts);

CREATE INDEX IF NOT EXISTS record_version_table_oid
    ON audit.record_version(table_oid);

-- =====================================================
-- STEP 3: Create DDL audit table (ddl_history)
-- =====================================================

CREATE TABLE IF NOT EXISTS audit.ddl_history (
    id              BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_name       TEXT NOT NULL DEFAULT '',
    command_tag     TEXT NOT NULL DEFAULT '',
    object_type     TEXT NOT NULL DEFAULT '',
    object_identity TEXT NOT NULL DEFAULT '',
    query_text      TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE audit.ddl_history IS
'Stores DDL schema change events captured by the ddl_command_end event trigger.';

CREATE INDEX IF NOT EXISTS ddl_history_event_time
    ON audit.ddl_history
    USING BRIN(event_time);

-- =====================================================
-- STEP 4: Helper function to compute record_id from primary key
-- =====================================================

CREATE OR REPLACE FUNCTION audit.primary_key_columns(entity_oid OID)
    RETURNS TEXT[]
    STABLE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE sql
AS $$
    SELECT
        COALESCE(
            array_agg(pa.attname::TEXT ORDER BY pa.attnum),
            ARRAY[]::TEXT[]
        )
    FROM
        pg_index pi
        JOIN pg_attribute pa
            ON pi.indrelid = pa.attrelid
            AND pa.attnum = ANY(pi.indkey)
    WHERE
        indrelid = $1
        AND indisprimary
$$;

COMMENT ON FUNCTION audit.primary_key_columns IS
'Returns the column names that form the primary key of a table, identified by OID.';

CREATE OR REPLACE FUNCTION audit.to_record_id(entity_oid OID, pkey_cols TEXT[], rec JSONB)
    RETURNS UUID
    STABLE
    LANGUAGE sql
    SET search_path = public
AS $$
    SELECT
        CASE
            WHEN rec IS NULL THEN NULL
            WHEN pkey_cols = ARRAY[]::TEXT[] THEN gen_random_uuid()
            ELSE (
                SELECT
                    md5(
                        (jsonb_build_array(to_jsonb($1)) || jsonb_agg($3 ->> key_))::TEXT
                    )::UUID
                FROM
                    unnest($2) x(key_)
            )
        END
$$;

COMMENT ON FUNCTION audit.to_record_id IS
'Computes a deterministic UUID v5 from a table OID and primary key values, enabling
indexed lookup of a record''s full version history.';

-- =====================================================
-- STEP 5: DML audit trigger functions
-- =====================================================

CREATE OR REPLACE FUNCTION audit.insert_update_delete_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    pkey_cols TEXT[] = audit.primary_key_columns(TG_RELID);
    record_jsonb JSONB = to_jsonb(NEW);
    record_id UUID = audit.to_record_id(TG_RELID, pkey_cols, record_jsonb);
    old_record_jsonb JSONB = to_jsonb(OLD);
    old_record_id UUID = audit.to_record_id(TG_RELID, pkey_cols, old_record_jsonb);
BEGIN
    INSERT INTO audit.record_version(
        record_id,
        old_record_id,
        op,
        table_oid,
        table_schema,
        table_name,
        record,
        old_record
    )
    SELECT
        record_id,
        old_record_id,
        TG_OP::audit.operation,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        record_jsonb,
        old_record_jsonb;

    RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION audit.insert_update_delete_trigger IS
'Row-level AFTER trigger function that logs INSERT, UPDATE, and DELETE operations
to audit.record_version. Computes deterministic record_id from primary key.';

CREATE OR REPLACE FUNCTION audit.truncate_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit.record_version(
        op,
        table_oid,
        table_schema,
        table_name
    )
    SELECT
        TG_OP::audit.operation,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME;

    RETURN COALESCE(OLD, NEW);
END;
$$;

COMMENT ON FUNCTION audit.truncate_trigger IS
'Statement-level AFTER trigger function that logs TRUNCATE operations to audit.record_version.';

-- =====================================================
-- STEP 6: Enable/disable audit tracking functions
-- =====================================================

CREATE OR REPLACE FUNCTION audit.enable_tracking(target_table REGCLASS)
    RETURNS VOID
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    statement_row TEXT = format('
        CREATE TRIGGER audit_i_u_d
            AFTER INSERT OR UPDATE OR DELETE
            ON %s
            FOR EACH ROW
            EXECUTE FUNCTION audit.insert_update_delete_trigger();',
        $1
    );
    statement_stmt TEXT = format('
        CREATE TRIGGER audit_t
            AFTER TRUNCATE
            ON %s
            FOR EACH STATEMENT
            EXECUTE FUNCTION audit.truncate_trigger();',
        $1
    );
    pkey_cols TEXT[] = audit.primary_key_columns($1);
BEGIN
    IF pkey_cols = ARRAY[]::TEXT[] THEN
        RAISE EXCEPTION 'Table % cannot be audited because it has no primary key', $1;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_i_u_d') THEN
        EXECUTE statement_row;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_t') THEN
        EXECUTE statement_stmt;
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.enable_tracking IS
'Creates audit triggers (audit_i_u_d for row-level, audit_t for truncate) on the given table.
Raises an exception if the table has no primary key.';

CREATE OR REPLACE FUNCTION audit.disable_tracking(target_table REGCLASS)
    RETURNS VOID
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    statement_row TEXT = format(
        'DROP TRIGGER IF EXISTS audit_i_u_d ON %s;',
        $1
    );
    statement_stmt TEXT = format(
        'DROP TRIGGER IF EXISTS audit_t ON %s;',
        $1
    );
BEGIN
    EXECUTE statement_row;
    EXECUTE statement_stmt;
END;
$$;

COMMENT ON FUNCTION audit.disable_tracking IS
'Removes audit triggers (audit_i_u_d, audit_t) from the given table.';

-- =====================================================
-- STEP 7: DDL event trigger function and event trigger
-- =====================================================

CREATE OR REPLACE FUNCTION audit.log_ddl_event()
RETURNS event_trigger
SET search_path = ''
LANGUAGE plpgsql AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO audit.ddl_history (user_name, command_tag, object_type, object_identity, query_text)
        VALUES (session_user::TEXT, obj.command_tag, COALESCE(obj.object_type, ''), COALESCE(obj.object_identity, ''), current_query());
    END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.log_ddl_event IS
'Event trigger function that captures DDL commands and logs them to audit.ddl_history.';

CREATE EVENT TRIGGER track_ddl_changes
    ON ddl_command_end
    EXECUTE FUNCTION audit.log_ddl_event();

COMMENT ON EVENT TRIGGER track_ddl_changes IS
'Event trigger that fires after any DDL command completes, logging the change to audit.ddl_history.';

-- =====================================================
-- STEP 8: Add audit_log column to entities table
-- =====================================================

ALTER TABLE entities ADD COLUMN IF NOT EXISTS audit_log BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN entities.audit_log IS 'When TRUE, DML operations on this table are logged to audit.record_version';

-- =====================================================
-- STEP 9: Add field metadata for audit_log column
-- =====================================================

INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES
    ('entities', 'audit_log', 'Audit Log', 'When enabled, DML operations on this table are logged to the audit log', 'true', 'boolean', FALSE, 122, 'default', 'default', NULL, TRUE, FALSE, '', '');

-- =====================================================
-- STEP 10: Trigger to manage audit tracking on entity changes
-- =====================================================
-- Handles three scenarios:
--   A) INSERT: enable audit on newly created managed tables
--   B) UPDATE: toggle audit when audit_log changes, or when managed changes
--   C) Rename: audit triggers follow automatically (trigger names are stable: audit_i_u_d, audit_t)

CREATE OR REPLACE FUNCTION manage_audit_log()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Enable audit on newly created managed tables with audit_log=TRUE
        IF NEW.managed AND NEW.audit_log THEN
            -- The physical table must exist (created by create_dd_table trigger)
            IF EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = 'public'
                  AND t.table_name = NEW.table_name
            ) THEN
                PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                RAISE NOTICE 'Enabled audit tracking for new table "%"', NEW.table_name;
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        -- Case 1: audit_log toggled
        IF OLD.audit_log IS DISTINCT FROM NEW.audit_log THEN
            IF NEW.managed THEN
                IF NEW.audit_log THEN
                    PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                    RAISE NOTICE 'Enabled audit tracking for table "%"', NEW.table_name;
                ELSE
                    PERFORM audit.disable_tracking(NEW.table_name::REGCLASS);
                    RAISE NOTICE 'Disabled audit tracking for table "%"', NEW.table_name;
                END IF;
            END IF;
        END IF;

        -- Case 2: managed toggled to TRUE (enable_dd_table creates the physical table)
        -- The enable_table_trigger fires first; by the time this runs the table exists.
        IF OLD.managed = FALSE AND NEW.managed = TRUE AND NEW.audit_log THEN
            IF EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = 'public'
                  AND t.table_name = NEW.table_name
            ) THEN
                PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                RAISE NOTICE 'Enabled audit tracking for newly managed table "%"', NEW.table_name;
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_audit_log IS
'AFTER INSERT/UPDATE trigger on entities: manages audit trigger lifecycle.
On INSERT, enables audit for new managed tables. On UPDATE, toggles audit
when audit_log or managed flags change.';

CREATE TRIGGER manage_audit_log_trigger
    AFTER INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_audit_log();

COMMENT ON TRIGGER manage_audit_log_trigger ON entities IS
'Manages audit trigger lifecycle when entities are created or modified.';

-- =====================================================
-- STEP 11: Enable audit on existing managed entity tables
-- =====================================================
-- For all managed tables that have audit_log=TRUE (which is all, since
-- the column defaults to TRUE), enable audit tracking now.

DO $$
DECLARE
    v_rec RECORD;
BEGIN
    FOR v_rec IN
        SELECT e.table_name FROM entities e
        WHERE e.managed = TRUE
          AND e.audit_log = TRUE
    LOOP
        -- Only enable if the table physically exists in public schema
        IF EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_rec.table_name
        ) THEN
            PERFORM audit.enable_tracking(v_rec.table_name::REGCLASS);
            RAISE NOTICE 'Enabled audit tracking for existing table "%"', v_rec.table_name;
        END IF;
    END LOOP;
END $$;

-- =====================================================
-- STEP 12: RLS on audit tables
-- =====================================================
-- Audit tables should only be readable by admin users via SECURITY DEFINER
-- functions. Block direct SELECT/UPDATE/DELETE through PostgREST.
-- INSERT is allowed for semantius_user because:
--   - DML audit triggers run as SECURITY DEFINER (function owner), so they
--     bypass RLS.  But granting INSERT is harmless and future-proofs things.
--   - DDL event triggers always run in the session security context, so
--     semantius_user needs INSERT on ddl_history when DDL is triggered by
--     SECURITY DEFINER entity management functions.

ALTER TABLE audit.record_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.ddl_history ENABLE ROW LEVEL SECURITY;

-- Allow INSERT so that audit trigger functions (which may fire in
-- semantius_user context) can write audit records.
CREATE POLICY record_version_insert ON audit.record_version
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

CREATE POLICY ddl_history_insert ON audit.ddl_history
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

-- Deny SELECT/UPDATE/DELETE (only SECURITY DEFINER functions can read)
CREATE POLICY record_version_deny_select ON audit.record_version
    FOR SELECT
    TO semantius_user
    USING (false);

CREATE POLICY ddl_history_deny_select ON audit.ddl_history
    FOR SELECT
    TO semantius_user
    USING (false);

-- Grant necessary table permissions to semantius_user
GRANT INSERT ON audit.record_version TO semantius_user;
GRANT INSERT ON audit.ddl_history TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE audit.record_version_id_seq TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE audit.ddl_history_id_seq TO semantius_user;

-- Grant usage on the audit schema to semantius_user (needed for trigger execution)
GRANT USAGE ON SCHEMA audit TO semantius_user;

-- Revoke default PUBLIC execute on audit functions
REVOKE EXECUTE ON FUNCTION audit.primary_key_columns(OID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.to_record_id(OID, TEXT[], JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.insert_update_delete_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.truncate_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.enable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.disable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION manage_audit_log() FROM PUBLIC;
