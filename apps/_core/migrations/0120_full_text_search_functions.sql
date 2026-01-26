-- =====================================================
-- FULL-TEXT SEARCH FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages search_vector column and GIN index based on searchable fields
-- Automatically maintains tables.searchable based on related fields

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
    v_is_managed BOOLEAN;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM tables WHERE table_name = p_table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping search vector update for "%" (table managed=false)', p_table_name;
        RETURN;
    END IF;
    
    -- Get all searchable text-based fields for this table
    SELECT ARRAY_AGG(field_name ORDER BY field_order)
    INTO v_searchable_fields
    FROM fields
    WHERE table_name = p_table_name
      AND searchable = TRUE
      AND format_to_json_type(format) = 'string';  -- Only text-based fields
    
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
        
        RAISE NOTICE 'Removed search_vector column and index from table "%" (no searchable fields)', p_table_name;
        RETURN;
    END IF;
    
    -- Build the tsvector expression by concatenating all searchable fields
    -- Using coalesce to handle NULL values and setweight for ranking
    v_search_expr := (
        SELECT string_agg(
            format('setweight(to_tsvector(''english'', coalesce(%I, '''')), ''%s'')',
                field_name,
                CASE 
                    WHEN ctype = 'label' THEN 'A'  -- Label fields get highest weight
                    WHEN field_name IN ('title', 'name') THEN 'A'  -- Title/name fields
                    WHEN field_name LIKE '%description%' THEN 'B'  -- Description fields
                    ELSE 'C'  -- Other searchable fields
                END
            ),
            ' || '
            ORDER BY field_order
        )
        FROM fields
        WHERE table_name = p_table_name
          AND searchable = TRUE
          AND format_to_json_type(format) = 'string'
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
    
    RAISE NOTICE 'Updated search_vector column and GIN index for table "%" with % searchable field(s)',
        p_table_name, array_length(v_searchable_fields, 1);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_search_vector_column IS 
'Creates or updates the search_vector GENERATED column and GIN index for a table based on searchable fields. Only executes when table is managed=true.';

-- =====================================================
-- HELPER FUNCTION: Update tables.searchable flag
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
    
    -- Update the searchable flag on the tables record
    UPDATE tables 
    SET searchable = v_has_searchable_fields
    WHERE table_name = p_table_name;
    
    RAISE NOTICE 'Updated searchable flag for table "%" to %', p_table_name, v_has_searchable_fields;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_table_searchable_flag IS 
'Auto-maintains the searchable flag on tables table based on whether any related fields are searchable.';

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
'Trigger function that updates search_vector column and GIN index when searchable fields are created, updated, or deleted.';

-- Apply trigger AFTER INSERT/UPDATE/DELETE on fields
CREATE TRIGGER handle_field_searchable_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_searchable_change();

COMMENT ON TRIGGER handle_field_searchable_change_trigger ON fields IS
'Automatically updates search_vector column and index when field searchable status changes';

-- =====================================================
-- TRIGGER FUNCTION: Recompute tables.searchable on direct update
-- =====================================================
-- Ensures tables.searchable always reflects the actual state of fields
-- even if someone tries to update it directly

CREATE OR REPLACE FUNCTION enforce_table_searchable_consistency()
RETURNS TRIGGER AS $$
BEGIN
    -- If searchable was changed, recompute it from fields
    IF OLD.searchable IS DISTINCT FROM NEW.searchable THEN
        PERFORM update_table_searchable_flag(NEW.table_name);
        -- Re-fetch the correct value
        SELECT searchable INTO NEW.searchable 
        FROM tables 
        WHERE table_name = NEW.table_name;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enforce_table_searchable_consistency IS 
'Trigger function that ensures tables.searchable always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_searchable_consistency_trigger
    BEFORE UPDATE ON tables
    FOR EACH ROW
    WHEN (OLD.searchable IS DISTINCT FROM NEW.searchable)
    EXECUTE FUNCTION enforce_table_searchable_consistency();

COMMENT ON TRIGGER enforce_table_searchable_consistency_trigger ON tables IS
'Ensures tables.searchable is always consistent with related fields, preventing manual changes';
