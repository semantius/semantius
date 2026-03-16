-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================

-- Ensure the authenticated role exists (abort if it doesn't)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        RAISE EXCEPTION 'The authenticated role does not exist. Please ensure that PostgREST is properly configured to create the authenticated role.';
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

            -- Grant semantius_user to current user
            EXECUTE format('GRANT semantius_user TO %I', current_user);
        
        RAISE NOTICE 'Role semantius_user created with INHERIT and granted authenticated role';
    END IF;
END $$;


-- =====================================================
-- SECURE DEFAULTS: Revoke PUBLIC execute on all future functions
-- =====================================================
-- PostgreSQL grants EXECUTE to PUBLIC by default on all functions.
-- This changes the default so new functions are NOT callable by PUBLIC,
-- preventing accidental privilege escalation via SECURITY DEFINER functions.
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

