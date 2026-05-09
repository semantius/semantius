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
    cube_mode TEXT NOT NULL DEFAULT 'auto',
    audit_log BOOLEAN NOT NULL DEFAULT FALSE,
    computed_fields JSONB NOT NULL DEFAULT '[]'::jsonb,
    validation_rules JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),

    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),

    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name),

    -- computed_fields and validation_rules must be JSON arrays
    CONSTRAINT computed_fields_is_array CHECK (jsonb_typeof(computed_fields) = 'array'),
    CONSTRAINT validation_rules_is_array CHECK (jsonb_typeof(validation_rules) = 'array')
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
COMMENT ON COLUMN entities.audit_log IS 'When TRUE, DML operations on this table are logged to audit_record_logs';
COMMENT ON COLUMN entities.computed_fields IS
'Ordered list of {name, jsonlogic, description?} entries. Each entry derives the named field from the same record before write. Default [].';
COMMENT ON COLUMN entities.validation_rules IS
'Ordered list of {code, message, jsonlogic, description?} entries. Each entry must evaluate truthy for the write to succeed. Default [].';

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
    default_value TEXT DEFAULT '',
    field_order INTEGER NOT NULL DEFAULT 0,
    input_type TEXT NOT NULL DEFAULT 'default',
    width TEXT NOT NULL DEFAULT 'default',
    ctype TEXT DEFAULT '',
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    enum_values JSONB DEFAULT NULL,
    "precision" SMALLINT NOT NULL DEFAULT 2,
    reference_table TEXT NOT NULL DEFAULT '',  -- Empty string means no reference (consistent with no-null policy)
    reference_delete_mode TEXT NOT NULL DEFAULT 'restrict',
    relationship_label TEXT NOT NULL DEFAULT 'has',
    singular_label_parent TEXT NOT NULL DEFAULT '',
    plural_label_parent TEXT NOT NULL DEFAULT '',
    unique_value BOOLEAN NOT NULL DEFAULT FALSE,
    cube_type TEXT NOT NULL DEFAULT 'auto',
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
    

    
    -- Ensure precision is within a reasonable range for NUMERIC scale
    CONSTRAINT valid_precision CHECK ("precision" >= 0 AND "precision" <= 18),

    -- Ensure reference_table is set when format is 'reference' or 'parent'
    CONSTRAINT reference_requires_table CHECK (
        (format IN ('reference', 'parent') AND reference_table != '') OR (format NOT IN ('reference', 'parent'))
    ),

    -- Ensure format is 'reference' or 'parent' when reference_table is set
    CONSTRAINT reference_table_requires_reference_format CHECK (
        (reference_table != '' AND format IN ('reference', 'parent')) OR (reference_table = '')
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
COMMENT ON COLUMN fields.default_value IS 'Default value for the field (as SQL expression)';
COMMENT ON COLUMN fields.field_order IS 'Display order for the field';
COMMENT ON COLUMN fields.input_type IS 'Input type for UI rendering: default, required, readonly, disabled, or hidden';
COMMENT ON COLUMN fields.width IS 'Display width for UI rendering: default (auto), s (small), m (medium), or w (wide)';
COMMENT ON COLUMN fields.ctype IS 'Special column type: empty string (normal field), id (primary key), or label (display field)';
COMMENT ON COLUMN fields.is_core IS 'Whether this is a core system field (id, label, created_at, updated_at) that cannot be deleted or have structural changes';
COMMENT ON COLUMN fields.enum_values IS 'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';
COMMENT ON COLUMN fields."precision" IS 'Decimal scale (digits after the decimal point) used when generating NUMERIC columns for number formats. Default 2 (currency-style).';
COMMENT ON COLUMN fields.reference_table IS 'Table name this field references (for foreign key relationships). Must reference entities.table_name when format is "reference". Empty string means no reference.';
COMMENT ON COLUMN fields.reference_delete_mode IS 'Controls ON DELETE behavior for foreign key: "restrict" (RESTRICT) or "clear" (SET NULL). Default: restrict.';
COMMENT ON COLUMN fields.relationship_label IS 'Verb describing what the referenced entity does to/with this entity (e.g. "employs", "heads"). Used for ER diagram and navigation labels.';
COMMENT ON COLUMN fields.singular_label_parent IS 'Custom singular label for the parent entity when format is ''parent''. Overrides the default singular_label from the parent entity when set.';
COMMENT ON COLUMN fields.plural_label_parent IS 'Custom plural label for the parent entity when format is ''parent''. Overrides the default plural_label from the parent entity when set.';
COMMENT ON COLUMN fields.unique_value IS 'When TRUE, enforces a partial unique index on this column. For string types, NULL and empty string values are excluded from the uniqueness check.';

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
$$ LANGUAGE plpgsql SET search_path = public;

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
$$ LANGUAGE plpgsql SET search_path = public;

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
    ('users', 'user', 'users', 'User', 'Users', 'Users and agents', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email'),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Logical modules that group related roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name'),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name'),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name'),
    ('user_roles', 'user_role', 'user_roles', 'User Role', 'User Roles', 'Many-to-many mapping between users and roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id'),
    ('role_permissions', 'role_permission', 'role_permissions', 'Role Permission', 'Role Permissions', 'Many-to-many mapping between roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id'),
    ('user_permissions', 'user_permission', 'user_permissions', 'User Permission', 'User Permissions', 'Many-to-many mapping between users and permissions for direct per-user permission grants', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id'),
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
  cube_mode_values TEXT[] := ARRAY['disabled', 'auto'];
  cube_type_values TEXT[] := ARRAY['disabled', 'auto', 'dimension', 'measure'];
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

  EXECUTE format(
    'ALTER TABLE entities ADD CONSTRAINT valid_cube_mode CHECK (cube_mode = ANY(%L))',
    cube_mode_values
  );

  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_cube_type CHECK (cube_type = ANY(%L))',
    cube_type_values
  );
  
  -- Insert field metadata for fields table using the same enum arrays
  -- Note: fields table has a generated primary key (id = table_name || '.' || field_name)
  -- All field definitions for the fields table are consolidated here with NO duplication
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('fields', 'id',                   'Id',                   'Generated identifier (table_name.field_name)',                           '',         'text',      TRUE,  1,   'readonly', 'default', 'id',   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'table_name',           'Table Name',           '',                                                                       '',         'parent',    FALSE, 10,  'default',  'default', NULL,   TRUE,  TRUE,  NULL,                            'entities',  'cascade', 'has fields'),
      ('fields', 'field_name',           'Field Name',           'Physical column name in database',                                       '',         'text',      FALSE, 20,  'required', 'default', NULL,   TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'title',                'Title',                'Human-readable display name for the field',                              '',         'text',      FALSE, 30,  'required', 'default', 'label',TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'description',          'Description',          '',                                                                       '',         'text',      FALSE, 40,  'default',  'w',       NULL,   TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'format',               'Format',               'JSON Schema format or primitive type',                                   'string',   'enum',      FALSE, 50,  'required', 'default', NULL,   TRUE,  FALSE, to_jsonb(format_values),         '',          '',        ''),
      ('fields', 'is_pk',               'Is Primary Key',       '',                                                                       '',         'boolean',   FALSE, 60,  'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'is_nullable',         'Is Nullable',          'Whether this field allows NULL values (computed from format)',            '',         'boolean',   FALSE, 70,  'readonly', 'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'default_value',       'Default Value',        '',                                                                       '',         'text',      FALSE, 80,  'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'field_order',         'Field Order',          '',                                                                       '',         'int32',     FALSE, 90,  'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'input_type',          'Input Type',           '',                                                                       'default',  'enum',      FALSE, 100, 'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(input_type_values),     '',          '',        ''),
      ('fields', 'width',               'Width',                '',                                                                       'default',  'enum',      FALSE, 110, 'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(width_values),          '',          '',        ''),
      ('fields', 'ctype',               'Column Type',          'Special column type (id, label, etc.)',                                  '',         'enum',      FALSE, 120, 'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(ctype_values),          '',          '',        ''),
      ('fields', 'is_core',             'Is Core',              '',                                                                       '',         'boolean',   FALSE, 130, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'searchable',          'Searchable',           'Whether field is included in full-text search',                          '',         'boolean',   FALSE, 135, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'enum_values',         'Enum Values',          'JSON array of allowed enum values',                                      '',         'json',      FALSE, 137, 'default',  'w',       NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'precision',           'Precision',            'Decimal scale used when generating NUMERIC columns for number formats',  '2',        'int32',     FALSE, 138, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_table',     'Reference Table',      'Table name for foreign key relationships',                               '',         'text',      FALSE, 138, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_delete_mode','Reference Delete Mode','ON DELETE behavior: restrict, clear, or cascade',                       'restrict', 'enum',      FALSE, 139, 'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(reference_delete_mode_values), '', '',     ''),
      ('fields', 'relationship_label',  'Relationship Label',   'Verb describing what the referenced entity does to/with this entity',  'has',      'text',      FALSE, 140, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'singular_label_parent','Singular Label Parent','Custom singular label for the parent entity (overrides default when set)','',        'text',      FALSE, 141, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'plural_label_parent', 'Plural Label Parent',  'Custom plural label for the parent entity (overrides default when set)', '',         'text',      FALSE, 142, 'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'unique_value',        'Unique Value',         'When TRUE, enforces a partial unique index (NULL and empty strings are not enforced)', '', 'boolean', FALSE, 143, 'default', 'default', NULL, TRUE, FALSE, NULL,                           '',          '',        ''),
      ('fields', 'cube_type',           'Cube Type',            '',                                                                       'auto',     'enum',      FALSE, 144, 'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(cube_type_values),      '',          '',        ''),
      ('fields', 'created_at',          'Created At',           '',                                                                       '',         'date-time', FALSE, 140, 'disabled', 'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'updated_at',          'Updated At',           '',                                                                       '',         'date-time', FALSE, 150, 'disabled', 'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        '');

  -- Insert edit_mode field metadata for entities table (uses edit_mode_values defined above)
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('entities', 'edit_mode', 'Edit Mode', 'UI edit mode for records of this table: auto, sidebar, modal, or page', 'auto', 'enum', FALSE, 119, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(edit_mode_values), '', '', ''),
      ('entities', 'cube_mode', 'Cube Mode', 'Cube mode for OLAP cube generation', 'auto', 'enum', FALSE, 121, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(cube_mode_values), '', '', '');
END $$;

-- Insert fields metadata for entities table
INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('entities', 'table_name',     'Table Name',     'Physical table name in database',                       '',             'text',      TRUE,  1,   'required', 'default', 'id',   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'singular',       'Singular',       'Singular form of table name',                           '',             'text',      FALSE, 10,  'required', 'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'plural',         'Plural',         'Plural form of table name, auto-assigned to table_name','',             'text',      FALSE, 20,  'readonly', 'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports',          '',             'text',      FALSE, 30,  'default',  'default', 'label',TRUE,  TRUE,  '', '',        ''),
    ('entities', 'plural_label',   'Plural Label',   'Human-readable plural label for UI/reports',            '',             'text',      FALSE, 40,  'default',  'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'icon_url',       'Icon URL',       'Optional URL or path to icon for this table',           '',             'url',       FALSE, 50,  'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'description',    'Description',    '',                                                       '',             'text',      FALSE, 60,  'default',  'w',       NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'module_id',      'Module Id',      '',                                                       '',             'reference', FALSE, 70,  'default',  'default', NULL,   TRUE,  FALSE, 'modules', 'clear', 'contains'),
    ('entities', 'view_permission','View Permission', 'Permission required to SELECT from this table',         'public:read',  'text',      FALSE, 80,  'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'edit_permission','Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'admin', 'text',      FALSE, 90,  'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'id_column',      'Id Column',      'Name of primary key column',                            'id',           'text',      FALSE, 100, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'label_column',   'Label Column',   'Name of label/display column',                          'label',        'text',      FALSE, 110, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'managed',        'Managed',        'When false, automatic DDL execution is disabled',       'true',         'boolean',   FALSE, 115, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'searchable',     'Searchable',     'Whether table is included in full-text search (auto-computed)', '',    'boolean',   FALSE, 117, 'disabled', 'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'is_child',       'Is Child',       'Whether table has any parent relationships (auto-computed)', '',       'boolean',   FALSE, 118, 'disabled', 'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'computed_fields','Computed Fields', 'JsonLogic derivations evaluated on every write',        '',             'json',      FALSE, 123, 'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'validation_rules','Validation Rules','JsonLogic invariants that must hold for the write to succeed','',     'json',      FALSE, 124, 'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'created_at',     'Created At',     '',                                                       '',             'date-time', FALSE, 130, 'disabled', 'default', NULL,  TRUE,  FALSE, '', '',        ''),
    ('entities', 'updated_at',     'Updated At',     '',                                                       '',             'date-time', FALSE, 140, 'disabled', 'default', NULL,  TRUE,  FALSE, '', '',        '');

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('users', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'text', FALSE, 10, 'readonly', 'default', NULL, TRUE, TRUE, '', ''),
    ('users', 'email', 'Email', '', 'email', FALSE, 20, 'default', 'default', 'label', TRUE, TRUE, '', ''),
    ('users', 'display_name', 'Display Name', '', 'text', FALSE, 25, 'default', 'default', NULL, TRUE, TRUE, '', ''),
    ('users', 'is_disabled', 'Is Disabled', '', 'boolean', FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('users', 'created_at', 'Created At', '', 'date-time', FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'updated_at', 'Updated At', '', 'date-time', FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, 60, 'readonly', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('modules', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, 10, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('modules', 'description', 'Description', '', 'text', FALSE, 20, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'text', FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_url', 'Logo URL', 'URL or base64 data URI for module logo', 'url', FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, 36, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, 37, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'module_slug', 'Module Slug', 'URL-safe unique identifier for module, auto-generated from module_name if not provided', 'text', FALSE, 38, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, 50, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'dashboard_config', 'Dashboard Configuration', '', 'json', FALSE, 60, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'created_at', 'Created At', '', 'date-time', FALSE, 90, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'updated_at', 'Updated At', '', 'date-time', FALSE, 100, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('roles', 'id',          'Id',          '',                              'int32',     TRUE,  1,  'readonly', 'default', 'id',    TRUE, FALSE, '',        '',      ''),
    ('roles', 'role_name',   'Role Name',   'Unique role name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE, TRUE,  '',        '',      ''),
    ('roles', 'description', 'Description', '',                              'text',      FALSE, 20, 'default',  'w',       NULL,    TRUE, TRUE,  '',        '',      ''),
    ('roles', 'module_id',   'Module Id',   'Module this role belongs to',   'reference', FALSE, 30, 'default',  'default', NULL,    TRUE, FALSE, 'modules', 'clear', 'contains'),
    ('roles', 'created_at',  'Created At',  '',                              'date-time', FALSE, 40, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      ''),
    ('roles', 'updated_at',  'Updated At',  '',                              'date-time', FALSE, 50, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      '');

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permissions', 'id',              'Id',              '',                                    'int32',     TRUE,  1,  'readonly', 'default', 'id',    TRUE, FALSE, '',        '',      ''),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE, TRUE,  '',        '',      ''),
    ('permissions', 'description',     'Description',     '',                                    'text',      FALSE, 20, 'default',  'w',       NULL,    TRUE, TRUE,  '',        '',      ''),
    ('permissions', 'module_id',       'Module Id',       'Module this permission belongs to',   'reference', FALSE, 30, 'default',  'default', NULL,    TRUE, FALSE, 'modules', 'clear', 'contains'),
    ('permissions', 'created_at',      'Created At',      '',                                    'date-time', FALSE, 40, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      ''),
    ('permissions', 'updated_at',      'Updated At',      '',                                    'date-time', FALSE, 50, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      '');

-- Insert fields metadata for user_roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_roles', 'id',          'Id',          'Generated identifier (user_id.role_id)',  'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',      '',        ''),
    ('user_roles', 'user_id',     'User Id',     'User this role is assigned to',           'parent',    FALSE, 10, 'required', 'default', NULL, TRUE, FALSE, 'users', 'cascade', 'has roles'),
    ('user_roles', 'role_id',     'Role Id',     'Role assigned to the user',               'parent',    FALSE, 20, 'required', 'default', NULL, TRUE, FALSE, 'roles', 'cascade', 'assigned to'),
    ('user_roles', 'assigned_at', 'Assigned At', 'Timestamp when role was assigned',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',      '',        ''),
    ('user_roles', 'assigned_by', 'Assigned By', 'User who assigned this role',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users', 'clear',   'has assigned');

UPDATE fields SET singular_label_parent = 'Role', plural_label_parent = 'Roles' WHERE table_name = 'user_roles' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User', plural_label_parent = 'Users' WHERE table_name = 'user_roles' AND field_name = 'role_id';

-- Insert fields metadata for role_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('role_permissions', 'id',            'Id',            'Generated identifier (role_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',            '',        ''),
    ('role_permissions', 'role_id',       'Role Id',       'Role this permission is granted to',           'parent',    FALSE, 10, 'default',  'default', NULL, TRUE, FALSE, 'roles',        'cascade', 'has permissions'),
    ('role_permissions', 'permission_id', 'Permission Id', 'Permission granted to the role',               'parent',    FALSE, 20, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'granted to'),
    ('role_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',             '',        ''),
    ('role_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users',        'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'role_id';
UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for user_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_permissions', 'id',            'Id',            'Generated identifier (user_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',             '',        ''),
    ('user_permissions', 'user_id',       'User Id',       'User this permission is granted to',           'parent',    FALSE, 10, 'required', 'default', NULL, TRUE, FALSE, 'users',         'cascade', 'has permissions'),
    ('user_permissions', 'permission_id', 'Permission Id', 'Permission granted to the user',               'parent',    FALSE, 20, 'required', 'default', NULL, TRUE, FALSE, 'permissions',   'cascade', 'granted to'),
    ('user_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',              '',        ''),
    ('user_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users',         'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'user_permissions' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User',       plural_label_parent = 'Users'       WHERE table_name = 'user_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for permission_hierarchy table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permission_hierarchy', 'id',                    'Id',                    'Generated identifier (parent_permission_id.child_permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',             '',        ''),
    ('permission_hierarchy', 'parent_permission_id',  'Parent Permission Id',  'Parent permission that implies child permissions',                 'parent',    FALSE, 10, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'parent of'),
    ('permission_hierarchy', 'child_permission_id',   'Child Permission Id',   'Child permission implied by parent',                              'parent',    FALSE, 20, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'child of'),
    ('permission_hierarchy', 'created_at',            'Created At',            '',                                                                'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',             '',        '');

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION validate_reference_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auto_set_plural() FROM PUBLIC;