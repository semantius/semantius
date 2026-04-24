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
    v_data_type := format_to_data_type(p_field.format);

    -- Build nullable clause
    IF p_field.is_nullable THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;

    -- Build default clause with sensible fallbacks for NOT NULL columns
    IF p_field.default_value IS NOT NULL AND trim(p_field.default_value) != '' THEN
        v_default_clause := format('DEFAULT %s', quote_default_value(p_field.default_value, v_data_type));
    ELSIF NOT p_field.is_nullable THEN
        IF v_data_type IN ('JSONB', 'JSON') THEN
            v_default_clause := 'DEFAULT ''{}''::jsonb';
        ELSE
            CASE v_data_type
                WHEN 'TEXT'                                    THEN v_default_clause := 'DEFAULT ''''';
                WHEN 'INTEGER', 'BIGINT', 'SMALLINT'           THEN v_default_clause := 'DEFAULT 0';
                WHEN 'NUMERIC', 'DECIMAL', 'REAL',
                     'DOUBLE PRECISION'                        THEN v_default_clause := 'DEFAULT 0.0';
                WHEN 'BOOLEAN'                                 THEN v_default_clause := 'DEFAULT FALSE';
                WHEN 'TIMESTAMP', 'TIMESTAMPTZ'               THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                WHEN 'DATE'                                    THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                ELSE v_default_clause := '';
            END CASE;
        END IF;
    ELSE
        v_default_clause := '';
    END IF;

    -- Add column (IF NOT EXISTS makes this idempotent)
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        p_field.table_name, p_field.field_name,
        v_data_type, v_nullable_clause, v_default_clause
    );
    EXECUTE v_alter_sql;

    -- Add / refresh column comment
    IF p_field.description IS NOT NULL AND trim(p_field.description) != '' THEN
        EXECUTE format('COMMENT ON COLUMN %I.%I IS %L',
            p_field.table_name, p_field.field_name, p_field.description);
    END IF;

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
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
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
       AND jsonb_array_length(p_field.enum_values) > 0
    THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
        BEGIN
            v_check_name := format('%s_%s_check', p_field.table_name, p_field.field_name);
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(p_field.enum_values) AS value
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

        -- Table comment
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format('COMMENT ON TABLE %I IS %L', NEW.table_name, NEW.description);
        END IF;

        -- updated_at maintenance trigger
        EXECUTE format(
            'CREATE TRIGGER update_%I_updated_at
                BEFORE UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION common.update_updated_at_column()',
            NEW.table_name, NEW.table_name
        );

        -- Row Level Security
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', NEW.table_name);

        EXECUTE format(
            'CREATE POLICY %I_select_policy ON %I
                FOR SELECT TO semantius_user
                USING (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.view_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_insert_policy ON %I
                FOR INSERT TO semantius_user
                WITH CHECK (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_update_policy ON %I
                FOR UPDATE TO semantius_user
                USING (rbac.has_permission(%L))
                WITH CHECK (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_delete_policy ON %I
                FOR DELETE TO semantius_user
                USING (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );

        RAISE NOTICE 'Created table "%" (managed changed to true)', NEW.table_name;
    END IF;

    -- ── Insert core field records if they were never created ─────────────
    -- create_dd_table inserts these when managed=true on INSERT, but when
    -- an entity was created with managed=false those records do not exist.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.id_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, 1, 'required', 'default', 'label', TRUE, TRUE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', '', TRUE, FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = 'created_at');

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', '', TRUE, FALSE, '', ''
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

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION enable_dd_table IS
'AFTER UPDATE trigger on entities: when managed changes from FALSE to TRUE,
creates the physical table (with RLS policies and updated_at trigger) if it does
not already exist, then adds any columns that were defined as field records while
the table was unmanaged.';

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

    -- Prevent changing structural attributes of core fields
    IF OLD.is_core THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.is_core <> NEW.is_core THEN
            RAISE EXCEPTION 'Cannot change is_core status of field "%"', OLD.field_name;
        END IF;
    END IF;

    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still allow updating column comments even if not managed
        IF OLD.description IS DISTINCT FROM NEW.description THEN
            IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS %L',
                    NEW.table_name, NEW.field_name, NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name, NEW.field_name
                );
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

    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name, NEW.field_name, NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name, NEW.field_name
            );
        END IF;
    END IF;

    -- Handle format change
    IF OLD.format <> NEW.format THEN
        v_old_data_type := format_to_data_type(OLD.format);
        v_new_data_type := format_to_data_type(NEW.format);

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
    IF OLD.is_nullable <> NEW.is_nullable THEN
        IF NEW.is_nullable THEN
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
            NEW.field_name, NEW.is_nullable, NEW.table_name;
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
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format))
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
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
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
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);

            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values) OR (OLD.format <> NEW.format) THEN
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name, v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                IF NEW.format = 'enum'
                   AND NEW.enum_values IS NOT NULL
                   AND jsonb_array_length(NEW.enum_values) > 0
                THEN
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(NEW.enum_values) AS value
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
