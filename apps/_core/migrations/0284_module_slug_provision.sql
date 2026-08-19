-- =====================================================
-- MIGRATION: provision modules.module_slug, drop modules.alias
-- =====================================================
-- modules.alias was renamed to modules.module_slug (commit 6b3c56b) by editing
-- 0020/0040/0060/0080 in place. Databases provisioned before that edit still
-- carry the old shape:
--   * column  modules.alias  (TEXT NOT NULL DEFAULT '', no UNIQUE)
--   * no     modules.module_slug column / UNIQUE constraint
--   * dictionary row fields('modules','alias') "Alias"
--   * get_user_modules() emitting an "alias" key
-- while the tool contract (create_module/update_module require module_slug),
-- the SKILL docs ({ui_baseurl}/{module_slug}/{table_name}), the UI routing and
-- 0200/0220 all expect module_slug.
--
-- This migration brings existing databases in line. It is idempotent and a
-- no-op on fresh databases where 0020 already created module_slug:
--   1. physical column: RENAME alias -> module_slug (or merge + DROP alias when
--      both exist)
--   2. backfill empty slugs from module_name (same rule the old auto_set_module_slug
--      trigger used, made unique with an _<id> suffix on collision) so the UNIQUE
--      constraint can be added and every module is routable
--   3. DEFAULT '' NOT NULL UNIQUE + column comment (matches 0020)
--   4. dictionary: fields('modules','alias') -> ('modules','module_slug') with the
--      0060/0220 metadata (title/description/input_type)
--   5. get_user_modules(): re-issue the current 0080 body (to_jsonb(m)) so the
--      payload carries module_slug instead of alias
--
-- Ordering note: this file runs after 0200 (slug JsonLogic rule) and 0220
-- (module_slug field metadata, a no-op while the row is still named alias),
-- which is why step 4 sets the metadata itself.

DO $$
DECLARE
    v_has_alias_col   BOOLEAN;
    v_has_slug_col    BOOLEAN;
    v_has_alias_field BOOLEAN;
    v_has_slug_field  BOOLEAN;
    v_has_rename_trg  BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'modules' AND column_name = 'alias'
    ) INTO v_has_alias_col;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'modules' AND column_name = 'module_slug'
    ) INTO v_has_slug_col;

    SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'modules' AND field_name = 'alias')
      INTO v_has_alias_field;
    SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'modules' AND field_name = 'module_slug')
      INTO v_has_slug_field;

    -- =====================================================
    -- STEP 1: physical column
    -- =====================================================
    IF v_has_alias_col AND NOT v_has_slug_col THEN
        ALTER TABLE modules RENAME COLUMN alias TO module_slug;
        RAISE NOTICE 'modules: renamed column alias -> module_slug';
        v_has_slug_col  := TRUE;
        v_has_alias_col := FALSE;
    ELSIF v_has_alias_col AND v_has_slug_col THEN
        -- Both present (partially migrated database): keep module_slug, take the
        -- alias value only where module_slug is still empty, then drop alias.
        UPDATE modules SET module_slug = alias WHERE module_slug = '' AND alias <> '';
        ALTER TABLE modules DROP COLUMN alias;
        RAISE NOTICE 'modules: merged alias into module_slug and dropped alias';
        v_has_alias_col := FALSE;
    END IF;

    -- =====================================================
    -- STEP 2: backfill empty slugs so UNIQUE can be enforced
    -- =====================================================
    -- Base slug: lowercase module_name with every non-alphanumeric run collapsed
    -- to '_' and leading/trailing '_' trimmed (the old auto_set_module_slug rule).
    -- Collisions (with an existing slug or another backfilled row) get '_<id>'.
    -- Result always matches the 0200 rule ^[a-z0-9][a-z0-9_-]*$.
    WITH candidates AS (
        SELECT id,
               trim(both '_' from lower(regexp_replace(module_name, '[^a-zA-Z0-9]+', '_', 'g'))) AS base
        FROM modules
        WHERE module_slug = ''
    ),
    resolved AS (
        SELECT c.id,
               CASE
                   WHEN c.base = '' THEN 'module_' || c.id
                   WHEN EXISTS (SELECT 1 FROM modules m2 WHERE m2.module_slug = c.base AND m2.id <> c.id)
                     OR (SELECT count(*) FROM candidates c2 WHERE c2.base = c.base) > 1
                        THEN c.base || '_' || c.id
                   ELSE c.base
               END AS slug
        FROM candidates c
    )
    UPDATE modules m
       SET module_slug = r.slug
      FROM resolved r
     WHERE m.id = r.id;

    -- =====================================================
    -- STEP 3: column contract (matches 0020: TEXT DEFAULT '' NOT NULL UNIQUE)
    -- =====================================================
    ALTER TABLE modules ALTER COLUMN module_slug SET DEFAULT '';
    UPDATE modules SET module_slug = '' WHERE module_slug IS NULL;
    ALTER TABLE modules ALTER COLUMN module_slug SET NOT NULL;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = 'modules'
          AND t.relnamespace = 'public'::regnamespace
          AND c.contype = 'u'
          AND c.conkey = ARRAY[(
              SELECT attnum FROM pg_attribute
              WHERE attrelid = t.oid AND attname = 'module_slug'
          )]
    ) THEN
        ALTER TABLE modules ADD CONSTRAINT modules_module_slug_key UNIQUE (module_slug);
        RAISE NOTICE 'modules: added UNIQUE (module_slug)';
    END IF;

    COMMENT ON COLUMN modules.module_slug IS 'URL-safe unique identifier for module';

    -- =====================================================
    -- STEP 4: dictionary row
    -- =====================================================
    IF v_has_alias_field AND NOT v_has_slug_field THEN
        -- Renaming fields.field_name fires validate_field_rename_and_format(),
        -- which would try to ALTER TABLE ... RENAME COLUMN alias -> module_slug on
        -- a managed entity. The physical rename already happened in step 1, so
        -- suspend that trigger for this metadata-only rename.
        SELECT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgrelid = 'public.fields'::regclass
              AND tgname = 'validate_field_rename_and_format_trigger'
        ) INTO v_has_rename_trg;

        IF v_has_rename_trg THEN
            ALTER TABLE fields DISABLE TRIGGER validate_field_rename_and_format_trigger;
        END IF;

        UPDATE fields
           SET field_name  = 'module_slug',
               title       = 'Module Slug',
               description = 'URL-safe unique identifier for module',
               input_type  = 'required'
         WHERE table_name = 'modules'
           AND field_name = 'alias';

        IF v_has_rename_trg THEN
            ALTER TABLE fields ENABLE TRIGGER validate_field_rename_and_format_trigger;
        END IF;

        RAISE NOTICE 'fields: renamed modules.alias -> modules.module_slug';

    ELSIF v_has_alias_field AND v_has_slug_field THEN
        -- delete_dd_field() runs ALTER TABLE ... DROP COLUMN IF EXISTS alias for a
        -- managed entity; the column is already gone after step 1, so this is safe.
        DELETE FROM fields WHERE table_name = 'modules' AND field_name = 'alias';
        RAISE NOTICE 'fields: dropped stale modules.alias row';

    ELSIF NOT v_has_slug_field THEN
        -- No dictionary row at all: seed it as 0060 does. add_dd_field() uses
        -- ADD COLUMN IF NOT EXISTS, so the existing physical column is kept.
        INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order,
                            input_type, width, ctype, searchable, reference_table, reference_delete_mode)
        VALUES ('modules', 'module_slug', 'Module Slug', 'URL-safe unique identifier for module',
                'text', FALSE, 38, 'required', 'default', 'core', FALSE, '', '');
        RAISE NOTICE 'fields: seeded modules.module_slug row';
    END IF;

    -- Make sure the metadata matches 0060/0220 even if the row already existed.
    UPDATE fields
       SET title       = 'Module Slug',
           description = 'URL-safe unique identifier for module',
           input_type  = 'required'
     WHERE table_name = 'modules'
       AND field_name = 'module_slug'
       AND (title <> 'Module Slug'
            OR description IS DISTINCT FROM 'URL-safe unique identifier for module'
            OR input_type <> 'required');
END;
$$;

-- =====================================================
-- STEP 5: get_user_modules() (current 0080 body)
-- =====================================================
-- Older databases still run the pre-rename body that builds the object by hand
-- and emits "alias"; to_jsonb(m) returns every current column, incl. module_slug.

CREATE OR REPLACE FUNCTION public.get_user_modules()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE(
        (SELECT jsonb_agg(to_jsonb(m) ORDER BY m.module_name)
        FROM modules m
        WHERE rbac.has_any_permission('admin', m.view_permission)),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION public.get_user_modules IS
'Returns modules array filtered by RLS. Used internally by get_userinfo().';

REVOKE EXECUTE ON FUNCTION public.get_user_modules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_modules() TO semantius_user;
