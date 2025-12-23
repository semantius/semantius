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
RETURNS TEXT AS $$
BEGIN
    RETURN CASE 
        WHEN p_format IN ('int32', 'int64', 'integer') THEN 'integer'
        WHEN p_format IN ('float', 'double', 'number') THEN 'number'
        WHEN p_format = 'boolean' THEN 'boolean'
        WHEN p_format IN ('array') THEN 'array'
        WHEN p_format IN ('object', 'json') THEN 'object'
        WHEN p_format = 'null' THEN 'null'
        ELSE 'string'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION format_to_json_type IS 
'Maps format values to JSON Schema primitive types for consistent type handling.';

-- =====================================================
-- TRIGGER FUNCTION: CREATE TABLE ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION create_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_policy_sql TEXT;
BEGIN
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
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
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
    INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, ctype, is_core)
    VALUES 
        (NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, FALSE, 0, 'readonly', 's', 'id', TRUE),
        (NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, FALSE, 1, 'required', 'm', 'label', TRUE),
        (NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, FALSE, 999998, 'disabled', 'm', 'timestamp', TRUE),
        (NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, FALSE, 999999, 'disabled', 'm', 'timestamp', TRUE);
    
    RAISE NOTICE 'Created table "%" with RLS policies using view permission "%" and edit permission "%"',
        NEW.table_name, NEW.view_permission, NEW.edit_permission;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION create_dd_table IS 
'Trigger function that creates a table with RLS policies when a row is inserted into tables table.';

-- Apply trigger AFTER INSERT on tables
CREATE TRIGGER create_table_trigger
    AFTER INSERT ON tables
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
BEGIN
    -- Skip if this is the id or label column (already created by create_dd_table)
    IF NEW.field_name IN (
        SELECT id_column FROM tables WHERE table_name = NEW.table_name
        UNION
        SELECT label_column FROM tables WHERE table_name = NEW.table_name
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
        v_default_clause := format('DEFAULT %s', NEW.default_value);
    ELSIF NOT NEW.is_nullable THEN
        -- Provide sensible defaults for NOT NULL columns without explicit default
        CASE v_data_type
            WHEN 'TEXT' THEN v_default_clause := 'DEFAULT ''''';
            WHEN 'INTEGER', 'BIGINT', 'SMALLINT' THEN v_default_clause := 'DEFAULT 0';
            WHEN 'NUMERIC', 'DECIMAL', 'REAL', 'DOUBLE PRECISION' THEN v_default_clause := 'DEFAULT 0.0';
            WHEN 'BOOLEAN' THEN v_default_clause := 'DEFAULT FALSE';
            WHEN 'TIMESTAMP', 'TIMESTAMPTZ' THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
            WHEN 'DATE' THEN v_default_clause := 'DEFAULT CURRENT_DATE';
            WHEN 'JSONB', 'JSON' THEN v_default_clause := 'DEFAULT ''{}''';
            ELSE v_default_clause := '';
        END CASE;
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
    
    RAISE NOTICE 'Added column "%" to table "%" with type %',
        NEW.field_name, NEW.table_name, v_data_type;
    
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
BEGIN
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
                NEW.default_value
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
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
BEGIN
    -- Prevent deletion of core fields (id, label, created_at, updated_at)
    IF OLD.is_core THEN
        RAISE EXCEPTION 'Cannot delete core system field "%". Core fields (id, label, created_at, updated_at) cannot be deleted.', OLD.field_name;
    END IF;
    
    -- Drop the column
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS %I',
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
    -- Drop the table (CASCADE will drop all dependent objects)
    EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', OLD.table_name);
    
    RAISE NOTICE 'Dropped table "%"', OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION delete_dd_table IS 
'Trigger function that drops a table when a row is deleted from tables table.';

-- Apply trigger BEFORE DELETE on tables
-- Note: Fields will be deleted via CASCADE on the foreign key
CREATE TRIGGER delete_table_trigger
    BEFORE DELETE ON tables
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_table();