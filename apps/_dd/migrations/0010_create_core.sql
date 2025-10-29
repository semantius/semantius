-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================

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


CREATE TABLE _tables (
    name TEXT PRIMARY KEY
);

CREATE TABLE _fields (
    table_name TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    column_type TEXT,
    PRIMARY KEY (table_name, name),
    FOREIGN KEY (table_name) REFERENCES _tables(name) ON DELETE CASCADE
);