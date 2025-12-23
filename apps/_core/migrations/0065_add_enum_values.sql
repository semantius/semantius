-- =====================================================
-- ADD ENUM VALUES SUPPORT
-- =====================================================
-- Add enum_values column to fields table to support enum types

ALTER TABLE fields ADD COLUMN IF NOT EXISTS enum_values JSONB DEFAULT NULL;

COMMENT ON COLUMN fields.enum_values IS 
'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';
