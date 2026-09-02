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
    module_id INTEGER NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    view_permission TEXT NOT NULL DEFAULT 'public:read',
    edit_permission TEXT NOT NULL DEFAULT 'admin',
    id_column TEXT NOT NULL DEFAULT 'id',
    label_column TEXT NOT NULL DEFAULT 'label',
    label_parent TEXT NOT NULL DEFAULT '',  -- Composed-label identity spine: names a reference/parent FK on this entity (empty = intrinsic; composed _label = local label)
    managed BOOLEAN NOT NULL DEFAULT TRUE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    is_child BOOLEAN NOT NULL DEFAULT FALSE,
    edit_mode TEXT NOT NULL DEFAULT 'auto',
    cube_mode TEXT NOT NULL DEFAULT 'auto',
    audit_log BOOLEAN NOT NULL DEFAULT FALSE,
    computed_fields JSONB NOT NULL DEFAULT '[]'::jsonb,
    validation_rules JSONB NOT NULL DEFAULT '[]'::jsonb,
    select_rule JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- Catalog/blueprint provenance (v0.1.2) — see docs/provenance-core-0.1.2-changes.md.
    -- All default empty (additive-safe): existing rows read as "absent".
    catalog_entity_code TEXT NOT NULL DEFAULT '',        -- canonical uber-model code; rename/dialect/silo join key
    catalog_owner_module TEXT NOT NULL DEFAULT '',       -- soft slug pointer to the catalog owner module (not an FK)
    entity_type TEXT NOT NULL DEFAULT 'unclassified',    -- closed data-class axis (write tier derives from it)
    catalog_entity_aliases JSONB NOT NULL DEFAULT '[]'::jsonb, -- append-only [{alias_code, source_domain, ...}] merge ledger
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),

    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),
    -- label_parent is empty (intrinsic) or a column-name identifier (validated against the
    -- fields catalog by the validate_label_parent trigger in 0145_managed_enable.sql).
    CONSTRAINT valid_label_parent CHECK (label_parent = '' OR label_parent ~ '^[a-z_][a-z0-9_]*$'),

    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name),

    -- computed_fields and validation_rules must be JSON arrays
    CONSTRAINT computed_fields_is_array CHECK (jsonb_typeof(computed_fields) = 'array'),
    CONSTRAINT validation_rules_is_array CHECK (jsonb_typeof(validation_rules) = 'array'),
    -- select_rule must be a JSON object
    CONSTRAINT select_rule_is_object CHECK (jsonb_typeof(select_rule) = 'object'),
    -- Provenance (v0.1.2): closed entity_type set (write tier derives from it) + JSON shape guards.
    -- entity_type CHECK is exactly 6 values (no implicit ''): authoritative because the field-metadata
    -- seed runs before the add_dd_field trigger exists, so no DD-built CHECK is generated.
    CONSTRAINT valid_entity_type CHECK (entity_type IN
        ('operational_workflow', 'operational_record', 'catalog', 'junction', 'computed', 'unclassified')),
    CONSTRAINT catalog_entity_aliases_is_array CHECK (jsonb_typeof(catalog_entity_aliases) = 'array')
);

CREATE INDEX idx_entities_module ON entities(module_id);

-- Matches the format the DDL triggers apply (plural label + blank line + description),
-- so this bootstrap comment stays identical to what update_dd_table_comment would regenerate.
COMMENT ON TABLE entities IS
E'Entities\n\nCatalog of tables in Semantius';

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
COMMENT ON COLUMN entities.select_rule IS
'JsonLogic rule evaluated per row for FOR SELECT RLS policy. When non-empty, generates a policy function that returns true only when the rule evaluates truthy. Default {}.';

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
    -- A default is a value (or one of the argument-less SQL expressions
    -- quote_default_value() allow-lists), never a statement: the dictionary
    -- interpolates it into ALTER TABLE ... DEFAULT, so statement separators and
    -- comment markers are rejected outright as a second line of defence.
    default_value TEXT DEFAULT ''
        CONSTRAINT valid_default_value CHECK (
            length(default_value) <= 200
            AND default_value !~ '[;[:cntrl:]]'
            AND position('--' IN default_value) = 0
            AND position('/*' IN default_value) = 0
        ),
    field_order INTEGER NOT NULL DEFAULT 0,
    input_type TEXT NOT NULL DEFAULT 'default',
    width TEXT NOT NULL DEFAULT 'default',
    ctype TEXT DEFAULT '',
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
    input_type_rule JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- Catalog/blueprint provenance (v0.1.2): stable design-time field identity (blueprint field name);
    -- the field-rename join key. Empty = created outside the deploy pipeline.
    catalog_field_code TEXT NOT NULL DEFAULT '',
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
            'json', 'html', 'text', 'multiline', 'code', 'jsonata', 'reference', 'parent', 'enum',
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

-- Matches the format the DDL triggers apply (plural label + blank line + description),
-- so this bootstrap comment stays identical to what update_dd_table_comment would regenerate.
COMMENT ON TABLE fields IS
E'Fields\n\nCatalog of the fields that make up a table';

COMMENT ON COLUMN fields.field_name IS 'Physical column name in database (lowercase, underscores only)';
COMMENT ON COLUMN fields.title IS 'Human-readable display name for the field';
COMMENT ON COLUMN fields.description IS 'Detailed description of the field (used for COMMENT ON COLUMN)';
COMMENT ON COLUMN fields.format IS 'JSON Schema format or primitive type for the field';
COMMENT ON COLUMN fields.is_pk IS 'Whether this field is the primary key';
COMMENT ON COLUMN fields.default_value IS 'Default value for the field (as SQL expression)';
COMMENT ON COLUMN fields.field_order IS 'Display order for the field';
COMMENT ON COLUMN fields.input_type IS 'Input type for UI rendering: default, required, readonly, disabled, or hidden';
COMMENT ON COLUMN fields.width IS 'Display width for UI rendering: default (auto), s (small), m (medium), or w (wide)';
COMMENT ON COLUMN fields.ctype IS 'Special column type and the SINGLE marker of a DD-managed core column. Values: empty string (normal, user-editable field); id (primary key); label (display field); audit (managed record-versioning columns created_at/updated_at, room for created_by/updated_by); core (other system/metadata columns). A non-empty ctype = core: protected against rename/format/default/delete (label rename being the one allowed exception). ctype is itself immutable and can only be set by privileged DD code (see the fields ctype-lock trigger). is_core is derived as (ctype <> '').';
COMMENT ON COLUMN fields.enum_values IS 'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';
COMMENT ON COLUMN fields."precision" IS 'Decimal scale (digits after the decimal point) used when generating NUMERIC columns for number formats. Default 2 (currency-style).';
COMMENT ON COLUMN fields.input_type_rule IS 'JsonLogic condition for field visibility in the UI. Evaluated client-side to show/hide the field.';
COMMENT ON COLUMN fields.reference_table IS 'Table name this field references (for foreign key relationships). Must reference entities.table_name when format is "reference". Empty string means no reference.';
COMMENT ON COLUMN fields.reference_delete_mode IS 'Controls ON DELETE behavior for foreign key: "restrict" (RESTRICT), "clear" (SET NULL), or "cascade" (CASCADE). Default: restrict.';
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

COMMENT ON FUNCTION validate_reference_table IS
'Trigger function that rejects a field whose reference_table is set but does not match any entities.table_name. Enforced via trigger (not a CHECK) so it can run a subquery.';

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
-- PROVENANCE: catalog_entity_aliases append-only guard (v0.1.2)
-- =====================================================
-- A cross-domain reuse/merge APPENDS an alias element ({alias_code, source_domain, ...});
-- prior elements are never removed or rewritten. Enforced as a narrow BEFORE UPDATE guard
-- (cheaper + more targeted than a JsonLogic validation rule, and avoids running the full
-- compute_validate machinery for this one check): the new array must contain every element
-- of the old one (jsonb @> superset). The WHEN clause skips the no-op common case, so it is
-- inert during renames and metadata edits. Rejection shares the 23514 class used by
-- validation_rules. SECURITY DEFINER + pinned search_path per house style.

CREATE OR REPLACE FUNCTION enforce_catalog_aliases_append_only()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT (NEW.catalog_entity_aliases @> OLD.catalog_entity_aliases) THEN
        RAISE EXCEPTION 'catalog_entity_aliases is append-only: existing alias elements cannot be removed or rewritten'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_catalog_aliases_append_only IS
'BEFORE UPDATE guard on entities: catalog_entity_aliases may only grow (new array must contain all prior elements via jsonb @>). Enforces the append-only cross-domain merge ledger.';

REVOKE EXECUTE ON FUNCTION enforce_catalog_aliases_append_only() FROM PUBLIC;

CREATE TRIGGER enforce_catalog_aliases_append_only_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.catalog_entity_aliases IS DISTINCT FROM NEW.catalog_entity_aliases)
    EXECUTE FUNCTION enforce_catalog_aliases_append_only();

-- =====================================================
-- SEED CORE TABLES METADATA
-- =====================================================
-- Add metadata for core RBAC and dynamic table system tables
-- These are marked with a non-empty ctype (core) to indicate they are protected system columns

-- Insert entities metadata for core tables
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES 
    ('entities', 'entity', 'entities', 'Entity', 'Entities', 'Catalog of tables in Semantius', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'singular_label',
     '[{"code":"catalog_entity_code_write_once","message":"catalog_entity_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_entity_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_entity_code"},""]}]},true]}}]'::jsonb),
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Catalog of the fields that make up a table', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'id', 'title',
     '[{"code":"catalog_field_code_write_once","message":"catalog_field_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_field_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_field_code"},""]}]},true]}}]'::jsonb),
    ('users', 'user', 'users', 'User', 'Users', 'Users and agents', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email', '[]'::jsonb),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Groups of related tables and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name',
     '[{"code":"catalog_module_code_write_once","message":"catalog_module_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_module_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_module_code"},""]}]},true]}}]'::jsonb),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name',
     '[{"code":"origin_immutable_roles","message":"roles.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}},{"code":"system_role_slug_immutable","message":"system role slugs cannot be changed after creation","source_module":"platform","jsonlogic":{"if":[{"and":[{"value_changed":"slug"},{"==":[{"var":"origin"},"system"]}]},{"==":[{"var":"$old"},null]},true]}}]'::jsonb),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name', '[]'::jsonb),
    ('user_roles', 'user_role', 'user_roles', 'User Role', 'User Roles', 'Many-to-many mapping between users and roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('role_permissions', 'role_permission', 'role_permissions', 'Role Permission', 'Role Permissions', 'Many-to-many mapping between roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('user_permissions', 'user_permission', 'user_permissions', 'User Permission', 'User Permissions', 'Many-to-many mapping between users and permissions for direct per-user permission grants', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('permission_hierarchy', 'permission_hierarchy', 'permission_hierarchy', 'Permission Hierarchy', 'Permission Hierarchy', 'Defines permission inclusion (including permission implies included permissions)', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id',
     '[{"code":"origin_immutable_hierarchy","message":"permission_hierarchy.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}}]'::jsonb);

-- Stamp the pure junctions explicitly (entity_type='junction' is authoritative; see dd_is_junction
-- in 0145). The structural test is two parent FK legs with no relationship payload of their own —
-- audit/provenance columns (assigned_at/assigned_by, granted_at/granted_by, origin, created_at)
-- don't count. permission_hierarchy qualifies: its two legs both point at permissions and its only
-- non-leg fields are origin (provenance) and created_at (audit). Stamping it is authoritative — the
-- dd_is_junction heuristic alone would miss it because origin is not an audit-named/ctype column.
-- Runs before the entity_type-watching triggers (0145), so it's a plain seed-time stamp; the
-- label-function backfill at the end of 0145 then builds the junction-shaped labels for all entities.
UPDATE entities SET entity_type = 'junction'
WHERE table_name IN ('user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy');

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
    'json', 'html', 'text', 'multiline', 'code', 'jsonata', 'reference', 'parent', 'enum',
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
  ctype_values TEXT[] := ARRAY['', 'id', 'label', 'audit', 'core'];
  reference_delete_mode_values TEXT[] := ARRAY['', 'restrict', 'clear', 'cascade'];
  edit_mode_values TEXT[] := ARRAY['auto', 'sidebar', 'modal', 'page'];
  cube_mode_values TEXT[] := ARRAY['disabled', 'auto'];
  cube_type_values TEXT[] := ARRAY['auto', 'dimension', 'measure', 'disabled'];
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
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('fields', 'id',                   'Id',                   'Generated identifier (table_name.field_name)',                           '',         'text',      TRUE,  10,     'readonly', 'default', 'id',    FALSE, NULL,                            '',          '',        ''),
      ('fields', 'table_name',           'Table Name',           '',                                                                       '',         'parent',    FALSE, 20,     'default',  'default', 'core',  TRUE,  NULL,                            'entities',  'cascade', 'has fields'),
      ('fields', 'field_name',           'Field Name',           'Physical column name in database',                                       '',         'text',      FALSE, 30,     'required', 'default', 'core',  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'format',               'Format',               'JSON Schema format or primitive type',                                   'text',     'enum',      FALSE, 40,     'required', 'default', 'core',  FALSE, to_jsonb(format_values),         '',          '',        ''),
      ('fields', 'title',                'Title',                'Human-readable display name for the field',                              '',         'text',      FALSE, 50,     'required', 'default', 'label', TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'description',          'Description',          '',                                                                       '',         'text',      FALSE, 60,     'default',  'w',       'core',  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'is_pk',                'Is Primary Key',       '',                                                                       '',         'boolean',   FALSE, 70,     'default',  'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'default_value',        'Default Value',        '',                                                                       '',         'text',      FALSE, 90,     'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'field_order',          'Field Order',          '',                                                                       '',         'int32',     FALSE, 100,    'default',  'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'input_type',           'Input Type',           '',                                                                       'default',  'enum',      FALSE, 110,    'required', 'default', 'core',  FALSE, to_jsonb(input_type_values),     '',          '',        ''),
      ('fields', 'width',                'Width',                '',                                                                       'default',  'enum',      FALSE, 120,    'required', 'default', 'core',  FALSE, to_jsonb(width_values),          '',          '',        ''),
      ('fields', 'ctype',                'Column Type',          'Special column type (id, label, etc.)',                                  '',         'enum',      FALSE, 130,    'default',  'default', 'core',  FALSE, to_jsonb(ctype_values),          '',          '',        ''),
      ('fields', 'searchable',           'Searchable',           'Whether field is included in full-text search',                          '',         'boolean',   FALSE, 150,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'enum_values',          'Enum Values',          'JSON array of allowed enum values',                                      '',         'json',      FALSE, 160,    'hidden',   'w',       'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'precision',            'Precision',            'Decimal scale used when generating NUMERIC columns for number formats',  '2',        'int32',     FALSE, 170,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_table',      'Reference Table',      'Table name for foreign key relationships',                               '',         'text',      FALSE, 180,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_delete_mode','Reference Delete Mode','ON DELETE behavior: restrict, clear, or cascade',                        'restrict', 'enum',      FALSE, 190,    'hidden',   'default', 'core',  FALSE, to_jsonb(reference_delete_mode_values), '', '',     ''),
      ('fields', 'relationship_label',   'Relationship Label',   'Verb describing what the referenced entity does to/with this entity',   'has',      'text',      FALSE, 200,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'singular_label_parent','Singular Label Parent','Custom singular label for the parent entity (overrides default when set)','',        'text',      FALSE, 210,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'plural_label_parent',  'Plural Label Parent',  'Custom plural label for the parent entity (overrides default when set)', '',         'text',      FALSE, 220,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'unique_value',         'Unique Value',         'When TRUE, enforces a partial unique index (NULL and empty strings are not enforced)', '', 'boolean', FALSE, 230, 'hidden',  'default', 'core', FALSE, NULL,                           '',          '',        ''),
      ('fields', 'cube_type',            'Cube Type',            '',                                                                       'auto',     'enum',      FALSE, 240,    'required', 'default', 'core',  FALSE, to_jsonb(cube_type_values),      '',          '',        ''),
      ('fields', 'input_type_rule',      'Input Type Rule',      'JsonLogic condition for field visibility',                               '',         'json',      FALSE, 250,    'default',  'w',       'core',  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'catalog_field_code',   'Catalog Field Code',   'Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Empty = created outside the deploy pipeline.', '', 'text', FALSE, 260, 'default', 'default', 'core', FALSE, NULL,           '',          '',        ''),
      ('fields', 'created_at',           'Created At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', 'audit', FALSE, NULL,                            '',          '',        ''),
      ('fields', 'updated_at',           'Updated At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', 'audit', FALSE, NULL,                            '',          '',        '');

  -- Insert edit_mode field metadata for entities table (uses edit_mode_values defined above)
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('entities', 'edit_mode', 'Edit Mode', 'UI edit mode for records of this table: auto, sidebar, modal, or page', 'auto', 'enum', FALSE, 119, 'default', 'default', 'core', FALSE, to_jsonb(edit_mode_values), '', '', ''),
      ('entities', 'cube_mode', 'Cube Mode', 'Cube mode for OLAP cube generation', 'auto', 'enum', FALSE, 121, 'default', 'default', 'core', FALSE, to_jsonb(cube_mode_values), '', '', '');

  -- Conditional visibility rules for format-dependent fields on the fields table.
  -- These fields default to 'hidden' and become visible/required only when the
  -- selected format makes them meaningful.
  UPDATE fields SET input_type_rule = rule::jsonb
  FROM (VALUES
    ('enum_values',          '{"if":[{"==":[{"var":"format"},"enum"]},"required","hidden"]}'),
    ('precision',            '{"if":[{"==":[{"var":"format"},"number"]},"required","hidden"]}'),
    ('reference_table',      '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('reference_delete_mode','{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('relationship_label',   '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('singular_label_parent','{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'),
    ('plural_label_parent',  '{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'),
    ('default_value',        '{"if":[{"!=":[{"var":"format"},"boolean"]},"default","hidden"]}'),
    ('searchable',           '{"if":[{"in":[{"var":"format"},["string","text","multiline","html","code"]]},"default","hidden"]}'),
    ('unique_value',         '{"if":[{"in":[{"var":"format"},["boolean","multiline","html","code","json","object","array"]]},"hidden","default"]}')
  ) AS r(field_name, rule)
  WHERE fields.table_name = 'fields' AND fields.field_name = r.field_name;
END $$;

-- Insert fields metadata for entities table
INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('entities', 'table_name',     'Table Name',     'Physical table name in database',                       '',             'text',      TRUE,  1,   'required', 'default', 'id',   TRUE,  '', '',        ''),
    ('entities', 'singular',       'Singular',       'Singular form of table name (auto-derived from table_name when blank)', '', 'text',      FALSE, 10,  'default',  'default', 'core', TRUE,  '', '',        ''),
    ('entities', 'plural',         'Plural',         'Plural form of table name, auto-assigned to table_name','',             'text',      FALSE, 20,  'readonly', 'default', 'core', TRUE,  '', '',        ''),
    ('entities', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports',          '',             'text',      FALSE, 30,  'default',  'default', 'label',TRUE,  '', '',        ''),
    ('entities', 'plural_label',   'Plural Label',   'Human-readable plural label for UI/reports',            '',             'text',      FALSE, 40,  'default',  'default', 'core', TRUE,  '', '',        ''),
    ('entities', 'icon_url',       'Icon URL',       'Optional URL or path to icon for this table',           '',             'url',       FALSE, 50,  'default',  'w',       'core', FALSE, '', '',        ''),
    ('entities', 'description',    'Description',    '',                                                       '',             'text',      FALSE, 60,  'default',  'w',       'core', TRUE,  '', '',        ''),
    ('entities', 'module_id',      'Module Id',      '',                                                       '',             'reference', FALSE, 70,  'required', 'default', 'core', FALSE, 'modules', 'cascade', 'contains'),
    ('entities', 'view_permission','View Permission', 'Permission required to SELECT from this table',         'public:read',  'text',      FALSE, 80,  'default',  'default', 'core', FALSE, '', '',        ''),
    ('entities', 'edit_permission','Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'admin', 'text',      FALSE, 90,  'default',  'default', 'core', FALSE, '', '',        ''),
    ('entities', 'id_column',      'Id Column',      'Name of primary key column',                            'id',           'text',      FALSE, 100, 'default',  'default', 'core', FALSE, '', '',        ''),
    ('entities', 'label_column',   'Label Column',   'Name of label/display column',                          'label',        'text',      FALSE, 110, 'default',  'default', 'core', FALSE, '', '',        ''),
    ('entities', 'label_parent',   'Label Parent',   'Names the reference/parent FK that is this entity''s identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label).', '', 'text', FALSE, 111, 'default', 'default', 'core', FALSE, '', '', ''),
    ('entities', 'managed',        'Managed',        'When false, automatic DDL execution is disabled',       'true',         'boolean',   FALSE, 115, 'default',  'default', 'core', FALSE, '', '',        ''),
    ('entities', 'searchable',     'Searchable',     'Whether table is included in full-text search (auto-computed)', '',    'boolean',   FALSE, 117, 'disabled', 'default', 'core', FALSE, '', '',        ''),
    ('entities', 'is_child',       'Is Child',       'Whether table has any parent relationships (auto-computed)', '',       'boolean',   FALSE, 118, 'disabled', 'default', 'core', FALSE, '', '',        ''),
    ('entities', 'computed_fields','Computed Fields', 'JsonLogic derivations evaluated on every write',        '',             'json',      FALSE, 123, 'default',  'w',       'core', FALSE, '', '',        ''),
    ('entities', 'validation_rules','Validation Rules','JsonLogic invariants that must hold for the write to succeed','',     'json',      FALSE, 124, 'default',  'w',       'core', FALSE, '', '',        ''),
    ('entities', 'select_rule',    'Select Rule',    'JsonLogic rule for per-row FOR SELECT RLS policy',         '',             'json',      FALSE, 125, 'default',  'w',       'core', FALSE, '', '',        ''),
    ('entities', 'entity_type',    'Entity Type',    'Data-class axis (operational_workflow|operational_record|catalog|junction|computed|unclassified). Write tier derives from it; unclassified = absent/derive-locally.', 'unclassified', 'enum', FALSE, 122, 'readonly', 'default', 'core', FALSE, '', '', ''),
    ('entities', 'catalog_entity_code',    'Catalog Entity Code',    'Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Empty = created outside the deploy pipeline.', '', 'text', FALSE, 126, 'default', 'default', 'core', FALSE, '', '', ''),
    ('entities', 'catalog_owner_module', 'Catalog Owner Module', 'For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local.', '', 'text', FALSE, 127, 'default', 'default', 'core', FALSE, '', '', ''),
    ('entities', 'catalog_entity_aliases', 'Catalog Entity Aliases', 'Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target.', '[]', 'json', FALSE, 129, 'default', 'w', 'core', FALSE, '', '', ''),
    ('entities', 'created_at',     'Created At',     '',                                                       '',             'date-time', FALSE, 130, 'disabled', 'default', 'audit', FALSE, '', '',        ''),
    ('entities', 'updated_at',     'Updated At',     '',                                                       '',             'date-time', FALSE, 140, 'disabled', 'default', 'audit', FALSE, '', '',        '');

-- entity_type is a closed enum; the physical CHECK is inline in CREATE TABLE entities (exactly 6
-- values). Set the DD enum_values for UI/get_schema, mirroring how module_type is handled below.
UPDATE fields SET enum_values = '["operational_workflow", "operational_record", "catalog", "junction", "computed", "unclassified"]'::jsonb
WHERE table_name = 'entities' AND field_name = 'entity_type';

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('users', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', FALSE, '', ''),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'text', FALSE, 10, 'readonly', 'default', 'core', TRUE, '', ''),
    ('users', 'email', 'Email', '', 'email', FALSE, 20, 'default', 'default', 'label', TRUE, '', ''),
    ('users', 'display_name', 'Display Name', '', 'text', FALSE, 25, 'default', 'default', 'core', TRUE, '', ''),
    ('users', 'is_disabled', 'Is Disabled', '', 'boolean', FALSE, 30, 'default', 'default', 'core', FALSE, '', ''),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, 35, 'default', 'w', 'core', FALSE, '', ''),
    ('users', 'created_at', 'Created At', '', 'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '', ''),
    ('users', 'updated_at', 'Updated At', '', 'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '', ''),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, 60, 'readonly', 'default', 'core', FALSE, '', '');

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('modules', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', FALSE, '', ''),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, 10, 'required', 'default', 'label', TRUE, '', ''),
    ('modules', 'description', 'Description', '', 'text', FALSE, 20, 'default', 'w', 'core', TRUE, '', ''),
    ('modules', 'module_type', 'Module Type', 'Module type: domain (normal) or master (promoted for sharing)', 'enum', FALSE, 25, 'readonly', 'default', 'core', FALSE, '', ''),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'text', FALSE, 30, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, 36, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'icon_name', 'Icon Name', 'Icon or logo name identifier', 'text', FALSE, 37, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, 38, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'module_slug', 'Module Slug', 'URL-safe unique identifier for module', 'text', FALSE, 38, 'required', 'default', 'core', FALSE, '', ''),
    ('modules', 'catalog_module_code', 'Catalog Module Code', 'Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Empty = greenfield.', 'text', FALSE, 44, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'domain_code', 'Domain Code', 'Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM)', 'text', FALSE, 45, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'access_scope', 'Access Scope', 'Basic for simple read/edit; full for role tiers, approvals & gating', 'enum', FALSE, 46, 'default', 'default', 'core', FALSE, '', ''),
    ('modules', 'manage_permission_id', 'Manage Permission', '', 'reference', FALSE, 39, 'default', 'default', 'core', FALSE, 'permissions', 'clear'),
    ('modules', 'admin_permission_id', 'Admin Permission', '', 'reference', FALSE, 40, 'default', 'default', 'core', FALSE, 'permissions', 'clear'),
    ('modules', 'default_viewer_role_id', 'Default Viewer Role', '', 'reference', FALSE, 41, 'default', 'default', 'core', FALSE, 'roles', 'clear'),
    ('modules', 'default_manager_role_id', 'Default Manager Role', '', 'reference', FALSE, 42, 'default', 'default', 'core', FALSE, 'roles', 'clear'),
    ('modules', 'default_admin_role_id', 'Default Admin Role', '', 'reference', FALSE, 43, 'default', 'default', 'core', FALSE, 'roles', 'clear'),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, 50, 'default', 'w', 'core', FALSE, '', ''),
    ('modules', 'dashboard_config', 'Dashboard Configuration', '', 'json', FALSE, 60, 'default', 'w', 'core', FALSE, '', ''),
    ('modules', 'created_at', 'Created At', '', 'date-time', FALSE, 90, 'disabled', 'default', 'audit', FALSE, '', ''),
    ('modules', 'updated_at', 'Updated At', '', 'date-time', FALSE, 100, 'disabled', 'default', 'audit', FALSE, '', '');

-- Set enum_values for module_type field
UPDATE fields SET enum_values = '["domain", "master"]'::jsonb WHERE table_name = 'modules' AND field_name = 'module_type';

-- Set enum_values for access_scope field (DB column default is 'basic')
UPDATE fields SET enum_values = '["basic", "full"]'::jsonb WHERE table_name = 'modules' AND field_name = 'access_scope';

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('roles', 'id',          'Id',          '',                              'int32',     TRUE,  1,  'readonly', 'default', 'id',    FALSE, '',        '',      ''),
    ('roles', 'role_name',   'Role Name',   'Unique role name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE,  '',        '',      ''),
    ('roles', 'slug',        'Slug',        'Snake_case unique identifier for role, auto-generated from role_name', 'text', FALSE, 15, 'readonly', 'default', 'core', FALSE, '', '', ''),
    ('roles', 'catalog_role_code', 'Catalog Role Code', 'Stable catalog persona/role this role was provisioned from (lineage; non-unique). Empty = created outside the pipeline.', 'text', FALSE, 16, 'default', 'default', 'core', FALSE, '', '', ''),
    ('roles', 'description', 'Description', '',                              'multiline', FALSE, 20, 'default',  'w',       'core',  TRUE,  '',        '',      ''),
    ('roles', 'origin',      'Origin',      '', 'enum', FALSE, 25, 'readonly', 'default', 'core', FALSE, '', '', ''),
    ('roles', 'module_id',   'Module Id',   'Module this role belongs to',   'reference', FALSE, 30, 'default',  'default', 'core',  FALSE, 'modules', 'clear', 'contains'),
    ('roles', 'created_at',  'Created At',  '',                              'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '',        '',      ''),
    ('roles', 'updated_at',  'Updated At',  '',                              'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '',        '',      '');

-- Mark roles.slug as unique (matches UNIQUE constraint on actual table)
UPDATE fields SET unique_value = TRUE WHERE table_name = 'roles' AND field_name = 'slug';

-- Set enum_values for roles.origin field
UPDATE fields SET enum_values = '["system", "model", "model_master", "user"]'::jsonb WHERE table_name = 'roles' AND field_name = 'origin';

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permissions', 'id',              'Id',              '',                                    'int32',     TRUE,  1,  'readonly', 'default', 'id',    FALSE, '',        '',      ''),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE,  '',        '',      ''),
    ('permissions', 'description',     'Description',     '',                                    'multiline', FALSE, 20, 'default',  'w',       'core',  TRUE,  '',        '',      ''),
    ('permissions', 'module_id',       'Module Id',       'Module this permission belongs to',   'reference', FALSE, 30, 'required', 'default', 'core',  FALSE, 'modules', 'cascade', 'contains'),
    ('permissions', 'created_at',      'Created At',      '',                                    'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '',        '',      ''),
    ('permissions', 'updated_at',      'Updated At',      '',                                    'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '',        '',      '');

-- Mark permission_name as unique (matches UNIQUE constraint on actual table)
UPDATE fields SET unique_value = TRUE WHERE table_name = 'permissions' AND field_name = 'permission_name';

-- Insert fields metadata for user_roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_roles', 'id',          'Id',          'Generated identifier (user_id.role_id)',  'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',      '',        ''),
    ('user_roles', 'user_id',     'User Id',     'User this role is assigned to',           'parent',    FALSE, 10, 'required', 'default', 'core', FALSE, 'users', 'cascade', 'has roles'),
    ('user_roles', 'role_id',     'Role Id',     'Role assigned to the user',               'parent',    FALSE, 20, 'required', 'default', 'core', FALSE, 'roles', 'cascade', 'assigned to'),
    ('user_roles', 'assigned_at', 'Assigned At', 'Timestamp when role was assigned',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',      '',        ''),
    ('user_roles', 'assigned_by', 'Assigned By', 'User who assigned this role',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users', 'clear',   'has assigned');

UPDATE fields SET singular_label_parent = 'Role', plural_label_parent = 'Roles' WHERE table_name = 'user_roles' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User', plural_label_parent = 'Users' WHERE table_name = 'user_roles' AND field_name = 'role_id';

-- Insert fields metadata for role_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('role_permissions', 'id',            'Id',            'Generated identifier (role_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',            '',        ''),
    ('role_permissions', 'role_id',       'Role Id',       'Role this permission is granted to',           'parent',    FALSE, 10, 'default',  'default', 'core', FALSE, 'roles',        'cascade', 'has permissions'),
    ('role_permissions', 'permission_id', 'Permission Id', 'Permission granted to the role',               'parent',    FALSE, 20, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'granted to'),
    ('role_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',             '',        ''),
    ('role_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users',        'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'role_id';
UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for user_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_permissions', 'id',            'Id',            'Generated identifier (user_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',             '',        ''),
    ('user_permissions', 'user_id',       'User Id',       'User this permission is granted to',           'parent',    FALSE, 10, 'required', 'default', 'core', FALSE, 'users',         'cascade', 'has permissions'),
    ('user_permissions', 'permission_id', 'Permission Id', 'Permission granted to the user',               'parent',    FALSE, 20, 'required', 'default', 'core', FALSE, 'permissions',   'cascade', 'granted to'),
    ('user_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',              '',        ''),
    ('user_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users',         'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'user_permissions' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User',       plural_label_parent = 'Users'       WHERE table_name = 'user_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for permission_hierarchy table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permission_hierarchy', 'id',                      'Id',                      'Generated identifier (including_permission_id.included_permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',             '',        ''),
    ('permission_hierarchy', 'including_permission_id',  'Including Permission Id',  'The broader permission that includes other permissions',                 'parent',    FALSE, 10, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'includes'),
    ('permission_hierarchy', 'included_permission_id',   'Included Permission Id',   'The narrower permission that is included by the broader one',            'parent',    FALSE, 20, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'included in'),
    ('permission_hierarchy', 'origin',                'Origin',                'How this hierarchy entry was created',                             'enum',      FALSE, 25, 'readonly', 'default', 'core', FALSE, '',             '',        ''),
    ('permission_hierarchy', 'created_at',            'Created At',            '',                                                                'date-time', FALSE, 30, 'disabled', 'default', 'audit', FALSE, '',             '',        '');

UPDATE fields SET singular_label_parent = 'Includes',    plural_label_parent = 'Includes'    WHERE table_name = 'permission_hierarchy' AND field_name = 'including_permission_id';
UPDATE fields SET singular_label_parent = 'Included in', plural_label_parent = 'Included in' WHERE table_name = 'permission_hierarchy' AND field_name = 'included_permission_id';

-- Set enum_values for permission_hierarchy.origin field
UPDATE fields SET enum_values = '["system", "model", "model_master", "user"]'::jsonb WHERE table_name = 'permission_hierarchy' AND field_name = 'origin';

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION validate_reference_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auto_set_plural() FROM PUBLIC;