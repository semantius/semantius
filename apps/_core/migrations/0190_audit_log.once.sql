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
-- Runs once: the audit schema, its type and the two log tables. The functions,
-- event triggers, policies and grants are in 0200_audit_log.sql, the tables'
-- dictionary rows in 0300_audit_log.jsonc.

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
    db_role        TEXT,
    is_superuser   BOOLEAN,
    client_addr    INET,
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

-- db_role, is_superuser and client_addr describe the CONNECTION that wrote the row, as
-- opposed to user_id, which describes the authenticated principal inside it.
-- They exist because user_id cannot distinguish "no JWT" from "no JWT and a
-- superuser psql session": both log 0. A write through the API carries
-- db_role = the authenticator role and is_superuser = false; anything else got
-- in past the request path.
--
-- All three are read from the backend's own state - a syscache-backed keyword,
-- a GUC, and the connection struct - so they cost no catalog scan, no parse and
-- no allocation, and none of them is settable by the client. Contrast
-- application_name, which is a connection-string parameter and therefore
-- evidence of nothing. They are constant for a session and still read per
-- statement rather than cached: the read is cheaper than the cache would be.
--
-- What they do NOT survive is a superuser who sets session_replication_role to
-- 'replica' before writing, which skips these triggers outright. They raise the
-- cost of an undocumented write; they do not make one impossible.
--
-- is_superuser is read from the GUC here, and 9900_owner_hardening reads
-- pg_roles.rolsuper instead, deliberately: the GUC reports the OUTER user, so
-- under a SECURITY DEFINER function - which every one of these triggers is - it
-- keeps reporting the session rather than the function owner. 9900 needs to know
-- whether the EFFECTIVE user can create a BYPASSRLS role, so the GUC is wrong
-- for it. This column wants the session, which is exactly what the GUC still
-- reports, and reading it costs no catalog access.

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

-- "Show me every privileged write, newest first" is the forensic question these
-- columns exist to answer, and it must stay fast as the table grows. The
-- predicate holds for approximately no rows on a healthy system, so the index
-- stays near-empty and costs nothing to maintain. It is deliberately not
-- predicated on a role NAME: role names are installation-specific, an index
-- predicate is not something a deployment can adjust, and is_superuser is the
-- property that actually matters.
CREATE INDEX IF NOT EXISTS audit_record_logs_superuser
    ON public.audit_record_logs(ts DESC)
    WHERE is_superuser;

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
'Stores schema change events captured by two event triggers: creations and alterations from ddl_command_end, drops from sql_drop, which is the only mechanism that reports them.';

CREATE INDEX IF NOT EXISTS audit_ddl_logs_event_time
    ON public.audit_ddl_logs
    USING BRIN(event_time);

-- =====================================================
-- STEP 11: RLS on audit tables
-- =====================================================
-- Audit tables are in public schema, so PostgREST can expose them.
-- RLS ensures only admin users can access audit data.

ALTER TABLE public.audit_record_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_ddl_logs ENABLE ROW LEVEL SECURITY;

-- Grant usage on the audit schema to semantius_user (needed for trigger execution)
GRANT USAGE ON SCHEMA audit TO semantius_user;
