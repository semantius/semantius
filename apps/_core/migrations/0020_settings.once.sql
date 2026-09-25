-- =====================================================
-- DEFAULT PRIVILEGES AND THE _SETTINGS TABLE
-- =====================================================
-- Runs once: CREATE TABLE cannot run a second time.

-- =====================================================
-- SECURE DEFAULTS: Revoke PUBLIC execute on all future functions
-- =====================================================
-- PostgreSQL grants EXECUTE to PUBLIC by default on every new function, which
-- is how a SECURITY DEFINER function becomes callable by an unauthenticated
-- session.
--
-- These two statements do NOT close that, and nothing in this tree may rely on
-- them. pg_default_acl records the privileges a schema ADDS to the built-in
-- default; a revoke of the built-in PUBLIC grant is not representable there, so
-- it is dropped and the next function created in the schema is world-executable
-- again. That holds whether or not the schema also carries a GRANT: `rbac` has
-- one, its pg_default_acl row exists and does hand EXECUTE to semantius_user,
-- and a function created under it still comes out with PUBLIC in its ACL. The
-- statements are kept because they cost nothing and a future PostgreSQL may
-- honor them.
--
-- What actually protects a function is an explicit REVOKE EXECUTE FROM PUBLIC,
-- per function or per schema; 0080_rbac_functions.sql does the whole rbac schema
-- at once, which is
-- the real reason nothing there is PUBLIC-executable. Guard test
-- 0900_test_security.sql fails the moment one is missing.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA common
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- =====================================================
-- _SETTINGS TABLE
-- =====================================================
-- Stores system-level configuration key/value pairs.
-- RLS is enabled with an explicit deny-all policy so that
-- the table is never exposed through PostgREST / the Data API.
-- SECURITY DEFINER functions (e.g. rbac.uid(), common.refresh_schema_cache())
-- can still read and write it because they run as the function owner
-- who has BYPASSRLS privilege.

CREATE TABLE _settings (
    name  TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);

ALTER TABLE _settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY settings_deny_all ON _settings
    FOR ALL
    TO semantius_user
    USING (false)
    WITH CHECK (false);
