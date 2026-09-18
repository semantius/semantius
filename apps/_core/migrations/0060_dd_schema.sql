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
    -- RESTRICT, not the deferred NO ACTION modules.view_permission needs: an
    -- entity is always created after the permissions it names, so an immediate
    -- check fails early instead of at commit.
    view_permission TEXT NOT NULL DEFAULT 'public:read'
        REFERENCES permissions(permission_name) ON DELETE RESTRICT ON UPDATE CASCADE,
    edit_permission TEXT NOT NULL DEFAULT 'admin'
        REFERENCES permissions(permission_name) ON DELETE RESTRICT ON UPDATE CASCADE,
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
    -- Catalog codes: which catalog blueprint this entity was built from. The modeler writes them so a
    -- later run can find the entity again after a rename or merge. They default empty, which is what
    -- an entity created outside the catalog has.
    catalog_entity_code TEXT NOT NULL DEFAULT '',        -- canonical uber-model code; rename/dialect/silo join key
    catalog_owner_module TEXT NOT NULL DEFAULT '',       -- soft slug pointer to the catalog owner module (not an FK)
    entity_type TEXT NOT NULL DEFAULT 'unclassified',    -- kind of data held; editable; the platform acts only on 'junction' (dd_is_junction in 0145)
    catalog_entity_aliases JSONB NOT NULL DEFAULT '[]'::jsonb, -- append-only [{alias_code, source_domain, ...}] merge ledger
    order_column TEXT NOT NULL DEFAULT '',
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
    -- entity_type is a closed set of 6 values; 'unclassified' is its empty value, so '' is rejected.
    -- This inline CHECK is the only one on the column: the field-metadata seed below runs before the
    -- add_dd_field trigger exists, so the dictionary builds no enum CHECK of its own for it.
    -- catalog_entity_aliases must be a JSON array.
    CONSTRAINT valid_entity_type CHECK (entity_type IN
        ('operational_workflow', 'operational_record', 'catalog', 'junction', 'computed', 'unclassified')),
    CONSTRAINT catalog_entity_aliases_is_array CHECK (jsonb_typeof(catalog_entity_aliases) = 'array'),
    CONSTRAINT valid_order_column CHECK (order_column = '' OR order_column ~ '^[a-z_][a-z0-9_]*$')
);

CREATE INDEX idx_entities_module ON entities(module_id);
-- The two permission columns are RESTRICT foreign keys, so every permission
-- delete and every rename scans them. The dictionary builds idx_<table>_<field>
-- for a reference field it creates; these are declared by hand, so their
-- indexes are too.
CREATE INDEX idx_entities_view_permission ON entities(view_permission);
CREATE INDEX idx_entities_edit_permission ON entities(edit_permission);

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
COMMENT ON COLUMN entities.order_column IS 'Store a fixed row order in this column';
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
    id TEXT GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY,
    -- ON UPDATE CASCADE carries a rename of entities.table_name (0140) to the fields rows.
    table_name TEXT NOT NULL REFERENCES entities(table_name) ON DELETE CASCADE ON UPDATE CASCADE,
    field_name TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    format TEXT NOT NULL DEFAULT 'text',
    is_pk BOOLEAN NOT NULL DEFAULT FALSE,
    -- A default is a value (or one of the argument-less SQL expressions
    -- quote_default_value() allow-lists), never a statement: the dictionary
    -- interpolates it into ALTER TABLE ... DEFAULT, so statement separators and
    -- comment markers are rejected outright as a second line of defense.
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
COMMENT ON COLUMN fields.input_type_rule IS 'JsonLogic rule evaluated client-side against the record being edited. It returns an input_type (default, required, readonly, disabled or hidden) that replaces the static input_type. Empty {} = no rule.';
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
            RAISE EXCEPTION 'Referenced table ${table} not found in entities'
                USING ERRCODE = '90212',
                      HINT = jsonb_build_object('table', NEW.reference_table)::text;
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
    USING ((SELECT rbac.has_permission('public:read')));

CREATE POLICY entities_insert_policy ON entities
    FOR INSERT
    TO semantius_user
    WITH CHECK ((SELECT rbac.has_permission('admin')));

CREATE POLICY entities_update_policy ON entities
    FOR UPDATE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')))
    WITH CHECK ((SELECT rbac.has_permission('admin')));

CREATE POLICY entities_delete_policy ON entities
    FOR DELETE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

-- =====================================================
-- RLS POLICIES FOR FIELDS
-- =====================================================

CREATE POLICY fields_select_policy ON fields
    FOR SELECT
    TO semantius_user
    USING ((SELECT rbac.has_permission('public:read')));

CREATE POLICY fields_insert_policy ON fields
    FOR INSERT
    TO semantius_user
    WITH CHECK ((SELECT rbac.has_permission('admin')));

CREATE POLICY fields_update_policy ON fields
    FOR UPDATE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')))
    WITH CHECK ((SELECT rbac.has_permission('admin')));

CREATE POLICY fields_delete_policy ON fields
    FOR DELETE
    TO semantius_user
    USING ((SELECT rbac.has_permission('admin')));

-- =====================================================
-- GRANT THE REQUEST ROLE ACCESS TO THE METADATA TABLES
-- =====================================================
-- These two are created after 0050's one-time GRANT ... ON ALL TABLES and there
-- is no default privilege in this schema to pick them up, so the request role
-- reaches them only through this grant. It comes after the RLS enable and the
-- eight policies above, in that order: a grant is what publishes a table
-- through the Data API, and until policies exist it is the whole of that
-- table's access control. Neither table has a sequence - entities is keyed by
-- table_name and fields.id is a generated text column.
GRANT SELECT, INSERT, UPDATE, DELETE ON entities, fields TO semantius_user;

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
            USING ERRCODE = '90213';
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
--
-- entity_type: the pure junctions are stamped explicitly (entity_type='junction' is authoritative; see
-- dd_is_junction in 0145). The structural test is two parent FK legs with no relationship payload of their
-- own — audit/provenance columns (assigned_at/assigned_by, granted_at/granted_by, origin, created_at)
-- don't count. permission_hierarchy qualifies: its two legs both point at permissions and its only
-- non-leg fields are origin (provenance) and created_at (audit). Stamping it is authoritative — the
-- dd_is_junction heuristic alone would miss it because origin is not an audit-named/ctype column.
-- This seed runs before the entity_type-watching triggers (0145); the label-function backfill at the
-- end of 0145 then builds the junction-shaped labels for all entities.
--
-- Rule 90702 accepts an empty module_slug: it is the column default and not every flow sets a slug.
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, validation_rules, entity_type, audit_log, order_column)
VALUES 
    ('entities', 'entity', 'entities', 'Entity', 'Entities', 'Catalog of tables in Semantius', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'singular_label',
     '[{"code":"90201","message":"catalog_entity_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_entity_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_entity_code"},""]}]},true]}}]'::jsonb, 'unclassified', TRUE, ''),
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Catalog of the fields that make up a table', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'id', 'title',
     '[{"code":"90202","message":"catalog_field_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_field_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_field_code"},""]}]},true]}}]'::jsonb, 'unclassified', TRUE, 'field_order'),
    ('users', 'user', 'users', 'User', 'Users', 'Users and agents', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email', '[]'::jsonb, 'unclassified', TRUE, ''),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Groups of related tables and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name',
     '[{"code":"90701","message":"catalog_module_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_module_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_module_code"},""]}]},true]}},{"code":"90702","message":"module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, ''-'' and ''_''","source_module":"platform","jsonlogic":{"or":[{"==":[{"var":"module_slug"},""]},{"is_match":[{"var":"module_slug"},"^[a-z0-9][a-z0-9_-]*$"]}]}}]'::jsonb, 'unclassified', TRUE, ''),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name',
     '[{"code":"90203","message":"roles.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}},{"code":"90204","message":"system role slugs cannot be changed after creation","source_module":"platform","jsonlogic":{"if":[{"and":[{"value_changed":"slug"},{"==":[{"var":"origin"},"system"]}]},{"==":[{"var":"$old"},null]},true]}},{"code":"90206","message":"catalog_role_code is write-once: it cannot be changed once set","source_module":"platform","jsonlogic":{"if":[{"value_changed":"catalog_role_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_role_code"},""]}]},true]}}]'::jsonb, 'unclassified', TRUE, ''),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'permission_name', 'permission_name', '[]'::jsonb, 'unclassified', TRUE, ''),
    ('user_roles', 'user_role', 'user_roles', 'User Role', 'User Roles', 'Many-to-many mapping between users and roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb, 'junction', TRUE, ''),
    ('role_permissions', 'role_permission', 'role_permissions', 'Role Permission', 'Role Permissions', 'Many-to-many mapping between roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb, 'junction', TRUE, ''),
    ('user_permissions', 'user_permission', 'user_permissions', 'User Permission', 'User Permissions', 'Many-to-many mapping between users and permissions for direct per-user permission grants', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb, 'junction', TRUE, ''),
    ('permission_hierarchy', 'permission_hierarchy', 'permission_hierarchy', 'Permission Hierarchy', 'Permission Hierarchy', 'Defines permission inclusion (including permission implies included permissions)', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id',
     '[{"code":"90205","message":"permission_hierarchy.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}}]'::jsonb, 'junction', TRUE, '');

-- =====================================================
-- FIELD FORMATS
-- =====================================================
-- SemSchema's formats.json, verbatim. json, not jsonb: jsonb does not keep key
-- order, and the key order is the order the fields.format enum offers.

CREATE OR REPLACE FUNCTION dd_formats()
RETURNS json LANGUAGE sql IMMUTABLE SET search_path = public
AS $f$ SELECT $formats${
  "json": {
    "type": [
      "object",
      "array",
      "string",
      "number",
      "integer",
      "boolean",
      "null"
    ],
    "description": "JSON value, or JSON text that parses to one"
  },
  "html": {
    "type": "string",
    "description": "HTML markup; must contain at least one tag"
  },
  "text": {
    "type": "string",
    "description": "Single-line text; no format check"
  },
  "multiline": {
    "type": "string",
    "description": "Multi-line text; no format check"
  },
  "code": {
    "type": "string",
    "description": "Source code; no format check"
  },
  "jsonata": {
    "type": "string",
    "description": "JSONata expression; no format check"
  },
  "jsonlogic": {
    "type": [
      "object",
      "array",
      "string",
      "number",
      "integer",
      "boolean",
      "null"
    ],
    "description": "JsonLogic rule, checked against the operators of the Semantius backend"
  },
  "reference": {
    "type": "integer",
    "description": "Key of a record in another entity"
  },
  "parent": {
    "type": "integer",
    "description": "Key of the record that owns this one"
  },
  "enum": {
    "type": "string",
    "description": "One of the values listed in enum"
  },
  "date": {
    "type": "string",
    "description": "Full date, RFC 3339 (2026-09-15)"
  },
  "time": {
    "type": "string",
    "description": "Time of day, RFC 3339 (14:30:00Z)"
  },
  "date-time": {
    "type": "string",
    "description": "Date and time, RFC 3339 (2026-09-15T14:30:00Z)"
  },
  "duration": {
    "type": "string",
    "description": "Duration, ISO 8601 (P3DT4H)"
  },
  "uri": {
    "type": "string",
    "description": "Absolute URI, RFC 3986; Unicode allowed as in an IRI (https://müller.de/straße); validates the same as iri"
  },
  "uri-reference": {
    "type": "string",
    "description": "URI or relative reference, RFC 3986; Unicode allowed as in an IRI (/straße, #top); validates the same as iri-reference"
  },
  "iri": {
    "type": "string",
    "description": "Absolute IRI, RFC 3987 (https://müller.de/straße); validates the same as uri"
  },
  "iri-reference": {
    "type": "string",
    "description": "IRI or relative reference, RFC 3987 (/straße, #top); validates the same as uri-reference"
  },
  "uri-template": {
    "type": "string",
    "description": "URI template, RFC 6570 (/users/{id})"
  },
  "url": {
    "type": "string",
    "description": "URL with an http, https or ftp scheme"
  },
  "email": {
    "type": "string",
    "description": "Email address, RFC 5321; Unicode allowed as in RFC 6531 (jörg@müller.de); validates the same as idn-email"
  },
  "idn-email": {
    "type": "string",
    "description": "Internationalized email address, RFC 6531 (jörg@müller.de); validates the same as email"
  },
  "hostname": {
    "type": "string",
    "description": "Host name, RFC 1123; Unicode allowed as in RFC 5890 (müller.de, xn--mller-kva.de); validates the same as idn-hostname"
  },
  "idn-hostname": {
    "type": "string",
    "description": "Internationalized host name, RFC 5890 (müller.de, xn--mller-kva.de); validates the same as hostname"
  },
  "ipv4": {
    "type": "string",
    "description": "IPv4 address"
  },
  "ipv6": {
    "type": "string",
    "description": "IPv6 address"
  },
  "regex": {
    "type": "string",
    "description": "Regular expression"
  },
  "uuid": {
    "type": "string",
    "description": "UUID, RFC 4122"
  },
  "json-pointer": {
    "type": "string",
    "description": "JSON Pointer, RFC 6901 (/a/0)"
  },
  "json-pointer-uri-fragment": {
    "type": "string",
    "description": "JSON Pointer as a URI fragment (#/a/0)"
  },
  "relative-json-pointer": {
    "type": "string",
    "description": "Relative JSON Pointer (1/a)"
  },
  "byte": {
    "type": "string",
    "description": "Base64-encoded data"
  },
  "binary": {
    "type": "string",
    "description": "Binary data; no format check"
  },
  "password": {
    "type": "string",
    "description": "Password; no format check"
  },
  "int32": {
    "type": "integer",
    "description": "Signed 32-bit integer"
  },
  "int64": {
    "type": "integer",
    "description": "Signed 64-bit integer"
  },
  "float": {
    "type": "number",
    "description": "Single-precision floating-point number"
  },
  "double": {
    "type": "number",
    "description": "Double-precision floating-point number"
  },
  "string": {
    "type": "string",
    "description": "Any string"
  },
  "number": {
    "type": "number",
    "description": "Any number"
  },
  "integer": {
    "type": "integer",
    "description": "Any integer"
  },
  "boolean": {
    "type": "boolean",
    "description": "true or false"
  },
  "object": {
    "type": "object",
    "description": "Any JSON object"
  },
  "array": {
    "type": "array",
    "description": "Any JSON array"
  }
}$formats$::json $f$;

COMMENT ON FUNCTION dd_formats() IS
'The field formats (SemSchema formats.json): format name -> {type, description}, in the order the fields.format enum offers them.';

REVOKE EXECUTE ON FUNCTION dd_formats() FROM PUBLIC;

-- =====================================================
-- ADD ENUM CONSTRAINTS AND INSERT FIELD METADATA USING DRY PRINCIPLE
-- =====================================================
-- Define enum value arrays ONCE and use for both CHECK constraints and field metadata
-- This ensures no duplication and maintains consistency

DO $$
DECLARE
  -- Define all enum value arrays in one place
  format_values TEXT[] := ARRAY(
    SELECT k FROM json_object_keys(dd_formats()) WITH ORDINALITY AS t(k, n) ORDER BY n
  );
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
    'ALTER TABLE fields ADD CONSTRAINT valid_format CHECK (format = ANY(%L))',
    format_values
  );

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
  -- input_type_rule: the format-dependent fields default to 'hidden' and become visible/required
  -- only when the selected format makes them meaningful.
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, enum_values, reference_table, reference_delete_mode, relationship_label, input_type_rule)
  VALUES
      ('fields', 'id',                   'Id',                   'Generated identifier (table_name.field_name)',                           '',         'text',      TRUE,  10,     'readonly', 'default', 'id',    FALSE, NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'table_name',           'Table Name',           'Entity this field belongs to',                                                                       '',         'parent',    FALSE, 20,     'default',  'default', 'core',  TRUE,  NULL,                            'entities',  'cascade', 'has fields', '{}'::jsonb),
      ('fields', 'field_name',           'Field Name',           'Physical column name in database',                                       '',         'text',      FALSE, 30,     'required', 'default', 'core',  TRUE,  NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'format',               'Format',               'JSON Schema format or primitive type',                                   'text',     'enum',      FALSE, 40,     'required', 'default', 'core',  FALSE, to_jsonb(format_values),         '',          '',        '', '{}'::jsonb),
      ('fields', 'title',                'Title',                'Human-readable display name for the field',                              '',         'text',      FALSE, 50,     'required', 'default', 'label', TRUE,  NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'description',          'Description',          'What the field represents',                                                                       '',         'text',      FALSE, 60,     'default',  'w',       'core',  TRUE,  NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'is_pk',                'Is Primary Key',       'Whether this field is the primary key; cannot change after the field is created',                                                                       '',         'boolean',   FALSE, 70,     'default',  'default', 'core',  FALSE, NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'default_value',        'Default Value',        'Column default: a literal value or an SQL expression such as CURRENT_TIMESTAMP',                                                                       '',         'text',      FALSE, 90,     'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"!=":[{"var":"format"},"boolean"]},"default","hidden"]}'::jsonb),
      ('fields', 'field_order',          'Field Order',          'Display order of the field within its entity',                                                                       '',         'int32',     FALSE, 100,    'default',  'default', 'core',  FALSE, NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'input_type',           'Input Type',           'How the UI presents the field for input; input_type_rule can override it per record',                                                                       'default',  'enum',      FALSE, 110,    'required', 'default', 'core',  FALSE, to_jsonb(input_type_values),     '',          '',        '', '{}'::jsonb),
      ('fields', 'width',                'Width',                'Display width of the field in the UI',                                                                       'default',  'enum',      FALSE, 120,    'required', 'default', 'core',  FALSE, to_jsonb(width_values),          '',          '',        '', '{}'::jsonb),
      ('fields', 'ctype',                'Column Type',          'Marks a DD-managed core column: empty (normal user field), id (primary key), label (display field), audit (record-versioning columns such as created_at and updated_at) or core (other system columns). A core column cannot be deleted or renamed (the label column may be renamed), and its format and default value cannot change. Set by the DD only and never changed.',                                  '',         'enum',      FALSE, 130,    'default',  'default', 'core',  FALSE, to_jsonb(ctype_values),          '',          '',        '', '{}'::jsonb),
      ('fields', 'searchable',           'Searchable',           'Whether field is included in full-text search',                          '',         'boolean',   FALSE, 150,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"in":[{"var":"format"},["string","text","multiline","html","code"]]},"default","hidden"]}'::jsonb),
      ('fields', 'enum_values',          'Enum Values',          'JSON array of allowed enum values',                                      '',         'json',      FALSE, 160,    'hidden',   'w',       'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"==":[{"var":"format"},"enum"]},"required","hidden"]}'::jsonb),
      ('fields', 'precision',            'Precision',            'Decimal scale used when generating NUMERIC columns for number formats',  '2',        'int32',     FALSE, 170,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"==":[{"var":"format"},"number"]},"required","hidden"]}'::jsonb),
      ('fields', 'reference_table',      'Reference Table',      'Table name for foreign key relationships',                               '',         'text',      FALSE, 180,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'::jsonb),
      ('fields', 'reference_delete_mode','Reference Delete Mode','What happens to this record when the referenced record is deleted: restrict (the delete is blocked), clear (this field is set to NULL) or cascade (this record is deleted too). Empty on fields that are not a reference or parent; on a reference, empty acts as restrict.',                        'restrict', 'enum',      FALSE, 190,    'hidden',   'default', 'core',  FALSE, to_jsonb(reference_delete_mode_values), '', '',     '', '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'::jsonb),
      ('fields', 'relationship_label',   'Relationship Label',   'Verb describing what the referenced entity does to/with this entity',   'has',      'text',      FALSE, 200,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'::jsonb),
      ('fields', 'singular_label_parent','Singular Label Parent','Custom singular label for the parent entity (overrides default when set)','',        'text',      FALSE, 210,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'::jsonb),
      ('fields', 'plural_label_parent',  'Plural Label Parent',  'Custom plural label for the parent entity (overrides default when set)', '',         'text',      FALSE, 220,    'hidden',   'default', 'core',  FALSE, NULL,                            '',          '',        '', '{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'::jsonb),
      ('fields', 'unique_value',         'Unique Value',         'When TRUE, enforces a partial unique index (NULL and empty strings are not enforced)', '', 'boolean', FALSE, 230, 'hidden',  'default', 'core', FALSE, NULL,                           '',          '',        '', '{"if":[{"in":[{"var":"format"},["boolean","multiline","html","code","json","jsonlogic","object","array"]]},"hidden","default"]}'::jsonb),
      ('fields', 'cube_type',            'Cube Type',            'Role of the field in the generated OLAP cube (dimension or measure); auto lets the platform choose, disabled leaves the field out',                                                                       'auto',     'enum',      FALSE, 240,    'required', 'default', 'core',  FALSE, to_jsonb(cube_type_values),      '',          '',        '', '{}'::jsonb),
      ('fields', 'input_type_rule',      'Input Type Rule',      'JsonLogic rule returning an input_type (default, required, readonly, disabled or hidden) that replaces the static input_type', '',         'jsonlogic', FALSE, 250,    'default',  'w',       'core',  FALSE, NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'catalog_field_code',   'Catalog Field Code',   'Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec.', '', 'text', FALSE, 260, 'default', 'default', 'core', FALSE, NULL,           '',          '',        '', '{}'::jsonb),
      ('fields', 'created_at',           'Created At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', 'audit', FALSE, NULL,                            '',          '',        '', '{}'::jsonb),
      ('fields', 'updated_at',           'Updated At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', 'audit', FALSE, NULL,                            '',          '',        '', '{}'::jsonb);

  -- Insert edit_mode field metadata for entities table (uses edit_mode_values defined above)
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('entities', 'edit_mode', 'Edit Mode', 'UI edit mode for records of this table: auto, sidebar, modal, or page', 'auto', 'enum', FALSE, 119, 'default', 'default', 'core', FALSE, to_jsonb(edit_mode_values), '', '', ''),
      ('entities', 'cube_mode', 'Cube Mode', 'Cube mode for OLAP cube generation', 'auto', 'enum', FALSE, 121, 'default', 'default', 'core', FALSE, to_jsonb(cube_mode_values), '', '', '');

END $$;

-- Insert fields metadata for entities table
-- entity_type is a closed enum; its enum_values mirror the valid_entity_type CHECK inline in
-- CREATE TABLE entities (exactly 6 values).
INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, enum_values)
VALUES
    ('entities', 'table_name',     'Table Name',     'Physical table name in database',                       '',             'text',      TRUE,  1,   'required', 'default', 'id',   TRUE,  '', '',        '', NULL),
    ('entities', 'singular',       'Singular',       'Singular form of table name (auto-derived from table_name when blank)', '', 'text',      FALSE, 10,  'default',  'default', 'core', TRUE,  '', '',        '', NULL),
    ('entities', 'plural',         'Plural',         'Plural form of table name, auto-assigned to table_name','',             'text',      FALSE, 20,  'readonly', 'default', 'core', TRUE,  '', '',        '', NULL),
    ('entities', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports',          '',             'text',      FALSE, 30,  'default',  'default', 'label',TRUE,  '', '',        '', NULL),
    ('entities', 'plural_label',   'Plural Label',   'Human-readable plural label for UI/reports',            '',             'text',      FALSE, 40,  'default',  'default', 'core', TRUE,  '', '',        '', NULL),
    ('entities', 'icon_url',       'Icon URL',       'Optional URL or path to icon for this table',           '',             'url',       FALSE, 50,  'default',  'w',       'core', FALSE, '', '',        '', NULL),
    ('entities', 'description',    'Description',    'What the entity represents',                                                       '',             'text',      FALSE, 60,  'default',  'w',       'core', TRUE,  '', '',        '', NULL),
    ('entities', 'module_id',      'Module Id',      'Module this entity belongs to',                                                       '',             'reference', FALSE, 70,  'required', 'default', 'core', FALSE, 'modules', 'cascade', 'contains', NULL),
    ('entities', 'view_permission','View Permission', 'Permission required to SELECT from this table',         'public:read',  'reference', FALSE, 80,  'default',  'default', 'core', FALSE, 'permissions', 'restrict', 'gates viewing', NULL),
    ('entities', 'edit_permission','Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'admin', 'reference', FALSE, 90,  'default',  'default', 'core', FALSE, 'permissions', 'restrict', 'gates editing', NULL),
    ('entities', 'id_column',      'Id Column',      'Name of primary key column',                            'id',           'text',      FALSE, 100, 'default',  'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'label_column',   'Label Column',   'Name of label/display column',                          'label',        'text',      FALSE, 110, 'default',  'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'label_parent',   'Label Parent',   'Reference or parent field of this entity whose record label the composed _label is built from (the identity spine). Empty = self-identifying: the composed label is the local label. Not allowed on a junction entity, and the spine must stay acyclic.', '', 'text', FALSE, 111, 'default', 'default', 'core', FALSE, '', '', '', NULL),
    ('entities', 'order_column',   'Order Column',   'Name of an integer column that stores a fixed row order. Setting it creates the column, and a record inserted without a value gets MAX + 10. Empty = no fixed order.',                '',             'text',      FALSE, 112, 'default',  'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'managed',        'Managed',        'When false, automatic DDL execution is disabled',       'true',         'boolean',   FALSE, 115, 'default',  'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'searchable',     'Searchable',     'Whether table is included in full-text search (auto-computed)', '',    'boolean',   FALSE, 117, 'disabled', 'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'is_child',       'Is Child',       'Whether table has any parent relationships (auto-computed)', '',       'boolean',   FALSE, 118, 'disabled', 'default', 'core', FALSE, '', '',        '', NULL),
    ('entities', 'audit_log',      'Audit Log',      'When TRUE, DML operations on this table are logged to audit_record_logs', 'false', 'boolean', FALSE, 122, 'default', 'default', 'core', FALSE, '', '', 'has', NULL),
    ('entities', 'computed_fields','Computed Fields', 'JsonLogic derivations evaluated on every write',        '',             'jsonlogic', FALSE, 123, 'default',  'w',       'core', FALSE, '', '',        '', NULL),
    ('entities', 'validation_rules','Validation Rules','JsonLogic invariants that must hold for the write to succeed','',     'jsonlogic', FALSE, 124, 'default',  'w',       'core', FALSE, '', '',        '', NULL),
    ('entities', 'select_rule',    'Select Rule',    'JsonLogic rule evaluated per row for the FOR SELECT RLS policy: true = the current user may see the record. Empty = no per-row rule.',         '',             'jsonlogic', FALSE, 125, 'default',  'w',       'core', FALSE, '', '',        '', NULL),
    ('entities', 'entity_type',    'Entity Type',    'What kind of data this entity holds. operational_workflow: records move through a gated lifecycle (even one gated step such as draft to submitted counts). operational_record: everyday business records without such a lifecycle. catalog: reference or lookup data maintained by admins. junction: a pure link between entities with no fields of its own; the platform labels its rows by the records they link. computed: every field is derived and never written directly. unclassified: not classified yet (the default).', 'unclassified', 'enum', FALSE, 122, 'required', 'default', 'core', FALSE, '', '', '', '["operational_workflow", "operational_record", "catalog", "junction", "computed", "unclassified"]'::jsonb),
    ('entities', 'catalog_entity_code',    'Catalog Entity Code',    'Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec.', '', 'text', FALSE, 126, 'default', 'default', 'core', FALSE, '', '', '', NULL),
    ('entities', 'catalog_owner_module', 'Catalog Owner Module', 'For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local.', '', 'text', FALSE, 127, 'default', 'default', 'core', FALSE, '', '', '', NULL),
    ('entities', 'catalog_entity_aliases', 'Catalog Entity Aliases', 'Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target.', '[]', 'json', FALSE, 129, 'default', 'w', 'core', FALSE, '', '', '', NULL),
    ('entities', 'created_at',     'Created At',     '',                                                       '',             'date-time', FALSE, 130, 'disabled', 'default', 'audit', FALSE, '', '',        '', NULL),
    ('entities', 'updated_at',     'Updated At',     '',                                                       '',             'date-time', FALSE, 140, 'disabled', 'default', 'audit', FALSE, '', '',        '', NULL);

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, default_value, unique_value)
VALUES
    ('users', 'id', 'Id', 'Internal identifier, assigned automatically', 'int32', TRUE, 1, 'readonly', 'default', 'id', FALSE, '', '', '', FALSE),
    ('users', 'external_id', 'External Id', 'Identity: the JWT sub claim from the authentication provider. Never empty: a human user must bring one, and an agent saved without one gets agent:<uuid>.', 'text', FALSE, 10, 'readonly', 'default', 'core', TRUE, '', '', '', TRUE),
    ('users', 'email', 'Email', 'Email address of the user', 'email', FALSE, 20, 'default', 'default', 'label', TRUE, '', '', '', FALSE),
    ('users', 'first_name', 'First Name', 'First name from JWT given_name claim', 'text', FALSE, 22, 'default', 'default', 'core', TRUE, '', '', '', FALSE),
    ('users', 'last_name', 'Last Name', 'Last name from JWT family_name claim', 'text', FALSE, 23, 'default', 'default', 'core', TRUE, '', '', '', FALSE),
    ('users', 'display_name', 'Display Name', 'Display name from the JWT name claim', 'text', FALSE, 25, 'default', 'default', 'core', TRUE, '', '', '', FALSE),
    ('users', 'is_disabled', 'Is Disabled', 'When TRUE, the user account is disabled', 'boolean', FALSE, 30, 'default', 'default', 'core', FALSE, '', '', '', FALSE),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, 35, 'default', 'w', 'core', FALSE, '', '', '', FALSE),
    ('users', 'is_agent', 'Is Agent', 'When TRUE this user is a service principal (agent)', 'boolean', FALSE, 100, 'default', 'default', '', FALSE, '', '', 'false', FALSE),
    ('users', 'created_at', 'Created At', '', 'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '', '', '', FALSE),
    ('users', 'updated_at', 'Updated At', '', 'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '', '', '', FALSE),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, 60, 'readonly', 'default', 'core', FALSE, '', '', '', FALSE);

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, enum_values)
VALUES
    ('modules', 'id', 'Id', 'Internal identifier, assigned automatically', 'int32', TRUE, 1, 'readonly', 'default', 'id', FALSE, '', '', NULL),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, 10, 'required', 'default', 'label', TRUE, '', '', NULL),
    ('modules', 'description', 'Description', 'What the module covers', 'text', FALSE, 20, 'default', 'w', 'core', TRUE, '', '', NULL),
    ('modules', 'module_type', 'Module Type', 'Module type: domain (normal) or master (promoted for sharing)', 'enum', FALSE, 25, 'readonly', 'default', 'core', FALSE, '', '', '["domain", "master"]'::jsonb),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'reference', FALSE, 30, 'default', 'default', 'core', FALSE, 'permissions', 'restrict', NULL),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, 36, 'default', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'icon_name', 'Icon Name', 'Icon or logo name identifier', 'text', FALSE, 37, 'default', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, 38, 'default', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'module_slug', 'Module Slug', 'URL-safe unique identifier for the module: lowercase, starting with a letter or digit, using only a-z, 0-9, - and _.', 'text', FALSE, 38, 'required', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'catalog_module_code', 'Catalog Module Code', 'Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec.', 'text', FALSE, 44, 'default', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'domain_code', 'Domain Code', 'Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM)', 'text', FALSE, 45, 'default', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'access_scope', 'Access Scope', 'Basic for simple read/edit; full for role tiers, approvals & gating', 'enum', FALSE, 46, 'default', 'default', 'core', FALSE, '', '', '["basic", "full"]'::jsonb),
    ('modules', 'manage_permission', 'Manage Permission', 'Manage permission of this module, by name', 'reference', FALSE, 39, 'default', 'default', 'core', FALSE, 'permissions', 'clear', NULL),
    ('modules', 'admin_permission', 'Admin Permission', 'Admin permission of this module, by name', 'reference', FALSE, 40, 'default', 'default', 'core', FALSE, 'permissions', 'clear', NULL),
    ('modules', 'default_viewer_role_id', 'Default Viewer Role', 'Default viewer role of this module', 'reference', FALSE, 41, 'default', 'default', 'core', FALSE, 'roles', 'clear', NULL),
    ('modules', 'default_manager_role_id', 'Default Manager Role', 'Default manager role of this module', 'reference', FALSE, 42, 'default', 'default', 'core', FALSE, 'roles', 'clear', NULL),
    ('modules', 'default_admin_role_id', 'Default Admin Role', 'Default admin role of this module', 'reference', FALSE, 43, 'default', 'default', 'core', FALSE, 'roles', 'clear', NULL),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, 50, 'default', 'w', 'core', FALSE, '', '', NULL),
    ('modules', 'dashboard_config', 'Dashboard Configuration', 'Layout and widgets of the module dashboard', 'json', FALSE, 60, 'default', 'w', 'core', FALSE, '', '', NULL),
    ('modules', 'version', 'Version', 'Auto-incremented version number', 'int32', FALSE, 85, 'readonly', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'version_date', 'Version Date', 'Timestamp of last version change', 'date-time', FALSE, 86, 'readonly', 'default', 'core', FALSE, '', '', NULL),
    ('modules', 'created_at', 'Created At', '', 'date-time', FALSE, 90, 'disabled', 'default', 'audit', FALSE, '', '', NULL),
    ('modules', 'updated_at', 'Updated At', '', 'date-time', FALSE, 100, 'disabled', 'default', 'audit', FALSE, '', '', NULL);

-- Insert fields metadata for roles table (slug's unique_value matches the UNIQUE constraint on the table)
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, unique_value, enum_values)
VALUES
    ('roles', 'id',          'Id',          'Internal identifier, assigned automatically',                              'int32',     TRUE,  1,  'readonly', 'default', 'id',    FALSE, '',        '',      '', FALSE, NULL),
    ('roles', 'role_name',   'Role Name',   'Unique role name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE,  '',        '',      '', FALSE, NULL),
    ('roles', 'slug',        'Slug',        'Snake_case unique identifier for the role, derived from role_name when omitted. Cannot be changed on a system role.', 'text', FALSE, 15, 'readonly', 'default', 'core', FALSE, '', '', '', TRUE, NULL),
    ('roles', 'catalog_role_code', 'Catalog Role Code', 'Stable catalog persona/role this role was provisioned from (lineage; non-unique). Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec.', 'text', FALSE, 16, 'default', 'default', 'core', FALSE, '', '', '', FALSE, NULL),
    ('roles', 'description', 'Description', 'What the role is for',                              'multiline', FALSE, 20, 'default',  'w',       'core',  TRUE,  '',        '',      '', FALSE, NULL),
    ('roles', 'origin',      'Origin',      'How the role was created: system (platform built-in), model (scaffold role of a domain module), model_master (scaffold role of a master module) or user (created by an admin). Set on insert and never changed.', 'enum', FALSE, 25, 'readonly', 'default', 'core', FALSE, '', '', '', FALSE, '["system", "model", "model_master", "user"]'::jsonb),
    ('roles', 'module_id',   'Module Id',   'Module this role belongs to',   'reference', FALSE, 30, 'default',  'default', 'core',  FALSE, 'modules', 'clear', 'contains', FALSE, NULL),
    ('roles', 'created_at',  'Created At',  '',                              'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '',        '',      '', FALSE, NULL),
    ('roles', 'updated_at',  'Updated At',  '',                              'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '',        '',      '', FALSE, NULL);

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    -- input_type 'required', not the 'readonly' every other ctype='id' row
    -- carries: those keys are generated by the database, this one is typed by
    -- whoever creates the permission, and readonly would make a permission
    -- impossible to create from the UI.
    ('permissions', 'permission_name', 'Permission Name', 'The permission itself, and the key other tables use to name it. Colon-separated segments of a-z, 0-9, - and _, each starting with a letter or digit, e.g. crm:read or service-catalog:view. No spaces, commas or dots: scope strings are split on commas and whitespace, and a dot would make permission_hierarchy ids ambiguous.',              'text',      TRUE,  1,  'required', 'default', 'id',    TRUE,  '',        '',      ''),
    ('permissions', 'description',     'Description',     'What the permission allows',                                    'multiline', FALSE, 20, 'default',  'w',       'core',  TRUE,  '',        '',      ''),
    ('permissions', 'module_id',       'Module Id',       'Module this permission belongs to',   'reference', FALSE, 30, 'required', 'default', 'core',  FALSE, 'modules', 'cascade', 'contains'),
    ('permissions', 'created_at',      'Created At',      '',                                    'date-time', FALSE, 40, 'disabled', 'default', 'audit', FALSE, '',        '',      ''),
    ('permissions', 'updated_at',      'Updated At',      '',                                    'date-time', FALSE, 50, 'disabled', 'default', 'audit', FALSE, '',        '',      '');

-- Insert fields metadata for user_roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, singular_label_parent, plural_label_parent)
VALUES
    ('user_roles', 'id',          'Id',          'Generated identifier (user_id.role_id)',  'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',      '',        '', '', ''),
    ('user_roles', 'user_id',     'User Id',     'User this role is assigned to',           'parent',    FALSE, 10, 'required', 'default', 'core', FALSE, 'users', 'cascade', 'has roles', 'Role', 'Roles'),
    ('user_roles', 'role_id',     'Role Id',     'Role assigned to the user',               'parent',    FALSE, 20, 'required', 'default', 'core', FALSE, 'roles', 'cascade', 'assigned to', 'User', 'Users'),
    ('user_roles', 'assigned_at', 'Assigned At', 'Timestamp when role was assigned',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',      '',        '', '', ''),
    ('user_roles', 'assigned_by', 'Assigned By', 'User who assigned this role',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users', 'clear',   'has assigned', '', '');

-- Insert fields metadata for role_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, singular_label_parent, plural_label_parent)
VALUES
    ('role_permissions', 'id',              'Id',              'Generated identifier (role_id.permission_name)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',            '',        '', '', ''),
    ('role_permissions', 'role_id',         'Role Id',         'Role this permission is granted to',             'parent',    FALSE, 10, 'default',  'default', 'core', FALSE, 'roles',        'cascade', 'has permissions', 'Permission', 'Permissions'),
    ('role_permissions', 'permission_name', 'Permission Name', 'Permission granted to the role',                 'parent',    FALSE, 20, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'granted to', 'Permission', 'Permissions'),
    ('role_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',             '',        '', '', ''),
    ('role_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users',        'clear',   'has granted', '', '');

-- Insert fields metadata for user_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, singular_label_parent, plural_label_parent)
VALUES
    ('user_permissions', 'id',              'Id',              'Generated identifier (user_id.permission_name)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',             '',        '', '', ''),
    ('user_permissions', 'user_id',         'User Id',         'User this permission is granted to',             'parent',    FALSE, 10, 'required', 'default', 'core', FALSE, 'users',         'cascade', 'has permissions', 'Permission', 'Permissions'),
    ('user_permissions', 'permission_name', 'Permission Name', 'Permission granted to the user',                 'parent',    FALSE, 20, 'required', 'default', 'core', FALSE, 'permissions',   'cascade', 'granted to', 'User', 'Users'),
    ('user_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', 'core', FALSE, '',              '',        '', '', ''),
    ('user_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', 'core', FALSE, 'users',         'clear',   'has granted', '', '');

-- Insert fields metadata for permission_hierarchy table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label, singular_label_parent, plural_label_parent, enum_values)
VALUES
    ('permission_hierarchy', 'id',                        'Id',                        'Generated identifier (including_permission_name.included_permission_name)', 'text',      TRUE,  1,  'readonly', 'default', 'id',   FALSE, '',             '',        '', '', '', NULL),
    ('permission_hierarchy', 'including_permission_name', 'Including Permission Name', 'The broader permission: holding it implies the included permission (e.g. crm:manage includes crm:read).',                     'parent',    FALSE, 10, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'includes', 'Includes', 'Includes', NULL),
    ('permission_hierarchy', 'included_permission_name',  'Included Permission Name',  'The narrower permission that is included by the broader one',                'parent',    FALSE, 20, 'default',  'default', 'core', FALSE, 'permissions',  'cascade', 'included in', 'Included in', 'Included in', NULL),
    ('permission_hierarchy', 'origin',                'Origin',                'How this hierarchy entry was created',                             'enum',      FALSE, 25, 'readonly', 'default', 'core', FALSE, '',             '',        '', '', '', '["system", "model", "model_master", "user"]'::jsonb),
    ('permission_hierarchy', 'created_at',            'Created At',            '',                                                                'date-time', FALSE, 30, 'disabled', 'default', 'audit', FALSE, '',             '',        '', '', '', NULL);

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION validate_reference_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auto_set_plural() FROM PUBLIC;