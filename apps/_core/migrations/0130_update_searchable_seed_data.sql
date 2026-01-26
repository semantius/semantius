-- =====================================================
-- UPDATE SEED DATA FOR SEARCHABLE FIELDS
-- =====================================================
-- Mark existing text-based fields as searchable
-- This includes label columns, email fields, description fields, and other text fields

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
