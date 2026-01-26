-- =====================================================
-- ADD ENUM VALUES SUPPORT
-- =====================================================
-- Add enum_values column to fields table to support enum types

ALTER TABLE fields ADD COLUMN IF NOT EXISTS enum_values JSONB DEFAULT NULL;

COMMENT ON COLUMN fields.enum_values IS 
'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';

-- =====================================================
-- ADD FOREIGN KEY SUPPORT
-- =====================================================
-- Add columns to support foreign key relationships

-- Add reference_table column - references tables.table_name
ALTER TABLE fields ADD COLUMN IF NOT EXISTS reference_table TEXT DEFAULT '';

-- Add reference_delete_mode column - controls ON DELETE behavior
ALTER TABLE fields ADD COLUMN IF NOT EXISTS reference_delete_mode TEXT NOT NULL DEFAULT 'restrict';

-- Add foreign key constraint from reference_table to tables.table_name
-- ON DELETE depends on reference_delete_mode: 'restrict' -> RESTRICT, 'clear' -> SET NULL
DO $$
BEGIN
    -- Add foreign key if it doesn't exist
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'fields_reference_table_fkey'
    ) THEN
        ALTER TABLE fields 
        ADD CONSTRAINT fields_reference_table_fkey 
        FOREIGN KEY (reference_table) 
        REFERENCES tables(table_name) 
        ON DELETE RESTRICT;
    END IF;
END $$;

-- Add constraint to validate reference_delete_mode
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'valid_reference_delete_mode'
    ) THEN
        ALTER TABLE fields
        ADD CONSTRAINT valid_reference_delete_mode CHECK (
            reference_delete_mode IN ('restrict', 'clear')
        );
    END IF;
END $$;

-- Add constraint to ensure reference_table is set when format is 'reference'
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'reference_requires_table'
    ) THEN
        ALTER TABLE fields
        ADD CONSTRAINT reference_requires_table CHECK (
            (format = 'reference' AND reference_table != '') OR (format != 'reference')
        );
    END IF;
END $$;

COMMENT ON COLUMN fields.reference_table IS 
'Table name this field references (for foreign key relationships). Must reference tables.table_name when format is "reference".';

COMMENT ON COLUMN fields.reference_delete_mode IS 
'Controls ON DELETE behavior for foreign key: "restrict" (RESTRICT) or "clear" (SET NULL). Default: restrict.';
