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
    v_name      TEXT;
    -- The physical relation and the names derived from it: <entity>_ext for
    -- an is_a or has_a entity, whose view carries the entity name.
    v_old_rel   TEXT := dd_relation(OLD.table_name, OLD.id_type);
    v_new_rel   TEXT := dd_relation(NEW.table_name, NEW.id_type);
    v_derived   BOOLEAN := NEW.id_type IN ('is_a', 'has_a');
    v_trg_old   NAME;
    v_trg_new   NAME;
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Mark that a cascade rename is in progress (transaction-local)
        PERFORM set_config('dd.table_rename', OLD.table_name || ':' || NEW.table_name, TRUE);

        -- Rename the physical table and all associated named objects when managed
        IF OLD.managed THEN
            -- A derived entity needs both of its names free, as when it was
            -- created (90250). A plain entity's rename meets an occupied name
            -- in ALTER TABLE below.
            IF v_derived THEN
                FOREACH v_name IN ARRAY ARRAY[NEW.table_name, v_new_rel] LOOP
                    IF to_regclass(format('public.%I', v_name)) IS NOT NULL THEN
                        RAISE EXCEPTION 'Table name ${relation} is already in use'
                            USING ERRCODE = '90250',
                                  HINT = jsonb_build_object('relation', v_name)::text;
                    END IF;
                END LOOP;
            END IF;

            EXECUTE format('ALTER TABLE %I RENAME TO %I', v_old_rel, v_new_rel);
            RAISE NOTICE 'Renamed table "%" to "%"', v_old_rel, v_new_rel;

            -- The view follows under its new name; the family refresh after
            -- this statement (zz_family_refresh_rename_trigger) rebuilds it and
            -- every routine whose text names the old one.
            IF v_derived AND to_regclass(format('public.%I', OLD.table_name)) IS NOT NULL THEN
                EXECUTE format('ALTER VIEW %I RENAME TO %I', OLD.table_name, NEW.table_name);
            END IF;

            -- The triggers named after the table: update_<table>_updated_at and
            -- the order column's a_auto_order_<table> (0230_entity_order_column.sql).
            -- A later order_column change finds the latter by the entity's name;
            -- left under the old one, it would stay behind, still assigning the
            -- dropped column, and fail every insert. The names are compared as
            -- type name, which truncates them to 63 bytes as CREATE TRIGGER did,
            -- so a long table name still finds its trigger. The RACI triggers
            -- follow a rename by their own trigger (raci_entity_renamed,
            -- 0370_raci.sql).
            FOR v_trg_old, v_trg_new IN
                SELECT t.tgname, x.new_name
                  FROM (VALUES (('update_' || v_old_rel || '_updated_at')::name, ('update_' || v_new_rel || '_updated_at')::name),
                               (('a_auto_order_' || v_old_rel)::name, ('a_auto_order_' || v_new_rel)::name)) AS x(old_name, new_name)
                  JOIN pg_trigger t ON t.tgname = x.old_name
                                   AND t.tgrelid = to_regclass(format('public.%I', v_new_rel))
                 WHERE x.old_name <> x.new_name
            LOOP
                EXECUTE format('ALTER TRIGGER %I ON %I RENAME TO %I', v_trg_old, v_new_rel, v_trg_new);
            END LOOP;

            -- Rename RLS policies (name patterns: <table>_select/insert/update/delete_policy)
            FOREACH v_suffix IN ARRAY ARRAY['select_policy', 'insert_policy', 'update_policy', 'delete_policy']
            LOOP
                IF EXISTS (
                    SELECT 1 FROM pg_policy p
                    JOIN pg_class c ON p.polrelid = c.oid
                    WHERE c.relname = v_new_rel
                      AND c.relnamespace = 'public'::regnamespace
                      AND p.polname = v_old_rel || '_' || v_suffix
                ) THEN
                    EXECUTE format(
                        'ALTER POLICY %I ON %I RENAME TO %I',
                        v_old_rel || '_' || v_suffix,
                        v_new_rel,
                        v_new_rel || '_' || v_suffix
                    );
                END IF;
            END LOOP;

            -- Rename GIN search_vector index if it exists
            -- (name pattern: <table>_search_vector_idx)
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = v_new_rel
                  AND indexname = v_old_rel || '_search_vector_idx'
            ) THEN
                EXECUTE format(
                    'ALTER INDEX %I RENAME TO %I',
                    v_old_rel || '_search_vector_idx',
                    v_new_rel || '_search_vector_idx'
                );
            END IF;

            -- Rename id sequence (<table>_<id_col>_seq): the identity
            -- sequence, or the counter of a typenumber key or of an is_a
            -- subtype in a typenumber family, which is named and owned the
            -- same way (dd_install_id_triggers, 0160_dd_functions.sql).
            IF EXISTS (
                SELECT 1 FROM pg_class c
                WHERE c.relname = v_old_rel || '_' || OLD.id_column || '_seq'
                  AND c.relnamespace = 'public'::regnamespace
                  AND c.relkind = 'S'
                  -- The table's own: table a with key b_c and table a_b with
                  -- key c spell one sequence name.
                  AND EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                               WHERE d.objid = c.oid
                                 AND d.refobjid = pg_catalog.to_regclass(format('public.%I', v_new_rel))
                                 AND d.deptype IN ('a', 'i'))
            ) THEN
                EXECUTE format(
                    'ALTER SEQUENCE %I RENAME TO %I',
                    v_old_rel || '_' || OLD.id_column || '_seq',
                    v_new_rel || '_' || NEW.id_column || '_seq'
                );
            END IF;

            -- Rename primary key constraint (<table>_pkey)
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_rel || '_pkey'
                  AND t.relname = v_new_rel
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.contype = 'p'
            ) THEN
                EXECUTE format(
                    'ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_new_rel,
                    v_old_rel || '_pkey',
                    v_new_rel || '_pkey'
                );
            END IF;

            -- Rename all FK constraints named <old_table>_<field>_fkey (the key
            -- of <entity>_ext included: <entity>_ext_id_fkey)
            FOR v_old_name IN
                SELECT c.conname::text
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = v_new_rel
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (replace(v_old_rel, '_', '\_') || '\_%\_fkey') ESCAPE '\'
                  AND c.contype = 'f'
            LOOP
                v_new_name := v_new_rel || substring(v_old_name FROM length(v_old_rel) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_new_rel, v_old_name, v_new_name);
            END LOOP;

            -- Rename all FK indexes named idx_<old_table>_<field>
            FOR v_old_name IN
                SELECT indexname::text
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = v_new_rel
                  AND indexname LIKE ('idx\_' || replace(v_old_rel, '_', '\_') || '\_%') ESCAPE '\'
            LOOP
                v_new_name := 'idx_' || v_new_rel || substring(v_old_name FROM length('idx_' || v_old_rel) + 1);
                -- An index name is unique in the schema, and the new table
                -- name can spell, with this field, the name the index of
                -- another table carries (dd_index_name_free). The field is
                -- what follows idx_<table>_ in the name.
                PERFORM dd_index_name_free(NEW.table_name, v_new_rel,
                                           substring(v_old_name FROM length('idx_' || v_old_rel) + 2), v_new_name);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

            -- Rename all check constraints named <old_table>_<field>_check
            FOR v_old_name IN
                SELECT c.conname::text
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = v_new_rel
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (replace(v_old_rel, '_', '\_') || '\_%\_check') ESCAPE '\'
                  AND c.contype = 'c'
            LOOP
                v_new_name := v_new_rel || substring(v_old_name FROM length(v_old_rel) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_new_rel, v_old_name, v_new_name);
            END LOOP;

            -- Rename all required checks named <old_table>_<field>_assert. Only the name
            -- changes: the check finds its table through tableoid, so renaming an entity
            -- needs no rebuild.
            FOR v_old_name IN
                SELECT c.conname::text
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = v_new_rel
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (replace(v_old_rel, '_', '\_') || '\_%\_assert') ESCAPE '\'
                  AND c.contype = 'c'
            LOOP
                v_new_name := v_new_rel || substring(v_old_name FROM length(v_old_rel) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_new_rel, v_old_name, v_new_name);
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
                WHERE t.relname = v_new_rel
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (replace(v_old_rel, '_', '\_') || '\_%\_not\_null') ESCAPE '\'
            LOOP
                v_new_name := v_new_rel || substring(v_old_name FROM length(v_old_rel) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_new_rel, v_old_name, v_new_name);
            END LOOP;

            -- Rename all unique indexes named <old_table>_<field>_unique
            FOR v_old_name IN
                SELECT indexname::text
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = v_new_rel
                  AND indexname LIKE (replace(v_old_rel, '_', '\_') || '\_%\_unique') ESCAPE '\'
            LOOP
                v_new_name := v_new_rel || substring(v_old_name FROM length(v_old_rel) + 1);
                -- As for the reference indexes above; the field stands
                -- between <table>_ and _unique.
                PERFORM dd_index_name_free(
                    NEW.table_name, v_new_rel,
                    substring(v_old_name FROM length(v_old_rel) + 2
                                         FOR length(v_old_name) - length(v_old_rel) - 1 - length('_unique')),
                    v_new_name);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

            -- Drop old compute_validate function (CASCADE drops its trigger too),
            -- and the rule function it wraps. The AFTER trigger
            -- manage_record_logic_trigger rebuilds both under the new name.
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE',
                'compute_validate_' || OLD.table_name);
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, jsonb, jsonb)',
                'record_rules_' || OLD.table_name);

            -- Drop both select_rule overloads (CASCADE drops the policies that use
            -- them). The AFTER trigger manage_select_rule_policy rebuilds them under
            -- the new name. The signatures pair the OLD function name with the NEW
            -- row type on purpose: the physical table was renamed a few lines above,
            -- so the composite type already answers to the new relation name while
            -- the functions still carry the old name.
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE',
                'select_rule_' || OLD.table_name, v_new_rel);
            EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE',
                'select_rule_' || OLD.table_name, v_new_rel);
            -- The row move function names the table in its body. CASCADE drops
            -- the zz_row_move trigger that runs it; manage_select_rule_policy
            -- generates both again under the new name.
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE',
                'row_move_mark_' || OLD.table_name);

            -- The family routines generated under the old name: the write
            -- routine (typed by the view, which already answers to the new
            -- name), the view's trigger function and a root's dispatch trigger
            -- function, with the triggers that call them. The family refresh
            -- after this statement generates them under the new name.
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, public.%I, public.%I, boolean)',
                'record_write_' || OLD.table_name, NEW.table_name, NEW.table_name);
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE',
                'view_write_' || OLD.table_name);
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE',
                'is_a_dispatch_' || OLD.table_name);

            -- Rename queue event triggers on the entity table.
            -- Pattern: queue_<queue_name>_<event>_on_<old_table>, one per DML
            -- event the mapping covers.
            FOR v_old_name IN
                SELECT t.tgname::text
                FROM pg_trigger t
                JOIN pg_class c ON t.tgrelid = c.oid
                WHERE c.relname = NEW.table_name
                  AND c.relnamespace = 'public'::regnamespace
                  AND t.tgname LIKE ('%\_on\_' || replace(OLD.table_name, '_', '\_')) ESCAPE '\'
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION rename_dd_table IS
'BEFORE UPDATE trigger on entities: renames the physical table and ALL associated named
objects when table_name changes: updated_at trigger, order column trigger, RLS policies, GIN search_vector
index, id sequence, primary key constraint, FK constraints, FK indexes, check constraints,
NOT NULL constraints (PG18+ named pg_constraint rows; no-op on PG<=17),
unique indexes, compute_validate and rule functions, select_rule and row move functions, and queue event triggers.
For an is_a or has_a entity the physical table is <entity>_ext and its view is renamed with it;
the generated family routines are dropped under the old name for the family refresh to rebuild.
Sets a transaction-local session variable so the cascaded update to fields.table_name is
allowed by update_dd_field without raising an exception.';

-- Apply trigger BEFORE UPDATE on entities (only when table_name changes)
CREATE OR REPLACE TRIGGER rename_table_trigger
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION rename_dd_reference_tables IS
'AFTER UPDATE trigger on entities: when table_name changes, updates fields.reference_table
in all fields across all tables that referenced the old name.  Cascades through
update_dd_field() to rebuild the physical FK constraint on the referencing table.';

CREATE OR REPLACE TRIGGER rename_reference_tables_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_reference_tables();

COMMENT ON TRIGGER rename_reference_tables_trigger ON entities IS
'Updates fields.reference_table and rebuilds FK constraints when entities.table_name is renamed';

-- =====================================================
-- STEP 1c: TRIGGER FUNCTION: CASCADE set_record entity refs ON entities.table_name UPDATE
-- =====================================================
-- Fires AFTER UPDATE on entities when table_name changes, and gives the rules
-- of every entity the new name wherever a set_record names the old one.
--
-- Only the second argument of a set_record names an entity. The same text can
-- stand in a rule where it is no table: a value the rule compares or joins,
-- the name a let binds, the message of a validation rule. So the rule is
-- walked the way the evaluator reads it and that one argument is replaced; a
-- replace over the rule's text would rename all of them.

-- p_rule with p_new in place of p_old as the entity of every set_record. An
-- array is a list of rules and an object with one key an operation whose
-- arguments are rules; anything else is a value and comes back as it is. The
-- name of a let and the name of a set_record are names, not rules.
CREATE OR REPLACE FUNCTION jl_rename_set_record_entity(p_rule JSONB, p_old TEXT, p_new TEXT)
RETURNS JSONB AS $$
DECLARE
    v_op    TEXT;
    v_args  JSONB;
    v_out   JSONB := '[]'::jsonb;
    v_arg   JSONB;
    v_list  BOOLEAN;
BEGIN
    IF p_rule IS NULL THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_rule) = 'array' THEN
        FOR i IN 0 .. jsonb_array_length(p_rule) - 1 LOOP
            v_out := v_out || jsonb_build_array(jl_rename_set_record_entity(p_rule -> i, p_old, p_new));
        END LOOP;
        RETURN v_out;
    END IF;

    IF NOT jl_is_operation(p_rule) THEN
        RETURN p_rule;
    END IF;

    v_op := jsonb_path_query_first(p_rule, '$.keyvalue().key') #>> '{}';
    v_args := p_rule -> v_op;
    v_list := jsonb_typeof(v_args) = 'array';
    IF NOT v_list THEN
        v_args := jsonb_build_array(v_args);
    END IF;

    FOR i IN 0 .. jsonb_array_length(v_args) - 1 LOOP
        v_arg := v_args -> i;
        IF v_op = 'set_record' AND i = 1 THEN
            IF jsonb_typeof(v_arg) = 'string' AND v_arg #>> '{}' = p_old THEN
                v_arg := to_jsonb(p_new);
            END IF;
        ELSIF NOT (i = 0 AND v_op IN ('let', 'set_record')) THEN
            v_arg := jl_rename_set_record_entity(v_arg, p_old, p_new);
        END IF;
        v_out := v_out || jsonb_build_array(v_arg);
    END LOOP;

    RETURN jsonb_build_object(v_op, CASE WHEN v_list THEN v_out ELSE v_out -> 0 END);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION jl_rename_set_record_entity(JSONB, TEXT, TEXT) IS
'A JsonLogic rule with p_new in place of p_old as the entity argument of every set_record in it, at any depth. Nothing else in the rule is changed: a text, a let name or a var equal to p_old stays.';

REVOKE EXECUTE ON FUNCTION jl_rename_set_record_entity(JSONB, TEXT, TEXT) FROM PUBLIC;

-- The list of rules of an entity, computed_fields or validation_rules, with
-- the "jsonlogic" of every entry rewritten. An entry that is no object, or has
-- no rule, stays as it is, and so does everything else in an entry.
CREATE OR REPLACE FUNCTION jl_rename_set_record_entities(p_rules JSONB, p_old TEXT, p_new TEXT)
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(
               CASE WHEN jsonb_typeof(t.item) = 'object' AND t.item ? 'jsonlogic'
                    THEN jsonb_set(t.item, '{jsonlogic}',
                                   jl_rename_set_record_entity(t.item -> 'jsonlogic', p_old, p_new))
                    ELSE t.item END
               ORDER BY t.ord), '[]'::jsonb)
      FROM jsonb_array_elements(p_rules) WITH ORDINALITY AS t(item, ord);
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION jl_rename_set_record_entities(JSONB, TEXT, TEXT) IS
'A list of computed fields or validation rules with jl_rename_set_record_entity applied to the jsonlogic of every entry.';

REVOKE EXECUTE ON FUNCTION jl_rename_set_record_entities(JSONB, TEXT, TEXT) FROM PUBLIC;

-- The two helpers are new objects of this file, and on an upgrade the trigger
-- function below already runs as semantius_owner, while they stay owned by
-- the installer until 9900_owner_hardening.sql runs last.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION
            jl_rename_set_record_entity(JSONB, TEXT, TEXT),
            jl_rename_set_record_entities(JSONB, TEXT, TEXT)
        TO semantius_owner;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION rename_dd_jsonlogic_refs()
RETURNS TRIGGER AS $$
DECLARE
    -- The name as it stands in the text of a rule. It only narrows the rows
    -- the rewrite visits; the rewrite itself looks at the argument.
    v_old_quoted TEXT := to_jsonb(OLD.table_name)::text;
BEGIN
    UPDATE entities
    SET computed_fields = jl_rename_set_record_entities(computed_fields, OLD.table_name, NEW.table_name)
    WHERE jsonb_typeof(computed_fields) = 'array'
      AND position('set_record' IN computed_fields::text) > 0
      AND position(v_old_quoted IN computed_fields::text) > 0;

    UPDATE entities
    SET validation_rules = jl_rename_set_record_entities(validation_rules, OLD.table_name, NEW.table_name)
    WHERE jsonb_typeof(validation_rules) = 'array'
      AND position('set_record' IN validation_rules::text) > 0
      AND position(v_old_quoted IN validation_rules::text) > 0;

    UPDATE entities
    SET select_rule = jl_rename_set_record_entity(select_rule, OLD.table_name, NEW.table_name)
    WHERE position('set_record' IN select_rule::text) > 0
      AND position(v_old_quoted IN select_rule::text) > 0;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION rename_dd_jsonlogic_refs IS
'AFTER UPDATE trigger on entities: when table_name changes, gives every set_record that names the
old table the new name, in the computed_fields, validation_rules and select_rule of ALL entities.
Only the entity argument of a set_record is rewritten.';

REVOKE EXECUTE ON FUNCTION rename_dd_jsonlogic_refs() FROM PUBLIC;

CREATE OR REPLACE TRIGGER rename_jsonlogic_refs_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_jsonlogic_refs();

COMMENT ON TRIGGER rename_jsonlogic_refs_trigger ON entities IS
'Updates set_record entity name references in JsonLogic rules when entities.table_name is renamed';

-- =====================================================
-- STEP 1d: TRIGGER FUNCTION: REWRITE stored record references ON entities.table_name UPDATE
-- =====================================================
-- A record reference (<table_name>:<key>, 0160_dd_functions.sql) carries the
-- name of the record's entity, so a rename rewrites every stored reference
-- into the renamed entity: the attached_to columns (ctype attached_to) of the
-- attachable entities and their link tables, matched by prefix, and
-- user_bookmarks.entity_name, which holds the table part on its own. Copies
-- outside the database - webhook payloads, integrations - keep the old name.
--
-- The rewrite is no edit of those records, so it runs past their triggers:
-- the rules of the entity (a bookmark's owner rule would run as the one
-- renaming), the attach step (which keeps attached_to as it is on every
-- update), updated_at, the audit log and the queues. dd_backfill_mute
-- (0210_computed_validation.sql) switches every plainly enabled one of the
-- rewritten relation off with ALTER TABLE rather than through a setting a
-- client could write; the lock it takes holds that table's writers back until
-- the rename commits. A table with no reference to rewrite is not locked at
-- all.
CREATE OR REPLACE FUNCTION rename_dd_record_refs()
RETURNS TRIGGER AS $$
DECLARE
    v_undo  TEXT[];
    v_stmt  TEXT;
    v_found BOOLEAN;
    r       RECORD;
BEGIN
    FOR r IN
        SELECT e.table_name AS entity, dd_relation(e.table_name, e.id_type) AS rel,
               format('%1$I = %2$L || substr(%1$I, %3$s)', f.field_name, NEW.table_name,
                      length(OLD.table_name) + 1) AS set_clause,
               format('%I LIKE %L', f.field_name, dd_ref_like(OLD.table_name)) AS match
          FROM fields f
          JOIN entities e ON e.table_name = f.table_name
         WHERE f.ctype = 'attached_to'
           AND e.managed
        UNION ALL
        SELECT 'user_bookmarks', 'user_bookmarks', format('entity_name = %L', NEW.table_name),
               format('entity_name = %L', OLD.table_name)
         WHERE to_regclass('public.user_bookmarks') IS NOT NULL
    LOOP
        CONTINUE WHEN to_regclass(format('public.%I', r.rel)) IS NULL;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE %s)', r.rel, r.match) INTO v_found;
        CONTINUE WHEN NOT v_found;

        v_undo := dd_backfill_mute(r.entity, TRUE);
        EXECUTE format('UPDATE public.%I SET %s WHERE %s', r.rel, r.set_clause, r.match);
        FOREACH v_stmt IN ARRAY v_undo LOOP
            EXECUTE v_stmt;
        END LOOP;
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION rename_dd_record_refs() IS
'AFTER UPDATE trigger on entities: when table_name changes, rewrites the stored record references into the entity - the attached_to columns of attachable entities and link tables, and user_bookmarks.entity_name - past the triggers of those tables, which it disables for the rewrite (dd_backfill_mute).';

REVOKE EXECUTE ON FUNCTION rename_dd_record_refs() FROM PUBLIC;

CREATE OR REPLACE TRIGGER rename_record_refs_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_record_refs();

COMMENT ON TRIGGER rename_record_refs_trigger ON entities IS
'Rewrites the stored record references into an entity when entities.table_name is renamed';

-- =====================================================
-- STEP 2: TRIGGER FUNCTION: VALIDATE AND RENAME ON fields UPDATE
-- =====================================================
-- Fires BEFORE UPDATE on fields.
-- Handles two things:
--   A) field_name rename  → ALTER TABLE ... RENAME COLUMN ... TO ...
--      Also renames associated FK constraints, indexes, and check constraints.
--   B) format validation  → reject if the new format maps to a different data type.

-- A rule reads a field by its name, and a rename rewrites no rule: the rule
-- would go on reading the old name, find nothing there, and decide on null
-- without a word. So a field that a rule names is not renamed, and the error
-- names the rule to change first.
--
-- The rules that count are the computed fields, the validation rules and the
-- select_rule of the entity and the input_type_rule of its fields, and the
-- same rules of every is_a or has_a entity below it: their records include
-- the field, and no entity of a family repeats a field name of another (90243),
-- so a name in such a rule is this field. A rule names the field when it reads
-- it (jl_row_keys: the field itself or a path below it, also behind $old), and
-- a computed field names the one it writes. What is not found: a field read
-- through the alias of a set_record in another entity's rule.
CREATE OR REPLACE FUNCTION dd_rule_naming_field(p_table TEXT, p_field TEXT, OUT p_entity TEXT, OUT p_rule TEXT)
AS $fn$
    WITH members AS (
        SELECT p_table AS table_name, 0 AS depth
        UNION ALL
        SELECT d.table_name, d.depth FROM dd_descendants(p_table) d
    ),
    rules AS (
        SELECT m.depth, e.table_name, 1 AS kind, c.ord, format('computed_fields[%s]', c.ord - 1) AS rule,
               c.item -> 'jsonlogic' AS logic, split_part(c.item ->> 'name', '.', 1) AS writes
          FROM members m
          JOIN entities e ON e.table_name = m.table_name
         CROSS JOIN LATERAL jsonb_array_elements(
                   CASE WHEN jsonb_typeof(e.computed_fields) = 'array' THEN e.computed_fields ELSE '[]'::jsonb END)
               WITH ORDINALITY AS c(item, ord)
        UNION ALL
        SELECT m.depth, e.table_name, 2, v.ord, format('validation_rules[%s]', v.ord - 1),
               v.item -> 'jsonlogic', NULL
          FROM members m
          JOIN entities e ON e.table_name = m.table_name
         CROSS JOIN LATERAL jsonb_array_elements(
                   CASE WHEN jsonb_typeof(e.validation_rules) = 'array' THEN e.validation_rules ELSE '[]'::jsonb END)
               WITH ORDINALITY AS v(item, ord)
        UNION ALL
        SELECT m.depth, e.table_name, 3, 1, 'select_rule', e.select_rule, NULL
          FROM members m
          JOIN entities e ON e.table_name = m.table_name
        UNION ALL
        SELECT m.depth, f.table_name, 4, f.field_order, f.field_name || '.input_type_rule', f.input_type_rule, NULL
          FROM members m
          JOIN fields f ON f.table_name = m.table_name
    )
    SELECT r.table_name, r.rule
      FROM rules r
     WHERE r.writes = p_field
        OR EXISTS (SELECT 1
                     FROM jl_row_keys(r.logic) AS k(key)
                    WHERE k.key = p_field
                       OR starts_with(k.key, p_field || '.')
                       OR k.key = '$old.' || p_field
                       OR starts_with(k.key, '$old.' || p_field || '.'))
     ORDER BY r.depth, r.table_name, r.kind, r.ord, r.rule
     LIMIT 1;
$fn$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_rule_naming_field(TEXT, TEXT) IS
'The first rule that names a field of an entity: the entity the rule belongs to and its place there (computed_fields[0], validation_rules[2], select_rule, <field>.input_type_rule). Looks at the entity and at every is_a or has_a entity below it. No row when no rule names the field.';

REVOKE EXECUTE ON FUNCTION dd_rule_naming_field(TEXT, TEXT) FROM PUBLIC;

-- New in this file and called by the definer trigger function below, which on
-- an upgrade already runs as semantius_owner while this function stays owned
-- by the installer until 9900_owner_hardening.sql runs last.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION dd_rule_naming_field(TEXT, TEXT) TO semantius_owner;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION validate_field_rename_and_format()
RETURNS TRIGGER AS $$
DECLARE
    v_rule_entity TEXT;
    v_rule_name   TEXT;
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
    v_rel         TEXT;
BEGIN
    -- Resolve parent entity's managed flag, and the physical relation that
    -- holds the column: <entity>_ext for an is_a or has_a entity, whose view
    -- the family refresh rebuilds after the statement.
    SELECT managed, dd_relation(table_name, id_type) INTO v_is_managed, v_rel
      FROM entities WHERE table_name = OLD.table_name;

    -- --------------------------------------------------
    -- A) Handle field_name rename
    -- --------------------------------------------------
    IF OLD.field_name IS DISTINCT FROM NEW.field_name THEN
        -- Core fields (dd_ctype_is_core) cannot be renamed, except the label column
        IF dd_ctype_is_core(OLD.ctype) THEN
            IF dd_ctype_is_label(OLD.ctype) THEN
                -- Label column rename is allowed; update entities.label_column
                -- to match. family_label_column_trigger (0160_dd_functions.sql)
                -- carries it to the entities based on this one.
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

        SELECT n.p_entity, n.p_rule INTO v_rule_entity, v_rule_name
          FROM dd_rule_naming_field(OLD.table_name, OLD.field_name) n;
        IF v_rule_name IS NOT NULL THEN
            RAISE EXCEPTION 'Field ${field_name} cannot be renamed while ${rule} on ${table} names it'
                USING ERRCODE = '90275',
                      HINT = jsonb_build_object('field_name', OLD.field_name, 'table', v_rule_entity,
                                                'rule', v_rule_name)::text;
        END IF;

        IF v_is_managed THEN
            -- Rename the physical column
            EXECUTE format(
                'ALTER TABLE %I RENAME COLUMN %I TO %I',
                v_rel, OLD.field_name, NEW.field_name
            );
            RAISE NOTICE 'Renamed column "%" to "%" in table "%"',
                OLD.field_name, NEW.field_name, OLD.table_name;

            -- Build old and new names for associated constraints / indexes
            v_old_fk     := format('%s_%s_fkey',   v_rel, OLD.field_name);
            v_new_fk     := format('%s_%s_fkey',   v_rel, NEW.field_name);
            v_old_idx    := format('idx_%s_%s',    v_rel, OLD.field_name);
            v_new_idx    := format('idx_%s_%s',    v_rel, NEW.field_name);
            v_old_check  := format('%s_%s_check',  v_rel, OLD.field_name);
            v_new_check  := format('%s_%s_check',  v_rel, NEW.field_name);
            v_old_unique := format('%s_%s_unique', v_rel, OLD.field_name);
            v_new_unique := format('%s_%s_unique', v_rel, NEW.field_name);
            v_old_notnull := format('%s_%s_not_null', v_rel, OLD.field_name);
            v_new_notnull := format('%s_%s_not_null', v_rel, NEW.field_name);

            -- Rename FK constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_fk
                  AND t.relname = v_rel
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_rel, v_old_fk, v_new_fk);
                RAISE NOTICE 'Renamed FK constraint "%" to "%"', v_old_fk, v_new_fk;
            END IF;

            -- Rename FK index if it exists. The index has to be this table's:
            -- table a with field b_c and table a_b with field c spell one
            -- name, and the new name must not be one another index carries.
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND tablename = v_rel AND indexname = v_old_idx
            ) THEN
                PERFORM dd_index_name_free(NEW.table_name, v_rel, NEW.field_name, v_new_idx);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_idx, v_new_idx);
                RAISE NOTICE 'Renamed index "%" to "%"', v_old_idx, v_new_idx;
            END IF;

            -- Rename check constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_check
                  AND t.relname = v_rel
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_rel, v_old_check, v_new_check);
                RAISE NOTICE 'Renamed check constraint "%" to "%"', v_old_check, v_new_check;
            END IF;

            -- Rename unique index if it exists, under the same two conditions.
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND tablename = v_rel AND indexname = v_old_unique
            ) THEN
                PERFORM dd_index_name_free(NEW.table_name, v_rel, NEW.field_name, v_new_unique);
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
                  AND t.relname = v_rel
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    v_rel, v_old_notnull, v_new_notnull);
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
        -- Core field formats cannot be changed (dd_ctype_is_core marks a core column; enforced here too)
        IF dd_ctype_is_core(OLD.ctype) THEN
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION validate_field_rename_and_format IS
'BEFORE UPDATE trigger on fields.
Renames the physical column (and associated constraints/indexes) when field_name changes.
Rejects format changes that would alter the underlying PostgreSQL data type.';

-- Apply trigger BEFORE UPDATE on fields
CREATE OR REPLACE TRIGGER validate_field_rename_and_format_trigger
    BEFORE UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_field_rename_and_format();

COMMENT ON TRIGGER validate_field_rename_and_format_trigger ON fields IS
'Renames column and validates format compatibility on field updates';

-- Revoke default PUBLIC execute on the new functions
REVOKE EXECUTE ON FUNCTION rename_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rename_dd_reference_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_field_rename_and_format() FROM PUBLIC;
