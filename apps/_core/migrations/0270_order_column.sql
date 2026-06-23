-- =====================================================
-- MIGRATION: order_column support
-- =====================================================
-- When entities.order_column is set to a non-empty value:
--   1. Adds an INTEGER column with that name to the target table (if managed)
--   2. Installs a BEFORE INSERT trigger that auto-assigns order values
-- When order_column is cleared (set to '' or changed):
--   1. Drops the old order column from the target table
--   2. Removes the old trigger
-- The auto_set_row_order() generic function (defined in 0070) receives the
-- column name via TG_ARGV and assigns max(col WHERE col < 900000) + 10
-- when the inserted value is 0, starting at 10 for the first record.

-- =====================================================
-- HELPER: install / uninstall order trigger + column
-- =====================================================

CREATE OR REPLACE FUNCTION install_order_column(p_table_name TEXT, p_order_column TEXT)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT;
    v_managed BOOLEAN;
BEGIN
    SET LOCAL client_min_messages = WARNING;

    SELECT managed INTO v_managed FROM entities WHERE table_name = p_table_name;
    IF NOT COALESCE(v_managed, FALSE) THEN
        RETURN;
    END IF;

    v_trigger_name := 'auto_row_order_' || p_table_name;

    -- Add the INTEGER column (idempotent)
    EXECUTE format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I INTEGER NOT NULL DEFAULT 0',
        p_table_name, p_order_column
    );

    -- Drop any previous trigger with this name, then create
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_table_name);
    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION auto_set_row_order(%L)',
        v_trigger_name, p_table_name, p_order_column
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION uninstall_order_column(p_table_name TEXT, p_order_column TEXT)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT;
    v_managed BOOLEAN;
BEGIN
    SET LOCAL client_min_messages = WARNING;

    SELECT managed INTO v_managed FROM entities WHERE table_name = p_table_name;
    IF NOT COALESCE(v_managed, FALSE) THEN
        RETURN;
    END IF;

    v_trigger_name := 'auto_row_order_' || p_table_name;

    -- Drop trigger
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_table_name);

    -- Drop column
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS %I',
        p_table_name, p_order_column
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION install_order_column(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION uninstall_order_column(TEXT, TEXT) FROM PUBLIC;

-- =====================================================
-- TRIGGER: manage order_column on entities INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION manage_order_column_on_insert()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.order_column <> '' THEN
        PERFORM install_order_column(NEW.table_name, NEW.order_column);
    END IF;
    RETURN NULL;  -- AFTER trigger
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Fire after create_table_trigger so the physical table exists
CREATE TRIGGER manage_order_column_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_order_column_on_insert();

-- =====================================================
-- TRIGGER: manage order_column on entities UPDATE
-- =====================================================

CREATE OR REPLACE FUNCTION manage_order_column_on_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Nothing changed
    IF OLD.order_column = NEW.order_column THEN
        RETURN NULL;
    END IF;

    -- Remove old order column if it was set
    IF OLD.order_column <> '' THEN
        PERFORM uninstall_order_column(NEW.table_name, OLD.order_column);
    END IF;

    -- Install new order column if set
    IF NEW.order_column <> '' THEN
        PERFORM install_order_column(NEW.table_name, NEW.order_column);
    END IF;

    RETURN NULL;  -- AFTER trigger
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER manage_order_column_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.order_column IS DISTINCT FROM NEW.order_column)
    EXECUTE FUNCTION manage_order_column_on_update();

REVOKE EXECUTE ON FUNCTION manage_order_column_on_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION manage_order_column_on_update() FROM PUBLIC;

-- =====================================================
-- BOOTSTRAP: install order trigger for fields table
-- =====================================================
-- The fields table already has a field_order column. Set order_column
-- on the fields entity so the generic mechanism takes over from the
-- removed auto_set_field_order() function.

UPDATE entities SET order_column = 'field_order' WHERE table_name = 'fields';

-- The UPDATE trigger above will install the trigger on the fields table.
-- However, since the fields table is a core DD table (not managed in the
-- normal sense), we install the trigger explicitly here as well.
SELECT install_order_column('fields', 'field_order');
