-- =====================================================
-- DDL RENAME SUPPORT
-- =====================================================
-- Adds support for renaming:
--   1. entities.table_name  → ALTER TABLE ... RENAME TO ...
--   2. fields.field_name    → ALTER TABLE ... RENAME COLUMN ... TO ...
-- Adds validation:
--   3. fields.format change → reject when underlying data type would change

-- =====================================================
-- STEP 1: TRIGGER FUNCTION: RENAME TABLE ON entities.table_name UPDATE
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
                SELECT c.conname::text
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
                SELECT indexname::text
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
                SELECT c.conname::text
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

            -- Rename all NOT NULL constraints named <old_table>_<field>_not_null.
            -- PostgreSQL 18+ stores NOT NULL as named pg_constraint rows; on
            -- PG<=17 no such rows exist, so this SELECT returns nothing and the
            -- loop is a no-op. The same migration is therefore correct on both
            -- PG<=17 (Neon/Supabase) and PG>=18 (e.g. pgdocker) — no version
            -- branch needed. (Matched by name rather than contype so it does not
            -- depend on the PG18-specific contype value 'n'.)
            FOR v_old_name IN
                SELECT c.conname::text
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (OLD.table_name || '\_%\_not\_null') ESCAPE '\'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name, v_old_name, v_new_name);
            END LOOP;

            -- Rename all unique indexes named <old_table>_<field>_unique
            FOR v_old_name IN
                SELECT indexname::text
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = NEW.table_name
                  AND indexname LIKE (OLD.table_name || '\_%\_unique') ESCAPE '\'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

            -- Drop old compute_validate function (CASCADE drops its trigger too).
            -- The AFTER trigger manage_record_logic_trigger will rebuild it under the new name.
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE',
                'compute_validate_' || OLD.table_name);

            -- Drop both select_rule overloads (CASCADE drops the policies that use
            -- them). The AFTER trigger manage_select_rule_policy rebuilds them under
            -- the new name. The signatures pair the OLD function name with the NEW
            -- row type on purpose: the physical table was renamed a few lines above,
            -- so the composite type already answers to NEW.table_name while the
            -- functions still carry the old name.
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE',
                'select_rule_' || OLD.table_name, NEW.table_name);
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE',
                'select_rule_' || OLD.table_name, NEW.table_name);

            -- Rename queue event triggers on the entity table.
            -- Pattern: queue_<queue_name>_<event>_on_<old_table>, one per DML
            -- event the mapping covers.
            FOR v_old_name IN
                SELECT t.tgname::text
                FROM pg_trigger t
                JOIN pg_class c ON t.tgrelid = c.oid
                WHERE c.relname = NEW.table_name
                  AND c.relnamespace = 'public'::regnamespace
                  AND t.tgname LIKE ('%\_on\_' || OLD.table_name) ESCAPE '\'
                  AND t.tgname LIKE 'queue\_%' ESCAPE '\'
            LOOP
                v_new_name := substring(v_old_name FROM 1 FOR length(v_old_name) - length(OLD.table_name))
                              || NEW.table_name;
                EXECUTE format('ALTER TRIGGER %I ON %I RENAME TO %I',
                    v_old_name, NEW.table_name, v_new_name);
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
NOT NULL constraints (PG18+ named pg_constraint rows; no-op on PG<=17),
unique indexes, compute_validate function, select_rule function, and queue event triggers.
Sets a transaction-local session variable so the cascaded update to fields.table_name is
allowed by update_dd_field without raising an exception.';

-- Apply trigger BEFORE UPDATE on entities (only when table_name changes)
CREATE TRIGGER rename_table_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_table();

COMMENT ON TRIGGER rename_table_trigger ON entities IS
'Renames the physical database table when entities.table_name is updated';

-- =====================================================
-- STEP 1b: TRIGGER FUNCTION: CASCADE reference_table ON entities.table_name UPDATE
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
-- STEP 1c: TRIGGER FUNCTION: CASCADE set_record entity refs ON entities.table_name UPDATE
-- =====================================================
-- Fires AFTER UPDATE on entities when table_name changes.
-- Scans all entities for JsonLogic set_record references to the old table name
-- in computed_fields, validation_rules, and select_rule, and replaces them with
-- the new name via simple text replacement on the JSONB.

CREATE OR REPLACE FUNCTION rename_dd_jsonlogic_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_old_quoted TEXT;
    v_new_quoted TEXT;
BEGIN
    v_old_quoted := '"' || OLD.table_name || '"';
    v_new_quoted := '"' || NEW.table_name || '"';

    -- Update set_record entity name references in computed_fields
    UPDATE entities
    SET computed_fields = replace(computed_fields::text, v_old_quoted, v_new_quoted)::jsonb
    WHERE computed_fields::text LIKE '%set_record%'
      AND computed_fields::text LIKE '%' || v_old_quoted || '%';

    -- Update set_record entity name references in validation_rules
    UPDATE entities
    SET validation_rules = replace(validation_rules::text, v_old_quoted, v_new_quoted)::jsonb
    WHERE validation_rules::text LIKE '%set_record%'
      AND validation_rules::text LIKE '%' || v_old_quoted || '%';

    -- Update set_record entity name references in select_rule
    UPDATE entities
    SET select_rule = replace(select_rule::text, v_old_quoted, v_new_quoted)::jsonb
    WHERE select_rule::text LIKE '%set_record%'
      AND select_rule::text LIKE '%' || v_old_quoted || '%';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION rename_dd_jsonlogic_refs IS
'AFTER UPDATE trigger on entities: when table_name changes, updates set_record entity
name references in computed_fields, validation_rules, and select_rule across ALL entities
that contain the old table name.';

REVOKE EXECUTE ON FUNCTION rename_dd_jsonlogic_refs() FROM PUBLIC;

CREATE TRIGGER rename_jsonlogic_refs_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_jsonlogic_refs();

COMMENT ON TRIGGER rename_jsonlogic_refs_trigger ON entities IS
'Updates set_record entity name references in JsonLogic rules when entities.table_name is renamed';

-- =====================================================
-- STEP 2: TRIGGER FUNCTION: VALIDATE AND RENAME ON fields UPDATE
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
    v_old_notnull TEXT;
    v_new_notnull TEXT;
BEGIN
    -- Resolve parent entity's managed flag
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = OLD.table_name;

    -- --------------------------------------------------
    -- A) Handle field_name rename
    -- --------------------------------------------------
    IF OLD.field_name IS DISTINCT FROM NEW.field_name THEN
        -- Core fields (ctype <> '') cannot be renamed, except the label column
        IF coalesce(OLD.ctype, '') <> '' THEN
            IF OLD.ctype = 'label' THEN
                -- Label column rename is allowed; update entities.label_column to match
                UPDATE entities
                   SET label_column = NEW.field_name
                 WHERE table_name = OLD.table_name
                   AND label_column = OLD.field_name;
                RAISE NOTICE 'Updated entities.label_column from "%" to "%" for table "%"',
                    OLD.field_name, NEW.field_name, OLD.table_name;
            ELSE
                RAISE EXCEPTION 'Cannot rename core system field ${field_name}'
                    USING ERRCODE = '90218',
                          HINT = jsonb_build_object('field_name', OLD.field_name)::text;
            END IF;
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
            v_old_notnull := format('%s_%s_not_null', OLD.table_name, OLD.field_name);
            v_new_notnull := format('%s_%s_not_null', OLD.table_name, NEW.field_name);

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

            -- Rename NOT NULL constraint if it exists. PG18+ stores NOT NULL as a
            -- named pg_constraint row (<table>_<col>_not_null); on PG<=17 no such
            -- row exists, so this EXISTS check is false and the rename is skipped.
            -- Same migration is therefore correct on PG<=17 and PG>=18.
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_notnull
                  AND t.relname = OLD.table_name
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    OLD.table_name, v_old_notnull, v_new_notnull);
                RAISE NOTICE 'Renamed NOT NULL constraint "%" to "%"', v_old_notnull, v_new_notnull;
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
        -- Core field formats cannot be changed (ctype <> '' marks a core column; enforced here too)
        IF coalesce(OLD.ctype, '') <> '' THEN
            RAISE EXCEPTION 'Cannot change format of core system field ${field_name}'
                USING ERRCODE = '90219',
                      HINT = jsonb_build_object('field_name', OLD.field_name)::text;
        END IF;

        -- field_data_type, not format_to_data_type: a reference takes the type
        -- of the key it points at, so text -> reference(permissions) is TEXT to
        -- TEXT and must be allowed, while text -> reference(users) is TEXT to
        -- INTEGER and must not. The format alone cannot tell the two apart.
        v_old_type := field_data_type(OLD.format, OLD."precision", OLD.reference_table);
        v_new_type := field_data_type(NEW.format, NEW."precision", NEW.reference_table);

        IF v_old_type <> v_new_type THEN
            RAISE EXCEPTION
                'Cannot change format of field ${field_name} from ${old_format} to ${new_format} '
                'because it would require changing the column type from ${old_type} to ${new_type}. '
                'Drop and recreate the field instead.'
                USING ERRCODE = '90223',
                      HINT = jsonb_build_object(
                          'field_name', OLD.field_name,
                          'old_format', OLD.format,
                          'new_format', NEW.format,
                          'old_type',   v_old_type,
                          'new_type',   v_new_type)::text;
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

-- Revoke default PUBLIC execute on the new functions
REVOKE EXECUTE ON FUNCTION rename_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rename_dd_reference_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_field_rename_and_format() FROM PUBLIC;
