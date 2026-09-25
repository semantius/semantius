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
-- Runs once: the entities and fields tables and their indexes. Their trigger
-- functions and grants are in 0140_dd_schema.sql, their own dictionary rows
-- in 0150_dd_bootstrap.once.sql.

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
    entity_type TEXT NOT NULL DEFAULT 'unclassified',    -- kind of data held; editable; the platform acts only on 'junction' (dd_is_junction in 0180_managed_enable.sql)
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
    -- fields catalog by the validate_label_parent trigger in 0180_managed_enable.sql).
    CONSTRAINT valid_label_parent CHECK (label_parent = '' OR label_parent ~ '^[a-z_][a-z0-9_]*$'),

    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name),

    -- computed_fields and validation_rules must be JSON arrays
    CONSTRAINT computed_fields_is_array CHECK (jsonb_typeof(computed_fields) = 'array'),
    CONSTRAINT validation_rules_is_array CHECK (jsonb_typeof(validation_rules) = 'array'),
    -- select_rule must be a JSON object
    CONSTRAINT select_rule_is_object CHECK (jsonb_typeof(select_rule) = 'object'),
    -- entity_type is a closed set of 6 values; 'unclassified' is its empty value, so '' is rejected.
    -- This inline CHECK is the only one on the column: the field-metadata seed in
    -- 0150_dd_bootstrap.once.sql runs before the
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

-- =====================================================
-- FIELDS TABLE
-- =====================================================
-- Stores metadata about fields in dynamically created tables

CREATE TABLE IF NOT EXISTS fields (
    id TEXT GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY,
    -- ON UPDATE CASCADE carries a rename of entities.table_name (0170_dd_rename.sql) to the fields rows.
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

-- =====================================================
-- ENABLE RLS ON METADATA TABLES
-- =====================================================

ALTER TABLE entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE fields ENABLE ROW LEVEL SECURITY;
