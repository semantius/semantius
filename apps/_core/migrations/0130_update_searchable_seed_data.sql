-- =====================================================
-- UPDATE SEED DATA FOR SEARCHABLE FIELDS
-- =====================================================
-- Mark existing text-based fields as searchable
-- This includes label columns, email fields, description fields, and other text fields

-- Temporarily disable the trigger to avoid ALTER TABLE conflicts
ALTER TABLE fields DISABLE TRIGGER handle_field_searchable_change_trigger;

-- Update searchable=TRUE for all text-based fields with meaningful content
UPDATE fields SET searchable = TRUE
WHERE format_to_json_type(format) = 'string'  -- Only string-based fields
  AND field_name IN (
    -- Common text fields that should be searchable
    'email', 'description', 'singular', 'singular_label', 'plural_label',
    'table_name', 'field_name', 'title', 'role_name', 'permission_name',
    'module_name', 'external_id', 'company', 'phone', 'status',
    'department', 'position', 'sku', 'category', 'customer_name',
    'full_name', 'product_name'
  )
  OR ctype = 'label';  -- All label columns should be searchable

-- Ensure label columns (ctype='label') are searchable
UPDATE fields SET searchable = TRUE
WHERE ctype = 'label' 
  AND format_to_json_type(format) = 'string';

-- Re-enable the trigger
ALTER TABLE fields ENABLE TRIGGER handle_field_searchable_change_trigger;

-- Now manually trigger the search vector updates for all affected tables
-- First collect all table names into a temporary table to avoid cursor issues
CREATE TEMP TABLE IF NOT EXISTS _temp_tables_to_update AS
SELECT DISTINCT table_name 
FROM fields 
WHERE searchable = TRUE
ORDER BY table_name;

-- Now update each table's search vector (no active query on fields table)
DO $$
DECLARE
    v_table_name TEXT;
BEGIN
    FOR v_table_name IN SELECT table_name FROM _temp_tables_to_update
    LOOP
        PERFORM update_search_vector_column(v_table_name);
        PERFORM update_table_searchable_flag(v_table_name);
    END LOOP;
END $$;

-- Clean up temp table
DROP TABLE IF EXISTS _temp_tables_to_update;
