-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================

-- Create the authenticated role if it doesn't exist (required for RLS policies)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated;
    END IF;
END
$$;

-- Grant the current user permission to set role to authenticated (required for testing)
GRANT authenticated TO CURRENT_USER;

-- Create the common schema
CREATE SCHEMA IF NOT EXISTS common;

COMMENT ON SCHEMA common IS 'Shared database objects and functions used across multiple schemas';

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION common.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION common.update_updated_at_column() IS 'Trigger function to automatically update updated_at column on row modification';

