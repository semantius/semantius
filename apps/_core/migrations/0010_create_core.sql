-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================

-- Enable pgcrypto for gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- Ensure the authenticated role exists (create it if missing)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
        RAISE NOTICE 'Role authenticated created';
    END IF;
END
$$;


-- ======================================================================================================================
-- COMMON SCHEMA - neondb_owner cannot switch to authenticated, add a new role semantius_user inheriting authenticated
-- ======================================================================================================================

DO $$
BEGIN
    -- Check if semantius_user role is missing
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_user') THEN
        
        CREATE ROLE semantius_user INHERIT NOLOGIN;
        
            -- Grant authenticated to semantius_user
            GRANT semantius_user TO authenticated;

            -- Grant semantius_user to the installing role, but never to a
            -- superuser: it already bypasses every check, and the membership
            -- is a test artifact that survives DROP EXTENSION (B11).
            IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) THEN
                EXECUTE format('GRANT semantius_user TO %I', current_user);
            END IF;
        
        RAISE NOTICE 'Role semantius_user created with INHERIT and granted authenticated role';
    END IF;
END $$;


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
-- per function or per schema; 0030 does the whole rbac schema at once, which is
-- the real reason nothing there is PUBLIC-executable. Guard test
-- 0060_test_security.sql fails the moment one is missing.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Create the common schema
CREATE SCHEMA IF NOT EXISTS common;

ALTER DEFAULT PRIVILEGES IN SCHEMA common
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMENT ON SCHEMA common IS 'Shared database objects and functions used across multiple schemas';

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION common.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = common;

COMMENT ON FUNCTION common.update_updated_at_column() IS 'Trigger function to automatically update updated_at column on row modification';

-- Explicit, for the reason given above. A trigger function needs no EXECUTE
-- privilege to fire: PostgreSQL checks it once, at CREATE TRIGGER time. Every
-- CREATE TRIGGER naming this function is either a plain statement in a migration
-- (0020, 0060), which the installer runs, or is built by SECURITY DEFINER
-- dictionary code (0070, 0145), which runs as the owner. Both already hold
-- EXECUTE without the PUBLIC grant.
REVOKE EXECUTE ON FUNCTION common.update_updated_at_column() FROM PUBLIC;

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
