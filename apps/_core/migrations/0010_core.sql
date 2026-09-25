-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================
-- Repeatable: the extension, the two API roles (guarded), the common schema
-- and its trigger function. The first tables are in 0020_settings.once.sql.

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

-- Create the common schema
CREATE SCHEMA IF NOT EXISTS common;

COMMENT ON SCHEMA common IS 'Shared database objects and functions used across multiple schemas';

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION common.update_updated_at_column()
RETURNS TRIGGER AS $$
DECLARE
    v_ignored TEXT[];
BEGIN
    IF TG_NARGS > 0 THEN
        -- Generated columns are left out of the comparison. A stored or
        -- virtual generated column follows its base columns, so it can never
        -- be the sole reason for a bump, and PostgreSQL leaves its value in
        -- NEW unspecified inside a BEFORE trigger. The catalog read costs one
        -- indexed lookup per row and runs only for tables that opt in.
        SELECT array_agg(attname::text) INTO v_ignored
        FROM pg_attribute
        WHERE attrelid = TG_RELID AND attnum > 0 AND NOT attisdropped AND attgenerated <> '';
        -- Every operand is an array, never a bare string literal:
        -- with an untyped 'updated_at' on the right, PostgreSQL's || operator
        -- resolution picks the anyarray||anyarray candidate and tries to parse
        -- the literal as array syntax, raising "malformed array literal"
        -- instead of appending it as an element.
        v_ignored := TG_ARGV || COALESCE(v_ignored, ARRAY[]::TEXT[]) || ARRAY['updated_at'];
        IF (to_jsonb(NEW) - v_ignored) = (to_jsonb(OLD) - v_ignored) THEN
            NEW.updated_at := OLD.updated_at;
            RETURN NEW;
        END IF;
    END IF;
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = common;

COMMENT ON FUNCTION common.update_updated_at_column() IS 'Trigger function to automatically update updated_at column on row modification. Given trigger arguments, first compares NEW and OLD ignoring updated_at, any generated column and the named arguments; a row that agrees outside those columns leaves updated_at untouched rather than bumping it, so a client cannot move it by resubmitting one either, and tables that pass no arguments keep the unconditional bump.';

-- Explicit: PostgreSQL grants EXECUTE to PUBLIC on every new function, and the
-- default-privilege revoke for `common` in 0020_settings.once.sql cannot take
-- that grant away (the comment there says why). A trigger function needs no EXECUTE
-- privilege to fire: PostgreSQL checks it once, at CREATE TRIGGER time. Every
-- CREATE TRIGGER naming this function is either a plain statement in a migration
-- (0070_rbac_schema.sql, 0140_dd_schema.sql), which the installer runs, or is
-- built by SECURITY DEFINER dictionary code (0160_dd_functions.sql,
-- 0180_managed_enable.sql), which runs as the owner. Both already hold
-- EXECUTE without the PUBLIC grant.
REVOKE EXECUTE ON FUNCTION common.update_updated_at_column() FROM PUBLIC;
