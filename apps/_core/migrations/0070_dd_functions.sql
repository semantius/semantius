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

CREATE OR REPLACE FUNCTION format_to_data_type(p_format TEXT)
RETURNS TEXT AS $$
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
        WHEN 'number' THEN 'NUMERIC'
        
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
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION format_to_data_type IS 
'Maps JSON Schema format values to PostgreSQL data types for CREATE/ALTER TABLE statements.';

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
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION format_to_json_type IS 
'Maps format values to JSON Schema types (returns JSONB - either a string for single type or array for json format).';

-- =====================================================
-- HELPER FUNCTION: QUOTE DEFAULT VALUE
-- =====================================================
-- Properly quotes default values based on data type
-- Properly quotes default values based on data type for DDL statements

CREATE OR REPLACE FUNCTION quote_default_value(p_default_value TEXT, p_data_type TEXT)
RETURNS TEXT AS $$
BEGIN
    -- If default value is NULL or empty, return as-is
    IF p_default_value IS NULL OR trim(p_default_value) = '' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a function call (contains parentheses) or cast (contains ::), return as-is
    IF p_default_value ~ '\(|::' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a numeric constant and data type is numeric, return as-is
    IF p_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT', 'NUMERIC', 'DECIMAL', 'REAL', 'DOUBLE PRECISION') 
       AND p_default_value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a boolean constant, return uppercase for consistency
    IF p_data_type = 'BOOLEAN' AND p_default_value IN ('TRUE', 'FALSE', 'true', 'false', 't', 'f') THEN
        RETURN UPPER(p_default_value);
    END IF;
    
    -- For TEXT and string-like types, quote the value
    IF p_data_type IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER VARYING') THEN
        RETURN quote_literal(p_default_value);
    END IF;
    
    -- Default: return as-is (for special types like UUID, JSONB, etc.)
    RETURN p_default_value;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION quote_default_value IS 
'Properly quotes default values based on data type for use in DDL statements.';

-- =====================================================
-- TRIGGER FUNCTION: CREATE TABLE ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION create_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_policy_sql TEXT;
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
    
    -- Add table comment if description provided
    IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
        EXECUTE format(
            'COMMENT ON TABLE %I IS %L',
            NEW.table_name,
            NEW.description
        );
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
    
    -- Create RLS policies for SELECT (view permission)
    v_policy_sql := format(
        'CREATE POLICY %I_select_policy ON %I
            FOR SELECT
            TO semantius_user
            USING (rbac.has_permission(%L))',
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
            WITH CHECK (rbac.has_permission(%L))',
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
            USING (rbac.has_permission(%L))
            WITH CHECK (rbac.has_permission(%L))',
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
            USING (rbac.has_permission(%L))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Insert field records for id, label, created_at, and updated_at columns
    -- All these are core fields that cannot be deleted or renamed (is_core = TRUE)
    -- The label column is marked as searchable=TRUE for full-text search
    INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    VALUES 
        (NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, FALSE, 0, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
        (NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, FALSE, 1, 'required', 'default', 'label', TRUE, TRUE, '', ''),
        (NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, FALSE, 999998, 'disabled', 'default', '', TRUE, FALSE, '', ''),
        (NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, FALSE, 999999, 'disabled', 'default', '', TRUE, FALSE, '', '');
    
    -- Note: The handle_field_searchable_change_trigger will fire for the above INSERTs
    -- and update entities.searchable automatically. However, since we're in a nested trigger context,
    -- we need to ensure the searchable flag gets set correctly after this trigger completes.
    -- The solution is to update it directly here since the label field is always searchable.
    UPDATE entities 
    SET searchable = TRUE 
    WHERE table_name = NEW.table_name 
      AND EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND searchable = TRUE);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION create_dd_table IS 
'Trigger function that creates a table with RLS policies when a row is inserted into entities table.';

-- Apply trigger AFTER INSERT on entities
CREATE TRIGGER create_table_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION create_dd_table();

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
        -- Still add column comment if description provided
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        END IF;
        RETURN NEW;
    END IF;
    
    -- Convert format to PostgreSQL data type
    v_data_type := format_to_data_type(NEW.format);
    
    -- Build nullable clause
    IF NEW.is_nullable THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;
    
    -- Build default clause with sensible defaults based on data type
    IF NEW.default_value IS NOT NULL AND trim(NEW.default_value) != '' THEN
        v_default_clause := format('DEFAULT %s', quote_default_value(NEW.default_value, v_data_type));
    ELSIF NOT NEW.is_nullable THEN
        -- Provide sensible defaults for NOT NULL columns without explicit default
        -- For JSONB/JSON: if default_value is empty string, convert to empty JSON object
        IF v_data_type IN ('JSONB', 'JSON') THEN
            v_default_clause := 'DEFAULT ''{}''::jsonb';
        ELSE
            CASE v_data_type
                WHEN 'TEXT' THEN v_default_clause := 'DEFAULT ''''';
                WHEN 'INTEGER', 'BIGINT', 'SMALLINT' THEN v_default_clause := 'DEFAULT 0';
                WHEN 'NUMERIC', 'DECIMAL', 'REAL', 'DOUBLE PRECISION' THEN v_default_clause := 'DEFAULT 0.0';
                WHEN 'BOOLEAN' THEN v_default_clause := 'DEFAULT FALSE';
                WHEN 'TIMESTAMP', 'TIMESTAMPTZ' THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                WHEN 'DATE' THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                ELSE v_default_clause := '';
            END CASE;
        END IF;
    ELSE
        v_default_clause := '';
    END IF;
    
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
    
    -- Add column comment if description provided
    IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
        EXECUTE format(
            'COMMENT ON COLUMN %I.%I IS %L',
            NEW.table_name,
            NEW.field_name,
            NEW.description
        );
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
        v_alter_sql := format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
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
    IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
        BEGIN
            -- Generate CHECK constraint name
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Build SQL array from JSONB array for IN clause
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(NEW.enum_values) AS value
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
    
    -- Prevent changing structural attributes of core fields
    -- Core fields can only have metadata updates (title, description, field_order, input_type, width)
    IF OLD.is_core THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;
        
        IF OLD.is_nullable <> NEW.is_nullable THEN
            RAISE EXCEPTION 'Cannot change nullable constraint of core system field "%"', OLD.field_name;
        END IF;
        
        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;
        
        IF OLD.is_core <> NEW.is_core THEN
            RAISE EXCEPTION 'Cannot change is_core status of field "%"', OLD.field_name;
        END IF;
    END IF;
    
    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still allow updating column comments even if not managed
        IF OLD.description IS DISTINCT FROM NEW.description THEN
            IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS %L',
                    NEW.table_name,
                    NEW.field_name,
                    NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
        END IF;
        
        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
    END IF;
    
    -- Allow updating format (which changes data type)
    IF OLD.format <> NEW.format THEN
        v_new_data_type := format_to_data_type(NEW.format);
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
    
    -- Allow updating nullable constraint
    IF OLD.is_nullable <> NEW.is_nullable THEN
        IF NEW.is_nullable THEN
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
            NEW.field_name, NEW.is_nullable, NEW.table_name;
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
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format))
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
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
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
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Check if enum_values changed or format changed
            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values) OR (OLD.format <> NEW.format) THEN
                
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
                IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
                    -- Build SQL array from JSONB array for IN clause
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(NEW.enum_values) AS value
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
    
    -- Prevent deletion of core fields (id, label, created_at, updated_at) for standalone field deletions
    IF OLD.is_core THEN
        RAISE EXCEPTION 'Cannot delete core system field "%". Core fields (id, label, created_at, updated_at) cannot be deleted.', OLD.field_name;
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION delete_dd_table IS 
'Trigger function that drops a table when a row is deleted from entities table.';

-- Apply trigger BEFORE DELETE on entities
-- Note: Fields will be deleted via CASCADE on the foreign key
CREATE TRIGGER delete_table_trigger
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_table();

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
BEGIN
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
        -- Drop the GIN index first
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            p_table_name || '_search_vector_idx'
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
            format('setweight(to_tsvector(''english'', coalesce(%I, '''')), ''%s'')',
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
        p_table_name || '_search_vector_idx'
    );
    
    -- Create GIN index on the search_vector column
    EXECUTE format(
        'CREATE INDEX %I ON %I USING GIN (search_vector)',
        p_table_name || '_search_vector_idx',
        p_table_name
    );

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_search_vector_column IS 
'Creates or updates the search_vector GENERATED column and GIN index for a table based on searchable fields. Works for both managed and core tables as long as the physical table exists.';

-- =====================================================
-- HELPER FUNCTION: Update entities.searchable flag
-- =====================================================
-- Auto-maintains the searchable flag on tables based on related fields

CREATE OR REPLACE FUNCTION update_table_searchable_flag(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_has_searchable_fields BOOLEAN;
BEGIN
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_table_searchable_flag IS 
'Auto-maintains the searchable flag on entities table based on whether any related fields are searchable.';

-- =====================================================
-- TRIGGER FUNCTION: Handle field searchable changes
-- =====================================================
-- Detects when searchable field list changes and updates search_vector accordingly

CREATE OR REPLACE FUNCTION handle_field_searchable_change()
RETURNS TRIGGER AS $$
DECLARE
    v_searchable_changed BOOLEAN := FALSE;
    v_table_name_to_update TEXT;
BEGIN
    -- Determine which table needs updating and if searchable changed
    IF TG_OP = 'INSERT' THEN
        v_table_name_to_update := NEW.table_name;
        v_searchable_changed := (NEW.searchable = TRUE);
    ELSIF TG_OP = 'UPDATE' THEN
        v_table_name_to_update := NEW.table_name;
        v_searchable_changed := (OLD.searchable IS DISTINCT FROM NEW.searchable);
    ELSIF TG_OP = 'DELETE' THEN
        v_table_name_to_update := OLD.table_name;
        v_searchable_changed := (OLD.searchable = TRUE);
    END IF;
    
    -- Update search vector if searchable fields changed
    -- The add_field_trigger runs alphabetically before this trigger, so the column already exists
    IF v_searchable_changed THEN
        PERFORM update_search_vector_column(v_table_name_to_update);
    END IF;
    
    -- Always update the table searchable flag when fields change
    PERFORM update_table_searchable_flag(v_table_name_to_update);
    
    -- Return appropriate value based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION handle_field_searchable_change IS 
'Trigger function that updates search_vector column and GIN index when searchable fields are created, updated, or deleted. The add_field_trigger executes before this trigger (alphabetically), ensuring the physical column exists before we update the search_vector.';

-- Apply trigger AFTER INSERT/UPDATE/DELETE on fields
CREATE TRIGGER handle_field_searchable_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_searchable_change();

COMMENT ON TRIGGER handle_field_searchable_change_trigger ON fields IS
'Automatically updates search_vector column and index when field searchable status changes';

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
$$ LANGUAGE plpgsql;

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
    SELECT EXISTS (
        SELECT 1 FROM fields 
        WHERE table_name = p_table_name 
          AND format = 'parent'
    ) INTO v_has_parent_fields;
    
    UPDATE entities 
    SET is_child = v_has_parent_fields
    WHERE table_name = p_table_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enforce_table_is_child_consistency IS 
'Trigger function that ensures entities.is_child always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_is_child_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.is_child IS DISTINCT FROM NEW.is_child)
    EXECUTE FUNCTION enforce_table_is_child_consistency();

COMMENT ON TRIGGER enforce_table_is_child_consistency_trigger ON entities IS
'Ensures entities.is_child is always consistent with related fields, preventing manual changes';
