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
    v_data_type := field_data_type(p_field.format, p_field."precision", p_field.reference_table);

    -- Build nullable clause
    IF is_nullable(p_field.format) THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;

    v_default_clause := coalesce('DEFAULT ' || dd_column_default(p_field.format, p_field.default_value, p_field.input_type, p_field.enum_values, v_data_type), '');

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

            -- A reference to an is_a or has_a entity points at its
            -- <entity>_ext table, as in add_dd_field (0160_dd_functions.sql).
            BEGIN
                EXECUTE format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
                    p_field.table_name, v_fk_name, p_field.field_name,
                    dd_relation(p_field.reference_table), v_ref_id_column, v_on_delete
                );
            EXCEPTION WHEN duplicate_object THEN
                RAISE NOTICE 'FK "%" already exists on "%.%", skipping',
                    v_fk_name, p_field.table_name, p_field.field_name;
            END;

            EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                v_idx_name, p_field.table_name, p_field.field_name);
        END IF;
    END IF;

    -- Only added when the name is free: this path never replaces a constraint that
    -- is already on the table.
    IF p_field.format = 'enum'
       AND NOT dd_constraint_exists(p_field.table_name, format('%s_%s_check', p_field.table_name, p_field.field_name)) THEN
        PERFORM dd_replace_enum_check(p_field, p_field.table_name);
    END IF;

    -- The column was just added, so every row holds its default and nothing needs
    -- reading. This path adopts tables, and existing rows must never abort that.
    IF dd_required_default_ok(p_field) OR NOT dd_relation_has_rows(p_field.table_name) THEN
        PERFORM dd_add_required_check(p_field, p_field.table_name);
    ELSE
        RAISE WARNING 'Field %.% stays unenforced: rows have no value for it',
            p_field.table_name, p_field.field_name;
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
-- HELPER FUNCTION: dd_check_id_field
-- =====================================================
-- Refuses to switch an entity to managed when it already has an id field row
-- whose format is not the one its id_type gives the key (90239). An unmanaged
-- entity gets no generated id row, so whoever registered it wrote one, and an
-- old export may say int32 where the key is now int64. Switching managed on
-- must not rewrite metadata somebody wrote - switching it on and off again has
-- to leave everything as it was - so the difference is reported instead of
-- fixed. Only the format is compared: it is what describes the key's type,
-- while input_type and input_type_rule are presentation the author may choose.
-- A missing row is not a difference; enable_dd_table creates it.
CREATE OR REPLACE FUNCTION dd_check_id_field(p_table_name TEXT, p_id_column TEXT, p_id_type TEXT, p_format TEXT)
RETURNS VOID AS $$
DECLARE
    v_actual TEXT;
BEGIN
    SELECT format INTO v_actual
      FROM fields WHERE table_name = p_table_name AND field_name = p_id_column;
    IF FOUND AND v_actual IS DISTINCT FROM p_format THEN
        RAISE EXCEPTION 'Entity ${table} cannot be managed: its id field ${id_column} has format ${actual_format}, but id_type ${id_type} needs ${expected_format}'
            USING ERRCODE = '90239',
                  HINT = jsonb_build_object(
                      'table', p_table_name,
                      'id_column', p_id_column,
                      'actual_format', v_actual,
                      'id_type', p_id_type,
                      'expected_format', p_format,
                      'hint', 'Change the format of the id field to ${expected_format} while the entity is unmanaged, then switch managed on.')::text;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_check_id_field(TEXT, TEXT, TEXT, TEXT) IS
'Raises 90239 when an entity about to become managed has an id field row whose format differs from the one its id_type gives the key. Called by enable_dd_table before it changes anything.';

-- =====================================================
-- TRIGGER FUNCTION: ENABLE TABLE WHEN managed F→T
-- =====================================================

CREATE OR REPLACE FUNCTION enable_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_field      fields%ROWTYPE;
    v_sequence_name TEXT;
    v_key        RECORD;
    v_skips      JSONB := '{}'::jsonb;
    v_reason     TEXT;
BEGIN
    -- Guard: only proceed when managed transitions FALSE → TRUE
    IF NOT (OLD.managed = FALSE AND NEW.managed = TRUE) THEN
        RETURN NEW;
    END IF;

    SET LOCAL client_min_messages = WARNING;

    -- The refusals come first, before anything is changed: 90234 for id_type
    -- computed, 90239 for an id field row that describes another key type.
    v_key := dd_id_column_ddl(NEW.table_name, NEW.id_column, NEW.id_type);
    PERFORM dd_check_id_field(NEW.table_name, NEW.id_column, NEW.id_type, v_key.id_format);

    -- Which required fields of an existing table must stay unenforced, read here because
    -- the statements below lock the table and these reads can scan all of it. The label
    -- row may not exist yet; the row it will get is required by default, so it is read
    -- as one.
    IF pg_catalog.to_regclass(format('public.%I', NEW.table_name)) IS NOT NULL THEN
        FOR v_field IN
            SELECT f.* FROM fields f
              JOIN information_schema.columns c
                ON c.table_schema = 'public' AND c.table_name = f.table_name AND c.column_name = f.field_name
             WHERE f.table_name = NEW.table_name
        LOOP
            v_reason := dd_required_skip_reason(v_field, NEW.table_name);
            IF v_reason IS NOT NULL THEN
                v_skips := v_skips || jsonb_build_object(v_field.field_name, v_reason);
            END IF;
        END LOOP;

        IF NOT EXISTS (SELECT 1 FROM fields f WHERE f.table_name = NEW.table_name AND f.field_name = NEW.label_column)
           AND EXISTS (SELECT 1 FROM information_schema.columns c
                        WHERE c.table_schema = 'public' AND c.table_name = NEW.table_name AND c.column_name = NEW.label_column) THEN
            v_field := NULL;
            v_field.table_name := NEW.table_name;
            v_field.field_name := NEW.label_column;
            v_field.format := 'text';
            v_field.input_type := 'required';
            v_field.is_pk := FALSE;
            v_field.input_type_rule := '{}'::jsonb;
            v_reason := dd_required_skip_reason(v_field, NEW.table_name);
            IF v_reason IS NOT NULL THEN
                v_skips := v_skips || jsonb_build_object(v_field.field_name, v_reason);
            END IF;
        END IF;
    END IF;

    -- ── Create the physical table if it does not yet exist ──────────────
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = NEW.table_name
    ) THEN
        v_create_sql := format(
            'CREATE TABLE IF NOT EXISTS public.%I (
                %s,
                %I TEXT NOT NULL DEFAULT '''',
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            NEW.table_name, v_key.column_ddl, NEW.label_column
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
            'CREATE TRIGGER %I
                BEFORE UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION common.update_updated_at_column()',
            'update_' || NEW.table_name || '_updated_at', NEW.table_name
        );

        RAISE NOTICE 'Created table "%" (managed changed to true)', NEW.table_name;
    ELSE
        -- Adoption: the table's key has to be the one id_type describes, and
        -- it has to be there already. A missing key column is refused rather
        -- than added by the loop further down, because adding a primary key
        -- to a table that has rows is not something to do as a side effect.
        PERFORM dd_check_id_column(NEW.table_name, NEW.id_column, NEW.id_type);
    END IF;

    PERFORM dd_install_id_triggers(NEW.table_name, NEW.id_column, NEW.id_type, NEW.id_prefix);

    -- ── Secure the table ─────────────────────────────────────────────────
    -- Unconditionally, whatever the table carried before. Becoming managed means
    -- the dictionary owns the table, so it ends up configured the way a table
    -- created managed would be: row-level security on, the four permission
    -- policies from view_permission and edit_permission, the table grant. There
    -- is no half-adopted state where an entity claims a permission model the
    -- table does not enforce.
    --
    -- What makes that safe is a refusal one step earlier, not caution here. A
    -- table whose protection is that the request role cannot write it - the two
    -- audit logs, registered as entities with managed = false - would be
    -- unlocked rather than adopted, because the INSERT and UPDATE policies and
    -- the grant beside them are exactly what it was protected from.
    -- 0200_audit_log.sql refuses the managed flip on those two entities outright,
    -- so they never arrive here; the reasoning is written out there.
    --
    -- Access can widen. A table that carried its own policies keeps them, and
    -- PostgreSQL ORs permissive policies together, so the permission model the
    -- entity declares is added to whatever was there. That is what adoption now
    -- means, and it is why the flip is a decision rather than a setting.
    --
    -- The policy creations are guarded by a pg_policies lookup because
    -- PostgreSQL has no CREATE POLICY IF NOT EXISTS; a policy that already
    -- carries one of the four names keeps its own definition. Predicates use the
    -- (SELECT rbac.has_permission(...)) InitPlan form, see the note in
    -- create_dd_table; test 0445 fails on the bare per-row form.
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', NEW.table_name);

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = NEW.table_name
          AND policyname = NEW.table_name || '_select_policy'
    ) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I
                FOR SELECT TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))',
            NEW.table_name || '_select_policy', NEW.table_name, NEW.view_permission
        );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = NEW.table_name
          AND policyname = NEW.table_name || '_insert_policy'
    ) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I
                FOR INSERT TO semantius_user
                WITH CHECK ((SELECT rbac.has_permission(%L)))',
            NEW.table_name || '_insert_policy', NEW.table_name, NEW.edit_permission
        );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = NEW.table_name
          AND policyname = NEW.table_name || '_update_policy'
    ) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I
                FOR UPDATE TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))
                WITH CHECK ((SELECT rbac.has_permission(%L)))',
            NEW.table_name || '_update_policy', NEW.table_name, NEW.edit_permission, NEW.edit_permission
        );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = NEW.table_name
          AND policyname = NEW.table_name || '_delete_policy'
    ) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I
                FOR DELETE TO semantius_user
                USING ((SELECT rbac.has_permission(%L)))',
            NEW.table_name || '_delete_policy', NEW.table_name, NEW.edit_permission
        );
    END IF;

    EXECUTE format(
        'GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO semantius_user',
        NEW.table_name
    );

    -- ── Insert core field records if they were never created ─────────────
    -- create_dd_table inserts these when managed=true on INSERT, but when
    -- an entity was created with managed=false those records do not exist.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, input_type_rule)
    SELECT NEW.table_name, NEW.id_column, 'Id', v_key.id_format, TRUE, 10, v_key.input_type, 'default', 'id', FALSE, '', '', v_key.input_type_rule
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.id_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.label_column, NEW.label_column_label, 'text', FALSE, 20, 'required', 'default', 'label', TRUE, '', ''
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
        ELSE
            -- A column the table already had: only what is missing gets added. A
            -- constraint already on the table is never dropped or changed, whoever wrote
            -- it, because PostgreSQL's automatic name for an inline CHECK on a column is
            -- the very name an enum's check uses here.
            IF v_field.format = 'enum'
               AND NOT dd_constraint_exists(NEW.table_name, format('%s_%s_check', NEW.table_name, v_field.field_name)) THEN
                PERFORM dd_replace_enum_check(v_field, NEW.table_name);
            END IF;
            IF v_skips ? v_field.field_name THEN
                RAISE WARNING 'Field %.% stays unenforced: %',
                    NEW.table_name, v_field.field_name, v_skips ->> v_field.field_name;
            ELSE
                PERFORM dd_add_required_check(v_field, NEW.table_name);
            END IF;
        END IF;
    END LOOP;

    -- The id column's sequence, granted here rather than beside the table grant
    -- above because on the hand-made path the column may only have been added by
    -- the loop above, and pg_get_serial_sequence raises on a column that does
    -- not exist. A table whose key is not a serial has no sequence and needs no
    -- grant. The table grant is unconditional now, so this one is too: the
    -- INSERT it completes has already been granted, and a serial key the request
    -- role cannot advance would refuse every insert it is allowed to make.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = NEW.table_name
          AND column_name  = NEW.id_column
    ) THEN
        v_sequence_name := pg_get_serial_sequence(
            format('public.%I', NEW.table_name), NEW.id_column);
        IF v_sequence_name IS NOT NULL THEN
            EXECUTE format(
                'GRANT USAGE, SELECT ON SEQUENCE %s TO semantius_user',
                v_sequence_name
            );
        END IF;
    END IF;

    -- Update searchable flag in case any searchable fields exist
    UPDATE entities
    SET searchable = dd_entity_searchable(NEW.table_name)
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
creates the physical table and its updated_at trigger if it does not already
exist, then secures it whatever it carried before - RLS enabled, the four permission
policies created if absent, the request-role table and sequence grants issued -
then adds any columns that were defined as field records while the table was
unmanaged. An adopted table ends up configured as a table created managed would
be; a table that carried policies of its own keeps them alongside, so access can
widen, which is why 0200_audit_log.sql refuses the managed flip outright for the
two entities whose protection is that the request role cannot write them. Finally
calls build_select_rule_policy() directly, so an entity carrying a select_rule
gets the per-row predicate rather than the permission-only policies installed
above. Calling it here rather than leaving it to the manage_select_rule_policy
AFTER-trigger is deliberate: two AFTER triggers on the same table fire in name
order, and if that one ran first the toggle would leave a select_rule entity
gated by view_permission alone.';

-- Apply trigger AFTER UPDATE on entities (only when managed changes F→T)
CREATE OR REPLACE TRIGGER enable_table_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.managed = FALSE AND NEW.managed = TRUE)
    EXECUTE FUNCTION enable_dd_table();

COMMENT ON TRIGGER enable_table_trigger ON entities IS
'Creates the physical table and adds missing columns when managed changes from false to true.';

-- users.external_id is seeded unique_value in 0150_dd_bootstrap.once.sql, before the dictionary triggers
-- exist, so the partial index they would build for it is built here.
CREATE UNIQUE INDEX IF NOT EXISTS users_external_id_unique ON users(external_id) WHERE external_id IS NOT NULL AND external_id != '';

-- =====================================================
-- REQUIRED CHECKS OF EXISTING FIELDS
-- =====================================================
-- A required check is created when a field is added or changed, so a field that was
-- already required never gets one that way, and the core tables' fields are seeded
-- before the triggers exist.
--
-- This is not a migration file because a migration file is one transaction in every
-- runner: its locks would pile up across all tables until it commits, and a live
-- database has no maintenance window to absorb that. Each call handles one table in
-- the caller's one transaction, and every runner calls it in a loop after the migration
-- files: runMigrations in packages/core/src/migrate.ts and the migrate() procedure
-- generated by packages/cli/commands/extension.ts.
--
-- It only adds what is missing, so it needs no ledger: a table skipped today because
-- it was busy, or a field skipped because its rows have missing values, is picked up
-- by a later migrate. All reads happen before the first statement that locks the
-- table. p_table is the table this call handled, to pass back as p_after, and NULL
-- when none are left.
CREATE OR REPLACE FUNCTION dd_install_missing_checks(p_after TEXT, OUT p_table TEXT, OUT p_skipped JSONB)
AS $$
DECLARE
    v_rel      TEXT;
    v_fields   fields[];
    v_field    fields;
    v_reason   TEXT;
    v_add      fields[] := ARRAY[]::fields[];
    v_defaults TEXT[]   := ARRAY[]::TEXT[];
    v_col      TEXT;
BEGIN
    p_skipped := '[]'::jsonb;

    SELECT e.table_name, dd_relation(e.table_name, e.id_type) INTO p_table, v_rel
      FROM entities e
     WHERE e.managed
       AND (p_after IS NULL OR e.table_name COLLATE "C" > p_after COLLATE "C")
     ORDER BY e.table_name COLLATE "C"
     LIMIT 1;

    IF p_table IS NULL OR pg_catalog.to_regclass(format('public.%I', v_rel)) IS NULL THEN
        RETURN;
    END IF;

    -- Read into an array before anything changes: this table may be fields itself, and
    -- PostgreSQL refuses ALTER TABLE while a loop in this session is still reading it.
    v_fields := ARRAY(
        SELECT f FROM fields f
          JOIN information_schema.columns c
            ON c.table_schema = 'public' AND c.table_name = v_rel AND c.column_name = f.field_name
         WHERE f.table_name = p_table AND f.input_type = 'required');

    FOREACH v_field IN ARRAY v_fields LOOP
        IF dd_required_test(v_field) IS NOT NULL
           AND NOT dd_constraint_exists(v_rel, format('%s_%s_assert', v_rel, v_field.field_name)) THEN
            v_reason := dd_required_skip_reason(v_field, v_rel);
            IF v_reason IS NULL THEN
                v_add := v_add || v_field;
            ELSE
                RAISE WARNING 'Field %.% stays unenforced: %', p_table, v_field.field_name, v_reason;
                p_skipped := p_skipped || jsonb_build_object('table', p_table, 'field', v_field.field_name, 'reason', v_reason);
            END IF;
        END IF;

        -- A required enum without an explicit default used to get its first value as the
        -- column default, and must now refuse a write that leaves it out.
        IF v_field.format = 'enum'
           AND coalesce(trim(v_field.default_value), '') = ''
           AND EXISTS (SELECT 1
                         FROM pg_catalog.pg_attribute a
                         JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                        WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', v_rel))
                          AND a.attname = v_field.field_name
                          AND pg_catalog.pg_get_expr(d.adbin, d.adrelid) <> '''''::text') THEN
            v_defaults := v_defaults || v_field.field_name;
        END IF;
    END LOOP;

    IF cardinality(v_add) = 0 AND cardinality(v_defaults) = 0 THEN
        RETURN;
    END IF;

    -- The default of an is_a or has_a view and write routine is a copy, so a changed one
    -- rebuilds the family. 90256 means an object someone else built depends on that view.
    BEGIN
        FOREACH v_field IN ARRAY v_add LOOP
            PERFORM dd_add_required_check(v_field, v_rel);
        END LOOP;
        FOREACH v_col IN ARRAY v_defaults LOOP
            EXECUTE format('ALTER TABLE %I ALTER COLUMN %I SET DEFAULT ''''', v_rel, v_col);
        END LOOP;
        IF cardinality(v_defaults) > 0 THEN
            PERFORM dd_refresh_family(ARRAY[p_table]);
        END IF;
    EXCEPTION
        WHEN lock_not_available OR SQLSTATE '90256' THEN
            RAISE WARNING 'Table % skipped until the next migrate: %', p_table, SQLERRM;
            p_skipped := p_skipped || jsonb_build_object('table', p_table, 'reason', SQLERRM);
    END;
END;
$$ LANGUAGE plpgsql SET lock_timeout = '2s' SET search_path = public;

COMMENT ON FUNCTION dd_install_missing_checks(TEXT) IS
'Adds the missing required checks of one table, the next managed entity after p_after, and resets the column default of its required enums without an explicit default. Reads first, locks for a moment, and skips what must wait, reporting it in p_skipped. Called in a loop by the migration runners, one transaction per table.';

REVOKE EXECUTE ON FUNCTION dd_install_missing_checks(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_field_ddl(fields) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enable_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_check_id_field(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

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
-- fallback heuristic recognizes a pure pairing table — ≥2 parent legs and every non-leg field is an
-- id/label/audit column (recognized audit names + ctype='audit'). A status/rating/note payload
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
    v_base        TEXT;
    v_id_col      TEXT;
    r             RECORD;
BEGIN
    -- Skip when the entity metadata or the physical table is absent, which is
    -- what a drop or a cascade leaves behind mid-statement. Being unmanaged is
    -- not a reason to skip: an unmanaged entity with a table gets its label
    -- companions like any other.
    IF NOT EXISTS (SELECT 1 FROM entities WHERE table_name = p_table_name) THEN
        RETURN;
    END IF;
    v_rowtype := format('public.%I', p_table_name);
    IF to_regclass(v_rowtype) IS NULL THEN
        RETURN;
    END IF;

    SELECT label_column, NULLIF(label_parent, ''), id_refentity, id_column
      INTO v_label_col, v_spine, v_base, v_id_col
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

    IF v_base IS NOT NULL THEN
        -- An is_a or has_a entity (the row type is its view): a record is the
        -- record of its base, so its composed label is the base's, which in
        -- turn is its root's.
        IF to_regclass(format('public.%I', v_base)) IS NOT NULL THEN
            v_body := format(
                'SELECT (SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I)',
                v_base, v_id_col, v_id_col);
        ELSE
            v_body := format('SELECT %s', v_local);
        END IF;

    ELSIF v_is_junction THEN
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
    -- For an is_a or has_a entity these are the reference fields of the whole
    -- record, inherited ones included, since its view shows them all.
    FOR r IN
        SELECT f.field_name, f.reference_table
        FROM dd_family_fields(p_table_name) WITH ORDINALITY AS f
        WHERE dd_is_fk_format(f.format) AND f.reference_table <> ''
        ORDER BY f.ordinality
    LOOP
        SELECT id_column INTO v_parent_id FROM entities WHERE table_name = r.reference_table;
        CONTINUE WHEN v_parent_id IS NULL;
        CONTINUE WHEN to_regclass(format('public.%I', r.reference_table)) IS NULL;
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=p_table_name AND column_name=r.field_name);
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=r.reference_table AND column_name=v_parent_id);
        -- Collision-aware: if a REAL column already owns the <fk>_label name (e.g. a denormalized
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
functions are SECURITY INVOKER so composed labels respect each caller''s row-level read permissions.
For an is_a or has_a entity they are functions of its view: _label is its base''s composed label, and
every reference field of the record gets its <fk>_label. The family refresh calls it for those.';

-- =====================================================
-- §9 RESERVED FIELD-NAME NAMESPACE
-- =====================================================
-- Only the "_" prefix is reserved (protects the generated _label column and the system "_*"
-- namespace). The "_label" SUFFIX is NOT reserved: real columns ending in _label (e.g. a
-- denormalized customer_label, or even a deliberate <fk>_label) are common and allowed. A real
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
        RAISE EXCEPTION 'Field name ${field_name} is reserved: names starting with "_" are reserved for generated/system columns (e.g. _label)'
            USING ERRCODE = '90224',
                  HINT = jsonb_build_object('field_name', NEW.field_name)::text;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION reserve_field_namespace() IS
'Trigger function that rejects user-created field names beginning with "_" (reserved for generated/system columns such as _label). Privileged BYPASSRLS roles are exempt.';

CREATE OR REPLACE TRIGGER fields_reserve_namespace_trigger
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
        RAISE EXCEPTION 'label_parent cannot be set on junction entity ${table}'
            USING ERRCODE = '90225',
                  HINT = jsonb_build_object('table', NEW.table_name)::text;
    END IF;

    SELECT format, reference_table INTO v_fmt, v_ref
      FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_parent;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'label_parent ${label_parent} is not a field of entity ${table}'
            USING ERRCODE = '90226',
                  HINT = jsonb_build_object('label_parent', NEW.label_parent,
                                            'table', NEW.table_name)::text;
    END IF;

    IF NOT dd_is_fk_format(v_fmt) OR COALESCE(v_ref, '') = '' THEN
        RAISE EXCEPTION 'label_parent ${label_parent} on ${table} must name a reference/parent field'
            USING ERRCODE = '90227',
                  HINT = jsonb_build_object('label_parent', NEW.label_parent,
                                            'table', NEW.table_name)::text;
    END IF;

    IF v_ref = NEW.table_name THEN
        RAISE EXCEPTION 'label_parent ${label_parent} must not be self-referential (the identity spine must be acyclic)'
            USING ERRCODE = '90228',
                  HINT = jsonb_build_object('label_parent', NEW.label_parent)::text;
    END IF;

    IF dd_is_junction(v_ref) THEN
        RAISE EXCEPTION 'label_parent ${label_parent} must not target junction entity ${table}'
            USING ERRCODE = '90229',
                  HINT = jsonb_build_object('label_parent', NEW.label_parent, 'table', v_ref)::text;
    END IF;

    -- Walk the committed spine chain from the target; returning to this entity is a cycle.
    v_cur := v_ref;
    WHILE COALESCE(v_cur, '') <> '' AND v_hops < 64 LOOP
        IF v_cur = NEW.table_name THEN
            RAISE EXCEPTION 'label_parent on ${table} via ${label_parent} would create a cycle in the identity spine'
                USING ERRCODE = '90230',
                      HINT = jsonb_build_object('table', NEW.table_name,
                                                'label_parent', NEW.label_parent)::text;
        END IF;
        v_cur := dd_spine_parent(v_cur);
        v_hops := v_hops + 1;
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validate_label_parent() IS
'Trigger function validating an entity''s label_parent: it must name a reference/parent field of the entity, must not self-reference, and must not introduce a cycle in the identity spine.';

CREATE OR REPLACE TRIGGER validate_label_parent_trigger
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
    -- Skip the rebuild when the new field cannot change a generated body: it
    -- emits DDL per reference field, on every field insert. Miss a case and
    -- nothing raises - a stale <fk>_label keeps answering with the old body.
    -- The parent-leg count is dd_is_junction(), which reads every field.
    -- Pinned by 0670_test_composed_labels.sql.
    IF TG_OP = 'INSERT' AND NOT (
            dd_is_fk_format(NEW.format)
         OR EXISTS (SELECT 1 FROM entities e
                     WHERE e.table_name = NEW.table_name
                       AND (e.label_column = NEW.field_name
                         OR NULLIF(e.label_parent, '') = NEW.field_name))
         OR (SELECT count(*) FROM fields f
              WHERE f.table_name = NEW.table_name
                AND f.format = 'parent') >= 2
         OR EXISTS (SELECT 1 FROM fields f
                     WHERE f.table_name = NEW.table_name
                       AND dd_is_fk_format(f.format)
                       AND f.reference_table <> ''
                       AND f.field_name || '_label' = NEW.field_name))
    THEN
        RETURN NULL;
    END IF;

    PERFORM rebuild_entity_label_functions(COALESCE(NEW.table_name, OLD.table_name));
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION dd_label_fn_sync_entity() IS
'Trigger function that regenerates the entity''s _label / <fk>_label computed-column functions after an entities row changes, by calling rebuild_entity_label_functions.';
COMMENT ON FUNCTION dd_label_fn_sync_field() IS
'Trigger function that regenerates the owning entity''s _label / <fk>_label computed-column functions after a fields row changes, by calling rebuild_entity_label_functions. An INSERT that cannot change a generated body skips the rebuild.';

CREATE OR REPLACE TRIGGER zzz_label_fn_entity_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_entity();

CREATE OR REPLACE TRIGGER zzz_label_fn_entity_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name   IS DISTINCT FROM NEW.table_name
       OR OLD.label_parent IS DISTINCT FROM NEW.label_parent
       OR OLD.entity_type  IS DISTINCT FROM NEW.entity_type
       OR OLD.label_column IS DISTINCT FROM NEW.label_column
       OR OLD.managed      IS DISTINCT FROM NEW.managed)
    EXECUTE FUNCTION dd_label_fn_sync_entity();

CREATE OR REPLACE TRIGGER zzz_label_fn_field_insert_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

CREATE OR REPLACE TRIGGER zzz_label_fn_field_delete_trigger
    AFTER DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

CREATE OR REPLACE TRIGGER zzz_label_fn_field_update_trigger
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
