-- =====================================================
-- ADD SEARCHABLE COLUMNS FOR FULL-TEXT SEARCH
-- =====================================================
-- Add searchable columns to fields and tables tables
-- to support full-text search functionality

-- Add searchable column to fields table
ALTER TABLE fields ADD COLUMN IF NOT EXISTS searchable BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN fields.searchable IS 
'Whether this field should be included in full-text search (true for text fields like title, description, email)';

-- Add searchable column to tables table (auto-maintained based on fields)
ALTER TABLE tables ADD COLUMN IF NOT EXISTS searchable BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN tables.searchable IS 
'Auto-maintained flag indicating if any field in this table is searchable. Updated automatically when fields change.';
