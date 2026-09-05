-- =====================================================
-- AUDIT LOG SYSTEM
-- =====================================================
-- Provides comprehensive audit logging for DML operations (INSERT, UPDATE,
-- DELETE, TRUNCATE) on managed entity tables and DDL schema changes.
--
-- Based on the supa_audit pattern (https://github.com/supabase/supa_audit)
-- but integrated directly into _core rather than as an extension.
--
-- All audit tables live in public schema (no separate audit namespace).
--
-- Features:
--   1. Per-table DML audit: enabled/disabled via entities.audit_log toggle
--   2. DDL audit: captures schema changes via event trigger
--   3. Automatic audit trigger management when entities are created/deleted
--   4. Audit trigger renamed when entities are renamed

-- =====================================================
-- STEP 1: Create audit schema (internal functions only)
-- =====================================================
-- The audit schema is used ONLY for internal helper functions and types.
-- The actual audit tables live in public schema for standard API access.

CREATE SCHEMA IF NOT EXISTS audit;

ALTER DEFAULT PRIVILEGES IN SCHEMA audit
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMENT ON SCHEMA audit IS 'Internal audit helper functions and types (tables are in public schema)';

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
-- STEP 2: Create DML audit table (audit_record_logs)
-- =====================================================

CREATE TABLE IF NOT EXISTS public.audit_record_logs (
    id             BIGSERIAL PRIMARY KEY,
    record_id      UUID,
    old_record_id  UUID,
    record_pk      TEXT NOT NULL DEFAULT '',
    op             audit.operation NOT NULL,
    ts             TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id        INTEGER NOT NULL DEFAULT 0,
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

COMMENT ON TABLE public.audit_record_logs IS
'Stores DML audit records for entity tables with audit_log enabled.
Each row captures the operation type, the full record (new/old), and metadata.';

COMMENT ON COLUMN public.audit_record_logs.record_pk IS 'Primary key value of the affected record for easy lookup';
COMMENT ON COLUMN public.audit_record_logs.user_id IS 'Internal user id from JWT (rbac.user_id). 0 when no JWT context.';

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS audit_record_logs_record_id
    ON public.audit_record_logs(record_id)
    WHERE record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS audit_record_logs_old_record_id
    ON public.audit_record_logs(old_record_id)
    WHERE old_record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS audit_record_logs_ts
    ON public.audit_record_logs
    USING BRIN(ts);

CREATE INDEX IF NOT EXISTS audit_record_logs_table_oid
    ON public.audit_record_logs(table_oid);

CREATE INDEX IF NOT EXISTS audit_record_logs_record_pk
    ON public.audit_record_logs(record_pk)
    WHERE record_pk != '';

-- =====================================================
-- STEP 3: Create DDL audit table (audit_ddl_logs)
-- =====================================================

CREATE TABLE IF NOT EXISTS public.audit_ddl_logs (
    id              BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id         INTEGER NOT NULL DEFAULT 0,
    command_tag     TEXT NOT NULL DEFAULT '',
    object_type     TEXT NOT NULL DEFAULT '',
    object_identity TEXT NOT NULL DEFAULT '',
    query_text      TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE public.audit_ddl_logs IS
'Stores DDL schema change events captured by the ddl_command_end event trigger.';

COMMENT ON COLUMN public.audit_ddl_logs.user_id IS 'Internal user id from JWT (rbac.user_id). 0 when no JWT context (e.g. migrations).';

CREATE INDEX IF NOT EXISTS audit_ddl_logs_event_time
    ON public.audit_ddl_logs
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
'Computes a deterministic UUID from a table OID and primary key values, enabling
indexed lookup of a record''s full version history.';

-- Helper: extract primary key value as text from a jsonb record
CREATE OR REPLACE FUNCTION audit.extract_record_pk(pkey_cols TEXT[], rec JSONB)
    RETURNS TEXT
    STABLE
    LANGUAGE sql
    SET search_path = public
AS $$
    SELECT
        CASE
            WHEN rec IS NULL THEN ''
            WHEN pkey_cols = ARRAY[]::TEXT[] THEN ''
            WHEN array_length(pkey_cols, 1) = 1 THEN COALESCE(rec ->> pkey_cols[1], '')
            ELSE COALESCE(
                (SELECT string_agg(COALESCE(rec ->> key_, ''), ':' ORDER BY ord)
                 FROM unnest(pkey_cols) WITH ORDINALITY AS x(key_, ord)),
                ''
            )
        END
$$;

COMMENT ON FUNCTION audit.extract_record_pk IS
'Extracts the primary key value(s) from a JSONB record as a text string.
For single-column PKs, returns the value directly. For composite PKs, returns colon-separated values.';

-- Helper: safely get current user_id from JWT context, returning 0 when unavailable
CREATE OR REPLACE FUNCTION audit.current_user_id()
    RETURNS INTEGER
    STABLE
    LANGUAGE plpgsql
    SET search_path = public
AS $$
BEGIN
    -- Derived through rbac (lazy context initialization), never read raw from
    -- the client-writable app.current_user_id setting. NULL (no authenticated
    -- user, e.g. during migrations) becomes 0.
    RETURN COALESCE(rbac.user_id_or_null(), 0);
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END;
$$;

COMMENT ON FUNCTION audit.current_user_id IS
'Safely returns the current JWT user_id from app context, or 0 when no JWT context is available (e.g. during migrations).';

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
    v_record_pk TEXT;
    v_user_id INTEGER;
BEGIN
    -- Only ever reached for UPDATE, where both images exist; the CHECK
    -- constraints on audit_record_logs require both, which is why this event is
    -- not folded into the statement-level triggers. COALESCE keeps the
    -- expression total rather than relying on that.
    v_record_pk := audit.extract_record_pk(pkey_cols, COALESCE(record_jsonb, old_record_jsonb));
    v_user_id := audit.current_user_id();

    INSERT INTO public.audit_record_logs(
        record_id,
        old_record_id,
        record_pk,
        op,
        user_id,
        table_oid,
        table_schema,
        table_name,
        record,
        old_record
    )
    SELECT
        record_id,
        old_record_id,
        v_record_pk,
        TG_OP::audit.operation,
        v_user_id,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        record_jsonb,
        old_record_jsonb;

    RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION audit.insert_update_delete_trigger IS
'Row-level AFTER UPDATE trigger function that logs updates to audit_record_logs.
Captures the JWT user_id and primary key value. INSERT and DELETE are logged by
the statement-level functions in this schema.';

-- INSERT and DELETE are logged one statement at a time. The work the row-level
-- function repeats per row - the catalog lookup for the primary key columns and
-- the resolution of the acting user - is constant for the whole statement, and
-- the rows themselves arrive as a set that can be inserted with a single
-- INSERT ... SELECT.
--
-- UPDATE is row-level. An update log entry carries the before
-- and after image of the same row, and the CHECK constraints on
-- audit_record_logs require both. A transition table is an unordered set whose
-- only join key is the primary key - which is exactly what old_record_id exists
-- to track changing. entities.table_name is a primary key that rename_dd_table
-- rewrites, and entities is audited, so pairing the two images by key would
-- silently attach the wrong before-image to a renamed row in a table whose whole
-- purpose is evidence.
--
-- new_rows and old_rows below are transition tables: ephemeral named relations
-- resolved from the query environment, not through search_path. They are the one
-- kind of name that cannot be schema-qualified, which is why they appear bare in
-- functions that otherwise qualify every identifier.

CREATE OR REPLACE FUNCTION audit.insert_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    pkey_cols TEXT[] = audit.primary_key_columns(TG_RELID);
    v_user_id INTEGER = audit.current_user_id();
BEGIN
    INSERT INTO public.audit_record_logs(
        record_id,
        old_record_id,
        record_pk,
        op,
        user_id,
        table_oid,
        table_schema,
        table_name,
        record,
        old_record
    )
    SELECT
        audit.to_record_id(TG_RELID, pkey_cols, to_jsonb(r)),
        NULL,
        audit.extract_record_pk(pkey_cols, to_jsonb(r)),
        'INSERT'::audit.operation,
        v_user_id,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        to_jsonb(r),
        NULL
    FROM new_rows r;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION audit.insert_trigger IS
'Statement-level AFTER INSERT trigger function that logs every inserted row to
audit_record_logs in one statement. Captures the JWT user_id and primary key value.';

CREATE OR REPLACE FUNCTION audit.delete_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    pkey_cols TEXT[] = audit.primary_key_columns(TG_RELID);
    v_user_id INTEGER = audit.current_user_id();
BEGIN
    INSERT INTO public.audit_record_logs(
        record_id,
        old_record_id,
        record_pk,
        op,
        user_id,
        table_oid,
        table_schema,
        table_name,
        record,
        old_record
    )
    SELECT
        NULL,
        audit.to_record_id(TG_RELID, pkey_cols, to_jsonb(r)),
        audit.extract_record_pk(pkey_cols, to_jsonb(r)),
        'DELETE'::audit.operation,
        v_user_id,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        NULL,
        to_jsonb(r)
    FROM old_rows r;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION audit.delete_trigger IS
'Statement-level AFTER DELETE trigger function that logs every deleted row to
audit_record_logs in one statement. Captures the JWT user_id and primary key value.';

CREATE OR REPLACE FUNCTION audit.truncate_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.audit_record_logs(
        op,
        user_id,
        table_oid,
        table_schema,
        table_name
    )
    SELECT
        TG_OP::audit.operation,
        audit.current_user_id(),
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME;

    RETURN COALESCE(OLD, NEW);
END;
$$;

COMMENT ON FUNCTION audit.truncate_trigger IS
'Statement-level AFTER trigger function that logs TRUNCATE operations to audit_record_logs.';

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
    -- The four trigger names are fixed literals rather than derived from the
    -- table name. That is what makes renaming an audited table free: the
    -- triggers follow the table and nothing has to be rebuilt.
    --
    -- audit_i and audit_d carry a REFERENCING clause, so they must be dropped
    -- and recreated rather than replaced when their shape changes; CREATE
    -- TRIGGER without OR REPLACE fails loudly on a name that already exists,
    -- which is what the existence checks below are for.
    statement_ins TEXT = format('
        CREATE TRIGGER audit_i
            AFTER INSERT
            ON %s
            REFERENCING NEW TABLE AS new_rows
            FOR EACH STATEMENT
            EXECUTE FUNCTION audit.insert_trigger();',
        $1
    );
    statement_upd TEXT = format('
        CREATE TRIGGER audit_i_u_d
            AFTER UPDATE
            ON %s
            FOR EACH ROW
            EXECUTE FUNCTION audit.insert_update_delete_trigger();',
        $1
    );
    statement_del TEXT = format('
        CREATE TRIGGER audit_d
            AFTER DELETE
            ON %s
            REFERENCING OLD TABLE AS old_rows
            FOR EACH STATEMENT
            EXECUTE FUNCTION audit.delete_trigger();',
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
    v_has_row_trigger BOOLEAN;
BEGIN
    IF pkey_cols = ARRAY[]::TEXT[] THEN
        RAISE EXCEPTION 'Table % cannot be audited because it has no primary key', $1;
    END IF;

    -- audit_i_u_d is the UPDATE trigger. A trigger of that name that also fires
    -- on INSERT or DELETE would log those events a second time once audit_i and
    -- audit_d are present, so it is dropped and rebuilt narrow rather than
    -- accepted as already there. Bits 0x04 INSERT and 0x08 DELETE, tested
    -- together: either one is enough to double-log.
    SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_i_u_d')
      INTO v_has_row_trigger;

    IF v_has_row_trigger AND EXISTS(
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = $1 AND tgname = 'audit_i_u_d'
          AND (tgtype & 12) <> 0
    ) THEN
        EXECUTE format('DROP TRIGGER audit_i_u_d ON %s', $1);
        v_has_row_trigger := FALSE;
    END IF;

    -- The checks below are name-only: a trigger already present is left exactly
    -- as it is. Changing the shape of audit_i, audit_d or audit_t therefore
    -- reaches only tables that do not yet carry it; an existing table needs
    -- disable_tracking() first.
    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_i') THEN
        EXECUTE statement_ins;
    END IF;

    IF NOT v_has_row_trigger THEN
        EXECUTE statement_upd;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_d') THEN
        EXECUTE statement_del;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_t') THEN
        EXECUTE statement_stmt;
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.enable_tracking IS
'Creates audit triggers on the given table: audit_i and audit_d statement-level for
INSERT and DELETE, audit_i_u_d row-level for UPDATE, audit_t for truncate.
Raises an exception if the table has no primary key.';

CREATE OR REPLACE FUNCTION audit.disable_tracking(target_table REGCLASS)
    RETURNS VOID
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    v_name TEXT;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['audit_i', 'audit_i_u_d', 'audit_d', 'audit_t']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_name, $1);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.disable_tracking IS
'Removes all audit triggers (audit_i, audit_i_u_d, audit_d, audit_t) from the given table.';

-- =====================================================
-- STEP 7: DDL event trigger function and event trigger
-- =====================================================

-- Scoped DDL audit. SECURITY DEFINER because the function calls
-- audit.current_user_id(), which is revoked from PUBLIC: without it the
-- request role cannot run any DDL at all, not even CREATE TEMP TABLE. The
-- other two audit triggers in this file are already definers.
--
-- Three filters, in the order they are applied:
--   1. in_extension - objects an extension script created belong to that
--      extension, not to this database's schema history.
--   2. schema scope - only the schemas Semantius owns are evidence. DDL in a
--      foreign schema, and temp objects (reported as schema 'pg_temp' here,
--      'pg_temp_N' in the catalog), are not ours to record. A NULL
--      schema_name is deliberately NOT filtered: GRANT, REVOKE and ALTER
--      DEFAULT PRIVILEGES report no schema, no classid, no objid and no object
--      identity - there is nothing to scope them by - and dropping them would
--      throw away the privilege history this table exists to keep. CREATE
--      SCHEMA also reports no schema (its identity is the new schema's name),
--      so creating a schema is always logged, foreign ones included.
--   3. generated label companions - rebuild_entity_label_functions (0145)
--      drops and recreates the whole set of <name>_label(rowtype) functions on
--      any field edit, so these events are churn, not history. This reaches
--      only the CREATE/ALTER FUNCTION and COMMENT events: the matching GRANT
--      and REVOKE events carry a NULL object_identity, so roughly half the
--      churn is unfilterable by any predicate this function can see.
--      Conversely the pattern is a suffix match, so a hand-written function
--      named <something>_label in one of the five schemas is not audited
--      either, and an entity whose name needs quoting is (the quote sits
--      between _label and the paren). Neither occurs today.
-- query_text is bounded: current_query() is the entire migration script for
-- script-driven DDL, stored once per event.
CREATE OR REPLACE FUNCTION audit.log_ddl_event()
RETURNS event_trigger
SECURITY DEFINER
SET search_path = ''
LANGUAGE plpgsql AS $$
DECLARE
    obj RECORD;
    v_user_id INTEGER;
BEGIN
    v_user_id := audit.current_user_id();
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        CONTINUE WHEN obj.in_extension;
        CONTINUE WHEN obj.schema_name IS NOT NULL
                  AND (starts_with(obj.schema_name, 'pg_temp')
                       OR obj.schema_name NOT IN ('public', 'common', 'rbac', 'audit', 'pgmq'));
        -- Bracket expressions, not backslash escapes: the body is re-parsed at
        -- first execution, so a session with standard_conforming_strings = off
        -- would otherwise turn this pattern into an invalid regexp.
        CONTINUE WHEN obj.object_type = 'function'
                  AND obj.object_identity ~ '(^|[.])[^.(]*_label[(]';
        INSERT INTO public.audit_ddl_logs (user_id, command_tag, object_type, object_identity, query_text)
        VALUES (v_user_id, obj.command_tag, COALESCE(obj.object_type, ''), COALESCE(obj.object_identity, ''),
                left(current_query(), 8192));
    END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.log_ddl_event IS
'Event trigger function that captures DDL commands and logs them to audit_ddl_logs with JWT user_id.';

-- The tag allowlist keeps the trigger from firing at all for commands that
-- cannot change the schema Semantius manages. It is deliberately broad: every
-- CREATE/ALTER of a database-local schema object, plus the privilege and
-- documentation commands. ddl_command_end reports no rows for DROP commands
-- (dropped objects are only visible to a sql_drop trigger), so DROP tags would
-- be dead weight here.
CREATE EVENT TRIGGER track_ddl_changes
    ON ddl_command_end
    WHEN TAG IN (
      'CREATE SCHEMA', 'ALTER SCHEMA'
    , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
    , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
    , 'CREATE VIEW', 'ALTER VIEW'
    , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
    , 'CREATE SEQUENCE', 'ALTER SEQUENCE'
    , 'CREATE INDEX', 'ALTER INDEX'
    , 'CREATE FUNCTION', 'ALTER FUNCTION'
    , 'CREATE PROCEDURE', 'ALTER PROCEDURE'
    , 'CREATE TRIGGER', 'ALTER TRIGGER'
    , 'CREATE POLICY', 'ALTER POLICY'
    , 'CREATE TYPE', 'ALTER TYPE'
    , 'CREATE DOMAIN', 'ALTER DOMAIN'
    , 'CREATE RULE', 'ALTER RULE'
    , 'CREATE EXTENSION', 'ALTER EXTENSION'
    , 'GRANT', 'REVOKE', 'ALTER DEFAULT PRIVILEGES'
    , 'SECURITY LABEL', 'COMMENT'
    )
    EXECUTE FUNCTION audit.log_ddl_event();

COMMENT ON EVENT TRIGGER track_ddl_changes IS
'Event trigger that fires after any DDL command completes, logging the change to audit_ddl_logs.';

-- =====================================================
-- STEP 8: audit_log column on entities
-- =====================================================
-- Column was added in 0060_dd_schema.sql. Nothing to do here.

-- =====================================================
-- STEP 9: Add field metadata for audit_log column
-- =====================================================

INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('entities', 'audit_log', 'Audit Log', 'When enabled, DML operations on this table are logged to the audit log', 'false', 'boolean', FALSE, 122, 'default', 'default', 'core', FALSE, '', '');

-- =====================================================
-- STEP 10: Register audit tables as entities (managed=false)
-- =====================================================
-- These are core system tables. managed=false means no DDL triggers fire
-- when inserting into entities, but having entries in entities/fields makes
-- them queryable through the standard API (get_schema, etc.).

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES
    ('audit_record_logs', 'audit_record_log', 'Audit Record Log', 'Audit Record Logs', 'DML audit trail for entity table records', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'table_name', FALSE),
    ('audit_ddl_logs', 'audit_ddl_log', 'Audit DDL Log', 'Audit DDL Logs', 'DDL audit trail for schema change events', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'command_tag', FALSE);

-- Field metadata for audit_record_logs
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('audit_record_logs', 'id',            'Id',            '',                                                                  'int64',     TRUE,  1,   'readonly', 'default', 'id',    FALSE, '', ''),
    ('audit_record_logs', 'record_id',     'Record Id',     'Deterministic UUID computed from table OID and primary key values', 'uuid',      FALSE, 10,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'old_record_id', 'Old Record Id', 'Record id before update/delete',                                   'uuid',      FALSE, 20,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'record_pk',     'Record PK',     'Primary key value of the affected record',                          'text',      FALSE, 25,  'readonly', 'default', 'core',  TRUE,  '', ''),
    ('audit_record_logs', 'op',            'Operation',     'DML operation type: INSERT, UPDATE, DELETE, TRUNCATE',               'text',      FALSE, 30,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'ts',            'Timestamp',     'When the operation occurred',                                        'date-time', FALSE, 40,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'user_id',       'User Id',       'Internal user id from JWT context (0 when unavailable)',             'int32',     FALSE, 50,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'table_oid',     'Table OID',     'PostgreSQL internal object identifier for the table',                'int32',     FALSE, 60,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_record_logs', 'table_schema',  'Table Schema',  'Schema containing the table',                                       'text',      FALSE, 70,  'readonly', 'default', 'core',  TRUE,  '', ''),
    ('audit_record_logs', 'table_name',    'Table Name',    'Name of the affected table',                                        'text',      FALSE, 80,  'readonly', 'default', 'label', TRUE,  '', ''),
    ('audit_record_logs', 'record',        'Record',        'Full record after INSERT/UPDATE (JSONB)',                            'json',      FALSE, 90,  'readonly', 'w',       'core',  FALSE, '', ''),
    ('audit_record_logs', 'old_record',    'Old Record',    'Previous record before UPDATE/DELETE (JSONB)',                       'json',      FALSE, 100, 'readonly', 'w',       'core',  FALSE, '', '');

-- Field metadata for audit_ddl_logs
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('audit_ddl_logs', 'id',              'Id',              '',                                                                'int64',     TRUE,  1,   'readonly', 'default', 'id',    FALSE, '', ''),
    ('audit_ddl_logs', 'event_time',      'Event Time',      'When the DDL command completed',                                  'date-time', FALSE, 10,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_ddl_logs', 'user_id',         'User Id',         'Internal user id from JWT context (0 when unavailable)',           'int32',     FALSE, 20,  'readonly', 'default', 'core',  FALSE, '', ''),
    ('audit_ddl_logs', 'command_tag',     'Command Tag',     'DDL command type (e.g. CREATE TABLE, ALTER TABLE)',                'text',      FALSE, 30,  'readonly', 'default', 'label', TRUE,  '', ''),
    ('audit_ddl_logs', 'object_type',     'Object Type',     'Type of database object affected',                                'text',      FALSE, 40,  'readonly', 'default', 'core',  TRUE,  '', ''),
    ('audit_ddl_logs', 'object_identity', 'Object Identity', 'Fully qualified name of the affected object',                     'text',      FALSE, 50,  'readonly', 'w',       'core',  TRUE,  '', ''),
    ('audit_ddl_logs', 'query_text',      'Query Text',      'The SQL statement that triggered the event',                      'text',      FALSE, 60,  'readonly', 'w',       'core',  FALSE, '', '');

-- =====================================================
-- STEP 11: Trigger to manage audit tracking on entity changes
-- =====================================================
-- Handles three scenarios:
--   A) INSERT: enable audit on newly created managed tables
--   B) UPDATE: toggle audit when audit_log changes, or when managed changes
--   C) Rename: audit triggers follow automatically (trigger names are stable:
--      audit_i, audit_i_u_d, audit_d, audit_t)

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
-- STEP 12: Enable audit for _core tables
-- =====================================================
-- Enable audit_log on all _core entities (system tables).
-- These don't have physical audit triggers added yet because
-- audit_log was default FALSE and they were inserted in earlier
-- migrations, but they DO have physical tables.

UPDATE entities SET audit_log = TRUE
WHERE table_name IN (
    'entities', 'fields', 'users', 'modules', 'roles', 'permissions',
    'user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy'
);

-- Now enable tracking on those tables that are managed and have physical tables
DO $$
DECLARE
    v_rec RECORD;
BEGIN
    FOR v_rec IN
        SELECT e.table_name FROM entities e
        WHERE e.managed = FALSE  -- _core tables are managed=false
          AND e.audit_log = TRUE
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_rec.table_name
        ) THEN
            PERFORM audit.enable_tracking(v_rec.table_name::REGCLASS);
            RAISE NOTICE 'Enabled audit tracking for core table "%"', v_rec.table_name;
        END IF;
    END LOOP;
END $$;

-- =====================================================
-- STEP 13: RLS on audit tables
-- =====================================================
-- Audit tables are in public schema, so PostgREST can expose them.
-- RLS ensures only admin users can access audit data.

ALTER TABLE public.audit_record_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_ddl_logs ENABLE ROW LEVEL SECURITY;

-- Allow all operations for admin users
CREATE POLICY audit_record_logs_select ON public.audit_record_logs
    FOR SELECT
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

CREATE POLICY audit_record_logs_insert ON public.audit_record_logs
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

CREATE POLICY audit_record_logs_delete ON public.audit_record_logs
    FOR DELETE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

CREATE POLICY audit_ddl_logs_select ON public.audit_ddl_logs
    FOR SELECT
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

CREATE POLICY audit_ddl_logs_insert ON public.audit_ddl_logs
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

CREATE POLICY audit_ddl_logs_delete ON public.audit_ddl_logs
    FOR DELETE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

-- Grant necessary table permissions to semantius_user
GRANT SELECT, INSERT, DELETE ON public.audit_record_logs TO semantius_user;
GRANT SELECT, INSERT, DELETE ON public.audit_ddl_logs TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE public.audit_record_logs_id_seq TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE public.audit_ddl_logs_id_seq TO semantius_user;

-- Grant usage on the audit schema to semantius_user (needed for trigger execution)
GRANT USAGE ON SCHEMA audit TO semantius_user;

-- Revoke default PUBLIC execute on audit functions
REVOKE EXECUTE ON FUNCTION audit.primary_key_columns(OID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.to_record_id(OID, TEXT[], JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.extract_record_pk(TEXT[], JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.current_user_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.insert_update_delete_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.insert_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.delete_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.truncate_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.log_ddl_event() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.enable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.disable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION manage_audit_log() FROM PUBLIC;
