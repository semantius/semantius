-- =====================================================
-- OWNER HARDENING: run the data dictionary as a non-superuser owner
-- =====================================================
-- Every data-dictionary trigger is SECURITY DEFINER and executes DDL as the
-- owner of the functions and tables. Until this migration that owner was
-- whoever installed Semantius core: on self-hosted servers the `postgres`
-- superuser, because the extension needs a superuser to install. Any flaw in
-- the DDL assembly (see the fields.default_value hardening in 0060/0070) would
-- therefore have handed an application administrator superuser powers
-- (COPY ... TO PROGRAM, CREATE ROLE ... SUPERUSER, ALTER SYSTEM).
--
-- This migration moves ownership of everything Semantius core created to a
-- dedicated `semantius_owner` role: NOLOGIN, NOSUPERUSER, NOINHERIT and
-- BYPASSRLS (SECURITY DEFINER code must still read and write every table
-- regardless of RLS). From here on, dictionary code runs with the powers of a
-- schema owner and nothing more; tables, functions and policies the
-- dictionary creates later are owned by the same role, and default privileges
-- FOR ROLE semantius_owner reproduce the grants 0010/0030/0050/0150/0160 set
-- up for the installing role.
--
-- Only a superuser can create a BYPASSRLS role, so the block runs when the
-- installer is a superuser (CREATE EXTENSION, pgdocker, docker-postgres) and
-- is skipped with a NOTICE on managed platforms (Neon, Supabase), where the
-- installing role already is a non-superuser BYPASSRLS owner.
--
-- Objects that belong to other extensions (pgcrypto in public, pgmq when the
-- real extension is present) are left alone. Event triggers are not touched:
-- PostgreSQL requires their owner to be a superuser.

DO $$
DECLARE
    r RECORD;
BEGIN
    IF current_setting('is_superuser') <> 'on' THEN
        RAISE NOTICE 'owner hardening skipped: % is not a superuser, Semantius core objects stay owned by the installing role', current_user;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        CREATE ROLE semantius_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
        COMMENT ON ROLE semantius_owner IS
            'Owner of the Semantius core objects and the role its SECURITY DEFINER dictionary code runs as. NOLOGIN, NOSUPERUSER, BYPASSRLS.';
        RAISE NOTICE 'Role semantius_owner created';
    END IF;

    -- The dictionary creates tables, functions, triggers and policies at runtime.
    GRANT USAGE, CREATE ON SCHEMA public, common, rbac, audit, pgmq TO semantius_owner;

    -- Relations: tables first (their owned sequences and row types follow),
    -- then standalone sequences, then views.
    FOR r IN
        SELECT n.nspname, c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
          AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
          AND pg_get_userbyid(c.relowner) = current_user
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              JOIN pg_extension e ON e.oid = d.refobjid
              WHERE d.classid = 'pg_class'::regclass
                AND d.objid = c.oid
                AND d.refclassid = 'pg_extension'::regclass
                AND d.deptype = 'e'
                AND e.extname <> 'pg_semantius')
        ORDER BY CASE c.relkind WHEN 'r' THEN 0 WHEN 'p' THEN 0 WHEN 'S' THEN 1 ELSE 2 END, n.nspname, c.relname
    LOOP
        -- A sequence owned by a column moves with its table; skip it if it already did.
        IF r.relkind = 'S' AND EXISTS (
            SELECT 1 FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
            WHERE n2.nspname = r.nspname AND c2.relname = r.relname
              AND pg_get_userbyid(c2.relowner) = 'semantius_owner') THEN
            CONTINUE;
        END IF;
        EXECUTE format('ALTER %s %I.%I OWNER TO semantius_owner',
            CASE r.relkind
                WHEN 'S' THEN 'SEQUENCE'
                WHEN 'v' THEN 'VIEW'
                WHEN 'm' THEN 'MATERIALIZED VIEW'
                ELSE 'TABLE'
            END,
            r.nspname, r.relname);
    END LOOP;

    -- Functions and procedures (this is what makes SECURITY DEFINER code run as semantius_owner).
    FOR r IN
        SELECT p.oid::regprocedure AS signature, p.prokind
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
          AND pg_get_userbyid(p.proowner) = current_user
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              JOIN pg_extension e ON e.oid = d.refobjid
              WHERE d.classid = 'pg_proc'::regclass
                AND d.objid = p.oid
                AND d.refclassid = 'pg_extension'::regclass
                AND d.deptype = 'e'
                AND e.extname <> 'pg_semantius')
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO semantius_owner',
            CASE r.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
            r.signature);
    END LOOP;

    -- Standalone types: enums, domains, ranges and free-standing composite types
    -- (table row types moved with their tables).
    FOR r IN
        SELECT t.oid::regtype AS type_name, t.typtype
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
          AND pg_get_userbyid(t.typowner) = current_user
          AND (
              t.typtype IN ('e', 'd', 'r')
              OR (t.typtype = 'c' AND EXISTS (
                  SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'))
          )
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              JOIN pg_extension e ON e.oid = d.refobjid
              WHERE d.classid = 'pg_type'::regclass
                AND d.objid = t.oid
                AND d.refclassid = 'pg_extension'::regclass
                AND d.deptype = 'e'
                AND e.extname <> 'pg_semantius')
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO semantius_owner',
            CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
            r.type_name);
    END LOOP;

    -- Objects the dictionary creates from now on are owned by semantius_owner:
    -- reproduce the default privileges that 0010, 0030, 0050, 0150 and 0160
    -- established for the installing role.
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO semantius_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO semantius_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA public
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA common
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA audit
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA rbac
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA rbac
        GRANT EXECUTE ON FUNCTIONS TO semantius_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA pgmq
        GRANT SELECT ON TABLES TO pg_monitor;
    ALTER DEFAULT PRIVILEGES FOR ROLE semantius_owner IN SCHEMA pgmq
        GRANT SELECT ON SEQUENCES TO pg_monitor;

    RAISE NOTICE 'Semantius core objects are now owned by semantius_owner';
END $$;
