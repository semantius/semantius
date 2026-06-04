-- =====================================================
-- MIGRATION: entity insert defaults (singular, singular_label)
-- =====================================================
-- When a row is inserted into entities, create_dd_table() (0070) seeds the
-- name/label field's title from entities.singular_label. Previously, if the
-- caller did not supply singular/singular_label they stayed '' (the column
-- default), so the name field was created with a blank title.
--
-- This migration fills sensible defaults BEFORE INSERT so they flow into the
-- field title automatically (create_dd_table runs AFTER INSERT and reads the
-- already-populated NEW.singular_label):
--
--   * singular        -- derived from table_name by a naive de-pluralize
--                        ('tenants' -> 'tenant', 'cities' -> 'city')
--   * singular_label  -- derived from label_column via snake_to_label()
--                        ('tenant_name' -> 'Tenant Name', 'label' -> 'Label')
--
-- Values supplied by the caller are always preserved verbatim -- defaults are
-- only applied when the column is left blank. plural is handled separately by
-- the existing auto_set_plural trigger (0060) and is not touched here.
--
-- Additive only (no objects removed), so a single forward migration covers both
-- fresh and existing/production databases.

-- =====================================================
-- FUNCTION: snake_to_label
-- =====================================================
-- Convert a snake_case identifier into a human-readable Title Case label.
--   'tenant_name'     -> 'Tenant Name'
--   'city'            -> 'City'
--   'address_line_1'  -> 'Address Line 1'
-- Collapses runs of underscores and trims leading/trailing ones.

CREATE OR REPLACE FUNCTION public.snake_to_label(p_input TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT initcap(trim(regexp_replace(coalesce(p_input, ''), '_+', ' ', 'g')));
$$;

COMMENT ON FUNCTION public.snake_to_label(TEXT) IS
'Converts a snake_case identifier to a Title Case label (e.g. tenant_name -> Tenant Name).';

REVOKE EXECUTE ON FUNCTION public.snake_to_label(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.snake_to_label(TEXT) TO semantius_user;

-- =====================================================
-- TRIGGER FUNCTION: set_entity_defaults
-- =====================================================
-- Fills singular and singular_label from table_name / label_column when the
-- caller leaves them blank. Runs BEFORE INSERT so create_dd_table() (AFTER
-- INSERT) sees the populated values and seeds the name field title correctly.

CREATE OR REPLACE FUNCTION public.set_entity_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    -- Derive singular from table_name (naive de-pluralize) when not provided.
    -- Handles regular plurals and '...ies'; leaves '...ss' and irregulars alone.
    IF NEW.singular IS NULL OR NEW.singular = '' THEN
        NEW.singular := CASE
            WHEN NEW.table_name ~ 'ies$'   THEN regexp_replace(NEW.table_name, 'ies$', 'y')
            WHEN NEW.table_name ~ '[^s]s$' THEN left(NEW.table_name, length(NEW.table_name) - 1)
            ELSE NEW.table_name
        END;
    END IF;

    -- Derive singular_label from label_column when not provided.
    IF NEW.singular_label IS NULL OR NEW.singular_label = '' THEN
        NEW.singular_label := public.snake_to_label(NEW.label_column);
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_entity_defaults() IS
'Trigger function that derives singular (de-pluralized table_name) and singular_label (snake_to_label of label_column) when left blank on insert.';

REVOKE EXECUTE ON FUNCTION public.set_entity_defaults() FROM PUBLIC;

DROP TRIGGER IF EXISTS set_entity_defaults_trigger ON entities;
CREATE TRIGGER set_entity_defaults_trigger
    BEFORE INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION public.set_entity_defaults();

COMMENT ON TRIGGER set_entity_defaults_trigger ON entities IS
'Derives singular and singular_label on insert when the caller leaves them blank.';
