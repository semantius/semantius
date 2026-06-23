-- =====================================================
-- MIGRATION: order_column support
-- =====================================================
-- Adds a new order_column TEXT column to entities. When set to a non-empty
-- value the migration machinery:
--   1. Adds an INTEGER column with that name to the target table (if managed)
--   2. Installs a BEFORE INSERT trigger that auto-assigns order values
-- When order_column is cleared (set to '' or changed):
--   1. Drops the old order column from the target table
--   2. Removes the old trigger
-- Also replaces the old auto_set_field_order() function with the generic
-- auto_set_row_order() that works on any table via TG_ARGV.

-- =====================================================
-- STEP 1: Add order_column to entities table
-- =====================================================

ALTER TABLE entities ADD COLUMN order_column TEXT NOT NULL DEFAULT '';

ALTER TABLE entities ADD CONSTRAINT valid_order_column
    CHECK (order_column = '' OR order_column ~ '^[a-z_][a-z0-9_]*$');

COMMENT ON COLUMN entities.order_column IS
'Column name used for fixed row ordering. When set, this column is added to the target table and auto-populated on INSERT. Empty = no ordering.';

-- =====================================================
-- STEP 2: Add field metadata for order_column
-- =====================================================

INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('entities', 'order_column', 'Order Column', 'Store a fixed row order in this column', '', 'text', FALSE, 119, 'default', 'default', 'core', FALSE, '', '', '');

-- =====================================================
-- STEP 3: Remove auto_set_field_order and replace with generic auto_set_row_order
-- =====================================================

DROP TRIGGER IF EXISTS auto_set_field_order_trigger ON fields;
DROP FUNCTION IF EXISTS auto_set_field_order();

-- Generic row-order auto-assignment. Installed on any table whose entity
-- has a non-empty order_column. When a row is inserted with the order
-- column = 0 (the default), assigns max(order_column WHERE value < 900000) + 10,
-- starting at 10 for the first record. The 900000 ceiling lets callers
-- pin rows above that threshold without affecting auto-numbering.

CREATE OR REPLACE FUNCTION auto_set_row_order()
RETURNS TRIGGER AS $$
DECLARE
    v_order_col TEXT;
    v_current   INTEGER;
BEGIN
    -- The column name is passed via TG_ARGV[0].
    v_order_col := TG_ARGV[0];

    EXECUTE format('SELECT ($1.%I)::integer', v_order_col) INTO v_current USING NEW;
    IF v_current = 0 THEN
        EXECUTE format(
            'SELECT COALESCE(MAX(%I) FILTER (WHERE %I < 900000), 0) + 10 FROM %I',
            v_order_col, v_order_col, TG_TABLE_NAME
        ) INTO v_current;
        NEW := jsonb_populate_record(NEW, jsonb_build_object(v_order_col, v_current));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_row_order IS
'Generic BEFORE INSERT trigger that auto-assigns a row-order value. Receives the column name via TG_ARGV[0]. Assigns max(col WHERE col < 900000) + 10 when the value is 0.';

REVOKE EXECUTE ON FUNCTION auto_set_row_order() FROM PUBLIC;

-- =====================================================
-- STEP 4: Helper functions to install / uninstall order trigger + column
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
-- STEP 5: Triggers on entities to manage order_column changes
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
-- STEP 6: Set order_column for the fields entity
-- =====================================================
-- The fields table already has a field_order column. Setting order_column
-- replaces the removed auto_set_field_order() with the generic mechanism.

UPDATE entities SET order_column = 'field_order' WHERE table_name = 'fields';

-- Install the trigger explicitly (the UPDATE trigger fires but fields is
-- a core DD table that already has the column, so install_order_column
-- just adds the trigger).
SELECT install_order_column('fields', 'field_order');
