-- =====================================================
-- MIGRATION: entities.order_column — fixed per-entity row ordering
-- =====================================================
-- Adds a generic "row order" mechanism driven by a single metadata column on
-- entities:
--
--   entities.order_column  TEXT  -- name of the INTEGER column that stores a
--                                    fixed row order on this entity's physical
--                                    table. '' (the default) = no row ordering.
--
-- behavior (all driven by AFTER INSERT/UPDATE triggers on entities, mirroring
-- the other table-altering DD triggers):
--   • When order_column is set (first time): ALTER TABLE ... ADD COLUMN
--     <order_column> INTEGER NOT NULL DEFAULT 0, and install a BEFORE INSERT
--     trigger that auto-assigns the order on inserts that don't provide a value.
--   • When order_column is changed to a different name: the previous column is
--     dropped and the new one created.
--   • When order_column is cleared ('' or NULL): the column and its auto-assign
--     trigger are dropped.
--
-- Auto-assign rule (matching the requirement): on INSERT, when the order column
-- has no value (0 / NULL), set it to MAX(order_column) + 10 over the rows whose
-- order is below 900000 (so values pinned at/above the 900,000 ceiling — e.g. the
-- created_at/updated_at audit columns at 999998/999999 — never inflate the
-- running max), or 10 for the first record.
--
-- This generalizes (and replaces) the old fields-only auto_set_field_order()
-- trigger: the `fields` entity simply declares order_column = 'field_order'.

-- =====================================================
-- 1. Add the order_column metadata column to entities
-- =====================================================

ALTER TABLE entities ADD COLUMN IF NOT EXISTS order_column TEXT NOT NULL DEFAULT '';

ALTER TABLE entities ADD CONSTRAINT valid_order_column
    CHECK (order_column = '' OR order_column ~ '^[a-z_][a-z0-9_]*$');

COMMENT ON COLUMN entities.order_column IS 'Store a fixed row order in this column';

-- Dictionary metadata so the field shows up in get_schema() properties and the UI.
-- The column was added above (with its CHECK constraint), so add_dd_field()'s
-- ADD COLUMN IF NOT EXISTS is a harmless no-op here.
INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('entities', 'order_column', 'Order Column', 'Store a fixed row order in this column', '', 'text', FALSE, 112, 'default', 'default', 'core', FALSE, '', '', '');

-- =====================================================
-- 2. Generic BEFORE INSERT auto-assign trigger function
-- =====================================================
-- Installed (per entity) on the physical table by handle_entity_order_column().
-- The order column name is passed as a trigger argument (TG_ARGV[0]), so a single
-- function serves every entity that declares an order_column.
--
-- The `fields` table is special: it holds the field metadata for many entities in
-- one physical table, so its order runs independently per table_name (a new field
-- continues its own entity's 10/20/30… sequence). Every other entity is a single
-- list, so the whole physical table is one sequence.
--
-- SECURITY DEFINER so the MAX() probe sees every row (true max), not just the rows
-- the inserting user can read under RLS — otherwise concurrent inserts by limited
-- users could collide on order values.

CREATE OR REPLACE FUNCTION auto_set_order_value()
RETURNS TRIGGER AS $$
DECLARE
    v_col     TEXT := TG_ARGV[0];
    v_current JSONB;
    v_val     BIGINT;
    v_next    BIGINT;
BEGIN
    v_current := to_jsonb(NEW);

    -- Current value of the order column on the incoming row ('' / NULL / 0 => unset).
    v_val := NULLIF(v_current ->> v_col, '')::BIGINT;

    IF v_val IS NULL OR v_val = 0 THEN
        IF TG_TABLE_NAME = 'fields' THEN
            -- Per table_name: a new field lands after that entity's existing fields.
            SELECT COALESCE(MAX(field_order), 0) + 10
            INTO v_next
            FROM fields
            WHERE field_order < 900000
              AND table_name = (v_current ->> 'table_name');
        ELSE
            EXECUTE format(
                'SELECT COALESCE(MAX(%I), 0) + 10 FROM %I.%I WHERE %I < 900000',
                v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col
            )
            INTO v_next;
        END IF;

        NEW := jsonb_populate_record(NEW, jsonb_build_object(v_col, v_next));
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION auto_set_order_value IS
'Generic BEFORE INSERT trigger: when the order column (TG_ARGV[0]) is unset (0/NULL), assigns MAX(order_column)+10 over rows below 900000 (or 10 for the first record). On the fields table the max is scoped per table_name. Installed per entity by handle_entity_order_column().';

REVOKE EXECUTE ON FUNCTION auto_set_order_value() FROM PUBLIC;

-- =====================================================
-- 3. Entity-level trigger: maintain the physical order column + its trigger
-- =====================================================
-- Fires AFTER the structural create/enable triggers (zz_ prefix) so the physical
-- table already exists. Idempotent and additive-safe.

CREATE OR REPLACE FUNCTION handle_entity_order_column()
RETURNS TRIGGER AS $$
DECLARE
    v_old          TEXT := '';
    v_new          TEXT := COALESCE(NEW.order_column, '');
    v_trigger_name TEXT := 'zz_auto_order_' || NEW.table_name;
BEGIN
    SET LOCAL client_min_messages = WARNING;

    IF TG_OP = 'UPDATE' THEN
        v_old := COALESCE(OLD.order_column, '');
    END IF;

    -- Only touch a physically existing table (unmanaged entities have none yet;
    -- the column is provisioned when the table is later created/enabled).
    IF to_regclass(format('public.%I', NEW.table_name)) IS NULL THEN
        RETURN NEW;
    END IF;

    -- Remove the previous order column + its trigger when the name changed or cleared.
    IF v_old <> '' AND v_old <> v_new THEN
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', v_trigger_name, NEW.table_name);
        EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS %I', NEW.table_name, v_old);
        RAISE NOTICE 'Dropped order column "%" on table "%"', v_old, NEW.table_name;
    END IF;

    IF v_new <> '' THEN
        -- Provision the order column (first time) and (re)install the auto-assign trigger.
        EXECUTE format(
            'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS %I INTEGER NOT NULL DEFAULT 0',
            NEW.table_name, v_new
        );
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', v_trigger_name, NEW.table_name);
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE INSERT ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION auto_set_order_value(%L)',
            v_trigger_name, NEW.table_name, v_new
        );
        RAISE NOTICE 'Provisioned order column "%" on table "%"', v_new, NEW.table_name;
    ELSE
        -- Cleared: ensure no stale auto-assign trigger remains.
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', v_trigger_name, NEW.table_name);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_entity_order_column IS
'AFTER INSERT/UPDATE trigger on entities: provisions or drops the physical order column named by entities.order_column and installs/removes the auto_set_order_value BEFORE INSERT trigger on the entity''s table.';

REVOKE EXECUTE ON FUNCTION handle_entity_order_column() FROM PUBLIC;

-- INSERT: only act when an order_column was supplied at creation time.
CREATE TRIGGER zz_entity_order_column_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    WHEN (COALESCE(NEW.order_column, '') <> '')
    EXECUTE FUNCTION handle_entity_order_column();

-- UPDATE: act when order_column changes, or when the table is enabled (managed F->T)
-- and an order_column is already declared (so the column is provisioned on enable).
CREATE TRIGGER zz_entity_order_column_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.order_column IS DISTINCT FROM NEW.order_column
       OR (OLD.managed = FALSE AND NEW.managed = TRUE AND COALESCE(NEW.order_column, '') <> ''))
    EXECUTE FUNCTION handle_entity_order_column();

-- =====================================================
-- 4. Remove the legacy fields-only auto_set_field_order() mechanism
-- =====================================================
-- Superseded by the generic order_column mechanism (the `fields` entity declares
-- order_column = 'field_order' below).

DROP TRIGGER IF EXISTS auto_set_field_order_trigger ON fields;
DROP FUNCTION IF EXISTS auto_set_field_order();

-- =====================================================
-- 5. Declare field_order as the order column for the fields entity
-- =====================================================
-- This UPDATE fires zz_entity_order_column_update_trigger, which (re)installs the
-- generic auto-assign trigger on the physical `fields` table. field_order already
-- exists, so the ADD COLUMN IF NOT EXISTS is a no-op.
--
-- On the fields table the auto-assign scopes MAX(field_order) per table_name, so a
-- new field lands at that entity's max (below the 900000 ceiling) + 10 — the pinned
-- created_at/updated_at audit columns at 999998/999999 never inflate the max.
UPDATE entities SET order_column = 'field_order' WHERE table_name = 'fields';
