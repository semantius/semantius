-- =====================================================
-- POSTGREST SCHEMA RELOAD NOTIFICATIONS
-- =====================================================
-- Send NOTIFY pgrst commands when tables or fields are modified
-- This ensures PostgREST automatically reloads its schema cache
-- =====================================================

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON TABLES CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_tables()
RETURNS TRIGGER AS $$
BEGIN
    -- Notify PostgREST to reload schema when tables metadata changes
    PERFORM pg_notify('pgrst', 'reload schema');
    
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_tables IS 
'Trigger function that notifies PostgREST to reload schema when entities are modified.';

-- Apply trigger on entities table
CREATE TRIGGER notify_pgrst_on_tables_change
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_tables();

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON FIELDS CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- Notify PostgREST to reload schema when fields metadata changes
    PERFORM pg_notify('pgrst', 'reload schema');
    
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_fields IS 
'Trigger function that notifies PostgREST to reload schema when fields are modified.';

-- Apply trigger on fields table
CREATE TRIGGER notify_pgrst_on_fields_change
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_fields();

-- Revoke default PUBLIC execute on notify trigger functions
REVOKE EXECUTE ON FUNCTION notify_pgrst_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION notify_pgrst_fields() FROM PUBLIC;
