-- =====================================================
-- MIGRATION: entity defaults
-- =====================================================
-- What an entity gets for a field the caller leaves blank: singular from
-- table_name, singular_label from singular, and label_column_label (the label
-- field's title) from label_column. A value the caller supplies is kept.
-- plural is set by auto_set_plural (0140_dd_schema.sql).

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
-- FUNCTION: dd_label_field_title
-- =====================================================
-- The label field's default title: label_column in words, without a leading
-- entity name. On companies, company_name is "Name", for the same reason a
-- phone field there is "Phone" and not "Company Phone". A column ending in
-- _number, _no, _id or _code keeps the entity name, because "Number" or "Id"
-- alone says nothing. The plural forms are tried too: singular is derived
-- naively (addresses gives addresse) or supplied as free text.
CREATE OR REPLACE FUNCTION public.dd_label_field_title(
    p_label_column TEXT,
    p_singular     TEXT,
    p_table_name   TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
    v_prefix TEXT;
BEGIN
    IF p_label_column !~ '_(number|no|id|code)$' THEN
        SELECT p INTO v_prefix
          FROM unnest(ARRAY[p_table_name,
                            lower(p_singular),
                            regexp_replace(p_table_name, 'ies$', 'y'),
                            regexp_replace(p_table_name, 'es$', ''),
                            regexp_replace(p_table_name, 's$', '')]) AS p
         WHERE p <> '' AND starts_with(p_label_column, p || '_')
         ORDER BY length(p) DESC
         LIMIT 1;
    END IF;

    RETURN public.snake_to_label(
        CASE WHEN v_prefix IS NULL THEN p_label_column
             ELSE substr(p_label_column, length(v_prefix) + 2)
        END);
END;
$$;

COMMENT ON FUNCTION public.dd_label_field_title(TEXT, TEXT, TEXT) IS
'Default title of an entity''s label field: label_column in words without a leading entity singular or plural (company_name on companies -> Name), except for a column ending in _number, _no, _id or _code (offer_number -> Offer Number).';

REVOKE EXECUTE ON FUNCTION public.dd_label_field_title(TEXT, TEXT, TEXT) FROM PUBLIC;
-- set_entity_defaults runs as the caller.
GRANT EXECUTE ON FUNCTION public.dd_label_field_title(TEXT, TEXT, TEXT) TO semantius_user;

-- =====================================================
-- TRIGGER FUNCTION: set_entity_defaults
-- =====================================================
-- BEFORE INSERT, so create_dd_table (AFTER INSERT) creates the label field
-- with its final title and no second entities UPDATE is needed.

CREATE OR REPLACE FUNCTION public.set_entity_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_title TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Naive de-pluralize: regular plurals and '...ies'; '...ss' and
        -- irregulars stay as they are.
        IF NEW.singular IS NULL OR NEW.singular = '' THEN
            NEW.singular := CASE
                WHEN NEW.table_name ~ 'ies$'   THEN regexp_replace(NEW.table_name, 'ies$', 'y')
                WHEN NEW.table_name ~ '[^s]s$' THEN left(NEW.table_name, length(NEW.table_name) - 1)
                ELSE NEW.table_name
            END;
        END IF;

        IF NEW.singular_label IS NULL OR NEW.singular_label = '' THEN
            NEW.singular_label := public.snake_to_label(NEW.singular);
        END IF;
    END IF;

    -- An is_a or has_a entity has no label field of its own: check_entity_family
    -- gives it its root's title.
    IF NEW.id_type IN ('is_a', 'has_a') THEN
        RETURN NEW;
    END IF;

    -- A label_column pointed at another field takes that field's title, unless
    -- the same update gives one. A label field rename finds no row under the
    -- new name yet, so the title stays.
    IF TG_OP = 'UPDATE'
       AND NEW.label_column IS DISTINCT FROM OLD.label_column
       AND NEW.label_column_label IS NOT DISTINCT FROM OLD.label_column_label THEN
        SELECT f.title INTO v_title
          FROM fields f
         WHERE f.table_name = OLD.table_name
           AND f.field_name = NEW.label_column;
        IF FOUND THEN
            NEW.label_column_label := v_title;
        END IF;
    END IF;

    IF NEW.label_column_label IS NULL OR NEW.label_column_label = '' THEN
        NEW.label_column_label := public.dd_label_field_title(
            NEW.label_column, NEW.singular, NEW.table_name);
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_entity_defaults() IS
'Trigger function that fills singular (de-pluralized table_name) and singular_label (snake_to_label of singular) on insert when left blank, and label_column_label (dd_label_field_title) on insert or update when left blank. A changed label_column takes the title of the field it now names.';

REVOKE EXECUTE ON FUNCTION public.set_entity_defaults() FROM PUBLIC;

DROP TRIGGER IF EXISTS set_entity_defaults_trigger ON entities;
CREATE OR REPLACE TRIGGER set_entity_defaults_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION public.set_entity_defaults();

COMMENT ON TRIGGER set_entity_defaults_trigger ON entities IS
'Fills singular, singular_label and label_column_label when the caller leaves them blank.';
