-- =====================================================
-- DDL RENAME SUPPORT
-- =====================================================
-- Adds support for renaming:
--   1. entities.table_name  → ALTER TABLE ... RENAME TO ...
--   2. fields.field_name    → ALTER TABLE ... RENAME COLUMN ... TO ...
-- Adds validation:
--   3. fields.format change → reject when underlying data type would change

-- =====================================================
-- STEP 1: Add ON UPDATE CASCADE to fields → entities FK
-- =====================================================
-- Required so that renaming entities.table_name automatically cascades
-- the metadata update to all related fields rows.

ALTER TABLE fields DROP CONSTRAINT IF EXISTS fields_table_name_fkey;

ALTER TABLE fields
    ADD CONSTRAINT fields_table_name_fkey
    FOREIGN KEY (table_name)
    REFERENCES entities(table_name)
    ON DELETE CASCADE
    ON UPDATE CASCADE;

-- =====================================================
-- STEP 2: TRIGGER FUNCTION: RENAME TABLE ON entities.table_name UPDATE
-- =====================================================
-- Fires BEFORE UPDATE on entities when table_name changes.
-- Renames the physical table and sets a transaction-local session variable
-- so the cascaded update to fields.table_name is allowed by update_dd_field.

CREATE OR REPLACE FUNCTION rename_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_suffix    TEXT;
    v_old_name  TEXT;
    v_new_name  TEXT;
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Mark that a cascade rename is in progress (transaction-local)
        PERFORM set_config('dd.table_rename', OLD.table_name || ':' || NEW.table_name, TRUE);

        -- Rename the physical table and all associated named objects when managed
        IF OLD.managed THEN
            EXECUTE format('ALTER TABLE %I RENAME TO %I', OLD.table_name, NEW.table_name);
            RAISE NOTICE 'Renamed table "%" to "%"', OLD.table_name, NEW.table_name;

            -- Rename updated_at trigger (name pattern: update_<table>_updated_at)
            IF EXISTS (
                SELECT 1 FROM pg_trigger t
                JOIN pg_class c ON t.tgrelid = c.oid
                WHERE c.relname = NEW.table_name
                  AND c.relnamespace = 'public'::regnamespace
                  AND t.tgname = 'update_' || OLD.table_name || '_updated_at'
            ) THEN
                EXECUTE format(
                    'ALTER TRIGGER %I ON %I RENAME TO %I',
                    'update_' || OLD.table_name || '_updated_at',
                    NEW.table_name,
                    'update_' || NEW.table_name || '_updated_at'
                );
            END IF;

            -- Rename RLS policies (name patterns: <table>_select/insert/update/delete_policy)
            FOREACH v_suffix IN ARRAY ARRAY['select_policy', 'insert_policy', 'update_policy', 'delete_policy']
            LOOP
                IF EXISTS (
                    SELECT 1 FROM pg_policy p
                    JOIN pg_class c ON p.polrelid = c.oid
                    WHERE c.relname = NEW.table_name
                      AND c.relnamespace = 'public'::regnamespace
                      AND p.polname = OLD.table_name || '_' || v_suffix
                ) THEN
                    EXECUTE format(
                        'ALTER POLICY %I ON %I RENAME TO %I',
                        OLD.table_name || '_' || v_suffix,
                        NEW.table_name,
                        NEW.table_name || '_' || v_suffix
                    );
                END IF;
            END LOOP;

            -- Rename GIN search_vector index if it exists
            -- (name pattern: <table>_search_vector_idx)
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public'
                  AND indexname = OLD.table_name || '_search_vector_idx'
            ) THEN
                EXECUTE format(
                    'ALTER INDEX %I RENAME TO %I',
                    OLD.table_name || '_search_vector_idx',
                    NEW.table_name || '_search_vector_idx'
                );
            END IF;

            -- Rename id sequence (<table>_<id_col>_seq)
            IF EXISTS (
                SELECT 1 FROM pg_class
                WHERE relname = OLD.table_name || '_' || OLD.id_column || '_seq'
                  AND relnamespace = 'public'::regnamespace
                  AND relkind = 'S'
            ) THEN
                EXECUTE format(
                    'ALTER SEQUENCE %I RENAME TO %I',
                    OLD.table_name || '_' || OLD.id_column || '_seq',
                    NEW.table_name || '_' || NEW.id_column || '_seq'
                );
            END IF;

            -- Rename primary key constraint (<table>_pkey)
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = OLD.table_name || '_pkey'
                  AND t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.contype = 'p'
            ) THEN
                EXECUTE format(
                    'ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name,
                    OLD.table_name || '_pkey',
                    NEW.table_name || '_pkey'
                );
            END IF;

            -- Rename all FK constraints named <old_table>_<field>_fkey
            FOR v_old_name IN
                SELECT c.conname
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (OLD.table_name || '\_%\_fkey') ESCAPE '\'
                  AND c.contype = 'f'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name, v_old_name, v_new_name);
            END LOOP;

            -- Rename all FK indexes named idx_<old_table>_<field>
            FOR v_old_name IN
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = NEW.table_name
                  AND indexname LIKE ('idx\_' || OLD.table_name || '\_%') ESCAPE '\'
            LOOP
                v_new_name := 'idx_' || NEW.table_name || substring(v_old_name FROM length('idx_' || OLD.table_name) + 1);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

            -- Rename all check constraints named <old_table>_<field>_check
            FOR v_old_name IN
                SELECT c.conname
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (OLD.table_name || '\_%\_check') ESCAPE '\'
                  AND c.contype = 'c'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name, v_old_name, v_new_name);
            END LOOP;

            -- Rename all unique indexes named <old_table>_<field>_unique
            FOR v_old_name IN
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = NEW.table_name
                  AND indexname LIKE (OLD.table_name || '\_%\_unique') ESCAPE '\'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION rename_dd_table IS
'BEFORE UPDATE trigger on entities: renames the physical table and ALL associated named
objects when table_name changes: updated_at trigger, RLS policies, GIN search_vector
index, id sequence, primary key constraint, FK constraints, FK indexes, check constraints,
and unique indexes.  Sets a transaction-local session variable so the cascaded update to
fields.table_name is allowed by update_dd_field without raising an exception.';

-- Apply trigger BEFORE UPDATE on entities (only when table_name changes)
CREATE TRIGGER rename_table_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_table();

COMMENT ON TRIGGER rename_table_trigger ON entities IS
'Renames the physical database table when entities.table_name is updated';

-- =====================================================
-- STEP 2b: TRIGGER FUNCTION: CASCADE reference_table ON entities.table_name UPDATE
-- =====================================================
-- Fires AFTER UPDATE on entities when table_name changes.
-- Updates fields.reference_table in every field across ALL tables that currently
-- points at the old table name.  Must run AFTER (not BEFORE) the entities row is
-- committed so that validate_reference_table_trigger can find the new name.
-- The update cascades through update_dd_field() which drops and recreates the
-- physical FK constraint to reference the renamed table.

CREATE OR REPLACE FUNCTION rename_dd_reference_tables()
RETURNS TRIGGER AS $$
BEGIN
    -- Update every field in any table that references the old entity name.
    -- update_dd_field() (AFTER trigger on fields) will detect the reference_table
    -- change and rebuild the FK constraint to point at NEW.table_name.
    UPDATE fields
    SET reference_table = NEW.table_name
    WHERE reference_table = OLD.table_name;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION rename_dd_reference_tables IS
'AFTER UPDATE trigger on entities: when table_name changes, updates fields.reference_table
in all fields across all tables that referenced the old name.  Cascades through
update_dd_field() to rebuild the physical FK constraint on the referencing table.';

CREATE TRIGGER rename_reference_tables_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_reference_tables();

COMMENT ON TRIGGER rename_reference_tables_trigger ON entities IS
'Updates fields.reference_table and rebuilds FK constraints when entities.table_name is renamed';

-- =====================================================
-- STEP 3: TRIGGER FUNCTION: VALIDATE AND RENAME ON fields UPDATE
-- =====================================================
-- Fires BEFORE UPDATE on fields.
-- Handles two things:
--   A) field_name rename  → ALTER TABLE ... RENAME COLUMN ... TO ...
--      Also renames associated FK constraints, indexes, and check constraints.
--   B) format validation  → reject if the new format maps to a different data type.

CREATE OR REPLACE FUNCTION validate_field_rename_and_format()
RETURNS TRIGGER AS $$
DECLARE
    v_is_managed  BOOLEAN;
    v_old_type    TEXT;
    v_new_type    TEXT;
    v_old_fk      TEXT;
    v_new_fk      TEXT;
    v_old_idx     TEXT;
    v_new_idx     TEXT;
    v_old_check   TEXT;
    v_new_check   TEXT;
    v_old_unique  TEXT;
    v_new_unique  TEXT;
BEGIN
    -- Resolve parent entity's managed flag
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = OLD.table_name;

    -- --------------------------------------------------
    -- A) Handle field_name rename
    -- --------------------------------------------------
    IF OLD.field_name IS DISTINCT FROM NEW.field_name THEN
        -- Core fields cannot be renamed
        IF OLD.is_core THEN
            RAISE EXCEPTION 'Cannot rename core system field "%"', OLD.field_name;
        END IF;

        IF v_is_managed THEN
            -- Rename the physical column
            EXECUTE format(
                'ALTER TABLE %I RENAME COLUMN %I TO %I',
                OLD.table_name, OLD.field_name, NEW.field_name
            );
            RAISE NOTICE 'Renamed column "%" to "%" in table "%"',
                OLD.field_name, NEW.field_name, OLD.table_name;

            -- Build old and new names for associated constraints / indexes
            v_old_fk     := format('%s_%s_fkey',   OLD.table_name, OLD.field_name);
            v_new_fk     := format('%s_%s_fkey',   OLD.table_name, NEW.field_name);
            v_old_idx    := format('idx_%s_%s',    OLD.table_name, OLD.field_name);
            v_new_idx    := format('idx_%s_%s',    OLD.table_name, NEW.field_name);
            v_old_check  := format('%s_%s_check',  OLD.table_name, OLD.field_name);
            v_new_check  := format('%s_%s_check',  OLD.table_name, NEW.field_name);
            v_old_unique := format('%s_%s_unique', OLD.table_name, OLD.field_name);
            v_new_unique := format('%s_%s_unique', OLD.table_name, NEW.field_name);

            -- Rename FK constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_fk
                  AND t.relname = OLD.table_name
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    OLD.table_name, v_old_fk, v_new_fk);
                RAISE NOTICE 'Renamed FK constraint "%" to "%"', v_old_fk, v_new_fk;
            END IF;

            -- Rename FK index if it exists
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND indexname = v_old_idx
            ) THEN
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_idx, v_new_idx);
                RAISE NOTICE 'Renamed index "%" to "%"', v_old_idx, v_new_idx;
            END IF;

            -- Rename check constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_check
                  AND t.relname = OLD.table_name
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    OLD.table_name, v_old_check, v_new_check);
                RAISE NOTICE 'Renamed check constraint "%" to "%"', v_old_check, v_new_check;
            END IF;

            -- Rename unique index if it exists
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND indexname = v_old_unique
            ) THEN
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_unique, v_new_unique);
                RAISE NOTICE 'Renamed unique index "%" to "%"', v_old_unique, v_new_unique;
            END IF;
        END IF;
    END IF;

    -- --------------------------------------------------
    -- B) Validate format change (only for managed tables)
    -- --------------------------------------------------
    -- For managed tables, the format maps to a physical column type.
    -- Changing format is valid only when the new format maps to the same
    -- underlying PostgreSQL data type (e.g. email → hostname is fine because
    -- both are TEXT, but email → json is not because TEXT ≠ JSONB).
    -- Unmanaged tables have no physical columns, so any format change is allowed.
    IF OLD.format IS DISTINCT FROM NEW.format AND v_is_managed THEN
        -- Core field formats cannot be changed (existing rule, enforced here too)
        IF OLD.is_core THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        v_old_type := format_to_data_type(OLD.format);
        v_new_type := format_to_data_type(NEW.format);

        IF v_old_type <> v_new_type THEN
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %. Drop and recreate the field instead.',
                OLD.field_name, OLD.format, NEW.format, v_old_type, v_new_type;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION validate_field_rename_and_format IS
'BEFORE UPDATE trigger on fields.
Renames the physical column (and associated constraints/indexes) when field_name changes.
Rejects format changes that would alter the underlying PostgreSQL data type.';

-- Apply trigger BEFORE UPDATE on fields
CREATE TRIGGER validate_field_rename_and_format_trigger
    BEFORE UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_field_rename_and_format();

COMMENT ON TRIGGER validate_field_rename_and_format_trigger ON fields IS
'Renames column and validates format compatibility on field updates';

-- =====================================================
-- STEP 4: Update update_dd_field() to handle the new semantics
-- =====================================================
-- Changes:
--   • table_name change: allow when the session variable set by rename_dd_table
--     confirms this is a cascade from an entity rename; reject otherwise.
--   • field_name change: no longer raise an exception — the BEFORE trigger
--     already renamed the physical column.  The AFTER trigger must use
--     NEW.field_name (already the renamed column name) for all subsequent DDL.
--   • format change: skip ALTER COLUMN TYPE when the data type is unchanged
--     (same-type format changes like email→hostname).  Incompatible type
--     changes are blocked by the BEFORE trigger before this code is reached.

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_old_data_type TEXT;
    v_new_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
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
    -- Core fields can only have metadata updates (title, description, field_order, input_type, width)
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
                    NEW.table_name,
                    NEW.field_name,
                    NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
    END IF;

    -- Handle format change
    -- The BEFORE trigger already rejected incompatible type changes, so at this
    -- point OLD and NEW formats always map to the same data type.
    -- Only execute ALTER COLUMN TYPE when the mapped type actually differs
    -- (this guards against edge cases and keeps DDL minimal).
    IF OLD.format <> NEW.format THEN
        v_old_data_type := format_to_data_type(OLD.format);
        v_new_data_type := format_to_data_type(NEW.format);

        IF v_old_data_type <> v_new_data_type THEN
            -- Defensive check: BEFORE trigger should have prevented this
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %.',
                NEW.field_name, OLD.format, NEW.format, v_old_data_type, v_new_data_type;
        END IF;

        -- Same underlying type — no ALTER needed; log the format change only
        RAISE NOTICE 'Changed format of column "%" from "%" to "%" in table "%" (data type unchanged: %)',
            NEW.field_name, OLD.format, NEW.format, NEW.table_name, v_new_data_type;
    END IF;

    -- Allow updating nullable constraint (derived from format)
    IF compute_is_nullable(OLD.format) <> compute_is_nullable(NEW.format) THEN
        IF compute_is_nullable(NEW.format) THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
            NEW.field_name, compute_is_nullable(NEW.format), NEW.table_name;
    END IF;

    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name,
                NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;

    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);

        -- Check if reference_table or reference_delete_mode changed
        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format) THEN

            -- Drop existing foreign key constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name,
                    v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;

            -- Add new foreign key constraint if format is now 'reference' or 'parent'
            IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
                -- Get the id_column of the referenced table
                SELECT id_column INTO v_ref_id_column
                FROM entities
                WHERE table_name = NEW.reference_table;

                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;

                -- Determine ON DELETE behavior
                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;

                -- Add foreign key constraint
                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
                    NEW.table_name,
                    v_fk_name,
                    NEW.field_name,
                    NEW.reference_table,
                    v_ref_id_column,
                    v_on_delete
                );
                EXECUTE v_alter_sql;

                -- Create index for foreign key if it doesn't exist
                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name,
                    NEW.table_name,
                    NEW.field_name
                );
                EXECUTE v_alter_sql;

                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name, NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                -- Drop index if format changed from reference/parent to something else
                EXECUTE format(
                    'DROP INDEX IF EXISTS %I',
                    v_idx_name
                );
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;

    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);

            -- Check if enum_values changed or format changed
            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values) OR (OLD.format <> NEW.format) THEN

                -- Drop existing CHECK constraint if it exists
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name,
                        v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                -- Add new CHECK constraint if format is now 'enum'
                IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
                    -- Build SQL array from JSONB array for IN clause
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(NEW.enum_values) AS value
                    );

                    -- Add CHECK constraint
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name,
                        v_check_name,
                        NEW.field_name,
                        v_enum_values_sql
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
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                -- Create partial unique index
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name,
                    NEW.table_name,
                    NEW.field_name,
                    v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                -- Drop unique index
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
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
format changes that alter the underlying data type are rejected by the BEFORE trigger.';

-- Revoke default PUBLIC execute on the new functions
REVOKE EXECUTE ON FUNCTION rename_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rename_dd_reference_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_field_rename_and_format() FROM PUBLIC;
