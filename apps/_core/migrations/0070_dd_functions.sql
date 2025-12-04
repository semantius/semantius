-- =====================================================
-- DYNAMIC TABLE MANAGEMENT FUNCTIONS
-- =====================================================
-- Automatically creates tables and fields when metadata is inserted
-- Integrates with RBAC for automatic RLS policy creation
-- =====================================================

-- =====================================================
-- HELPER FUNCTION: MAP JSON SCHEMA FORMAT TO POSTGRESQL DATA TYPE
-- =====================================================

CREATE OR REPLACE FUNCTION format_to_data_type(format_value TEXT)
RETURNS TEXT AS $$
BEGIN
    -- Map JSON Schema formats to PostgreSQL data types
    -- Primitive types map directly, special formats map to appropriate SQL types
    RETURN CASE LOWER(format_value)
        -- JSON Schema primitive types
        WHEN 'string' THEN 'TEXT'
        WHEN 'number' THEN 'NUMERIC'
        WHEN 'integer' THEN 'INTEGER'
        WHEN 'boolean' THEN 'BOOLEAN'
        WHEN 'object' THEN 'JSONB'
        WHEN 'array' THEN 'JSONB'
        WHEN 'null' THEN 'TEXT'
        
        -- JSON Schema string formats
        WHEN 'email' THEN 'TEXT'
        WHEN 'date' THEN 'DATE'
        WHEN 'date-time' THEN 'TIMESTAMPTZ'
        WHEN 'time' THEN 'TIME'
        WHEN 'uri' THEN 'TEXT'
        WHEN 'url' THEN 'TEXT'
        WHEN 'uuid' THEN 'UUID'
        WHEN 'ipv4' THEN 'INET'
        WHEN 'ipv6' THEN 'INET'
        WHEN 'hostname' THEN 'TEXT'
        
        -- Additional PostgreSQL-specific types
        WHEN 'bigint' THEN 'BIGINT'
        WHEN 'smallint' THEN 'SMALLINT'
        WHEN 'decimal' THEN 'DECIMAL'
        WHEN 'real' THEN 'REAL'
        WHEN 'double precision' THEN 'DOUBLE PRECISION'
        WHEN 'timestamp' THEN 'TIMESTAMP'
        WHEN 'timestamptz' THEN 'TIMESTAMPTZ'
        WHEN 'timetz' THEN 'TIMETZ'
        WHEN 'json' THEN 'JSON'
        WHEN 'jsonb' THEN 'JSONB'
        
        -- Default: assume it's already a PostgreSQL type (for backwards compatibility)
        ELSE UPPER(format_value)
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION format_to_data_type IS 
'Maps JSON Schema format values to PostgreSQL data types for CREATE/ALTER TABLE statements';

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
            %I TEXT NOT NULL,
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
    
    -- Insert field records for id and label columns
    -- Using INSERT with RETURNING to avoid recursive trigger issues
    INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, ctype)
    VALUES 
        (NEW.table_name, NEW.id_column, 'Id', 'integer', TRUE, FALSE, 0, 'id'),
        (NEW.table_name, NEW.label_column, NEW.singular_label, 'string', FALSE, FALSE, 1, 'label');
    
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
    
    -- Build nullable clause
    IF NEW.is_nullable THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;
    
    -- Build default clause
    IF NEW.default_value IS NOT NULL THEN
        v_default_clause := format('DEFAULT %s', NEW.default_value);
    ELSE
        v_default_clause := '';
    END IF;
    
    -- Build ALTER TABLE statement
    -- Convert JSON Schema format to PostgreSQL data type
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        NEW.table_name,
        NEW.field_name,
        format_to_data_type(NEW.format),
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
        NEW.field_name, NEW.table_name, format_to_data_type(NEW.format);
    
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
    
    -- Allow updating format (data type)
    IF OLD.format <> NEW.format THEN
        v_alter_sql := format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE %s',
            NEW.table_name,
            NEW.field_name,
            format_to_data_type(NEW.format)
        );
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" type to % in table "%"',
            NEW.field_name, format_to_data_type(NEW.format), NEW.table_name;
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
DECLARE
    v_id_column TEXT;
    v_label_column TEXT;
BEGIN
    -- Get the protected columns
    SELECT id_column, label_column 
    INTO v_id_column, v_label_column
    FROM tables
    WHERE table_name = OLD.table_name;
    
    -- Prevent deletion of id or label columns
    IF OLD.field_name = v_id_column OR OLD.field_name = v_label_column THEN
        RAISE EXCEPTION 'Cannot delete system columns (% or %)', v_id_column, v_label_column;
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