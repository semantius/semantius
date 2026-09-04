-- =====================================================
-- DYNAMIC TABLE MANAGEMENT FUNCTIONS
-- =====================================================
-- Automatically creates tables and fields when metadata is inserted
-- Integrates with RBAC for automatic RLS policy creation
-- =====================================================

-- =====================================================
-- FORMAT TO DATA TYPE MAPPING FUNCTION
-- =====================================================
-- Maps JSON Schema format values to PostgreSQL data types
-- This function converts the format column value to an actual PostgreSQL type

CREATE OR REPLACE FUNCTION format_to_data_type(p_format TEXT, p_precision SMALLINT DEFAULT NULL)
RETURNS TEXT AS $$
DECLARE
    v_scale SMALLINT := COALESCE(p_precision, 2);
BEGIN
    RETURN CASE p_format
        -- Integer formats
        WHEN 'int32' THEN 'INTEGER'
        WHEN 'int64' THEN 'BIGINT'
        WHEN 'integer' THEN 'INTEGER'
        WHEN 'reference' THEN 'INTEGER'  -- Foreign key references use INTEGER
        WHEN 'parent' THEN 'INTEGER'     -- Parent references use INTEGER (like reference)
        
        -- Number formats
        WHEN 'float' THEN 'REAL'
        WHEN 'double' THEN 'DOUBLE PRECISION'
        WHEN 'number' THEN 'NUMERIC(18, ' || v_scale || ')'
        
        -- Special types (not TEXT)
        WHEN 'uuid' THEN 'UUID'
        WHEN 'binary' THEN 'BYTEA'
        
        -- Date/Time formats
        WHEN 'date' THEN 'DATE'
        WHEN 'time' THEN 'TIME'
        WHEN 'date-time' THEN 'TIMESTAMPTZ'
        WHEN 'duration' THEN 'INTERVAL'
        
        -- Boolean format
        WHEN 'boolean' THEN 'BOOLEAN'
        
        -- JSON formats
        WHEN 'json' THEN 'JSONB'
        WHEN 'object' THEN 'JSONB'
        WHEN 'array' THEN 'JSONB'
        
        -- Default case (handles all string-like formats: text, email, url, hostname, etc.)
        ELSE 'TEXT'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_data_type IS 
'Maps JSON Schema format values to PostgreSQL data types for CREATE/ALTER TABLE statements. For "number" format, the optional p_precision argument controls the NUMERIC scale (default 2).';

-- =====================================================
-- HELPER FUNCTION: FORMAT TO JSON SCHEMA TYPE
-- =====================================================
-- Maps format values to JSON Schema primitive types
-- Used to avoid duplication in type and default value handling
-- This function is closely related to format_to_data_type above

CREATE OR REPLACE FUNCTION format_to_json_type(p_format TEXT)
RETURNS JSONB AS $$
BEGIN
    RETURN CASE 
        -- Special case: json format can accept any type
        WHEN p_format = 'json' THEN to_jsonb(ARRAY['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'])
        -- Single type mappings
        WHEN p_format IN ('int32', 'int64', 'integer', 'reference', 'parent') THEN to_jsonb('integer'::text)
        WHEN p_format IN ('float', 'double', 'number') THEN to_jsonb('number'::text)
        WHEN p_format = 'boolean' THEN to_jsonb('boolean'::text)
        WHEN p_format IN ('array') THEN to_jsonb('array'::text)
        WHEN p_format IN ('object') THEN to_jsonb('object'::text)
        WHEN p_format = 'null' THEN to_jsonb('null'::text)
        ELSE to_jsonb('string'::text)
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_json_type IS 
'Maps format values to JSON Schema types (returns JSONB - either a string for single type or array for json format).';

-- =====================================================
-- IS_NULLABLE FUNCTION
-- =====================================================
-- Determines whether a column should allow NULL values based on its format.
-- Nullable formats: reference (optional FK), date (unknown date), date-time (not-yet timestamps)
-- All other formats use NOT NULL with appropriate defaults.

CREATE OR REPLACE FUNCTION is_nullable(p_format TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN p_format IN ('reference', 'date', 'date-time');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION is_nullable IS
'Determines whether a column should allow NULL values based on its format. Returns TRUE for reference, date, and date-time formats.';

-- =====================================================
-- ENUM HELPER FUNCTIONS
-- =====================================================
-- Centralised handling of enum default behavior:
--   • effective_enum_values  -- expands enum_values with '' for non-required enums,
--                               so empty defaults are accepted by the CHECK constraint.
--   • effective_enum_default -- resolves the actual column default for an enum field
--                               based on input_type and the explicit default_value.

CREATE OR REPLACE FUNCTION effective_enum_values(p_input_type TEXT, p_enum_values JSONB)
RETURNS JSONB AS $$
BEGIN
    IF p_enum_values IS NULL OR jsonb_typeof(p_enum_values) != 'array' OR jsonb_array_length(p_enum_values) = 0 THEN
        RETURN p_enum_values;
    END IF;
    -- For non-required enums, ensure '' is in the allowed list so the implicit
    -- empty-string default does not violate the CHECK constraint.
    IF p_input_type IS DISTINCT FROM 'required' AND NOT (p_enum_values @> '[""]'::jsonb) THEN
        RETURN p_enum_values || '[""]'::jsonb;
    END IF;
    RETURN p_enum_values;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_values IS
'Returns the effective list of allowed enum values: appends '''' for non-required enums so that the implicit empty-string default is accepted by the CHECK constraint.';

CREATE OR REPLACE FUNCTION effective_enum_default(p_default_value TEXT, p_input_type TEXT, p_enum_values JSONB)
RETURNS TEXT AS $$
BEGIN
    -- Explicit default takes precedence
    IF p_default_value IS NOT NULL AND trim(p_default_value) != '' THEN
        RETURN p_default_value;
    END IF;
    -- Required enum without explicit default: pick the first allowed value
    IF p_input_type = 'required'
       AND p_enum_values IS NOT NULL
       AND jsonb_typeof(p_enum_values) = 'array'
       AND jsonb_array_length(p_enum_values) > 0 THEN
        RETURN p_enum_values->>0;
    END IF;
    -- Non-required enum without explicit default: empty string
    RETURN '';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_default IS
'Computes the effective default for an enum field: explicit default_value if set, else first enum value when input_type is required, else empty string.';

-- Nullability is derived on demand from a field's format via the is_nullable()
-- function above; callers invoke is_nullable(format) directly rather than reading
-- a stored column (no is_nullable column is materialized on the fields table).

-- =====================================================
-- HELPER FUNCTION: QUOTE DEFAULT VALUE
-- =====================================================
-- Properly quotes default values based on data type
-- Properly quotes default values based on data type for DDL statements

-- SECURITY: the result of this function is interpolated verbatim (%s) into
-- ALTER TABLE ... DEFAULT statements that run inside SECURITY DEFINER triggers,
-- i.e. as the table owner. fields.default_value is writable by every holder of
-- the admin permission, so this function must NEVER return caller-supplied text
-- unquoted. A default is a VALUE, not an expression: a quoted string literal is
-- cast by PostgreSQL to the column type, so quote_literal() is the safe general
-- case. Only a fixed allow-list of well-known, argument-less SQL expressions and
-- plain numeric/boolean/NULL literals are emitted bare.
CREATE OR REPLACE FUNCTION quote_default_value(p_default_value TEXT, p_data_type TEXT)
RETURNS TEXT AS $$
DECLARE
    v_value TEXT := trim(p_default_value);
    v_upper TEXT;
BEGIN
    -- If default value is NULL or empty, return as-is
    IF p_default_value IS NULL OR v_value = '' THEN
        RETURN p_default_value;
    END IF;

    v_upper := upper(v_value);

    -- The NULL keyword
    IF v_upper = 'NULL' THEN
        RETURN 'NULL';
    END IF;

    -- Boolean constants for boolean columns (t/f are normalised to keywords)
    IF p_data_type = 'BOOLEAN' AND v_upper IN ('TRUE', 'FALSE', 'T', 'F') THEN
        RETURN CASE WHEN v_upper IN ('TRUE', 'T') THEN 'TRUE' ELSE 'FALSE' END;
    END IF;

    -- Plain numeric constants for numeric columns (NUMERIC(18, n) included)
    IF p_data_type ~ '^(INTEGER|BIGINT|SMALLINT|NUMERIC|DECIMAL|REAL|DOUBLE PRECISION)'
       AND v_value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        RETURN v_value;
    END IF;

    -- Allow-listed argument-less SQL expressions (exact, case-insensitive match)
    IF v_upper IN (
        'CURRENT_TIMESTAMP', 'CURRENT_DATE', 'CURRENT_TIME',
        'LOCALTIMESTAMP', 'LOCALTIME',
        'NOW()', 'CLOCK_TIMESTAMP()', 'STATEMENT_TIMESTAMP()', 'TRANSACTION_TIMESTAMP()',
        'GEN_RANDOM_UUID()',
        'CURRENT_USER', 'SESSION_USER'
    ) THEN
        RETURN v_upper;
    END IF;

    -- Everything else is a literal value; PostgreSQL casts it to the column type
    -- (so '[]' works for JSONB, '2026-01-01' for DATE, '1e3' for NUMERIC, ...).
    RETURN quote_literal(p_default_value);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION quote_default_value IS
'Quotes a fields.default_value for use in DDL. Returns bare text only for NULL, boolean and numeric literals and a fixed allow-list of argument-less SQL expressions (CURRENT_TIMESTAMP, now(), gen_random_uuid(), ...); every other value becomes a quoted string literal that PostgreSQL casts to the column type. Never returns caller-supplied text unquoted.';

-- =====================================================
-- HELPER FUNCTIONS: BUILD OBJECT COMMENTS
-- =====================================================
-- Centralised construction of the COMMENT ON TABLE / COMMENT ON COLUMN bodies
-- applied by the DDL triggers, so the create and update paths stay identical.
--   • dd_table_comment  -- "<plural_label>" then a blank line + description (when set)
--   • dd_field_comment  -- "<title> (<format>)" then description, plus enum value list

CREATE OR REPLACE FUNCTION dd_table_comment(p_plural_label TEXT, p_description TEXT)
RETURNS TEXT AS $$
DECLARE
    v_body TEXT;
BEGIN
    -- Summary line: the plural label
    v_body := COALESCE(trim(p_plural_label), '');
    -- Description paragraph (blank line before it)
    IF p_description IS NOT NULL AND trim(p_description) != '' THEN
        v_body := CASE WHEN v_body = '' THEN '' ELSE v_body || E'\n\n' END || p_description;
    END IF;
    RETURN NULLIF(v_body, '');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_table_comment IS
'Builds the COMMENT ON TABLE body for an entity: the plural label as a summary line, followed by a blank line and the description when one is set. Returns NULL when both are empty. Used by the entity create and update DDL triggers so both paths stay in sync.';

CREATE OR REPLACE FUNCTION dd_field_comment(p_title TEXT, p_format TEXT, p_description TEXT, p_enum_values JSONB)
RETURNS TEXT AS $$
DECLARE
    v_body   TEXT;
    v_values TEXT;
BEGIN
    -- Summary line: "<title> (<format>)"
    v_body := trim(trim(COALESCE(p_title, '')) || ' (' || COALESCE(p_format, '') || ')');
    -- Description paragraph (blank line before it)
    IF p_description IS NOT NULL AND trim(p_description) != '' THEN
        v_body := v_body || E'\n\n' || p_description;
    END IF;
    -- Enum value list: comma-separated allowed values on their own line
    IF p_format = 'enum'
       AND p_enum_values IS NOT NULL
       AND jsonb_typeof(p_enum_values) = 'array'
       AND jsonb_array_length(p_enum_values) > 0 THEN
        SELECT string_agg(value, ', ') INTO v_values
        FROM jsonb_array_elements_text(p_enum_values) AS value;
        v_body := v_body || E'\n\n' || v_values;
    END IF;
    RETURN NULLIF(v_body, '');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_field_comment IS
'Builds the COMMENT ON COLUMN body for a field: a "<title> (<format>)" summary line, then the description (when set), then for enum fields a blank line and the comma-separated list of allowed values. Used by the field create and update DDL triggers so both paths stay in sync.';

-- =====================================================
-- TRIGGER FUNCTION: CREATE TABLE ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION create_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_policy_sql TEXT;
    v_comment    TEXT;
BEGIN
    -- Skip DDL execution if table is not managed
    IF NOT NEW.managed THEN
        RAISE NOTICE 'Skipping table creation for "%" (managed=false)', NEW.table_name;
        RETURN NEW;
    END IF;
    
    -- Validate that view and edit permissions exist
    IF NOT rbac.validate_permission_exists(NEW.view_permission) THEN
        RAISE EXCEPTION 'View permission "%" does not exist in permissions table', NEW.view_permission;
    END IF;
    
    IF NOT rbac.validate_permission_exists(NEW.edit_permission) THEN
        RAISE EXCEPTION 'Edit permission "%" does not exist in permissions table', NEW.edit_permission;
    END IF;
    
    -- Build CREATE TABLE statement
    v_create_sql := format(
        'CREATE TABLE IF NOT EXISTS public.%I (
            %I SERIAL PRIMARY KEY,
            %I TEXT NOT NULL DEFAULT '''',
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        )',
        NEW.table_name,
        NEW.id_column,
        NEW.label_column
    );
    
    -- Create the table
    EXECUTE v_create_sql;
    
    -- Set table comment: plural label summary + optional description
    v_comment := dd_table_comment(NEW.plural_label, NEW.description);
    IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON TABLE %I IS %L', NEW.table_name, v_comment);
    END IF;

    -- Add updated_at trigger using common schema function
    EXECUTE format(
        'CREATE TRIGGER update_%I_updated_at
            BEFORE UPDATE ON %I
            FOR EACH ROW
            EXECUTE FUNCTION common.update_updated_at_column()',
        NEW.table_name,
        NEW.table_name
    );
    
    -- Enable RLS on the new table
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', NEW.table_name);
    
    -- Policy predicates wrap rbac.has_permission() in a scalar sub-select: PostgreSQL then evaluates
    -- it once per statement (InitPlan) instead of once per row (P1, 1.7 s vs 10 ms on 100k rows).
    -- Test 0445 fails on the bare per-row form.
    -- Create RLS policies for SELECT (view permission)
    v_policy_sql := format(
        'CREATE POLICY %I_select_policy ON %I
            FOR SELECT
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))',
        NEW.table_name,
        NEW.table_name,
        NEW.view_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for INSERT (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_insert_policy ON %I
            FOR INSERT
            TO semantius_user
            WITH CHECK ((SELECT rbac.has_permission(%L)))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for UPDATE (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_update_policy ON %I
            FOR UPDATE
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))
            WITH CHECK ((SELECT rbac.has_permission(%L)))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for DELETE (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_delete_policy ON %I
            FOR DELETE
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Insert field records for id, label, created_at, and updated_at columns.
    -- All these are core fields (ctype <> '') that cannot be deleted or renamed; ctype is set
    -- here by privileged DD code (the fields_ctype_lock trigger forbids users from setting it).
    -- The label column is marked as searchable=TRUE for full-text search.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    VALUES
        (NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, 10, 'readonly', 'default', 'id', FALSE, '', ''),
        (NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, 20, 'required', 'default', 'label', TRUE, '', ''),
        (NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', 'audit', FALSE, '', ''),
        (NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', 'audit', FALSE, '', '');
    
    -- Note: The handle_field_searchable_insert_trigger will fire for the above INSERTs
    -- and update entities.searchable automatically. However, since we're in a nested trigger context,
    -- we need to ensure the searchable flag gets set correctly after this trigger completes.
    -- The solution is to update it directly here since the label field is always searchable.
    UPDATE entities 
    SET searchable = TRUE 
    WHERE table_name = NEW.table_name 
      AND EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND searchable = TRUE);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION create_dd_table IS 
'Trigger function that creates a table with RLS policies when a row is inserted into entities table.';

-- Apply trigger AFTER INSERT on entities
CREATE TRIGGER create_table_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION create_dd_table();

-- =====================================================
-- TRIGGER FUNCTION: SYNC TABLE COMMENT ON UPDATE
-- =====================================================
-- Keeps COMMENT ON TABLE in sync when an entity's plural_label or description
-- changes (or the table is renamed). Fires AFTER UPDATE so the physical rename
-- performed by the BEFORE UPDATE rename trigger has already applied and
-- NEW.table_name refers to the current table.

CREATE OR REPLACE FUNCTION update_dd_table_comment()
RETURNS TRIGGER AS $$
DECLARE
    v_comment TEXT;
BEGIN
    -- Only managed tables that physically exist have a table to comment on
    IF NOT NEW.managed OR to_regclass(format('public.%I', NEW.table_name)) IS NULL THEN
        RETURN NEW;
    END IF;

    -- Nothing to do unless a comment input or the table identity changed
    IF OLD.plural_label IS DISTINCT FROM NEW.plural_label
       OR OLD.description IS DISTINCT FROM NEW.description
       OR OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        v_comment := dd_table_comment(NEW.plural_label, NEW.description);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON TABLE %I IS %L', NEW.table_name, v_comment);
        ELSE
            EXECUTE format('COMMENT ON TABLE %I IS NULL', NEW.table_name);
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_table_comment IS
'Trigger function that re-applies COMMENT ON TABLE (plural label + description) when an entity''s plural_label, description or table_name changes, keeping the table comment in sync with the entity metadata.';

CREATE TRIGGER update_table_comment_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION update_dd_table_comment();

-- =====================================================
-- TRIGGER FUNCTION: AUTO-SET FIELD ORDER ON INSERT
-- =====================================================
-- When a new field is inserted with field_order = 0 (the default),
-- automatically assign it to max(field_order) + 10 for that table,
-- so new fields are always appended to the end of the fields list.

CREATE OR REPLACE FUNCTION auto_set_field_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.field_order = 0 THEN
        SELECT COALESCE(MAX(field_order), 0) + 10
        INTO NEW.field_order
        FROM fields
        WHERE table_name = NEW.table_name;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_field_order IS
'Trigger function that auto-assigns field_order to max(field_order)+10 when field_order=0 is inserted.';

-- Apply trigger BEFORE INSERT on fields (must run before add_dd_field)
CREATE TRIGGER auto_set_field_order_trigger
    BEFORE INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_field_order();

-- =====================================================
-- ctype LOCK: ctype is the single, un-tamperable core marker
-- =====================================================
-- ctype marks a DD-managed core column (id/label/audit/core); all structural protection
-- (no rename/delete/format/default change) keys on `ctype <> ''`. For that to be sound the
-- marker must be settable ONLY by DD/migration code and immutable thereafter — otherwise a
-- tenant admin (who holds the fields edit permission) could mint a ctype, or clear the ctype
-- of the id column to "free" it for deletion. Privilege is decided by BYPASSRLS: the migration
-- owner and every SECURITY DEFINER DD function (create_dd_table, enable_dd_table, …) run as the
-- BYPASSRLS owner; the request path runs as semantius_user (NOBYPASSRLS). Non-privileged
-- callers get ctype forced to '' on INSERT and a hard rejection on any UPDATE that changes it.
CREATE OR REPLACE FUNCTION lock_field_ctype()
RETURNS TRIGGER AS $$
DECLARE
    v_privileged BOOLEAN;
BEGIN
    -- Normalize enum_values: coerce non-array JSONB (e.g. '{}') to NULL so
    -- jsonb_array_length() calls in get_schema / triggers never receive a non-array.
    IF NEW.enum_values IS NOT NULL AND jsonb_typeof(NEW.enum_values) != 'array' THEN
        NEW.enum_values := NULL;
    END IF;

    SELECT rolbypassrls INTO v_privileged FROM pg_roles WHERE rolname = current_user;
    IF COALESCE(v_privileged, FALSE) THEN
        RETURN NEW;  -- DD / migration code: trusted to set ctype
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.ctype := '';  -- users cannot mint a core marker on a new field
    ELSIF NEW.ctype IS DISTINCT FROM OLD.ctype THEN
        RAISE EXCEPTION 'ctype is system-managed and cannot be changed on field "%"', NEW.field_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION lock_field_ctype IS
'BEFORE INSERT/UPDATE guard on fields: only a BYPASSRLS (DD/migration) caller may set or change ctype. Non-privileged users get ctype forced to '''' on INSERT and a rejection on any UPDATE that changes ctype. Keeps ctype (the core marker that "core = ctype <> ''" depends on) un-tamperable.';

REVOKE EXECUTE ON FUNCTION lock_field_ctype() FROM PUBLIC;

CREATE TRIGGER fields_ctype_lock
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION lock_field_ctype();

REVOKE EXECUTE ON FUNCTION auto_set_field_order() FROM PUBLIC;

-- =====================================================
-- TRIGGER FUNCTION: ADD FIELD ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION add_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_nullable_clause TEXT;
    v_default_clause TEXT;
    v_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
    v_comment TEXT;
BEGIN
    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;
    
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping field addition for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Skip if this is the id or label column (already created by create_dd_table)
    IF NEW.field_name IN (
        SELECT id_column FROM entities WHERE table_name = NEW.table_name
        UNION
        SELECT label_column FROM entities WHERE table_name = NEW.table_name
    ) THEN
        -- Still set the column comment (title/format summary + description [+ enum values])
        v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
        END IF;
        RETURN NEW;
    END IF;
    
    -- Convert format to PostgreSQL data type
    v_data_type := format_to_data_type(NEW.format, NEW."precision");
    
    -- Build nullable clause based on format
    IF is_nullable(NEW.format) THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;
    
    -- Build default clause with sensible defaults based on data type
    DECLARE
        v_resolved_default TEXT;
    BEGIN
        IF NEW.format = 'enum' THEN
            v_resolved_default := effective_enum_default(NEW.default_value, NEW.input_type, NEW.enum_values);
        ELSE
            v_resolved_default := NEW.default_value;
        END IF;

        IF v_resolved_default IS NOT NULL AND trim(v_resolved_default) != '' THEN
            v_default_clause := format('DEFAULT %s', quote_default_value(v_resolved_default, v_data_type));
        ELSIF NOT is_nullable(NEW.format) THEN
            -- Provide sensible defaults for NOT NULL columns without explicit default
            IF v_data_type IN ('JSONB', 'JSON') THEN
                IF NEW.format = 'array' THEN
                    v_default_clause := 'DEFAULT ''[]''::jsonb';
                ELSE
                    v_default_clause := 'DEFAULT ''{}''::jsonb';
                END IF;
            ELSE
                CASE
                    WHEN v_data_type = 'TEXT' THEN v_default_clause := 'DEFAULT ''''';
                    WHEN v_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT') THEN v_default_clause := 'DEFAULT 0';
                    WHEN v_data_type IN ('REAL', 'DOUBLE PRECISION') OR v_data_type LIKE 'NUMERIC%' OR v_data_type LIKE 'DECIMAL%' THEN v_default_clause := 'DEFAULT 0.0';
                    WHEN v_data_type = 'BOOLEAN' THEN v_default_clause := 'DEFAULT FALSE';
                    WHEN v_data_type IN ('TIMESTAMP', 'TIMESTAMPTZ') THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                    WHEN v_data_type = 'DATE' THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                    ELSE v_default_clause := '';
                END CASE;
            END IF;
        ELSE
            v_default_clause := '';
        END IF;
    END;
    
    -- Build ALTER TABLE statement
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        NEW.table_name,
        NEW.field_name,
        v_data_type,
        v_nullable_clause,
        v_default_clause
    );
    
    -- Add the column
    EXECUTE v_alter_sql;

    -- Set column comment: title/format summary + description [+ enum values]
    v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
    IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
    END IF;

    -- If this is a primary key field, set it as primary key
    IF NEW.is_pk THEN
        -- Check if table already has a primary key
        IF EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name
            AND is_pk = TRUE 
            AND field_name <> NEW.field_name
        ) THEN
            RAISE EXCEPTION 'Table % already has a primary key', NEW.table_name;
        END IF;
        
        -- Add primary key constraint
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            NEW.table_name,
            NEW.table_name || '_pkey'
        );
        
        EXECUTE format(
            'ALTER TABLE %I ADD PRIMARY KEY (%I)',
            NEW.table_name,
            NEW.field_name
        );
    END IF;
    
    -- If this is a reference or parent field, add foreign key constraint
    IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
        -- Get the id_column of the referenced table
        SELECT id_column INTO v_ref_id_column
        FROM entities
        WHERE table_name = NEW.reference_table;
        
        IF v_ref_id_column IS NULL THEN
            RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
        END IF;
        
        -- Determine ON DELETE behavior based on reference_delete_mode
        IF NEW.reference_delete_mode = 'clear' THEN
            v_on_delete := 'SET NULL';
        ELSIF NEW.reference_delete_mode = 'cascade' THEN
            v_on_delete := 'CASCADE';
        ELSE
            v_on_delete := 'RESTRICT';
        END IF;
        
        -- Generate foreign key constraint name
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        
        -- Add foreign key constraint (skip if constraint already exists - e.g. pre-existing schema FKs)
        -- ON UPDATE CASCADE enables automatic cascading when a referenced TEXT PK
        -- (e.g. entities.table_name) is renamed. For INTEGER PKs it has no effect.
        v_alter_sql := format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
            NEW.table_name,
            v_fk_name,
            NEW.field_name,
            NEW.reference_table,
            v_ref_id_column,
            v_on_delete
        );
        BEGIN
            EXECUTE v_alter_sql;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'Foreign key constraint "%" already exists on "%.%", skipping creation. Verify ON DELETE behavior matches expected: %',
                v_fk_name, NEW.table_name, NEW.field_name, v_on_delete;
        END;
        
        -- Create index for foreign key
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);
        v_alter_sql := format(
            'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
            v_idx_name,
            NEW.table_name,
            NEW.field_name
        );
        EXECUTE v_alter_sql;
    END IF;
    
    -- If this is an enum field, add CHECK constraint for allowed values
    IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_typeof(NEW.enum_values) = 'array' AND jsonb_array_length(NEW.enum_values) > 0 THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum JSONB;
        BEGIN
            -- Generate CHECK constraint name
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Compute effective allowed values (adds '' for non-required enums)
            v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);

            -- Build SQL array from JSONB array for IN clause
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(v_effective_enum) AS value
            );
            
            -- Add CHECK constraint
            v_alter_sql := format(
                'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                NEW.table_name,
                v_check_name,
                NEW.field_name,
                v_enum_values_sql
            );
            EXECUTE v_alter_sql;
            
            RAISE NOTICE 'Added CHECK constraint "%" for enum field "%.%"',
                v_check_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    -- If unique_value is TRUE, create a partial unique index
    IF NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            -- For string types, exclude NULL and empty string from uniqueness enforcement
            IF format_to_json_type(NEW.format)::text = '"string"' THEN
                v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
            ELSE
                v_where_clause := format('%I IS NOT NULL', NEW.field_name);
            END IF;
            EXECUTE format(
                'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                v_unique_idx_name,
                NEW.table_name,
                NEW.field_name,
                v_where_clause
            );
            RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION add_dd_field IS 
'Trigger function that adds a column to a table when a row is inserted into fields table.';

-- Apply trigger AFTER INSERT on fields
CREATE TRIGGER add_field_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION add_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: UPDATE FIELD ON UPDATE
-- =====================================================

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_new_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
    v_comment TEXT;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        RAISE EXCEPTION 'Cannot change table_name of a field';
    END IF;
    
    IF OLD.field_name <> NEW.field_name THEN
        RAISE EXCEPTION 'Cannot rename field. Drop and recreate instead.';
    END IF;
    
    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field';
    END IF;
    
    -- Prevent changing structural attributes of core fields (a non-empty ctype marks a
    -- DD-managed core column). Core fields can only have metadata updates (title, description,
    -- field_order, input_type, width). ctype itself is immutable + privilege-locked by the
    -- fields_ctype_lock trigger, so it cannot be cleared to escape this guard.
    IF coalesce(OLD.ctype, '') <> '' THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;
    END IF;
    
    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still keep the column comment in sync even if not managed
        IF OLD.title IS DISTINCT FROM NEW.title
           OR OLD.format IS DISTINCT FROM NEW.format
           OR OLD.description IS DISTINCT FROM NEW.description
           OR OLD.enum_values IS DISTINCT FROM NEW.enum_values THEN
            v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
            IF v_comment IS NOT NULL THEN
                EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
            ELSE
                EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', NEW.table_name, NEW.field_name);
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Keep column comment in sync when title/format/description/enum values change
    IF OLD.title IS DISTINCT FROM NEW.title
       OR OLD.format IS DISTINCT FROM NEW.format
       OR OLD.description IS DISTINCT FROM NEW.description
       OR OLD.enum_values IS DISTINCT FROM NEW.enum_values THEN
        v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
        ELSE
            EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', NEW.table_name, NEW.field_name);
        END IF;
    END IF;

    -- Allow updating format (which changes data type)
    IF OLD.format <> NEW.format THEN
        v_new_data_type := format_to_data_type(NEW.format, NEW."precision");
        v_alter_sql := format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE %s',
            NEW.table_name,
            NEW.field_name,
            v_new_data_type
        );
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" type to % (format: %) in table "%"',
            NEW.field_name, v_new_data_type, NEW.format, NEW.table_name;
    END IF;
    
    -- Handle nullable change when format changes (e.g., text→reference would change nullability)
    IF OLD.format <> NEW.format THEN
        IF is_nullable(OLD.format) <> is_nullable(NEW.format) THEN
            IF is_nullable(NEW.format) THEN
                v_alter_sql := format(
                    'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            ELSE
                v_alter_sql := format(
                    'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
            EXECUTE v_alter_sql;
            RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
                NEW.field_name, is_nullable(NEW.format), NEW.table_name;
        END IF;
    END IF;
    
    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name,
                NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format, NEW."precision"))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;
    
    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);
        
        -- Check if reference_table or reference_delete_mode changed
        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR 
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format) THEN
            
            -- Drop existing foreign key constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name,
                    v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;
            
            -- Add new foreign key constraint if format is now 'reference' or 'parent'
            IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
                -- Get the id_column of the referenced table
                SELECT id_column INTO v_ref_id_column
                FROM entities
                WHERE table_name = NEW.reference_table;
                
                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;
                
                -- Determine ON DELETE behavior
                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSIF NEW.reference_delete_mode = 'cascade' THEN
                    v_on_delete := 'CASCADE';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;
                
                -- Add foreign key constraint
                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
                    NEW.table_name,
                    v_fk_name,
                    NEW.field_name,
                    NEW.reference_table,
                    v_ref_id_column,
                    v_on_delete
                );
                EXECUTE v_alter_sql;
                
                -- Create index for foreign key if it doesn't exist
                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name,
                    NEW.table_name,
                    NEW.field_name
                );
                EXECUTE v_alter_sql;
                
                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name, NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                -- Drop index if format changed from reference/parent to something else
                EXECUTE format(
                    'DROP INDEX IF EXISTS %I',
                    v_idx_name
                );
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;
    
    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Check if enum_values, input_type, or format changed
            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values)
               OR (OLD.format <> NEW.format)
               OR (OLD.input_type IS DISTINCT FROM NEW.input_type) THEN
                
                -- Drop existing CHECK constraint if it exists
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name,
                        v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;
                
                -- Add new CHECK constraint if format is now 'enum'
                IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_typeof(NEW.enum_values) = 'array' AND jsonb_array_length(NEW.enum_values) > 0 THEN
                    v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);

                    -- Build SQL array from JSONB array for IN clause
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(v_effective_enum) AS value
                    );
                    
                    -- Add CHECK constraint
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name,
                        v_check_name,
                        NEW.field_name,
                        v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;
                    
                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;
    
    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                -- Create partial unique index
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name,
                    NEW.table_name,
                    NEW.field_name,
                    v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                -- Drop unique index
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS 
'Trigger function that updates column properties when a field is updated.';

-- Apply trigger AFTER UPDATE on fields
CREATE TRIGGER update_field_trigger
    AFTER UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION update_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE FIELD ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_is_managed BOOLEAN;
    v_table_exists BOOLEAN;
    v_fk_name TEXT;
    v_idx_name TEXT;
BEGIN
    -- Check if the parent table still exists in entities table
    -- If it doesn't exist, this deletion is part of a CASCADE from table deletion, so allow it
    SELECT EXISTS(SELECT 1 FROM entities WHERE table_name = OLD.table_name) INTO v_table_exists;
    
    IF NOT v_table_exists THEN
        -- Table is being deleted, allow cascade deletion of all fields including core fields
        RETURN OLD;
    END IF;
    
    -- Prevent deletion of core fields (a non-empty ctype marks a DD-managed core column)
    -- for standalone field deletions.
    IF coalesce(OLD.ctype, '') <> '' THEN
        RAISE EXCEPTION 'Cannot delete core system field "%". Core fields (ctype id/label/audit/core) cannot be deleted.', OLD.field_name;
    END IF;
    
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = OLD.table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping field deletion for "%.%" (table managed=false)', OLD.table_name, OLD.field_name;
        RETURN OLD;
    END IF;
    
    -- Drop foreign key constraint if this is a reference or parent field
    IF OLD.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', OLD.table_name, OLD.field_name);
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            OLD.table_name,
            v_fk_name
        );
        RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
        
        -- Drop index for foreign key
        v_idx_name := format('idx_%s_%s', OLD.table_name, OLD.field_name);
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            v_idx_name
        );
        RAISE NOTICE 'Dropped index "%"', v_idx_name;
    END IF;
    
    -- Drop unique index if unique_value was set
    IF OLD.unique_value THEN
        EXECUTE format('DROP INDEX IF EXISTS %I', format('%s_%s_unique', OLD.table_name, OLD.field_name));
        RAISE NOTICE 'Dropped unique index "%"', format('%s_%s_unique', OLD.table_name, OLD.field_name);
    END IF;
    
    -- Drop the column (CASCADE to drop any dependent objects like generated columns)
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS %I CASCADE',
        OLD.table_name,
        OLD.field_name
    );
    
    RAISE NOTICE 'Dropped column "%" from table "%"',
        OLD.field_name, OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_field IS 
'Trigger function that drops a column when a field is deleted.';

-- Apply trigger BEFORE DELETE on fields
CREATE TRIGGER delete_field_trigger
    BEFORE DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE TABLE ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_table()
RETURNS TRIGGER AS $$
BEGIN
    -- Skip DDL execution if table is not managed
    IF NOT OLD.managed THEN
        RAISE NOTICE 'Skipping table deletion for "%" (managed=false)', OLD.table_name;
        RETURN OLD;
    END IF;
    
    -- Drop the table (CASCADE will drop all dependent objects)
    EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', OLD.table_name);
    
    RAISE NOTICE 'Dropped table "%"', OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_table IS 
'Trigger function that drops a table when a row is deleted from entities table.';

-- Apply trigger BEFORE DELETE on entities
-- Note: Fields will be deleted via CASCADE on the foreign key
CREATE TRIGGER delete_table_trigger
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_table();

-- =====================================================
-- TRIGGER FUNCTION: update RLS policies on permission change
-- =====================================================
-- When entities.edit_permission is changed, the INSERT, UPDATE, and DELETE
-- RLS policies must be dropped and recreated with the new permission value.
--
-- NOTE: The SELECT policy is already handled by manage_select_rule_policy
-- (in 0180_computed_validation.sql) which fires when view_permission changes.

CREATE OR REPLACE FUNCTION update_entity_policies()
RETURNS TRIGGER AS $$
BEGIN
    -- Only act on managed tables that have physical RLS policies
    IF NOT NEW.managed THEN
        RETURN NEW;
    END IF;

    -- Sub-select form: see the note in create_dd_table (P1).
    -- INSERT policy is edit_permission-only (there is no per-row rule on inserts).
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I',
        NEW.table_name || '_insert_policy', NEW.table_name);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR INSERT TO semantius_user WITH CHECK ((SELECT rbac.has_permission(%L)))',
        NEW.table_name || '_insert_policy', NEW.table_name, NEW.edit_permission);

    -- SELECT/UPDATE/DELETE are rule-aware: build_select_rule_policy() rebuilds them on the
    -- canonical predicate (select_rule when set, else view/edit permission). Delegating here
    -- keeps the read policy, the read helpers, and the write USING clauses on ONE predicate,
    -- so an edit_permission change does not silently strip the row rule from writes.
    PERFORM build_select_rule_policy(NEW.table_name);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_entity_policies IS
'AFTER UPDATE trigger on entities: drops and recreates INSERT, UPDATE, and DELETE
RLS policies when edit_permission changes. The SELECT policy is handled separately
by manage_select_rule_policy (0180_computed_validation.sql).';

CREATE TRIGGER update_entity_policies_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.edit_permission IS DISTINCT FROM NEW.edit_permission)
    EXECUTE FUNCTION update_entity_policies();

COMMENT ON TRIGGER update_entity_policies_trigger ON entities IS
'Rebuilds INSERT/UPDATE/DELETE RLS policies when entities.edit_permission is updated';

-- =====================================================
-- FULL-TEXT SEARCH FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages search_vector column and GIN index based on searchable fields
-- Automatically maintains entities.searchable based on related fields

-- =====================================================
-- HELPER FUNCTION: Update search_vector column and index
-- =====================================================
-- This function generates and executes DDL to create/recreate the search_vector
-- column and GIN index for a table based on its searchable fields

CREATE OR REPLACE FUNCTION update_search_vector_column(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_searchable_fields TEXT[];
    v_search_expr TEXT;
    v_table_exists BOOLEAN;
    v_relid REGCLASS;
    v_attnum SMALLINT;
    v_current_fingerprint TEXT;
    v_new_fingerprint TEXT;
    v_index_name TEXT;
    v_index_exists BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;

    -- Check if the table actually exists in the database
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = p_table_name
    ) INTO v_table_exists;
    
    IF NOT v_table_exists THEN

        RETURN;
    END IF;

    v_relid := format('public.%I', p_table_name)::regclass;
    v_index_name := p_table_name || '_search_vector_idx';

    -- What is installed right now: the generated column, if any, and the
    -- fingerprint we stamped into its comment the last time we built it. Both
    -- come back NULL when there is nothing to compare against.
    SELECT a.attnum, col_description(v_relid, a.attnum::int)
    INTO v_attnum, v_current_fingerprint
    FROM pg_attribute a
    WHERE a.attrelid = v_relid
      AND a.attname = 'search_vector'
      AND a.attgenerated = 's'
      AND NOT a.attisdropped;

    -- Get all searchable text-based fields for this table that actually exist as columns
    SELECT ARRAY_AGG(field_name ORDER BY field_order)
    INTO v_searchable_fields
    FROM fields f
    WHERE f.table_name = p_table_name
      AND f.searchable = TRUE
      AND format_to_json_type(f.format)::text = '"string"'  -- Only text-based fields
      AND EXISTS (  -- Only include fields that actually exist as columns in the table
          SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name = p_table_name
            AND c.column_name = f.field_name
      );
    
    -- If no searchable fields, drop the search_vector column and index if they exist
    IF v_searchable_fields IS NULL OR array_length(v_searchable_fields, 1) IS NULL THEN
        -- Nothing installed and nothing wanted: skip the DDL. ALTER TABLE takes
        -- ACCESS EXCLUSIVE before it evaluates IF EXISTS, so even a drop that
        -- matches nothing blocks the table for the rest of the transaction.
        IF v_attnum IS NULL THEN
            RETURN;
        END IF;

        -- Drop the GIN index first
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            v_index_name
        );
        
        -- Drop the search_vector column
        EXECUTE format(
            'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector',
            p_table_name
        );
        

        RETURN;
    END IF;
    
    -- Build the tsvector expression by concatenating all searchable fields
    -- Using coalesce to handle NULL values and setweight for ranking
    v_search_expr := (
        SELECT string_agg(
            format('setweight(to_tsvector(''simple'', coalesce(%I, '''')), ''%s'')',
                f.field_name,
                CASE 
                    WHEN f.ctype = 'label' THEN 'A'  -- Label fields get highest weight
                    WHEN f.field_name IN ('title', 'name') THEN 'A'  -- Title/name fields
                    WHEN f.field_name LIKE '%description%' THEN 'B'  -- Description fields
                    ELSE 'C'  -- Other searchable fields
                END
            ),
            ' || '
            ORDER BY f.field_order
        )
        FROM fields f
        WHERE f.table_name = p_table_name
          AND f.searchable = TRUE
          AND format_to_json_type(f.format)::text = '"string"'
          AND EXISTS (  -- Only include fields that actually exist as columns
              SELECT 1 FROM information_schema.columns c
              WHERE c.table_schema = 'public'
                AND c.table_name = p_table_name
                AND c.column_name = f.field_name
          )
    );
    
    -- Everything below is one full table rewrite: ADD COLUMN ... GENERATED ...
    -- STORED has to materialise the tsvector for every existing row, so it holds
    -- ACCESS EXCLUSIVE (blocking readers, not just writers) for the whole
    -- rewrite and rebuilds every index on the table -- about 650 ms per 100k
    -- rows, linear. Skip it when the installed column was generated from exactly
    -- this expression and its index is still in place.
    --
    -- The comparison is against a fingerprint of the text we generate, not
    -- against pg_get_expr(): PostgreSQL deparses the stored expression with
    -- casts of its own ('simple'::regconfig, 'A'::"char"), so the deparsed form
    -- never matches what is built above and the guard would never fire.
    v_new_fingerprint := 'fts:' || md5(v_search_expr);

    SELECT EXISTS (
        SELECT 1
        FROM pg_class i
        JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE n.nspname = 'public'
          AND i.relname = v_index_name
          AND i.relkind = 'i'
    ) INTO v_index_exists;

    IF v_index_exists AND v_current_fingerprint IS NOT DISTINCT FROM v_new_fingerprint THEN
        RETURN;
    END IF;

    -- Drop existing search_vector column if it exists
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector',
        p_table_name
    );
    
    -- Create the search_vector column as GENERATED ALWAYS
    EXECUTE format(
        'ALTER TABLE %I ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (%s) STORED',
        p_table_name,
        v_search_expr
    );
    
    -- Drop existing GIN index if it exists
    EXECUTE format(
        'DROP INDEX IF EXISTS %I',
        v_index_name
    );
    
    -- Create GIN index on the search_vector column
    EXECUTE format(
        'CREATE INDEX %I ON %I USING GIN (search_vector)',
        v_index_name,
        p_table_name
    );

    -- Stamp the fingerprint so the next call can tell whether anything changed.
    EXECUTE format(
        'COMMENT ON COLUMN %I.search_vector IS %L',
        p_table_name,
        v_new_fingerprint
    );

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_search_vector_column IS 
'Creates or updates the search_vector GENERATED column and GIN index for a table based on searchable fields. Works for both managed and core tables as long as the physical table exists. Rebuilding is a full table rewrite under ACCESS EXCLUSIVE (~650 ms per 100k rows) that also rebuilds every index on the table, so it is skipped when the generated expression is unchanged; the check is a fingerprint stored in the column comment.';

-- =====================================================
-- HELPER FUNCTION: Update entities.searchable flag
-- =====================================================
-- Auto-maintains the searchable flag on tables based on related fields

CREATE OR REPLACE FUNCTION update_table_searchable_flag(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_has_searchable_fields BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Check if any fields in this table are searchable
    SELECT EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = p_table_name
          AND searchable = TRUE
    ) INTO v_has_searchable_fields;

    -- Update the searchable flag on the entities record
    UPDATE entities 
    SET searchable = v_has_searchable_fields
    WHERE table_name = p_table_name;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_searchable_flag IS 
'Auto-maintains the searchable flag on entities table based on whether any related fields are searchable.';

-- =====================================================
-- HELPER FUNCTION: Apply the searchable changes of one statement
-- =====================================================
-- Shared by the three statement-level triggers below.

CREATE OR REPLACE FUNCTION apply_field_searchable_change(
    p_rebuild TEXT[],
    p_touched TEXT[]
)
RETURNS VOID AS $$
DECLARE
    v_table_name TEXT;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- One rebuild per table per statement, never one per changed field row:
    -- a rebuild is a full table rewrite under ACCESS EXCLUSIVE.
    FOREACH v_table_name IN ARRAY coalesce(p_rebuild, ARRAY[]::TEXT[]) LOOP
        PERFORM update_search_vector_column(v_table_name);
    END LOOP;

    FOREACH v_table_name IN ARRAY coalesce(p_touched, ARRAY[]::TEXT[]) LOOP
        PERFORM update_table_searchable_flag(v_table_name);
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION apply_field_searchable_change IS
'Rebuilds search_vector for every table in p_rebuild and recomputes entities.searchable for every table in p_touched. Called once per statement by the handle_field_searchable_* triggers.';

-- =====================================================
-- TRIGGER FUNCTIONS: Handle field searchable changes
-- =====================================================
-- Statement-level, one function per event, because a trigger that uses
-- transition tables may only be defined for a single event. Statement level
-- rather than row level for two reasons:
--   * a statement that changes N fields of a table rebuilds that table once
--     instead of N times, and every rebuild is a full table rewrite;
--   * AFTER STATEMENT triggers run after all AFTER ROW triggers, so the physical
--     DDL from add_field_trigger and update_field_trigger has always been
--     applied by the time the tsvector expression is built. The row-level
--     version depended on trigger name ordering for that and only got it right
--     for add_field_trigger: update_field_trigger sorts after handle_field_*,
--     so an UPDATE changing both format and searchable used to build the
--     expression against the pre-ALTER column.

CREATE OR REPLACE FUNCTION handle_field_searchable_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    SELECT array_agg(DISTINCT table_name) FILTER (WHERE searchable),
           array_agg(DISTINCT table_name)
    INTO v_rebuild, v_touched
    FROM new_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION handle_field_searchable_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    -- Compare the set of searchable field names per table across the whole
    -- statement instead of pairing old rows with new ones: this catches one
    -- field being switched off while another is switched on, and needs no join
    -- key (fields.id is generated from table_name || field_name, so it moves
    -- when a field is renamed).
    SELECT array_agg(coalesce(n.table_name, o.table_name))
    INTO v_rebuild
    FROM (
        SELECT table_name,
               array_agg(field_name ORDER BY field_name) FILTER (WHERE searchable) AS searchable_names
        FROM new_fields
        GROUP BY table_name
    ) n
    FULL JOIN (
        SELECT table_name,
               array_agg(field_name ORDER BY field_name) FILTER (WHERE searchable) AS searchable_names
        FROM old_fields
        GROUP BY table_name
    ) o ON o.table_name = n.table_name
    WHERE n.searchable_names IS DISTINCT FROM o.searchable_names;

    SELECT array_agg(DISTINCT table_name) INTO v_touched FROM new_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION handle_field_searchable_delete()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    SELECT array_agg(DISTINCT table_name) FILTER (WHERE searchable),
           array_agg(DISTINCT table_name)
    INTO v_rebuild, v_touched
    FROM old_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_searchable_insert IS
'Statement-level trigger function: rebuilds search_vector once per table for the fields inserted by one statement.';
COMMENT ON FUNCTION handle_field_searchable_update IS
'Statement-level trigger function: rebuilds search_vector once per table whose set of searchable fields changed in one statement.';
COMMENT ON FUNCTION handle_field_searchable_delete IS
'Statement-level trigger function: rebuilds search_vector once per table for the fields deleted by one statement.';

-- One trigger per event: transition tables cannot be shared across events.
CREATE TRIGGER handle_field_searchable_insert_trigger
    AFTER INSERT ON fields
    REFERENCING NEW TABLE AS new_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_insert();

CREATE TRIGGER handle_field_searchable_update_trigger
    AFTER UPDATE ON fields
    REFERENCING OLD TABLE AS old_fields NEW TABLE AS new_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_update();

CREATE TRIGGER handle_field_searchable_delete_trigger
    AFTER DELETE ON fields
    REFERENCING OLD TABLE AS old_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_delete();

COMMENT ON TRIGGER handle_field_searchable_insert_trigger ON fields IS
'Automatically updates search_vector column and index when searchable fields are inserted';
COMMENT ON TRIGGER handle_field_searchable_update_trigger ON fields IS
'Automatically updates search_vector column and index when field searchable status changes';
COMMENT ON TRIGGER handle_field_searchable_delete_trigger ON fields IS
'Automatically updates search_vector column and index when searchable fields are deleted';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.searchable on direct update
-- =====================================================
-- Ensures entities.searchable always reflects the actual state of fields
-- even if someone tries to update it directly

CREATE OR REPLACE FUNCTION enforce_table_searchable_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_searchable BOOLEAN;
BEGIN
    -- If searchable was changed, recompute it from fields and override the value
    IF OLD.searchable IS DISTINCT FROM NEW.searchable THEN
        -- Compute the correct value from fields
        SELECT EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name 
              AND searchable = TRUE
        ) INTO v_computed_searchable;
        
        -- Override any manual change with the computed value
        NEW.searchable := v_computed_searchable;

    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_searchable_consistency IS 
'Trigger function that ensures entities.searchable always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_searchable_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.searchable IS DISTINCT FROM NEW.searchable)
    EXECUTE FUNCTION enforce_table_searchable_consistency();

COMMENT ON TRIGGER enforce_table_searchable_consistency_trigger ON entities IS
'Ensures entities.searchable is always consistent with related fields, preventing manual changes';
-- =====================================================
-- IS_CHILD FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages entities.is_child based on whether any field has format='parent'
-- Automatically maintains entities.is_child similar to searchable

-- =====================================================
-- HELPER FUNCTION: Update entities.is_child flag
-- =====================================================

CREATE OR REPLACE FUNCTION update_table_is_child_flag(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_has_parent_fields BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    SELECT EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = p_table_name
          AND format = 'parent'
    ) INTO v_has_parent_fields;
    
    UPDATE entities 
    SET is_child = v_has_parent_fields
    WHERE table_name = p_table_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_is_child_flag IS 
'Auto-maintains the is_child flag on entities table based on whether any related fields have format=''parent''.';

-- =====================================================
-- TRIGGER FUNCTION: Handle field parent format changes
-- =====================================================

CREATE OR REPLACE FUNCTION handle_field_parent_format_change()
RETURNS TRIGGER AS $$
DECLARE
    v_parent_changed BOOLEAN := FALSE;
    v_table_name_to_update TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (NEW.format = 'parent');
    ELSIF TG_OP = 'UPDATE' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (OLD.format IS DISTINCT FROM NEW.format AND (OLD.format = 'parent' OR NEW.format = 'parent'));
    ELSIF TG_OP = 'DELETE' THEN
        v_table_name_to_update := OLD.table_name;
        v_parent_changed := (OLD.format = 'parent');
    END IF;

    IF v_parent_changed THEN
        PERFORM update_table_is_child_flag(v_table_name_to_update);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_parent_format_change IS 
'Trigger function that updates entities.is_child when fields with format=''parent'' are created, updated, or deleted.';

CREATE TRIGGER handle_field_parent_format_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_parent_format_change();

COMMENT ON TRIGGER handle_field_parent_format_change_trigger ON fields IS
'Automatically updates entities.is_child when field parent format status changes';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.is_child on direct update
-- =====================================================

CREATE OR REPLACE FUNCTION enforce_table_is_child_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_is_child BOOLEAN;
BEGIN
    IF OLD.is_child IS DISTINCT FROM NEW.is_child THEN
        SELECT EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name 
              AND format = 'parent'
        ) INTO v_computed_is_child;

        NEW.is_child := v_computed_is_child;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_is_child_consistency IS 
'Trigger function that ensures entities.is_child always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_is_child_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.is_child IS DISTINCT FROM NEW.is_child)
    EXECUTE FUNCTION enforce_table_is_child_consistency();

COMMENT ON TRIGGER enforce_table_is_child_consistency_trigger ON entities IS
'Ensures entities.is_child is always consistent with related fields, preventing manual changes';

-- =====================================================
-- GET RECORD BY ID
-- =====================================================
-- Looks up an entity by table_name, reads its id_column, then queries the
-- physical table for the row matching the supplied id value. Returns the
-- full row as JSONB, or NULL when the entity or record does not exist.

CREATE OR REPLACE FUNCTION get_record_by_id(p_entity_name TEXT, p_id INTEGER)
RETURNS JSONB AS $$
DECLARE
    v_id_column       TEXT;
    v_view_permission TEXT;
    v_select_rule     JSONB;
    v_result          JSONB;
    v_allowed         BOOLEAN;
BEGIN
    -- Authenticate the caller. This function is SECURITY DEFINER and therefore
    -- bypasses RLS, so it MUST enforce the same access control that RLS would.
    -- rbac.uid() validates the JWT and primes the permission cache used below.
    PERFORM rbac.uid();

    -- Look up the entity to find its id_column and the access predicate.
    SELECT id_column, view_permission, select_rule
      INTO v_id_column, v_view_permission, v_select_rule
    FROM entities
    WHERE table_name = p_entity_name;

    -- Entity not found
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Enforce the entity's CANONICAL PREDICATE (spec authz-spec.md / D8), the SAME boundary
    -- the RLS SELECT policy uses — NOT view_permission alone. Return NULL rather than raising
    -- when the row is inaccessible, so callers (incl. the set_record operator) cannot
    -- distinguish "not allowed" from "does not exist", preventing record-existence leakage.
    IF v_select_rule IS NULL OR v_select_rule = '{}'::jsonb THEN
        -- No row rule: view_permission is the access predicate (the default rule).
        IF NOT rbac.has_permission(v_view_permission) THEN
            RETURN NULL;
        END IF;
        EXECUTE format(
            'SELECT row_to_json(t)::jsonb FROM %I t WHERE %I = $1 LIMIT 1',
            p_entity_name, v_id_column
        ) INTO v_result USING p_id;
    ELSE
        -- select_rule REPLACES view_permission: evaluate the per-row rule for THIS row.
        -- (The select_rule_<table>() helper is created by build_select_rule_policy.)
        EXECUTE format(
            'SELECT row_to_json(t)::jsonb, public.%I(t) FROM %I t WHERE %I = $1 LIMIT 1',
            'select_rule_' || p_entity_name, p_entity_name, v_id_column
        ) INTO v_result, v_allowed USING p_id;
        IF NOT COALESCE(v_allowed, FALSE) THEN
            RETURN NULL;
        END IF;
    END IF;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION get_record_by_id IS
'Returns a single entity record as JSONB by looking up the entity id_column and querying the physical table. SECURITY DEFINER: authenticates via rbac.uid() and enforces the entity''s view_permission (the same access boundary as RLS / get_schema). Returns NULL when the entity or record does not exist, or when the caller lacks view permission (the two cases are indistinguishable, to avoid leaking record existence).';

-- Revoke default PUBLIC execute on all DDL functions defined in this file
REVOKE EXECUTE ON FUNCTION get_record_by_id(TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_record_by_id(TEXT, INTEGER) TO semantius_user;
REVOKE EXECUTE ON FUNCTION format_to_data_type(TEXT, SMALLINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) TO semantius_user;
GRANT EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION is_nullable(TEXT) FROM PUBLIC;
-- Grant is_nullable to semantius_user: it is called directly (e.g. in get_schema's required-fields
-- query and the field DDL triggers) in the inserting user's context, so semantius_user needs EXECUTE.
GRANT EXECUTE ON FUNCTION is_nullable(TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION format_to_json_type(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION quote_default_value(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_table_comment(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_field_comment(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_dd_table_comment() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION add_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_search_vector_column(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_searchable_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_field_searchable_change(TEXT[], TEXT[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_searchable_consistency() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_is_child_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_parent_format_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_is_child_consistency() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_entity_policies() FROM PUBLIC;
