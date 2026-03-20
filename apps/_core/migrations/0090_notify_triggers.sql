-- =====================================================
-- POSTGREST SCHEMA RELOAD NOTIFICATIONS
-- =====================================================
-- Send NOTIFY pgrst commands when tables or fields are modified.
-- All notifications go through common.refresh_schema_cache() which
-- also keeps the db_version timestamp in _settings up to date.
-- =====================================================

-- =====================================================
-- COMMON: SCHEMA CACHE REFRESH
-- =====================================================
-- Central function called by all DDL and DML triggers.
-- Sends NOTIFY pgrst, 'reload schema' and writes the current
-- timestamp into _settings(name='db_version') so clients can
-- detect that the schema has changed without polling PostgREST.

CREATE OR REPLACE FUNCTION common.refresh_schema_cache() RETURNS void AS $$
DECLARE
    v_db_version_ts TEXT;
    v_current       TEXT;
BEGIN
    -- ISO 8601 datetime without JSON quoting
    v_db_version_ts := clock_timestamp()::text;

    -- Update db_version only when the stored value is outdated (or missing)
    SELECT value INTO v_current FROM _settings WHERE name = 'db_version';
    IF NOT FOUND OR v_current < v_db_version_ts THEN
        INSERT INTO _settings (name, value) VALUES ('db_version', v_db_version_ts)
        ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    -- Notify PostgREST to reload its schema cache
    NOTIFY pgrst, 'reload schema';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, common;

COMMENT ON FUNCTION common.refresh_schema_cache() IS
'Notifies PostgREST to reload its schema cache and updates the db_version timestamp in _settings.';

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON TABLES CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_tables()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM common.refresh_schema_cache();

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_tables IS
'Trigger function that notifies PostgREST to reload schema when entities are modified.';

-- Apply trigger on entities table
CREATE TRIGGER notify_pgrst_on_tables_change
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_tables();

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON FIELDS CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_fields()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM common.refresh_schema_cache();

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_fields IS
'Trigger function that notifies PostgREST to reload schema when fields are modified.';

-- Apply trigger on fields table
CREATE TRIGGER notify_pgrst_on_fields_change
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_fields();

-- =====================================================
-- DDL EVENT TRIGGERS: NOTIFY ON SCHEMA CHANGES
-- =====================================================
-- Fire on every DDL command that PostgREST cares about so its
-- schema cache stays in sync automatically.

-- Watch CREATE and ALTER commands
CREATE OR REPLACE FUNCTION pgrst_ddl_watch() RETURNS event_trigger AS $$
DECLARE
    cmd record;
BEGIN
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.command_tag IN (
          'CREATE SCHEMA', 'ALTER SCHEMA'
        , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
        , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
        , 'CREATE VIEW', 'ALTER VIEW'
        , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
        , 'CREATE FUNCTION', 'ALTER FUNCTION'
        , 'CREATE TRIGGER'
        , 'CREATE TYPE', 'ALTER TYPE'
        , 'CREATE RULE'
        , 'COMMENT'
        )
        -- don't notify for CREATE TEMP table or other pg_temp objects
        AND cmd.schema_name IS DISTINCT FROM 'pg_temp'
        THEN
            PERFORM common.refresh_schema_cache();
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Watch DROP commands
CREATE OR REPLACE FUNCTION pgrst_drop_watch() RETURNS event_trigger AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        IF obj.object_type IN (
          'schema'
        , 'table'
        , 'foreign table'
        , 'view'
        , 'materialized view'
        , 'function'
        , 'trigger'
        , 'type'
        , 'rule'
        )
        AND obj.is_temporary IS false -- no pg_temp objects
        THEN
            PERFORM common.refresh_schema_cache();
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER pgrst_ddl_watch
    ON ddl_command_end
    EXECUTE PROCEDURE pgrst_ddl_watch();

CREATE EVENT TRIGGER pgrst_drop_watch
    ON sql_drop
    EXECUTE PROCEDURE pgrst_drop_watch();

-- Revoke default PUBLIC execute on notify trigger functions
REVOKE EXECUTE ON FUNCTION notify_pgrst_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION notify_pgrst_fields() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgrst_ddl_watch() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgrst_drop_watch() FROM PUBLIC;

-- Allow semantius_user to call common.refresh_schema_cache() so that DML
-- triggers on entities/fields (which fire in the session user's context) can
-- invoke the function.  The function itself is SECURITY DEFINER, so it
-- always runs as the owner and is the only code that touches _settings.
GRANT USAGE ON SCHEMA common TO semantius_user;
GRANT EXECUTE ON FUNCTION common.refresh_schema_cache() TO semantius_user;
