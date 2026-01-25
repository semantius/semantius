-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SCHEMA
-- =====================================================
-- This schema allows runtime definition of tables and their fields
-- Integrates with RBAC system for permission-based access control
-- =====================================================

-- =====================================================
-- TABLES TABLE
-- =====================================================
-- Stores metadata about dynamically created tables

CREATE TABLE IF NOT EXISTS tables (
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
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),     
    
    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name)
);

CREATE INDEX idx_tables_module ON tables(module_id);

COMMENT ON TABLE tables IS 
'Metadata for dynamically created tables. Each row triggers table creation and RLS policy setup.';

COMMENT ON COLUMN tables.table_name IS 'Physical table name in database (lowercase, underscores only)';
COMMENT ON COLUMN tables.singular IS 'Singular form of table name (e.g., customer for customers table)';
COMMENT ON COLUMN tables.plural IS 'Plural form of table name, auto-assigned to table_name (e.g., customers)';
COMMENT ON COLUMN tables.singular_label IS 'Human-readable singular label for UI/reports (e.g., Customer)';
COMMENT ON COLUMN tables.plural_label IS 'Human-readable plural label for UI/reports (e.g., Customers)';
COMMENT ON COLUMN tables.icon_url IS 'Optional URL or path to icon for this table';
COMMENT ON COLUMN tables.view_permission IS 'Permission required to SELECT from this table';
COMMENT ON COLUMN tables.edit_permission IS 'Permission required to INSERT/UPDATE/DELETE from this table';
COMMENT ON COLUMN tables.id_column IS 'Name of primary key column (created automatically)';
COMMENT ON COLUMN tables.label_column IS 'Name of label/display column (created automatically)';
COMMENT ON COLUMN tables.managed IS 'When false, automatic DDL execution for table and field changes is disabled';

-- =====================================================
-- FIELDS TABLE
-- =====================================================
-- Stores metadata about fields in dynamically created tables

CREATE TABLE IF NOT EXISTS fields (
    id VARCHAR GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY,
    table_name TEXT NOT NULL REFERENCES tables(table_name) ON DELETE CASCADE,
    field_name TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    format TEXT NOT NULL DEFAULT 'text',
    is_pk BOOLEAN NOT NULL DEFAULT FALSE,
    is_nullable BOOLEAN NOT NULL DEFAULT TRUE,
    default_value TEXT DEFAULT '',
    field_order INTEGER NOT NULL DEFAULT 0,
    input_type TEXT NOT NULL DEFAULT 'default',
    width TEXT NOT NULL DEFAULT 'm',
    ctype TEXT DEFAULT '',
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Unique constraint on table_name and field_name
    CONSTRAINT fields_table_field_unique UNIQUE (table_name, field_name),
    
    -- Validate field_name follows PostgreSQL naming conventions
    CONSTRAINT valid_field_name CHECK (field_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate format is a known format
    CONSTRAINT valid_format CHECK (
        format IN (
            -- Custom SemSchema formats
            'json', 'html', 'text', 'code', 'jsonata',
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
    
    -- Validate input_type
    CONSTRAINT valid_input_type CHECK (
        input_type IN ('default', 'required', 'readonly', 'disabled', 'hidden')
    ),
    
    -- Validate width
    CONSTRAINT valid_width CHECK (
        width IN ('s', 'm', 'w')
    )
);

-- Add this partial unique index:
CREATE UNIQUE INDEX one_pk_per_table_idx
ON fields (table_name)
WHERE is_pk;-- Ensure only one primary key per table    

CREATE INDEX idx_fields_table ON fields(table_name);
CREATE INDEX idx_fields_name ON fields(field_name);
CREATE INDEX idx_fields_is_pk ON fields(is_pk) WHERE is_pk = TRUE;

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
COMMENT ON COLUMN fields.input_type IS 'Input type for UI rendering (default, required, readonly, disabled, hidden)';
COMMENT ON COLUMN fields.width IS 'Display width for UI rendering (s=small, m=medium, w=wide)';
COMMENT ON COLUMN fields.is_core IS 'Whether this is a core system field (id, label, created_at, updated_at) that cannot be deleted or have structural changes';

-- =====================================================
-- ENABLE RLS ON METADATA TABLES
-- =====================================================

ALTER TABLE tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE fields ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- RLS POLICIES FOR TABLES
-- =====================================================

CREATE POLICY tables_select_policy ON tables
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('public:read'));

CREATE POLICY tables_insert_policy ON tables
    FOR INSERT
    TO semantius_user
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY tables_update_policy ON tables
    FOR UPDATE
    TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY tables_delete_policy ON tables
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
    BEFORE INSERT OR UPDATE ON tables
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_plural();

COMMENT ON TRIGGER auto_set_plural_trigger ON tables IS
'Automatically sets plural to match table_name on INSERT/UPDATE';

-- =====================================================
-- UPDATE TIMESTAMP TRIGGERS
-- =====================================================
-- Uses common.update_updated_at_column() from common schema

CREATE TRIGGER update_tables_updated_at
    BEFORE UPDATE ON tables
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

-- Insert tables metadata for core tables
INSERT INTO tables (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES 
    ('tables', 'table', 'tables', 'Table', 'Tables', 'Metadata for dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'singular_label'),
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Metadata for fields in dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'id', 'title'),
    ('users', 'user', 'users', 'User', 'Users', 'External users synchronized from JWT tokens', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email'),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Logical modules that group related roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name'),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name'),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name');

-- Insert fields metadata for tables table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('tables', 'table_name', 'Table Name', 'Physical table name in database', 'text', TRUE, FALSE, 0, 'default', 'm', 'id', TRUE),
    ('tables', 'singular', 'Singular', 'Singular form of table name', 'text', FALSE, FALSE, 10, 'default', 'm', NULL, TRUE),
    ('tables', 'plural', 'Plural', 'Plural form of table name, auto-assigned to table_name', 'text', FALSE, FALSE, 20, 'readonly', 'm', NULL, TRUE),
    ('tables', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports', 'text', FALSE, FALSE, 30, 'required', 'm', 'label', TRUE),
    ('tables', 'plural_label', 'Plural Label', 'Human-readable plural label for UI/reports', 'text', FALSE, FALSE, 40, 'default', 'm', NULL, TRUE),
    ('tables', 'icon_url', 'Icon URL', 'Optional URL or path to icon for this table', 'url', FALSE, FALSE, 50, 'default', 'w', NULL, TRUE),
    ('tables', 'description', 'Description', 'Detailed description of the table', 'text', FALSE, FALSE, 60, 'default', 'w', NULL, TRUE),
    ('tables', 'module_id', 'Module Id', 'Module this table belongs to', 'int32', FALSE, TRUE, 70, 'default', 's', NULL, TRUE),
    ('tables', 'view_permission', 'View Permission', 'Permission required to SELECT from this table', 'text', FALSE, FALSE, 80, 'default', 'm', NULL, TRUE),
    ('tables', 'edit_permission', 'Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'text', FALSE, FALSE, 90, 'default', 'm', NULL, TRUE),
    ('tables', 'id_column', 'Id Column', 'Name of primary key column', 'text', FALSE, FALSE, 100, 'default', 'm', NULL, TRUE),
    ('tables', 'label_column', 'Label Column', 'Name of label/display column', 'text', FALSE, FALSE, 110, 'default', 'm', NULL, TRUE),
    ('tables', 'managed', 'Managed', 'When false, automatic DDL execution is disabled', 'boolean', FALSE, FALSE, 115, 'default', 's', NULL, TRUE),
    ('tables', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 120, 'disabled', 'm', NULL, TRUE),
    ('tables', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 130, 'disabled', 'm', NULL, TRUE);

-- Insert fields metadata for fields table
-- Note: fields table has a generated primary key (id = table_name || '.' || field_name)
-- table_name and field_name have a unique constraint together
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('fields', 'id', 'Id', 'Generated identifier (table_name.field_name)', 'text', TRUE, FALSE, 0, 'readonly', 'm', 'id', TRUE),
    ('fields', 'table_name', 'Table Name', 'Table this field belongs to', 'text', FALSE, FALSE, 10, 'default', 'm', NULL, TRUE),
    ('fields', 'field_name', 'Field Name', 'Physical column name in database', 'text', FALSE, FALSE, 20, 'default', 'm', NULL, TRUE),
    ('fields', 'title', 'Title', 'Human-readable display name for the field', 'text', FALSE, FALSE, 30, 'required', 'm', 'label', TRUE),
    ('fields', 'description', 'Description', 'Detailed description of the field', 'text', FALSE, FALSE, 40, 'default', 'w', NULL, TRUE),
    ('fields', 'format', 'Format', 'JSON Schema format or primitive type', 'text', FALSE, FALSE, 50, 'default', 'm', NULL, TRUE),
    ('fields', 'is_pk', 'Is Primary Key', 'Whether this field is the primary key', 'boolean', FALSE, FALSE, 60, 'default', 's', NULL, TRUE),
    ('fields', 'is_nullable', 'Is Nullable', 'Whether this field allows NULL values', 'boolean', FALSE, FALSE, 70, 'default', 's', NULL, TRUE),
    ('fields', 'default_value', 'Default Value', 'Default value for the field', 'text', FALSE, FALSE, 80, 'default', 'm', NULL, TRUE),
    ('fields', 'field_order', 'Field Order', 'Display order for the field', 'int32', FALSE, FALSE, 90, 'default', 's', NULL, TRUE),
    ('fields', 'input_type', 'Input Type', 'Input type for UI rendering', 'text', FALSE, FALSE, 100, 'default', 'm', NULL, TRUE),
    ('fields', 'width', 'Width', 'Display width for UI rendering', 'text', FALSE, FALSE, 110, 'default', 's', NULL, TRUE),
    ('fields', 'ctype', 'Column Type', 'Special column type (id, label, etc.)', 'text', FALSE, FALSE, 120, 'default', 'm', NULL, TRUE),
    ('fields', 'is_core', 'Is Core', 'Whether this is a core system field', 'boolean', FALSE, FALSE, 130, 'default', 's', NULL, TRUE),
    ('fields', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 140, 'disabled', 'm', NULL, TRUE),
    ('fields', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 150, 'disabled', 'm', NULL, TRUE);

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('users', 'id', 'Id', 'Internal user identifier', 'int32', TRUE, FALSE, 0, 'readonly', 's', 'id', TRUE),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'text', FALSE, FALSE, 10, 'readonly', 'm', NULL, TRUE),
    ('users', 'email', 'Email', 'User email address', 'email', FALSE, FALSE, 20, 'default', 'm', 'label', TRUE),
    ('users', 'is_disabled', 'Is Disabled', 'Whether user account is disabled', 'boolean', FALSE, FALSE, 30, 'default', 's', NULL, TRUE),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, FALSE, 35, 'default', 'w', NULL, TRUE),
    ('users', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', NULL, TRUE),
    ('users', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'm', NULL, TRUE),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, TRUE, 60, 'readonly', 'm', NULL, TRUE);

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('modules', 'id', 'Id', 'Internal module identifier', 'int32', TRUE, FALSE, 0, 'readonly', 's', 'id', TRUE),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, FALSE, 10, 'required', 'm', 'label', TRUE),
    ('modules', 'description', 'Description', 'Description of the module', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'text', FALSE, FALSE, 30, 'default', 'm', NULL, TRUE),
    ('modules', 'logo_url', 'Logo URL', 'URL or base64 data URI for module logo', 'url', FALSE, FALSE, 35, 'default', 'w', NULL, TRUE),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, FALSE, 36, 'default', 's', NULL, TRUE),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, FALSE, 37, 'default', 'm', NULL, TRUE),
    ('modules', 'alias', 'Alias', 'Alternative name or identifier for module', 'text', FALSE, FALSE, 38, 'default', 'm', NULL, TRUE),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, FALSE, 39, 'default', 'w', NULL, TRUE),
    ('modules', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', NULL, TRUE),
    ('modules', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'm', NULL, TRUE);

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('roles', 'id', 'Id', 'Internal role identifier', 'int32', TRUE, FALSE, 0, 'readonly', 's', 'id', TRUE),
    ('roles', 'role_name', 'Role Name', 'Unique role name', 'text', FALSE, FALSE, 10, 'required', 'm', 'label', TRUE),
    ('roles', 'description', 'Description', 'Description of the role', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE),
    ('roles', 'module_id', 'Module Id', 'Module this role belongs to', 'int32', FALSE, TRUE, 30, 'default', 's', NULL, TRUE),
    ('roles', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', NULL, TRUE),
    ('roles', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'm', NULL, TRUE);

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
VALUES 
    ('permissions', 'id', 'Id', 'Internal permission identifier', 'int32', TRUE, FALSE, 0, 'readonly', 's', 'id', TRUE),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name', 'text', FALSE, FALSE, 10, 'required', 'm', 'label', TRUE),
    ('permissions', 'description', 'Description', 'Description of the permission', 'text', FALSE, FALSE, 20, 'default', 'w', NULL, TRUE),
    ('permissions', 'module_id', 'Module Id', 'Module this permission belongs to', 'int32', FALSE, TRUE, 30, 'default', 's', NULL, TRUE),
    ('permissions', 'created_at', 'Created At', 'Timestamp when record was created', 'date-time', FALSE, FALSE, 40, 'disabled', 'm', NULL, TRUE),
    ('permissions', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'date-time', FALSE, FALSE, 50, 'disabled', 'm', NULL, TRUE);