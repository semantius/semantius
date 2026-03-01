-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SCHEMA
-- =====================================================
-- This schema allows runtime definition of tables and their fields
-- Integrates with RBAC system for permission-based access control
-- =====================================================

-- =====================================================
-- ENTITIES TABLE
-- =====================================================
-- Stores metadata about dynamically created tables

CREATE TABLE IF NOT EXISTS entities (
    table_name TEXT PRIMARY KEY,
    singular TEXT NOT NULL DEFAULT '',
    plural TEXT DEFAULT '',  -- Nullable because trigger auto-sets it before constraint check
    singular_label TEXT NOT NULL DEFAULT '',
    plural_label TEXT NOT NULL DEFAULT '',
    icon_url TEXT DEFAULT '',
    description TEXT DEFAULT '',
    module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
    view_permission TEXT NOT NULL DEFAULT 'public:read',
    edit_permission TEXT NOT NULL DEFAULT 'admin',
    id_column TEXT NOT NULL DEFAULT 'id',
    label_column TEXT NOT NULL DEFAULT 'label',
    managed BOOLEAN NOT NULL DEFAULT TRUE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    is_child BOOLEAN NOT NULL DEFAULT FALSE,
    edit_mode TEXT NOT NULL DEFAULT 'auto',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),     
    
    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name)
);

CREATE INDEX idx_entities_module ON entities(module_id);

COMMENT ON TABLE entities IS 
'Metadata for dynamically created tables. Each row triggers table creation and RLS policy setup.';

COMMENT ON COLUMN entities.table_name IS 'Physical table name in database (lowercase, underscores only)';
COMMENT ON COLUMN entities.singular IS 'Singular form of table name (e.g., customer for customers table)';
COMMENT ON COLUMN entities.plural IS 'Plural form of table name, auto-assigned to table_name (e.g., customers)';
COMMENT ON COLUMN entities.singular_label IS 'Human-readable singular label for UI/reports (e.g., Customer)';
COMMENT ON COLUMN entities.plural_label IS 'Human-readable plural label for UI/reports (e.g., Customers)';
COMMENT ON COLUMN entities.icon_url IS 'Optional URL or path to icon for this table';
COMMENT ON COLUMN entities.view_permission IS 'Permission required to SELECT from this table';
COMMENT ON COLUMN entities.edit_permission IS 'Permission required to INSERT/UPDATE/DELETE from this table';
COMMENT ON COLUMN entities.id_column IS 'Name of primary key column (created automatically)';
COMMENT ON COLUMN entities.label_column IS 'Name of label/display column (created automatically)';
COMMENT ON COLUMN entities.managed IS 'When false, automatic DDL execution for table and field changes is disabled';

-- =====================================================
-- FIELDS TABLE
-- =====================================================
-- Stores metadata about fields in dynamically created tables

CREATE TABLE IF NOT EXISTS fields (
    id VARCHAR GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY,
    table_name TEXT NOT NULL REFERENCES entities(table_name) ON DELETE CASCADE,
    field_name TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    format TEXT NOT NULL DEFAULT 'text',
    is_pk BOOLEAN NOT NULL DEFAULT FALSE,
    is_nullable BOOLEAN NOT NULL DEFAULT TRUE,
    default_value TEXT DEFAULT '',
    field_order INTEGER NOT NULL DEFAULT 0,
    input_type TEXT NOT NULL DEFAULT 'default',
    width TEXT NOT NULL DEFAULT 'default',
    ctype TEXT DEFAULT '',
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    enum_values JSONB DEFAULT NULL,
    reference_table TEXT NOT NULL DEFAULT '',  -- Empty string means no reference (consistent with no-null policy)
    reference_delete_mode TEXT NOT NULL DEFAULT 'restrict',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Unique constraint on table_name and field_name
    CONSTRAINT fields_table_field_unique UNIQUE (table_name, field_name),
    
    -- Validate field_name follows PostgreSQL naming conventions
    CONSTRAINT valid_field_name CHECK (field_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate format is a known format
    CONSTRAINT valid_format CHECK (
        format IN (
            -- Custom SemSchema formats
            'json', 'html', 'text', 'code', 'jsonata', 'reference', 'parent', 'enum',
            -- Standard JSON Schema formats
            'date', 'time', 'date-time', 'duration',
            'uri', 'uri-reference', 'uri-template', 'url',
            'email', 'hostname', 'ipv4', 'ipv6', 'regex', 'uuid',
            'json-pointer', 'json-pointer-uri-fragment', 'relative-json-pointer',
            'byte', 'int32', 'int64', 'float', 'double', 'password', 'binary',
            -- Primitive types from JSON Schema
            'string', 'number', 'integer', 'boolean', 'object', 'array', 'null'
        )
    ),
    

    
    -- Ensure reference_table is set when format is 'reference' or 'parent'
    CONSTRAINT reference_requires_table CHECK (
        (format IN ('reference', 'parent') AND reference_table != '') OR (format NOT IN ('reference', 'parent'))
    )
);

-- Add this partial unique index:
CREATE UNIQUE INDEX one_pk_per_table_idx
ON fields (table_name)
WHERE is_pk;-- Ensure only one primary key per table    

CREATE INDEX idx_fields_table ON fields(table_name);
CREATE INDEX idx_fields_name ON fields(field_name);
CREATE INDEX idx_fields_is_pk ON fields(is_pk) WHERE is_pk = TRUE;
CREATE INDEX idx_fields_reference_table ON fields(reference_table) WHERE reference_table != '';

COMMENT ON TABLE fields IS 
'Metadata for fields in dynamically created tables. Each row triggers ALTER TABLE to add column.';

COMMENT ON COLUMN fields.field_name IS 'Physical column name in database (lowercase, underscores only)';
COMMENT ON COLUMN fields.title IS 'Human-readable display name for the field';
COMMENT ON COLUMN fields.description IS 'Detailed description of the field (used for COMMENT ON COLUMN)';
COMMENT ON COLUMN fields.format IS 'JSON Schema format or primitive type for the field';
COMMENT ON COLUMN fields.is_pk IS 'Whether this field is the primary key';
COMMENT ON COLUMN fields.is_nullable IS 'Whether this field allows NULL values';
COMMENT ON COLUMN fields.default_value IS 'Default value for the field (as SQL expression)';
COMMENT ON COLUMN fields.field_order IS 'Display order for the field';
COMMENT ON COLUMN fields.input_type IS 'Input type for UI rendering: default, required, readonly, disabled, or hidden';
COMMENT ON COLUMN fields.width IS 'Display width for UI rendering: default (auto), s (small), m (medium), or w (wide)';
COMMENT ON COLUMN fields.ctype IS 'Special column type: empty string (normal field), id (primary key), or label (display field)';
COMMENT ON COLUMN fields.is_core IS 'Whether this is a core system field (id, label, created_at, updated_at) that cannot be deleted or have structural changes';
COMMENT ON COLUMN fields.enum_values IS 'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';
COMMENT ON COLUMN fields.reference_table IS 'Table name this field references (for foreign key relationships). Must reference entities.table_name when format is "reference". Empty string means no reference.';
COMMENT ON COLUMN fields.reference_delete_mode IS 'Controls ON DELETE behavior for foreign key: "restrict" (RESTRICT) or "clear" (SET NULL). Default: restrict.';

-- Create trigger function to validate reference_table when not empty
-- We use a trigger instead of CHECK constraint to allow subqueries
CREATE OR REPLACE FUNCTION validate_reference_table()
RETURNS TRIGGER AS $$
BEGIN
    -- Only validate if reference_table is not empty
    IF NEW.reference_table != '' THEN
        -- Check if the referenced table exists
        IF NOT EXISTS (SELECT 1 FROM entities WHERE table_name = NEW.reference_table) THEN
            RAISE EXCEPTION 'Referenced table "%" not found in entities', NEW.reference_table;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER validate_reference_table_trigger
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_reference_table();

-- =====================================================
-- ENABLE RLS ON METADATA TABLES
-- =====================================================

ALTER TABLE entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE fields ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- RLS POLICIES FOR ENTITIES
-- =====================================================

CREATE POLICY entities_select_policy ON entities
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('public:read'));

CREATE POLICY entities_insert_policy ON entities
    FOR INSERT
    TO semantius_user
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY entities_update_policy ON entities
    FOR UPDATE
    TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY entities_delete_policy ON entities
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

-- =====================================================
-- RLS POLICIES FOR FIELDS
-- =====================================================

CREATE POLICY fields_select_policy ON fields
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('public:read'));

CREATE POLICY fields_insert_policy ON fields
    FOR INSERT
    TO semantius_user
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY fields_update_policy ON fields
    FOR UPDATE
    TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY fields_delete_policy ON fields
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

-- =====================================================
-- AUTO-SET PLURAL TRIGGER
-- =====================================================
-- Automatically sets plural to match table_name on INSERT/UPDATE
-- This ensures plural always equals table_name and ignores user input

CREATE OR REPLACE FUNCTION auto_set_plural()
RETURNS TRIGGER AS $$
BEGIN
    -- Always set plural to table_name, ignoring any provided value
    NEW.plural := NEW.table_name;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION auto_set_plural IS 
'Trigger function that automatically sets plural column to match table_name, ignoring user input';

CREATE TRIGGER auto_set_plural_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_plural();

COMMENT ON TRIGGER auto_set_plural_trigger ON entities IS
'Automatically sets plural to match table_name on INSERT/UPDATE';

-- =====================================================
-- UPDATE TIMESTAMP TRIGGERS
-- =====================================================
-- Uses common.update_updated_at_column() from common schema

CREATE TRIGGER update_entities_updated_at
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_fields_updated_at
    BEFORE UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION common.update_updated_at_column();

-- =====================================================
-- SEED CORE TABLES METADATA
-- =====================================================
-- Add metadata for core RBAC and dynamic table system tables
-- These are marked with is_core=true to indicate they are system tables

-- Insert entities metadata for core tables
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES 
    ('entities', 'entity', 'entities', 'Entity', 'Entities', 'Metadata for dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'singular_label'),
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Metadata for fields in dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'id', 'title'),
    ('users', 'user', 'users', 'User', 'Users', 'External users synchronized from JWT tokens', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email'),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Logical modules that group related roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name'),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name'),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name'),
    ('user_roles', 'user_role', 'user_roles', 'User Role', 'User Roles', 'Many-to-many mapping between users and roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id'),
    ('role_permissions', 'role_permission', 'role_permissions', 'Role Permission', 'Role Permissions', 'Many-to-many mapping between roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id'),
    ('permission_hierarchy', 'permission_hierarchy', 'permission_hierarchy', 'Permission Hierarchy', 'Permission Hierarchy', 'Defines permission inheritance (parent implies children)', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id');

-- =====================================================
-- ADD ENUM CONSTRAINTS AND INSERT FIELD METADATA USING DRY PRINCIPLE
-- =====================================================
-- Define enum value arrays ONCE and use for both CHECK constraints and field metadata
-- This ensures no duplication and maintains consistency

DO $$
DECLARE
  -- Define all enum value arrays in one place
  format_values TEXT[] := ARRAY[
    -- Custom SemSchema formats
    'json', 'html', 'text', 'code', 'jsonata', 'reference', 'parent', 'enum',
    -- Standard JSON Schema formats
    'date', 'time', 'date-time', 'duration',
    'uri', 'uri-reference', 'uri-template', 'url',
    'email', 'hostname', 'ipv4', 'ipv6', 'regex', 'uuid',
    'json-pointer', 'json-pointer-uri-fragment', 'relative-json-pointer',
    'byte', 'int32', 'int64', 'float', 'double', 'password', 'binary',
    -- Primitive types from JSON Schema
    'string', 'number', 'integer', 'boolean', 'object', 'array', 'null'
  ];
  input_type_values TEXT[] := ARRAY['default', 'required', 'readonly', 'disabled', 'hidden'];
  width_values TEXT[] := ARRAY['default', 's', 'm', 'w'];
  ctype_values TEXT[] := ARRAY['', 'id', 'label'];
  reference_delete_mode_values TEXT[] := ARRAY['', 'restrict', 'clear', 'cascade'];
  edit_mode_values TEXT[] := ARRAY['auto', 'sidebar', 'modal', 'page'];
BEGIN
  -- Add enum constraints
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_input_type CHECK (input_type = ANY(%L))',
    input_type_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_width CHECK (width = ANY(%L))',
    width_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_ctype CHECK (ctype = ANY(%L))',
    ctype_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_reference_delete_mode CHECK (reference_delete_mode = ANY(%L))',
    reference_delete_mode_values
  );

  EXECUTE format(
    'ALTER TABLE entities ADD CONSTRAINT valid_edit_mode CHECK (edit_mode = ANY(%L))',
    edit_mode_values
  );
  
  -- Insert field metadata for fields table using the same enum arrays
  -- Note: fields table has a generated primary key (id = table_name || '.' || field_name)
  -- All field definitions for the fields table are consolidated here with NO duplication
  INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode)
  VALUES 
      ('fields', 'id', 'Id', 'Generated identifier (table_name.field_name)', 'text', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, NULL, '', ''),
      ('fields', 'table_name', 'Table Name', 'Table this field belongs to', 'parent', FALSE, FALSE, 10, 'default', 'default', NULL, TRUE, TRUE, NULL, 'entities', 'cascade'),
      ('fields', 'field_name', 'Field Name', 'Physical column name in database', 'text', FALSE, FALSE, 20, 'default', 'default', NULL, TRUE, TRUE, NULL, '', ''),
      ('fields', 'title', 'Title', 'Human-readable display name for the field', 'text', FALSE, FALSE, 30, 'required', 'default', 'label', TRUE, TRUE, NULL, '', ''),
      ('fields', 'description', 'Description', 'Detailed description of the field', 'text', FALSE, FALSE, 40, 'default', 'w', NULL, TRUE, TRUE, NULL, '', ''),
      ('fields', 'format', 'Format', 'JSON Schema format or primitive type', 'enum', FALSE, FALSE, 50, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(format_values), '', ''),
      ('fields', 'is_pk', 'Is Primary Key', 'Whether this field is the primary key', 'boolean', FALSE, FALSE, 60, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'is_nullable', 'Is Nullable', 'Whether this field allows NULL values', 'boolean', FALSE, FALSE, 70, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'default_value', 'Default Value', 'Default value for the field', 'text', FALSE, FALSE, 80, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'field_order', 'Field Order', 'Display order for the field', 'int32', FALSE, FALSE, 90, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'input_type', 'Input Type', 'Input type for UI rendering', 'enum', FALSE, FALSE, 100, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(input_type_values), '', ''),
      ('fields', 'width', 'Width', 'Display width for UI rendering', 'enum', FALSE, FALSE, 110, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(width_values), '', ''),
      ('fields', 'ctype', 'Column Type', 'Special column type (id, label, etc.)', 'enum', FALSE, FALSE, 120, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(ctype_values), '', ''),
      ('fields', 'is_core', 'Is Core', 'Whether this is a core system field', 'boolean', FALSE, FALSE, 130, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'searchable', 'Searchable', 'Whether field is included in full-text search', 'boolean', FALSE, FALSE, 135, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'enum_values', 'Enum Values', 'JSON array of allowed enum values', 'json', FALSE, TRUE, 137, 'default', 'w', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'reference_table', 'Reference Table', 'Table name for foreign key relationships', 'text', FALSE, FALSE, 138, 'default', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'reference_delete_mode', 'Reference Delete Mode', 'ON DELETE behavior: restrict, clear, or cascade', 'enum', FALSE, FALSE, 139, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(reference_delete_mode_values), '', ''),
      ('fields', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 140, 'disabled', 'default', NULL, TRUE, FALSE, NULL, '', ''),
      ('fields', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 150, 'disabled', 'default', NULL, TRUE, FALSE, NULL, '', '');

  -- Insert edit_mode field metadata for entities table (uses edit_mode_values defined above)
  INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode)
  VALUES
      ('entities', 'edit_mode', 'Edit Mode', 'UI edit mode for records of this table: auto, sidebar, modal, or page', 'enum', FALSE, FALSE, 119, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(edit_mode_values), '', '');
END $$;

-- Insert fields metadata for entities table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('entities', 'table_name', 'Table Name', 'Physical table name in database', 'text', TRUE, FALSE, 0, 'default', 'default', 'id', TRUE, TRUE, '', ''),
    ('entities', 'singular', 'Singular', 'Singular form of table name', 'text', FALSE, FALSE, 10, 'default', 'default', NULL, TRUE, TRUE, '', ''),
    ('entities', 'plural', 'Plural', 'Plural form of table name, auto-assigned to table_name', 'text', FALSE, FALSE, 20, 'readonly', 'default', NULL, TRUE, TRUE, '', ''),
    ('entities', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports', 'text', FALSE, FALSE, 30, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('entities', 'plural_label', 'Plural Label', 'Human-readable plural label for UI/reports', 'text', FALSE, FALSE, 40, 'default', 'default', NULL, TRUE, TRUE, '', ''),
    ('entities', 'icon_url', 'Icon URL', 'Optional URL or path to icon for this table', 'url', FALSE, FALSE, 50, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('entities', 'description', 'Description', 'Detailed description of the table', 'text', FALSE, FALSE, 60, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('entities', 'module_id', 'Module Id', 'Module this table belongs to', 'reference', FALSE, TRUE, 70, 'default', 'default', NULL, TRUE, FALSE, 'modules', 'clear'),
    ('entities', 'view_permission', 'View Permission', 'Permission required to SELECT from this table', 'text', FALSE, FALSE, 80, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'edit_permission', 'Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'text', FALSE, FALSE, 90, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'id_column', 'Id Column', 'Name of primary key column', 'text', FALSE, FALSE, 100, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'label_column', 'Label Column', 'Name of label/display column', 'text', FALSE, FALSE, 110, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'managed', 'Managed', 'When false, automatic DDL execution is disabled', 'boolean', FALSE, FALSE, 115, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'searchable', 'Searchable', 'Whether table is included in full-text search (auto-computed)', 'boolean', FALSE, FALSE, 117, 'readonly', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'is_child', 'Is Child', 'Whether table has any parent relationships (auto-computed)', 'boolean', FALSE, FALSE, 118, 'readonly', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 120, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('entities', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 130, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('users', 'id', 'Id', 'Internal user identifier', 'int32', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'text', FALSE, FALSE, 10, 'readonly', 'default', NULL, TRUE, TRUE, '', ''),
    ('users', 'email', 'Email', 'User email address', 'email', FALSE, FALSE, 20, 'default', 'default', 'label', TRUE, TRUE, '', ''),
    ('users', 'is_disabled', 'Is Disabled', 'Whether user account is disabled', 'boolean', FALSE, FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('users', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, TRUE, 60, 'readonly', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('modules', 'id', 'Id', 'Internal module identifier', 'int32', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, FALSE, 10, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('modules', 'description', 'Description', 'Description of the module', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'text', FALSE, FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_url', 'Logo URL', 'URL or base64 data URI for module logo', 'url', FALSE, FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, FALSE, 36, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, FALSE, 37, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'alias', 'Alias', 'Alternative name or identifier for module', 'text', FALSE, FALSE, 38, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, FALSE, 39, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('roles', 'id', 'Id', 'Internal role identifier', 'int32', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('roles', 'role_name', 'Role Name', 'Unique role name', 'text', FALSE, FALSE, 10, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('roles', 'description', 'Description', 'Description of the role', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('roles', 'module_id', 'Module Id', 'Module this role belongs to', 'reference', FALSE, TRUE, 30, 'default', 'default', NULL, TRUE, FALSE, 'modules', 'clear'),
    ('roles', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('roles', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('permissions', 'id', 'Id', 'Internal permission identifier', 'int32', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name', 'text', FALSE, FALSE, 10, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('permissions', 'description', 'Description', 'Description of the permission', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('permissions', 'module_id', 'Module Id', 'Module this permission belongs to', 'reference', FALSE, TRUE, 30, 'default', 'default', NULL, TRUE, FALSE, 'modules', 'clear'),
    ('permissions', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('permissions', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for user_roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('user_roles', 'id', 'Id', 'Generated identifier (user_id.role_id)', 'text', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('user_roles', 'user_id', 'User Id', 'User this role is assigned to', 'parent', FALSE, FALSE, 10, 'default', 'default', NULL, TRUE, FALSE, 'users', 'cascade'),
    ('user_roles', 'role_id', 'Role Id', 'Role assigned to the user', 'parent', FALSE, FALSE, 20, 'default', 'default', NULL, TRUE, FALSE, 'roles', 'cascade'),
    ('user_roles', 'assigned_at', 'Assigned At', 'Timestamp when role was assigned', 'date-time', FALSE, FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('user_roles', 'assigned_by', 'Assigned By', 'User who assigned this role', 'reference', FALSE, TRUE, 40, 'default', 'default', NULL, TRUE, FALSE, 'users', 'clear');

-- Insert fields metadata for role_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('role_permissions', 'id', 'Id', 'Generated identifier (role_id.permission_id)', 'text', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('role_permissions', 'role_id', 'Role Id', 'Role this permission is granted to', 'parent', FALSE, FALSE, 10, 'default', 'default', NULL, TRUE, FALSE, 'roles', 'cascade'),
    ('role_permissions', 'permission_id', 'Permission Id', 'Permission granted to the role', 'parent', FALSE, FALSE, 20, 'default', 'default', NULL, TRUE, FALSE, 'permissions', 'cascade'),
    ('role_permissions', 'granted_at', 'Granted At', 'Timestamp when permission was granted', 'date-time', FALSE, FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('role_permissions', 'granted_by', 'Granted By', 'User who granted this permission', 'reference', FALSE, TRUE, 40, 'default', 'default', NULL, TRUE, FALSE, 'users', 'clear');

-- Insert fields metadata for permission_hierarchy table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('permission_hierarchy', 'id', 'Id', 'Generated identifier (parent_permission_id.child_permission_id)', 'text', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('permission_hierarchy', 'parent_permission_id', 'Parent Permission Id', 'Parent permission that implies child permissions', 'parent', FALSE, FALSE, 10, 'default', 'default', NULL, TRUE, FALSE, 'permissions', 'cascade'),
    ('permission_hierarchy', 'child_permission_id', 'Child Permission Id', 'Child permission implied by parent', 'parent', FALSE, FALSE, 20, 'default', 'default', NULL, TRUE, FALSE, 'permissions', 'cascade'),
    ('permission_hierarchy', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '', '');