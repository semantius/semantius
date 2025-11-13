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
    singular TEXT NOT NULL,
    plural TEXT,  -- Nullable because trigger auto-sets it before constraint check
    singular_label TEXT NOT NULL,
    plural_label TEXT NOT NULL,
    icon_url TEXT,
    description TEXT,
    module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
    view_permission TEXT NOT NULL DEFAULT 'public:read',
    edit_permission TEXT NOT NULL DEFAULT 'admin',
    id_column TEXT NOT NULL DEFAULT 'id',
    label_column TEXT NOT NULL DEFAULT 'label',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Ensure id and label columns are different
    CONSTRAINT different_columns CHECK (id_column <> label_column),
    
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

-- =====================================================
-- FIELDS TABLE
-- =====================================================
-- Stores metadata about fields in dynamically created tables

CREATE TABLE IF NOT EXISTS fields (
    table_name TEXT NOT NULL REFERENCES tables(table_name) ON DELETE CASCADE,
    field_name TEXT NOT NULL,
    label TEXT NOT NULL,
    description TEXT,
    data_type TEXT NOT NULL,
    is_pk BOOLEAN NOT NULL DEFAULT FALSE,
    is_nullable BOOLEAN NOT NULL DEFAULT TRUE,
    default_value TEXT,
    field_order INTEGER NOT NULL DEFAULT 0,
    ctype TEXT,
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (table_name, field_name),
    
    -- Validate field_name follows PostgreSQL naming conventions
    CONSTRAINT valid_field_name CHECK (field_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate data_type is a known PostgreSQL type
    CONSTRAINT valid_data_type CHECK (
        data_type IN (
            'TEXT', 'INTEGER', 'BIGINT', 'SMALLINT',
            'NUMERIC', 'DECIMAL', 'REAL', 'DOUBLE PRECISION',
            'BOOLEAN', 'DATE', 'TIMESTAMP', 'TIMESTAMPTZ',
            'TIME', 'TIMETZ', 'UUID', 'JSONB', 'JSON'
        )
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
COMMENT ON COLUMN fields.label IS 'Human-readable display name for the field';
COMMENT ON COLUMN fields.description IS 'Detailed description of the field (used for COMMENT ON COLUMN)';
COMMENT ON COLUMN fields.data_type IS 'PostgreSQL data type for the column';
COMMENT ON COLUMN fields.is_pk IS 'Whether this field is the primary key';
COMMENT ON COLUMN fields.is_nullable IS 'Whether this field allows NULL values';
COMMENT ON COLUMN fields.default_value IS 'Default value for the field (as SQL expression)';
COMMENT ON COLUMN fields.field_order IS 'Display order for the field';

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
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Metadata for fields in dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'label'),
    ('users', 'user', 'users', 'User', 'Users', 'External users synchronized from JWT tokens', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email'),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Logical modules that group related roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name'),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name'),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name');

-- Insert fields metadata for tables table
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('tables', 'table_name', 'Table Name', 'Physical table name in database', 'TEXT', TRUE, FALSE, 0, 'id', TRUE),
    ('tables', 'singular', 'Singular', 'Singular form of table name', 'TEXT', FALSE, FALSE, 10, NULL, TRUE),
    ('tables', 'plural', 'Plural', 'Plural form of table name, auto-assigned to table_name', 'TEXT', FALSE, FALSE, 20, NULL, TRUE),
    ('tables', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports', 'TEXT', FALSE, FALSE, 30, 'label', TRUE),
    ('tables', 'plural_label', 'Plural Label', 'Human-readable plural label for UI/reports', 'TEXT', FALSE, FALSE, 40, NULL, TRUE),
    ('tables', 'icon_url', 'Icon URL', 'Optional URL or path to icon for this table', 'TEXT', FALSE, TRUE, 50, NULL, TRUE),
    ('tables', 'description', 'Description', 'Detailed description of the table', 'TEXT', FALSE, TRUE, 60, NULL, TRUE),
    ('tables', 'module_id', 'Module Id', 'Module this table belongs to', 'INTEGER', FALSE, TRUE, 70, NULL, TRUE),
    ('tables', 'view_permission', 'View Permission', 'Permission required to SELECT from this table', 'TEXT', FALSE, FALSE, 80, NULL, TRUE),
    ('tables', 'edit_permission', 'Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'TEXT', FALSE, FALSE, 90, NULL, TRUE),
    ('tables', 'id_column', 'Id Column', 'Name of primary key column', 'TEXT', FALSE, FALSE, 100, NULL, TRUE),
    ('tables', 'label_column', 'Label Column', 'Name of label/display column', 'TEXT', FALSE, FALSE, 110, NULL, TRUE),
    ('tables', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMP', FALSE, FALSE, 120, NULL, TRUE),
    ('tables', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMP', FALSE, FALSE, 130, NULL, TRUE);

-- Insert fields metadata for fields table
-- Note: fields table has a composite primary key (table_name, field_name)
-- Both are marked with ctype='ckey' to indicate they are part of the composite key
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('fields', 'table_name', 'Table Name', 'Table this field belongs to', 'TEXT', FALSE, FALSE, 0, 'ckey', TRUE),
    ('fields', 'field_name', 'Field Name', 'Physical column name in database', 'TEXT', FALSE, FALSE, 10, 'ckey', TRUE),
    ('fields', 'label', 'Label', 'Human-readable display name for the field', 'TEXT', FALSE, FALSE, 20, 'label', TRUE),
    ('fields', 'description', 'Description', 'Detailed description of the field', 'TEXT', FALSE, TRUE, 30, NULL, TRUE),
    ('fields', 'data_type', 'Data Type', 'PostgreSQL data type for the column', 'TEXT', FALSE, FALSE, 40, NULL, TRUE),
    ('fields', 'is_pk', 'Is Primary Key', 'Whether this field is the primary key', 'BOOLEAN', FALSE, FALSE, 50, NULL, TRUE),
    ('fields', 'is_nullable', 'Is Nullable', 'Whether this field allows NULL values', 'BOOLEAN', FALSE, FALSE, 60, NULL, TRUE),
    ('fields', 'default_value', 'Default Value', 'Default value for the field', 'TEXT', FALSE, TRUE, 70, NULL, TRUE),
    ('fields', 'field_order', 'Field Order', 'Display order for the field', 'INTEGER', FALSE, FALSE, 80, NULL, TRUE),
    ('fields', 'ctype', 'Column Type', 'Special column type (id, label, etc.)', 'TEXT', FALSE, TRUE, 90, NULL, TRUE),
    ('fields', 'is_core', 'Is Core', 'Whether this is a core system field', 'BOOLEAN', FALSE, FALSE, 100, NULL, TRUE),
    ('fields', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMP', FALSE, FALSE, 110, NULL, TRUE),
    ('fields', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMP', FALSE, FALSE, 120, NULL, TRUE);

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('users', 'id', 'Id', 'Internal user identifier', 'INTEGER', TRUE, FALSE, 0, 'id', TRUE),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'TEXT', FALSE, FALSE, 10, NULL, TRUE),
    ('users', 'email', 'Email', 'User email address', 'TEXT', FALSE, TRUE, 20, 'label', TRUE),
    ('users', 'is_disabled', 'Is Disabled', 'Whether user account is disabled', 'BOOLEAN', FALSE, TRUE, 30, NULL, TRUE),
    ('users', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMPTZ', FALSE, FALSE, 40, NULL, TRUE),
    ('users', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMPTZ', FALSE, FALSE, 50, NULL, TRUE),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'TIMESTAMPTZ', FALSE, TRUE, 60, NULL, TRUE);

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('modules', 'id', 'Id', 'Internal module identifier', 'INTEGER', TRUE, FALSE, 0, 'id', TRUE),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'TEXT', FALSE, FALSE, 10, 'label', TRUE),
    ('modules', 'description', 'Description', 'Description of the module', 'TEXT', FALSE, TRUE, 20, NULL, TRUE),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'TEXT', FALSE, FALSE, 30, NULL, TRUE),
    ('modules', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMPTZ', FALSE, FALSE, 40, NULL, TRUE),
    ('modules', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMPTZ', FALSE, FALSE, 50, NULL, TRUE);

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('roles', 'id', 'Id', 'Internal role identifier', 'INTEGER', TRUE, FALSE, 0, 'id', TRUE),
    ('roles', 'role_name', 'Role Name', 'Unique role name', 'TEXT', FALSE, FALSE, 10, 'label', TRUE),
    ('roles', 'description', 'Description', 'Description of the role', 'TEXT', FALSE, TRUE, 20, NULL, TRUE),
    ('roles', 'module_id', 'Module Id', 'Module this role belongs to', 'INTEGER', FALSE, TRUE, 30, NULL, TRUE),
    ('roles', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMPTZ', FALSE, FALSE, 40, NULL, TRUE),
    ('roles', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMPTZ', FALSE, FALSE, 50, NULL, TRUE);

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, label, description, data_type, is_pk, is_nullable, field_order, ctype, is_core)
VALUES 
    ('permissions', 'id', 'Id', 'Internal permission identifier', 'INTEGER', TRUE, FALSE, 0, 'id', TRUE),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name', 'TEXT', FALSE, FALSE, 10, 'label', TRUE),
    ('permissions', 'description', 'Description', 'Description of the permission', 'TEXT', FALSE, TRUE, 20, NULL, TRUE),
    ('permissions', 'module_id', 'Module Id', 'Module this permission belongs to', 'INTEGER', FALSE, TRUE, 30, NULL, TRUE),
    ('permissions', 'created_at', 'Created At', 'Timestamp when record was created', 'TIMESTAMPTZ', FALSE, FALSE, 40, NULL, TRUE),
    ('permissions', 'updated_at', 'Updated At', 'Timestamp when record was last updated', 'TIMESTAMPTZ', FALSE, FALSE, 50, NULL, TRUE);