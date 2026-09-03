-- =====================================================
-- MANAGED ENABLE SUPPORT
-- =====================================================
-- Adds support for:
--   1. Toggling entities.managed from FALSE to TRUE:
--      Creates the physical table (if missing) with full DDL setup
--      (RLS policies, updated_at trigger), then adds any missing
--      columns for existing field records.
--   2. Updating a field in a managed table when the column does not
--      yet exist in the database: column is created on-the-fly.

-- =====================================================
-- HELPER FUNCTION: apply_field_ddl
-- =====================================================
-- Applies all DDL for a single field record to the physical table.
-- Uses IF NOT EXISTS / exception guards so it is safe to call on
-- columns that already exist (idempotent).
-- Called by:
--   • enable_dd_table() trigger  – for each existing field when
--     managed is first enabled
--   • update_dd_field() trigger  – when the column is found to be
--     missing from an otherwise-managed table

CREATE OR REPLACE FUNCTION apply_field_ddl(p_field fields)
RETURNS VOID AS $$
DECLARE
    v_alter_sql      TEXT;
    v_nullable_clause TEXT;
    v_default_clause  TEXT;
    v_data_type       TEXT;
    v_ref_id_column   TEXT;
    v_fk_name         TEXT;
    v_idx_name        TEXT;
    v_on_delete       TEXT;
BEGIN
    SET LOCAL client_min_messages = WARNING;

    -- Convert format to PostgreSQL data type
    v_data_type := format_to_data_type(p_field.format, p_field."precision");

    -- Build nullable clause
    IF is_nullable(p_field.format) THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;

    -- Build default clause with sensible fallbacks for NOT NULL columns
    DECLARE
        v_resolved_default TEXT;
    BEGIN
        IF p_field.format = 'enum' THEN
            v_resolved_default := effective_enum_default(p_field.default_value, p_field.input_type, p_field.enum_values);
        ELSE
            v_resolved_default := p_field.default_value;
        END IF;

        IF v_resolved_default IS NOT NULL AND trim(v_resolved_default) != '' THEN
            v_default_clause := format('DEFAULT %s', quote_default_value(v_resolved_default, v_data_type));
        ELSIF NOT is_nullable(p_field.format) THEN
            IF v_data_type IN ('JSONB', 'JSON') THEN
                IF p_field.format = 'array' THEN
                    v_default_clause := 'DEFAULT ''[]''::jsonb';
                ELSE
                    v_default_clause := 'DEFAULT ''{}''::jsonb';
                END IF;
            ELSE
                CASE
                    WHEN v_data_type = 'TEXT'                                THEN v_default_clause := 'DEFAULT ''''';
                    WHEN v_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT')    THEN v_default_clause := 'DEFAULT 0';
                    WHEN v_data_type IN ('REAL', 'DOUBLE PRECISION')
                         OR v_data_type LIKE 'NUMERIC%'
                         OR v_data_type LIKE 'DECIMAL%'                       THEN v_default_clause := 'DEFAULT 0.0';
                    WHEN v_data_type = 'BOOLEAN'                              THEN v_default_clause := 'DEFAULT FALSE';
                    WHEN v_data_type IN ('TIMESTAMP', 'TIMESTAMPTZ')          THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                    WHEN v_data_type = 'DATE'                                 THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                    ELSE v_default_clause := '';
                END CASE;
            END IF;
        ELSE
            v_default_clause := '';
        END IF;
    END;

    -- Add column (IF NOT EXISTS makes this idempotent)
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        p_field.table_name, p_field.field_name,
        v_data_type, v_nullable_clause, v_default_clause
    );
    EXECUTE v_alter_sql;

    -- Add / refresh column comment: title/format summary + description [+ enum values]
    DECLARE
        v_comment TEXT := dd_field_comment(p_field.title, p_field.format, p_field.description, p_field.enum_values);
    BEGIN
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L',
                p_field.table_name, p_field.field_name, v_comment);
        END IF;
    END;

    -- Foreign key (reference / parent format)
    IF p_field.format IN ('reference', 'parent')
       AND p_field.reference_table IS NOT NULL
       AND p_field.reference_table != ''
    THEN
        SELECT id_column INTO v_ref_id_column
        FROM entities WHERE table_name = p_field.reference_table;

        IF v_ref_id_column IS NOT NULL THEN
            IF p_field.reference_delete_mode = 'clear' THEN
                v_on_delete := 'SET NULL';
            ELSIF p_field.reference_delete_mode = 'cascade' THEN
                v_on_delete := 'CASCADE';
            ELSE
                v_on_delete := 'RESTRICT';
            END IF;

            v_fk_name  := format('%s_%s_fkey', p_field.table_name, p_field.field_name);
            v_idx_name := format('idx_%s_%s',  p_field.table_name, p_field.field_name);

            BEGIN
                EXECUTE format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
                    p_field.table_name, v_fk_name, p_field.field_name,
                    p_field.reference_table, v_ref_id_column, v_on_delete
                );
            EXCEPTION WHEN duplicate_object THEN
                RAISE NOTICE 'FK "%" already exists on "%.%", skipping',
                    v_fk_name, p_field.table_name, p_field.field_name;
            END;

            EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                v_idx_name, p_field.table_name, p_field.field_name);
        END IF;
    END IF;

    -- Enum CHECK constraint
    IF p_field.format = 'enum'
       AND p_field.enum_values IS NOT NULL
       AND jsonb_typeof(p_field.enum_values) = 'array'
       AND jsonb_array_length(p_field.enum_values) > 0
    THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum  JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', p_field.table_name, p_field.field_name);
            v_effective_enum := effective_enum_values(p_field.input_type, p_field.enum_values);
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(v_effective_enum) AS value
            );
            BEGIN
                EXECUTE format(
                    'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                    p_field.table_name, v_check_name, p_field.field_name, v_enum_values_sql
                );
            EXCEPTION WHEN duplicate_object THEN
                RAISE NOTICE 'CHECK constraint "%" already exists, skipping', v_check_name;
            END;
        END;
    END IF;

    -- Partial unique index
    IF p_field.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause    TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', p_field.table_name, p_field.field_name);
            IF format_to_json_type(p_field.format)::text = '"string"' THEN
                v_where_clause := format('%I IS NOT NULL AND %I != ''''',
                    p_field.field_name, p_field.field_name);
            ELSE
                v_where_clause := format('%I IS NOT NULL', p_field.field_name);
            END IF;
            EXECUTE format(
                'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                v_unique_idx_name, p_field.table_name, p_field.field_name, v_where_clause
            );
        END;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION apply_field_ddl(fields) IS
'Idempotent helper: applies ADD COLUMN + FK + CHECK + unique-index DDL for a
single field record.  Called by enable_dd_table() and update_dd_field() to
create columns that were defined while managed=false.';

-- =====================================================
-- TRIGGER FUNCTION: ENABLE TABLE WHEN managed F→T
-- =====================================================

CREATE OR REPLACE FUNCTION enable_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_field      fields%ROWTYPE;
BEGIN
    -- Guard: only proceed when managed transitions FALSE → TRUE
    IF NOT (OLD.managed = FALSE AND NEW.managed = TRUE) THEN
        RETURN NEW;
    END IF;

    SET LOCAL client_min_messages = WARNING;

    -- ── Create the physical table if it does not yet exist ──────────────
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = NEW.table_name
    ) THEN
        v_create_sql := format(
            'CREATE TABLE IF NOT EXISTS public.%I (
                %I SERIAL PRIMARY KEY,
                %I TEXT NOT NULL DEFAULT '''',
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            NEW.table_name, NEW.id_column, NEW.label_column
        );
        EXECUTE v_create_sql;

        -- Table comment: plural label summary + optional description
        DECLARE
            v_comment TEXT := dd_table_comment(NEW.plural_label, NEW.description);
        BEGIN
            IF v_comment IS NOT NULL THEN
                EXECUTE format('COMMENT ON TABLE %I IS %L', NEW.table_name, v_comment);
            END IF;
        END;

        -- updated_at maintenance trigger
        EXECUTE format(
            'CREATE TRIGGER update_%I_updated_at
                BEFORE UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION common.update_updated_at_column()',
            NEW.table_name, NEW.table_name
        );

        -- Row Level Security. Predicates use the (SELECT rbac.has_permission(...)) InitPlan form,
        -- see the note in create_dd_table (P1); test 0445 fails on the bare per-row form.
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', NEW.table_name);

        EXECUTE format(
            'CREATE POLICY %I_select_policy ON %I
                FOR SELECT TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))',
            NEW.table_name, NEW.table_name, NEW.view_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_insert_policy ON %I
                FOR INSERT TO semantius_user
                WITH CHECK ((SELECT rbac.has_permission(%L)))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_update_policy ON %I
                FOR UPDATE TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))
                WITH CHECK ((SELECT rbac.has_permission(%L)))',
            NEW.table_name, NEW.table_name, NEW.edit_permission, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_delete_policy ON %I
                FOR DELETE TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );

        RAISE NOTICE 'Created table "%" (managed changed to true)', NEW.table_name;
    END IF;

    -- ── Insert core field records if they were never created ─────────────
    -- create_dd_table inserts these when managed=true on INSERT, but when
    -- an entity was created with managed=false those records do not exist.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, 10, 'readonly', 'default', 'id', FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.id_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, 20, 'required', 'default', 'label', TRUE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', 'audit', FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = 'created_at');

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', 'audit', FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = 'updated_at');

    -- ── Add any missing columns for existing field records ───────────────
    FOR v_field IN
        SELECT * FROM fields WHERE table_name = NEW.table_name
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name    = NEW.table_name
              AND column_name   = v_field.field_name
        ) THEN
            PERFORM apply_field_ddl(v_field);
            RAISE NOTICE 'Added missing column "%" to table "%" (managed changed to true)',
                v_field.field_name, NEW.table_name;
        END IF;
    END LOOP;

    -- Update searchable flag in case any searchable fields exist
    UPDATE entities
    SET searchable = EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = NEW.table_name AND searchable = TRUE
    )
    WHERE table_name = NEW.table_name;

    -- Build the canonical-predicate RLS policies (select_rule, or the permission-only default
    -- when no rule is set) DETERMINISTICALLY here, rather than relying on the separate
    -- manage_select_rule_policy AFTER-trigger firing in the right alphabetical order (F3). The
    -- table-creation block above installs permission-only policies; this replaces the SELECT /
    -- UPDATE / DELETE policies with the per-row rule when entities.select_rule is non-empty, so
    -- the F→T toggle can never leave a select_rule-bearing entity gated by view_permission alone.
    -- Idempotent: build_select_rule_policy drops + recreates, so the redundant manage_*-trigger
    -- call is harmless.
    PERFORM build_select_rule_policy(NEW.table_name);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION enable_dd_table IS
'AFTER UPDATE trigger on entities: when managed changes from FALSE to TRUE,
creates the physical table (with RLS policies and updated_at trigger) if it does
not already exist, then adds any columns that were defined as field records while
the table was unmanaged. Finally calls build_select_rule_policy() so the canonical
select_rule predicate is installed deterministically, without depending on the
firing order of the manage_select_rule_policy AFTER-trigger (F3).';

-- Apply trigger AFTER UPDATE on entities (only when managed changes F→T)
CREATE TRIGGER enable_table_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.managed = FALSE AND NEW.managed = TRUE)
    EXECUTE FUNCTION enable_dd_table();

COMMENT ON TRIGGER enable_table_trigger ON entities IS
'Creates the physical table and adds missing columns when managed changes from false to true.';

-- =====================================================
-- UPDATE update_dd_field: create missing column first
-- =====================================================
-- When a field belonging to a managed table is updated but the physical
-- column does not yet exist, create it via apply_field_ddl() before
-- attempting any ALTER operations.

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql      TEXT;
    v_old_data_type  TEXT;
    v_new_data_type  TEXT;
    v_is_managed     BOOLEAN;
    v_ref_id_column  TEXT;
    v_fk_name        TEXT;
    v_idx_name       TEXT;
    v_on_delete      TEXT;
    v_comment        TEXT;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        -- Allow only when this is a cascade triggered by rename_dd_table()
        IF current_setting('dd.table_rename', TRUE) <> OLD.table_name || ':' || NEW.table_name THEN
            RAISE EXCEPTION 'Cannot change table_name of a field';
        END IF;
        -- Cascade rename: metadata has been updated; no DDL needed here
        RETURN NEW;
    END IF;

    -- field_name was renamed by validate_field_rename_and_format() BEFORE trigger;
    -- no exception here — just continue with the rest of the DDL using NEW.field_name.

    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field';
    END IF;

    -- Prevent changing structural attributes of core fields (a non-empty ctype marks a
    -- DD-managed core column); ctype itself is immutable + privilege-locked (fields_ctype_lock).
    IF coalesce(OLD.ctype, '') <> '' THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;
    END IF;

    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Keep the column comment in sync even if not managed, but only when the
        -- physical column actually exists (an unmanaged entity may be metadata-only
        -- with no physical table/column to comment on).
        IF (OLD.title IS DISTINCT FROM NEW.title
            OR OLD.format IS DISTINCT FROM NEW.format
            OR OLD.description IS DISTINCT FROM NEW.description
            OR OLD.enum_values IS DISTINCT FROM NEW.enum_values)
           AND EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name   = NEW.table_name
                 AND column_name  = NEW.field_name
           ) THEN
            v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
            IF v_comment IS NOT NULL THEN
                EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
            ELSE
                EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', NEW.table_name, NEW.field_name);
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- If the physical column is missing from a managed table (e.g. it was defined
    -- while managed=false), create it now with the new field values and return.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = NEW.table_name
          AND column_name  = NEW.field_name
    ) THEN
        PERFORM apply_field_ddl(NEW);
        RAISE NOTICE 'Created missing column "%.%" in managed table', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- Keep column comment in sync when title/format/description/enum values change
    IF OLD.title IS DISTINCT FROM NEW.title
       OR OLD.format IS DISTINCT FROM NEW.format
       OR OLD.description IS DISTINCT FROM NEW.description
       OR OLD.enum_values IS DISTINCT FROM NEW.enum_values THEN
        v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', NEW.table_name, NEW.field_name, v_comment);
        ELSE
            EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', NEW.table_name, NEW.field_name);
        END IF;
    END IF;

    -- Handle format change
    IF OLD.format <> NEW.format THEN
        v_old_data_type := format_to_data_type(OLD.format, OLD."precision");
        v_new_data_type := format_to_data_type(NEW.format, NEW."precision");

        IF v_old_data_type <> v_new_data_type THEN
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %.',
                NEW.field_name, OLD.format, NEW.format, v_old_data_type, v_new_data_type;
        END IF;

        RAISE NOTICE 'Changed format of column "%" from "%" to "%" in table "%" (data type unchanged: %)',
            NEW.field_name, OLD.format, NEW.format, NEW.table_name, v_new_data_type;
    END IF;

    -- Allow updating nullable constraint (derived from format)
    IF is_nullable(OLD.format) <> is_nullable(NEW.format) THEN
        IF is_nullable(NEW.format) THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                NEW.table_name, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                NEW.table_name, NEW.field_name
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
            NEW.field_name, is_nullable(NEW.format), NEW.table_name;
    END IF;

    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name, NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format, NEW."precision"))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;

    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name  := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s',  NEW.table_name, NEW.field_name);

        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format)
        THEN
            -- Drop existing FK constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name, v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;

            -- Add new FK constraint
            IF NEW.format IN ('reference', 'parent')
               AND NEW.reference_table IS NOT NULL
               AND NEW.reference_table != ''
            THEN
                SELECT id_column INTO v_ref_id_column
                FROM entities WHERE table_name = NEW.reference_table;

                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;

                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSIF NEW.reference_delete_mode = 'cascade' THEN
                    v_on_delete := 'CASCADE';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;

                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
                    NEW.table_name, v_fk_name, NEW.field_name,
                    NEW.reference_table, v_ref_id_column, v_on_delete
                );
                EXECUTE v_alter_sql;

                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name, NEW.table_name, NEW.field_name
                );
                EXECUTE v_alter_sql;

                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name,
                    NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                EXECUTE format('DROP INDEX IF EXISTS %I', v_idx_name);
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;

    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum  JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);

            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values)
               OR (OLD.format <> NEW.format)
               OR (OLD.input_type IS DISTINCT FROM NEW.input_type) THEN
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name, v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                IF NEW.format = 'enum'
                   AND NEW.enum_values IS NOT NULL
                   AND jsonb_typeof(NEW.enum_values) = 'array'
                   AND jsonb_array_length(NEW.enum_values) > 0
                THEN
                    v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(v_effective_enum) AS value
                    );
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name, v_check_name, NEW.field_name, v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;
                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;

    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause    TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''',
                        NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name, NEW.table_name, NEW.field_name, v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS
'Trigger function that updates column properties when a field is updated.
table_name changes are allowed only as part of a cascade from rename_dd_table().
field_name renames are handled by the validate_field_rename_and_format BEFORE trigger.
format changes that alter the underlying data type are rejected by the BEFORE trigger.
When the physical column is missing from a managed table (e.g. defined while managed=false),
the column is created via apply_field_ddl() and the function returns early.';

REVOKE EXECUTE ON FUNCTION apply_field_ddl(fields) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enable_dd_table() FROM PUBLIC;

-- =====================================================
-- COMPOSED RECORD LABELS  (label_parent + _label / <fk>_label)
-- =====================================================
-- A record's composed label answers "which record is this?" by folding the entity's local label
-- with its parent chain. Labels are DERIVED AT READ TIME (never stored) as PostgREST computed
-- columns: a function whose single argument is the table's row type is exposed as a selectable
-- column of that table (e.g. select=id,_label). The functions are SECURITY INVOKER, so each parent
-- read inside them is gated by that parent's own RLS policy — a parent the caller cannot read
-- degrades to the local label, it never leaks (viewer-relative labels).
--
-- Two derived columns per entity:
--   _label          composed label of the row (root: local; relational: parent._label › local;
--                   junction: legA._label › legB._label …)
--   <fk>_label      for every reference/parent field: the referenced record's composed label
--
-- The fold uses concat_ws(sep, …) (skips NULL arms, so no dangling separator) over scalar
-- subqueries (NULL when the FK is null / deleted / hidden) and NULLIF(local,'') (empty local
-- contributes nothing) — this is the required degrade-to-local behavior.
--
-- Termination is a VALIDATION guarantee, not a runtime guard: self-referential spines are rejected
-- and the label_parent graph is kept acyclic (validate_label_parent), so the generated functions
-- can recurse plainly and always terminate.

-- Shared predicate: a field that carries a foreign key (and thus gets a <fk>_label companion).
-- Used by BOTH the generator and get_schema() so the advertised set never drifts from the built set.
CREATE OR REPLACE FUNCTION dd_is_fk_format(p_format TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
SET search_path = public
AS $$ SELECT p_format IN ('reference', 'parent') $$;

COMMENT ON FUNCTION dd_is_fk_format(TEXT) IS
'TRUE when a field format denotes a foreign-key relationship (''reference'' or ''parent'').';

-- Junction recognition (§6): entity_type='junction' is authoritative; until it is stamped, the
-- fallback heuristic recognises a pure pairing table — ≥2 parent legs and every non-leg field is an
-- id/label/audit column (recognised audit names + ctype='audit'). A status/rating/note payload
-- field disqualifies it (so an interview scorecard is NOT a junction).
CREATE OR REPLACE FUNCTION dd_is_junction(p_table_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM entities WHERE table_name = p_table_name) THEN FALSE
    WHEN (SELECT entity_type FROM entities WHERE table_name = p_table_name) = 'junction' THEN TRUE
    ELSE COALESCE((
      SELECT count(*) FILTER (WHERE f.format = 'parent') >= 2
         AND count(*) FILTER (WHERE NOT (
                  f.format = 'parent'
               OR f.field_name = e.id_column
               OR f.field_name = e.label_column
               OR COALESCE(f.ctype, '') = 'audit'
               OR f.field_name IN ('created_at','updated_at','created_by','updated_by',
                                   'assigned_at','assigned_by','granted_at','granted_by')
             )) = 0
      FROM fields f
      CROSS JOIN entities e
      WHERE f.table_name = p_table_name AND e.table_name = p_table_name
    ), FALSE)
  END
$$;

COMMENT ON FUNCTION dd_is_junction(TEXT) IS
'TRUE when an entity is a pure M:N junction/pairing table: entity_type=''junction'' is authoritative, otherwise a heuristic requiring ≥2 parent legs and no payload fields (only id/label/audit columns besides the legs).';

-- The committed identity-spine parent of an entity (reference_table of its label_parent field),
-- or '' when it has no spine. Used by validate_label_parent() to walk the chain for cycles.
CREATE OR REPLACE FUNCTION dd_spine_parent(p_table_name TEXT)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT f.reference_table
    FROM entities e
    JOIN fields f ON f.table_name = e.table_name AND f.field_name = NULLIF(e.label_parent, '')
    WHERE e.table_name = p_table_name
  ), '')
$$;

COMMENT ON FUNCTION dd_spine_parent(TEXT) IS
'Returns the identity-spine parent of an entity (the reference_table of its label_parent field), or '''' when it has no spine. Used by validate_label_parent to walk the chain for cycles.';

-- (Re)generate _label and every <fk>_label for one entity from current metadata + physical columns.
-- Defensive: only references columns/tables that physically exist, so it produces valid SQL for any
-- entity shape (core meta-tables, composite-PK junctions, dangling references). check_function_bodies
-- is disabled around the CREATEs so order-independent / mutually-referential generation never fails;
-- the bodies are validated at first call instead.
CREATE OR REPLACE FUNCTION rebuild_entity_label_functions(p_table_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_id_col      TEXT;
    v_label_col   TEXT;
    v_spine       TEXT;
    v_rowtype     TEXT;
    v_local       TEXT;
    v_body        TEXT;
    v_is_junction BOOLEAN;
    v_saved       TEXT;
    v_legs        TEXT[];
    v_parent_id   TEXT;
    v_spine_ref   TEXT;
    v_spine_fmt   TEXT;
    v_sql         TEXT;
    r             RECORD;
BEGIN
    -- Skip when entity metadata or the physical table is absent (drops / cascades / unmanaged).
    IF NOT EXISTS (SELECT 1 FROM entities WHERE table_name = p_table_name) THEN
        RETURN;
    END IF;
    v_rowtype := format('public.%I', p_table_name);
    IF to_regclass(v_rowtype) IS NULL THEN
        RETURN;
    END IF;

    SELECT id_column, label_column, NULLIF(label_parent, '')
      INTO v_id_col, v_label_col, v_spine
      FROM entities WHERE table_name = p_table_name;

    v_saved := current_setting('check_function_bodies');
    PERFORM set_config('check_function_bodies', 'off', true);

    -- Drop every label function currently bound to this row type (clears stale companions after a
    -- field rename / drop / format change before recreating the live set).
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND (p.proname = '_label' OR p.proname LIKE '%\_label')
          AND p.pronargs = 1
          AND p.proargtypes[0] = to_regtype(v_rowtype)::oid
    LOOP
        -- Build the statement first, then EXECUTE the variable: the plpgsql_check
        -- profiler re-evaluates an EXECUTE's string expression after the statement
        -- ran, and re-rendering r.sig after the DROP would yield a bare OID.
        v_sql := 'DROP FUNCTION IF EXISTS ' || r.sig;
        EXECUTE v_sql;
    END LOOP;

    -- Local term: own label value with '' folded to NULL (so it contributes nothing).
    IF v_label_col IS NOT NULL AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = p_table_name AND column_name = v_label_col
    ) THEN
        v_local := format('NULLIF((rec.%I)::text, %L)', v_label_col, '');
    ELSE
        v_local := 'NULL::text';
    END IF;

    v_is_junction := dd_is_junction(p_table_name);

    IF v_is_junction THEN
        -- Junction: combine the parent legs (field order); no local term.
        v_legs := ARRAY[]::TEXT[];
        FOR r IN
            SELECT f.field_name, f.reference_table
            FROM fields f
            WHERE f.table_name = p_table_name
              AND f.format = 'parent'
              AND f.reference_table <> ''
              AND f.reference_table <> p_table_name
            ORDER BY f.field_order
        LOOP
            SELECT id_column INTO v_parent_id FROM entities WHERE table_name = r.reference_table;
            CONTINUE WHEN v_parent_id IS NULL;
            CONTINUE WHEN to_regclass(format('public.%I', r.reference_table)) IS NULL;
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name=p_table_name AND column_name=r.field_name);
            v_legs := array_append(v_legs, format(
                '(SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I)',
                r.reference_table, v_parent_id, r.field_name));
        END LOOP;

        IF array_length(v_legs, 1) >= 1 THEN
            v_body := format('SELECT NULLIF(concat_ws(%L, %s), %L)',
                             ' › ', array_to_string(v_legs, ', '), '');
        ELSE
            v_body := format('SELECT %s', v_local);
        END IF;

    ELSIF v_spine IS NOT NULL THEN
        -- Relational: parent._label › local, degrading to local when the spine does not resolve.
        SELECT format, reference_table INTO v_spine_fmt, v_spine_ref
          FROM fields WHERE table_name = p_table_name AND field_name = v_spine;
        IF dd_is_fk_format(v_spine_fmt)
           AND COALESCE(v_spine_ref, '') <> ''
           AND v_spine_ref <> p_table_name
           AND to_regclass(format('public.%I', v_spine_ref)) IS NOT NULL
           AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name=p_table_name AND column_name=v_spine)
        THEN
            SELECT id_column INTO v_parent_id FROM entities WHERE table_name = v_spine_ref;
            v_body := format(
                'SELECT NULLIF(concat_ws(%L, (SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I), %s), %L)',
                ' › ', v_spine_ref, v_parent_id, v_spine, v_local, '');
        ELSE
            v_body := format('SELECT %s', v_local);
        END IF;

    ELSE
        -- Root / self-identifying: composed label is the local label.
        v_body := format('SELECT %s', v_local);
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION public._label(rec %s) RETURNS text '
        'LANGUAGE sql STABLE SET search_path = public AS $body$ %s $body$',
        v_rowtype, v_body);
    -- Computed-label functions are SECURITY INVOKER (default): keep them off PUBLIC but executable
    -- by the request role so they work as PostgREST computed columns and in nested _label calls.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public._label(%s) FROM PUBLIC', v_rowtype);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public._label(%s) TO semantius_user', v_rowtype);
    EXECUTE format(
        'COMMENT ON FUNCTION public._label(%s) IS %L',
        v_rowtype,
        format('Composed record label for entity "%s" (PostgREST computed column). Generated by rebuild_entity_label_functions from entity/field metadata.', p_table_name));

    -- <fk>_label companion for every reference/parent field (referenced record's composed label).
    FOR r IN
        SELECT f.field_name, f.reference_table
        FROM fields f
        WHERE f.table_name = p_table_name AND dd_is_fk_format(f.format) AND f.reference_table <> ''
        ORDER BY f.field_order
    LOOP
        SELECT id_column INTO v_parent_id FROM entities WHERE table_name = r.reference_table;
        CONTINUE WHEN v_parent_id IS NULL;
        CONTINUE WHEN to_regclass(format('public.%I', r.reference_table)) IS NULL;
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=p_table_name AND column_name=r.field_name);
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=r.reference_table AND column_name=v_parent_id);
        -- Collision-aware: if a REAL column already owns the <fk>_label name (e.g. a denormalised
        -- display column), it wins — skip the companion so the column is never shadowed by a function.
        CONTINUE WHEN EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=p_table_name AND column_name = r.field_name || '_label');
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION public.%I(rec %s) RETURNS text '
            'LANGUAGE sql STABLE SET search_path = public AS $body$ '
            'SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I $body$',
            r.field_name || '_label', v_rowtype, r.reference_table, v_parent_id, r.field_name);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(%s) FROM PUBLIC', r.field_name || '_label', v_rowtype);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO semantius_user', r.field_name || '_label', v_rowtype);
        EXECUTE format(
            'COMMENT ON FUNCTION public.%I(%s) IS %L',
            r.field_name || '_label', v_rowtype,
            format('Composed label of the "%s" record referenced by %s.%s (PostgREST computed column). Generated by rebuild_entity_label_functions.', r.reference_table, p_table_name, r.field_name));
    END LOOP;

    PERFORM set_config('check_function_bodies', v_saved, true);
END;
$fn$;

COMMENT ON FUNCTION rebuild_entity_label_functions(TEXT) IS
'Regenerates the _label and <fk>_label PostgREST computed-column functions for one entity from
current metadata + physical columns. SECURITY DEFINER (creates functions) but the generated
functions are SECURITY INVOKER so composed labels respect each caller''s row-level read permissions.';

-- =====================================================
-- §9 RESERVED FIELD-NAME NAMESPACE
-- =====================================================
-- Only the "_" prefix is reserved (protects the generated _label column and the system "_*"
-- namespace). The "_label" SUFFIX is NOT reserved: real columns ending in _label (e.g. a
-- denormalised customer_label, or even a deliberate <fk>_label) are common and allowed. A real
-- column always wins over a generated <fk>_label companion — the generator and get_schema are
-- collision-aware and skip a companion whose name is already a real column (so nothing is shadowed
-- silently). Privileged DD/migration code (BYPASSRLS) is exempt.
CREATE OR REPLACE FUNCTION reserve_field_namespace()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public
AS $$
DECLARE v_priv BOOLEAN;
BEGIN
    SELECT rolbypassrls INTO v_priv FROM pg_roles WHERE rolname = current_user;
    IF COALESCE(v_priv, FALSE) THEN
        RETURN NEW;
    END IF;
    IF NEW.field_name ~ '^_' THEN
        RAISE EXCEPTION 'Field name "%" is reserved: names starting with "_" are reserved for generated/system columns (e.g. _label)', NEW.field_name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION reserve_field_namespace() IS
'Trigger function that rejects user-created field names beginning with "_" (reserved for generated/system columns such as _label). Privileged BYPASSRLS roles are exempt.';

CREATE TRIGGER fields_reserve_namespace_trigger
    BEFORE INSERT OR UPDATE OF field_name ON fields
    FOR EACH ROW
    EXECUTE FUNCTION reserve_field_namespace();

-- =====================================================
-- §10 label_parent VALIDATION  (+ §2/§11 acyclic, no self-reference)
-- =====================================================
CREATE OR REPLACE FUNCTION validate_label_parent()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fmt  TEXT;
    v_ref  TEXT;
    v_cur  TEXT;
    v_hops INT := 0;
BEGIN
    IF COALESCE(NEW.label_parent, '') = '' THEN
        RETURN NEW;
    END IF;

    IF dd_is_junction(NEW.table_name) THEN
        RAISE EXCEPTION 'label_parent cannot be set on junction entity "%"', NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT format, reference_table INTO v_fmt, v_ref
      FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_parent;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'label_parent "%" is not a field of entity "%"', NEW.label_parent, NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT dd_is_fk_format(v_fmt) OR COALESCE(v_ref, '') = '' THEN
        RAISE EXCEPTION 'label_parent "%" on "%" must name a reference/parent field', NEW.label_parent, NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_ref = NEW.table_name THEN
        RAISE EXCEPTION 'label_parent "%" must not be self-referential (the identity spine must be acyclic)', NEW.label_parent
            USING ERRCODE = 'check_violation';
    END IF;

    IF dd_is_junction(v_ref) THEN
        RAISE EXCEPTION 'label_parent "%" must not target junction entity "%"', NEW.label_parent, v_ref
            USING ERRCODE = 'check_violation';
    END IF;

    -- Walk the committed spine chain from the target; returning to this entity is a cycle.
    v_cur := v_ref;
    WHILE COALESCE(v_cur, '') <> '' AND v_hops < 64 LOOP
        IF v_cur = NEW.table_name THEN
            RAISE EXCEPTION 'label_parent on "%" via "%" would create a cycle in the identity spine', NEW.table_name, NEW.label_parent
                USING ERRCODE = 'check_violation';
        END IF;
        v_cur := dd_spine_parent(v_cur);
        v_hops := v_hops + 1;
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validate_label_parent() IS
'Trigger function validating an entity''s label_parent: it must name a reference/parent field of the entity, must not self-reference, and must not introduce a cycle in the identity spine.';

CREATE TRIGGER validate_label_parent_trigger
    BEFORE INSERT OR UPDATE OF label_parent ON entities
    FOR EACH ROW
    EXECUTE FUNCTION validate_label_parent();

-- =====================================================
-- LIFECYCLE WIRING  (zzz_ names → fire AFTER the structural DD triggers)
-- =====================================================
-- One generator, driven by the same metadata get_schema reads, kept in sync by lightweight AFTER
-- triggers rather than by editing the structural trigger functions.
CREATE OR REPLACE FUNCTION dd_label_fn_sync_entity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Table rename: rebuild self under the new name, and every entity whose generated bodies
        -- hard-code the old name (reference_table already cascaded to the new name by then).
        PERFORM rebuild_entity_label_functions(NEW.table_name);
        PERFORM rebuild_entity_label_functions(s.t)
          FROM (SELECT DISTINCT table_name AS t FROM fields WHERE reference_table = NEW.table_name) s;
    ELSE
        PERFORM rebuild_entity_label_functions(NEW.table_name);
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION dd_label_fn_sync_field()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM rebuild_entity_label_functions(COALESCE(NEW.table_name, OLD.table_name));
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION dd_label_fn_sync_entity() IS
'Trigger function that regenerates the entity''s _label / <fk>_label computed-column functions after an entities row changes, by calling rebuild_entity_label_functions.';
COMMENT ON FUNCTION dd_label_fn_sync_field() IS
'Trigger function that regenerates the owning entity''s _label / <fk>_label computed-column functions after a fields row changes, by calling rebuild_entity_label_functions.';

CREATE TRIGGER zzz_label_fn_entity_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_entity();

CREATE TRIGGER zzz_label_fn_entity_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name   IS DISTINCT FROM NEW.table_name
       OR OLD.label_parent IS DISTINCT FROM NEW.label_parent
       OR OLD.entity_type  IS DISTINCT FROM NEW.entity_type
       OR OLD.label_column IS DISTINCT FROM NEW.label_column
       OR OLD.managed      IS DISTINCT FROM NEW.managed)
    EXECUTE FUNCTION dd_label_fn_sync_entity();

CREATE TRIGGER zzz_label_fn_field_insert_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

CREATE TRIGGER zzz_label_fn_field_delete_trigger
    AFTER DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

CREATE TRIGGER zzz_label_fn_field_update_trigger
    AFTER UPDATE ON fields
    FOR EACH ROW
    WHEN (OLD.field_name      IS DISTINCT FROM NEW.field_name
       OR OLD.format          IS DISTINCT FROM NEW.format
       OR OLD.reference_table IS DISTINCT FROM NEW.reference_table)
    EXECUTE FUNCTION dd_label_fn_sync_field();

REVOKE EXECUTE ON FUNCTION rebuild_entity_label_functions(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION reserve_field_namespace() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_label_parent() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_label_fn_sync_entity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_label_fn_sync_field() FROM PUBLIC;
-- Pure predicates: off PUBLIC (TEST 2.2) but available to the request role.
REVOKE EXECUTE ON FUNCTION dd_is_fk_format(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_is_junction(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_spine_parent(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_is_fk_format(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_is_junction(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_spine_parent(TEXT) TO semantius_user;

-- Backfill: build label functions for every entity that already exists (core meta-tables and any
-- entity created before these triggers were installed). Entities created later self-provision via
-- the AFTER triggers above. Order-independent thanks to check_function_bodies being off per build.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT table_name FROM entities ORDER BY table_name LOOP
        PERFORM rebuild_entity_label_functions(r.table_name);
    END LOOP;
END $$;
