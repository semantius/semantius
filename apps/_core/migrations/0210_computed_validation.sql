-- =====================================================
-- COMPUTED FIELDS AND VALIDATION RULES
-- =====================================================
-- Per-record derivation and invariant checks expressed as JsonLogic.
--
-- Schema for entities.computed_fields and entities.validation_rules lives in
-- 0130_dd_schema.once.sql alongside the rest of the entities table; this file
-- contains only the runtime: a per-entity rule function,
-- common.record_rules_<entity>, and a per-table BEFORE INSERT OR UPDATE OR
-- DELETE trigger wrapping it, both (re)generated whenever either array is
-- non-empty, and dropped when both are empty or the entity itself is deleted.
-- An is_a or has_a entity gets the function only: its generated write routine
-- (0160_dd_functions.sql) calls it over the whole record.
--
-- Reserved variables injected into the JsonLogic data:
--   $today    -> current date in UTC
--   $now      -> current timestamp in UTC
--   $user_id  -> internal user_id from JWT context, null when no context
--   $role_ids -> the ids of the user's roles (public.jl_role_ids), empty when
--                no context
--   $old      -> previous row as JSON on UPDATE and DELETE, null on INSERT
--   $mode     -> the operation: 'insert' | 'update' | 'delete'
--
-- DELETE arm: the rules also fire on DELETE, evaluated against the row being
-- removed (OLD). Computed-field output is discarded on DELETE (the row is going
-- away), but validation_rules can abort the delete — e.g. a rule guarded by
-- {"!=": [{"var": "$mode"}, "delete"]} blocks deletion. The trigger is per row,
-- so a statement deleting many rows is judged one row at a time and a single
-- refusal takes the whole statement with it.
-- =====================================================
-- STEP 0: Error-hint merge used by the generated trigger
-- =====================================================
-- The merge is additive and the key already present wins - jsonb || takes the
-- right operand. A 42501 keeps its own hint.code because its hint is merged
-- into, not replaced, and no caller adds a code key, so the operand order
-- plays no part in that. The order decides only a key both sides carry, which
-- is why throw_error refuses parameters named entity, rule or field
-- (jl_reserved_error_parameters in 0050_jsonlogic.sql): with this order such a
-- parameter would win over the locating key the trigger adds. A cascaded write
-- keeps the innermost entity and rule for another reason: no trigger on the way
-- out adds keys to its error.
--
-- The cast is guarded rather than tested with a leading brace: text that starts
-- with one can still be malformed, and a raise in here would replace the error
-- the caller is trying to report.
CREATE OR REPLACE FUNCTION public.jl_error_hint(p_hint TEXT, p_add JSONB)
RETURNS TEXT AS $$
DECLARE
    v_obj JSONB;
BEGIN
    IF p_hint IS NULL OR p_hint = '' THEN
        v_obj := '{}'::jsonb;
    ELSE
        BEGIN
            v_obj := p_hint::jsonb;
        EXCEPTION WHEN OTHERS THEN
            v_obj := NULL;
        END;
        IF v_obj IS NULL OR jsonb_typeof(v_obj) <> 'object' THEN
            v_obj := jsonb_build_object('hint', p_hint);
        END IF;
    END IF;
    RETURN (p_add || v_obj)::text;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION public.jl_error_hint(TEXT, JSONB) IS
'Merges locating keys into the JSON hint of an error being re-raised, keeping every key the original hint already carries. A hint that is not a JSON object is wrapped as {"hint": <text>} first.';

REVOKE EXECUTE ON FUNCTION public.jl_error_hint(TEXT, JSONB) FROM PUBLIC;

-- =====================================================
-- A rule is checked when the entity is saved
-- =====================================================
-- A mistake in a rule is otherwise found only when a record reaches it, and
-- most mistakes not even then: the evaluator answers, and the answer is wrong.
-- The save refuses them instead, in two groups.
--
-- Two are checked on every write of the entity (dd_check_rule). An operator
-- the evaluator does not implement raises on the first record that reaches it;
-- in a select_rule the generated predicate swallows that error and every row
-- is hidden, with nothing to say why. A select_rule or a validation rule that
-- is not one operation is worse. The evaluator reads an object with several
-- keys, and every literal, as a value; a value is truthy unless it is empty;
-- so the rule passes every record and shows every row, and nobody notices
-- that it never ran. That includes a condition typed as text and the literal
-- true: a rule meant to hold always has no use that removing it does not serve
-- better. A computed field may be a literal, because a constant is a
-- legitimate value for a field. The empty select_rule {} means no rule and
-- stays valid. A select_rule that is no object at all is left to the
-- select_rule_is_object CHECK.
--
-- The rest are checked on a rule that is new or changed: a name of a computed
-- field or a message of a validation rule that is not text
-- (dd_check_rule_entry_types), and an object with several keys anywhere in a rule,
-- an argument count the operator does not take, a literal argument of the
-- wrong kind and a variable with no value where it is read
-- (dd_check_rule_detail). These are what the checker of the Semantius app
-- refuses, so the two accept the same rules. A rule can be stored without
-- having passed them, and such a rule must not block the writes that leave it
-- alone: an edit of another column, ensure_entities applying the entity again,
-- or a change elsewhere that writes this row, such as a rename of an entity
-- that its set_record names or a field saved on a base it is built on. A
-- rename that rewrites the entity name inside such a rule changes the rule,
-- and is refused.
--
-- The check is a trigger of its own and not part of the builders below. A
-- rule can be in the dictionary without having passed a save - a restored
-- dump, a row written with the triggers off - and the builders must still be
-- able to install what is stored, or one such rule would block every later
-- rebuild of its entity. They install it; build_select_rule_policy makes a
-- stored select_rule that is no operation hide every row.
--
-- The first group runs on every write of the entity, not only when a rule
-- changes, so an entity that stores a rule it refuses cannot be saved again -
-- renamed, re-applied by ensure_entities, edited in any column - until the
-- rule is put right. A delete is not checked.
CREATE OR REPLACE FUNCTION dd_check_rule(p_table TEXT, p_rule TEXT, p_logic JSONB, p_operation_only BOOLEAN)
RETURNS VOID AS $$
DECLARE
    v_op TEXT;
BEGIN
    IF p_operation_only AND NOT jl_is_operation(p_logic) THEN
        RAISE EXCEPTION '${rule} on ${table} must be a single JsonLogic operation: an object with exactly one key'
            USING ERRCODE = '90919',
                  HINT = jsonb_build_object('rule', p_rule, 'table', p_table)::text;
    END IF;

    v_op := jl_unknown_operator(p_logic);
    IF v_op IS NOT NULL THEN
        RAISE EXCEPTION '${rule} on ${table} uses an operation the evaluator does not implement: ${op}'
            USING ERRCODE = '90909',
                  HINT = jsonb_build_object('rule', p_rule, 'table', p_table, 'op', v_op)::text;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_check_rule(TEXT, TEXT, JSONB, BOOLEAN) IS
'Raises 90919 when a rule that has to be one JsonLogic operation is not, and 90909 when a rule names an operator the evaluator does not implement. p_rule is the rule''s place in the entity, such as validation_rules[0].';

-- A name of a computed field and a message of a validation rule are text, as
-- the app's checker demands: read as text, the builder would take 5 for "5".
-- The save runs this over every new or changed entry. It runs before the
-- permission checks of row-level security, as dd_check_rule does, and so
-- looks only at what the caller wrote; a missing key and a code outside its
-- class are left to dd_check_rule_entry in the builder, which runs once the
-- write is allowed. The builder itself does not demand text, because it
-- installs rules stored before this check as well, and refusing one there
-- would block every later rebuild of its entity.
CREATE OR REPLACE FUNCTION dd_check_rule_entry_types(p_table TEXT, p_column TEXT, p_idx INT, p_item JSONB)
RETURNS VOID AS $$
BEGIN
    IF jsonb_typeof(p_item) <> 'object' THEN
        RETURN;
    END IF;
    IF p_column = 'computed_fields' THEN
        IF jsonb_typeof(p_item -> 'name') NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'computed_fields[${index}] on ${table} is missing required "name"'
                USING ERRCODE = '90900',
                      HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
        END IF;
    ELSIF jsonb_typeof(p_item -> 'message') NOT IN ('string', 'null') THEN
        RAISE EXCEPTION 'validation_rules[${index}] on ${table} is missing required "message"'
            USING ERRCODE = '90903',
                  HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_check_rule_entry_types(TEXT, TEXT, INT, JSONB) IS
'Raises 90900 when the name of a computed_fields entry is not text, and 90903 when the message of a validation_rules entry (p_column) is not text. A missing key is left to dd_check_rule_entry.';

-- The keys an entry of computed_fields (p_column) or validation_rules needs,
-- and the class of a validation rule's code. The builder runs this over every
-- entry it installs.
CREATE OR REPLACE FUNCTION dd_check_rule_entry(p_table TEXT, p_column TEXT, p_idx INT, p_item JSONB)
RETURNS VOID AS $$
DECLARE
    v_code TEXT := p_item ->> 'code';
BEGIN
    IF p_column = 'computed_fields' THEN
        IF COALESCE(p_item ->> 'name', '') = '' THEN
            RAISE EXCEPTION 'computed_fields[${index}] on ${table} is missing required "name"'
                USING ERRCODE = '90900',
                      HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
        END IF;
        IF (p_item -> 'jsonlogic') IS NULL THEN
            RAISE EXCEPTION 'computed_fields[${index}] on ${table} is missing required "jsonlogic"'
                USING ERRCODE = '90901',
                      HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
        END IF;
        RETURN;
    END IF;

    IF COALESCE(v_code, '') = '' THEN
        RAISE EXCEPTION 'validation_rules[${index}] on ${table} is missing required "code"'
            USING ERRCODE = '90902',
                  HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
    END IF;
    IF (p_item ->> 'message') IS NULL THEN
        RAISE EXCEPTION 'validation_rules[${index}] on ${table} is missing required "message"'
            USING ERRCODE = '90903',
                  HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
    END IF;
    IF (p_item -> 'jsonlogic') IS NULL THEN
        RAISE EXCEPTION 'validation_rules[${index}] on ${table} is missing required "jsonlogic"'
            USING ERRCODE = '90904',
                  HINT = jsonb_build_object('index', p_idx, 'table', p_table)::text;
    END IF;

    -- Refused here rather than when the rule fires: PL/pgSQL accepts any
    -- five uppercase alphanumerics as an ERRCODE, so a code like
    -- "must_be_positive" installs happily and then fails at write time,
    -- inside a trigger, on a row that has nothing to do with it.
    --
    -- "platform" is a naming convention, not a trust boundary - a
    -- dictionary administrator can write it, and already writes the rule's
    -- logic and message anyway.
    IF (p_item ->> 'source_module') = 'platform' THEN
        IF v_code !~ '^90[0-9]{3}$' THEN
            RAISE EXCEPTION 'validation_rules[${index}] on ${table} is a platform rule, so its code must be a class 90 number, not ${rule_code}'
                USING ERRCODE = '90906',
                      HINT = jsonb_build_object('index', p_idx, 'table', p_table, 'rule_code', v_code)::text;
        END IF;
    ELSIF v_code !~ '^99[0-9]{3}$' THEN
        RAISE EXCEPTION 'validation_rules[${index}] on ${table} must carry a class 99 code, not ${rule_code}'
            USING ERRCODE = '90905',
                  HINT = jsonb_build_object('index', p_idx, 'table', p_table, 'rule_code', v_code)::text;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_check_rule_entry(TEXT, TEXT, INT, JSONB) IS
'Raises 90900 to 90906 when an entry of computed_fields or validation_rules (p_column) lacks a key it needs or carries a code outside its class.';

-- The mistakes jl_rule_problem finds, raised under the rule's place and table
-- as dd_check_rule raises its own, with the path inside the rule beside them.
-- An unknown operator is dd_check_rule's to report, and is raised here only
-- in the same form, for a caller that runs this check alone.
CREATE OR REPLACE FUNCTION dd_check_rule_detail(p_table TEXT, p_rule TEXT, p_logic JSONB)
RETURNS VOID AS $$
DECLARE
    v_problem JSONB := jl_rule_problem(p_logic);
    v_hint    TEXT;
BEGIN
    IF v_problem IS NULL THEN
        RETURN;
    END IF;
    v_hint := (jsonb_build_object('rule', p_rule, 'table', p_table) || (v_problem - 'code'))::text;
    CASE v_problem ->> 'code'
        WHEN '90909' THEN
            RAISE EXCEPTION '${rule} on ${table} uses an operation the evaluator does not implement: ${op}'
                USING ERRCODE = '90909',
                      HINT = (jsonb_build_object('rule', p_rule, 'table', p_table, 'op', v_problem -> 'op'))::text;
        WHEN '90921' THEN
            RAISE EXCEPTION '${rule} on ${table} gives ${op} ${count} arguments, a number it does not take'
                USING ERRCODE = '90921', HINT = v_hint;
        WHEN '90922' THEN
            RAISE EXCEPTION '${rule} on ${table}: ${op} needs ${expected} at ${path}'
                USING ERRCODE = '90922', HINT = v_hint;
        WHEN '90923' THEN
            RAISE EXCEPTION '${rule} on ${table} holds an object with ${key_count} keys, which is a value and not an operation'
                USING ERRCODE = '90923', HINT = v_hint;
        ELSE
            RAISE EXCEPTION '${rule} on ${table} reads ${variable}, which has no value where it is read'
                USING ERRCODE = '90924', HINT = v_hint;
    END CASE;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_check_rule_detail(TEXT, TEXT, JSONB) IS
'Raises the first mistake jl_rule_problem finds in a rule: 90921 an argument count, 90922 a literal argument, 90923 an object with several keys, 90924 a variable with no value where it is read. The hint carries rule, table and path, and the parameters of the mistake.';

-- A computed_fields or validation_rules entry is new or changed when the row
-- before the write holds no entry equal to it, so reordering the rules, or
-- adding one, leaves the others alone. An entry that is no object, or has no
-- "jsonlogic" key, is left to the builders, which refuse it with the code that
-- names what is missing.
CREATE OR REPLACE FUNCTION check_entity_rules()
RETURNS TRIGGER AS $$
DECLARE
    v_item       JSONB;
    v_idx        INT;
    v_place      TEXT;
    v_new        BOOLEAN;
    v_old_select JSONB;
    v_old_valid  JSONB := '[]'::jsonb;
    v_old_comp   JSONB := '[]'::jsonb;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old_select := OLD.select_rule;
        v_old_valid := CASE WHEN jsonb_typeof(OLD.validation_rules) = 'array' THEN OLD.validation_rules ELSE '[]'::jsonb END;
        v_old_comp := CASE WHEN jsonb_typeof(OLD.computed_fields) = 'array' THEN OLD.computed_fields ELSE '[]'::jsonb END;
    END IF;

    IF jsonb_typeof(NEW.select_rule) = 'object' AND NEW.select_rule <> '{}'::jsonb THEN
        PERFORM dd_check_rule(NEW.table_name, 'select_rule', NEW.select_rule, TRUE);
        IF TG_OP = 'INSERT' OR NEW.select_rule IS DISTINCT FROM v_old_select THEN
            PERFORM dd_check_rule_detail(NEW.table_name, 'select_rule', NEW.select_rule);
        END IF;
    END IF;

    IF jsonb_typeof(NEW.validation_rules) = 'array' THEN
        FOR v_idx IN 0 .. jsonb_array_length(NEW.validation_rules) - 1 LOOP
            v_item := NEW.validation_rules -> v_idx;
            v_place := format('validation_rules[%s]', v_idx);
            v_new := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_old_valid) AS o(item) WHERE o.item = v_item);
            IF v_new THEN
                PERFORM dd_check_rule_entry_types(NEW.table_name, 'validation_rules', v_idx, v_item);
            END IF;
            IF jsonb_typeof(v_item) = 'object' AND v_item ? 'jsonlogic' THEN
                PERFORM dd_check_rule(NEW.table_name, v_place, v_item -> 'jsonlogic', TRUE);
                IF v_new THEN
                    PERFORM dd_check_rule_detail(NEW.table_name, v_place, v_item -> 'jsonlogic');
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- A numbered label is the database's to write (common.label_number_assign,
    -- 0160_dd_functions.sql), and a rule writing it would overwrite the number
    -- after the label step ran.
    IF NEW.label_format = 'number' AND jsonb_typeof(NEW.computed_fields) = 'array'
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.computed_fields) c
                    WHERE split_part(c ->> 'name', '.', 1) = NEW.label_column) THEN
        RAISE EXCEPTION 'computed_fields on ${table} cannot write the label column ${field_name}, which is numbered'
            USING ERRCODE = '90288',
                  HINT = jsonb_build_object('table', NEW.table_name, 'field_name', NEW.label_column,
                                            'hint', 'Set label_format to custom, or remove the rule.')::text;
    END IF;

    IF jsonb_typeof(NEW.computed_fields) = 'array' THEN
        FOR v_idx IN 0 .. jsonb_array_length(NEW.computed_fields) - 1 LOOP
            v_item := NEW.computed_fields -> v_idx;
            v_place := format('computed_fields[%s]', v_idx);
            v_new := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_old_comp) AS o(item) WHERE o.item = v_item);
            IF v_new THEN
                PERFORM dd_check_rule_entry_types(NEW.table_name, 'computed_fields', v_idx, v_item);
            END IF;
            IF jsonb_typeof(v_item) = 'object' AND v_item ? 'jsonlogic' THEN
                PERFORM dd_check_rule(NEW.table_name, v_place, v_item -> 'jsonlogic', FALSE);
                IF v_new THEN
                    PERFORM dd_check_rule_detail(NEW.table_name, v_place, v_item -> 'jsonlogic');
                END IF;
            END IF;
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_entity_rules() IS
'BEFORE INSERT OR UPDATE trigger on entities. On every write it refuses a rule that names an unknown operator (90909), a select_rule or validation rule that is not one JsonLogic operation (90919), and a computed field that writes a numbered label column (90288). On a rule that is new or changed it also refuses a name or message that is not text (90900, 90903) and the mistakes of dd_check_rule_detail (90921 to 90924).';

-- The check runs as whoever saves the entity, so the request role needs the
-- helpers; the trigger function itself is called by the trigger alone.
REVOKE EXECUTE ON FUNCTION dd_check_rule(TEXT, TEXT, JSONB, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_check_rule(TEXT, TEXT, JSONB, BOOLEAN) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_check_rule_entry_types(TEXT, TEXT, INT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_check_rule_entry_types(TEXT, TEXT, INT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_check_rule_entry(TEXT, TEXT, INT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_check_rule_entry(TEXT, TEXT, INT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_check_rule_detail(TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_check_rule_detail(TEXT, TEXT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION check_entity_rules() FROM PUBLIC;

-- On an upgrade the dictionary's definer code already runs as semantius_owner,
-- while a function new in this file stays owned by the installer until
-- 9900_owner_hardening.sql runs last. A .jsonc file in between writes entities
-- through that code, and the check would be refused its helpers.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION
            dd_check_rule(TEXT, TEXT, JSONB, BOOLEAN),
            dd_check_rule_entry_types(TEXT, TEXT, INT, JSONB),
            dd_check_rule_entry(TEXT, TEXT, INT, JSONB),
            dd_check_rule_detail(TEXT, TEXT, JSONB)
        TO semantius_owner;
    END IF;
END $$;

CREATE OR REPLACE TRIGGER check_entity_rules_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION check_entity_rules();

COMMENT ON TRIGGER check_entity_rules_trigger ON entities IS
'Refuses an entity whose rules name an unknown operator or whose select_rule or validation rules are not single JsonLogic operations.';

-- The input_type_rule of a field is a rule as well, evaluated by the client
-- for every record it shows. A client falls back to the static input_type
-- when the rule raises, so a misspelled operator would turn a required or
-- hidden field into an ordinary one without a word. It is refused when the
-- field is saved, like the rules of an entity. The rule yields an input type,
-- so it may be a literal, and the empty object means that there is no rule.
CREATE OR REPLACE FUNCTION check_field_rules()
RETURNS TRIGGER AS $$
DECLARE
    v_old JSONB;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old := OLD.input_type_rule;
    END IF;
    IF NEW.input_type_rule IS NOT NULL AND NEW.input_type_rule <> '{}'::jsonb THEN
        PERFORM dd_check_rule(NEW.table_name, NEW.field_name || '.input_type_rule', NEW.input_type_rule, FALSE);
        IF TG_OP = 'INSERT' OR NEW.input_type_rule IS DISTINCT FROM v_old THEN
            PERFORM dd_check_rule_detail(NEW.table_name, NEW.field_name || '.input_type_rule', NEW.input_type_rule);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_field_rules() IS
'BEFORE INSERT OR UPDATE trigger on fields: refuses an input_type_rule that names an unknown operator (90909) on every write of the field, and one with a mistake of dd_check_rule_detail (90921 to 90924) when it is new or changed, under the rule name <field>.input_type_rule.';

REVOKE EXECUTE ON FUNCTION check_field_rules() FROM PUBLIC;

CREATE OR REPLACE TRIGGER check_field_rules_trigger
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION check_field_rules();

COMMENT ON TRIGGER check_field_rules_trigger ON fields IS
'Refuses a field whose input_type_rule names an unknown operator, or whose new or changed input_type_rule has a mistake the evaluator would not report.';

-- =====================================================
-- STEP 1: Per-row trigger generator
-- =====================================================

-- Whether a rule reads a $ variable, found by walking it, as the evaluator
-- would, for the keys it reads (jl_row_keys): the variable itself, a path
-- below it, or a key that is not written out. The interpreter evaluates the
-- key of a var, of missing and of missing_some as JsonLogic, so
-- {"var":{"cat":["$ol","d.label"]}} resolves to $old.label with the name
-- nowhere in the rule; what such a key will be cannot be known here, so it
-- counts as reading every variable.
CREATE OR REPLACE FUNCTION dd_rule_reads(p_logic JSONB, p_variable TEXT)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM jl_row_keys(p_logic) AS k(key)
                    WHERE k.key IS NULL OR k.key = p_variable OR starts_with(k.key, p_variable || '.'));
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_rule_reads(JSONB, TEXT) IS
'TRUE when a JsonLogic rule reads the given $ variable, a path below it, or a key it computes (jl_row_keys).';

REVOKE EXECUTE ON FUNCTION dd_rule_reads(JSONB, TEXT) FROM PUBLIC;

-- Whether a record rule of an entity - a computed field or a validation rule -
-- reads a $ variable (dd_rule_reads). The rule functions
-- (build_record_logic_trigger) and the computed-field pass (computed_backfill)
-- build the costly variables, $old and $role_ids, only for an entity whose
-- record rules read them; a select_rule predicate asks dd_rule_reads of the
-- select_rule itself.
CREATE OR REPLACE FUNCTION dd_entity_reads(p_entity entities, p_variable TEXT)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1
                     FROM jsonb_array_elements(coalesce(p_entity.computed_fields, '[]'::jsonb)
                                               || coalesce(p_entity.validation_rules, '[]'::jsonb)) AS r(item)
                    WHERE dd_rule_reads(r.item -> 'jsonlogic', p_variable));
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_entity_reads(entities, TEXT) IS
'TRUE when a computed field or a validation rule of the entity reads the given $ variable (dd_rule_reads).';

REVOKE EXECUTE ON FUNCTION dd_entity_reads(entities, TEXT) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION dd_rule_reads(JSONB, TEXT), dd_entity_reads(entities, TEXT) TO semantius_owner;
    END IF;
END $$;

-- $role_ids, the ids of the caller's roles (rbac.user_role_ids, empty without a
-- user) as a JSON array. It reads user_roles, so a rule gets it only when it
-- reads it (dd_entity_reads, dd_rule_reads).
CREATE OR REPLACE FUNCTION public.jl_role_ids()
RETURNS JSONB AS $$
    SELECT to_jsonb(rbac.user_role_ids());
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION public.jl_role_ids() IS
'The JsonLogic variable $role_ids: the ids of the caller''s roles as a JSON array, empty without a user.';

REVOKE EXECUTE ON FUNCTION public.jl_role_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jl_role_ids() TO semantius_user;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION public.jl_role_ids() TO semantius_owner;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION build_record_logic_trigger(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_rules_name TEXT;
    v_trg_name CONSTANT TEXT := 'compute_validate_trigger';
    v_body TEXT;
    v_rules_block TEXT := '';
    v_item JSONB;
    v_name TEXT;
    v_path_sql TEXT;
    v_logic_lit TEXT;
    v_code TEXT;
    v_message TEXT;
    v_rule_hint TEXT;
    v_has_computed BOOLEAN;
    v_needs_old BOOLEAN := FALSE;
    v_writeback TEXT;
    v_extra_ctx TEXT := '';
    v_derived BOOLEAN;
    v_had_rules BOOLEAN;
BEGIN
    v_fn_name := 'compute_validate_' || p_table_name;
    v_rules_name := 'record_rules_' || p_table_name;

    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- No entity by that name. Every caller passes one it just read, and the
        -- entities DELETE arm drops the functions itself, so this is reached
        -- only by a caller naming a table the dictionary does not know - drop
        -- whatever is there under those names and leave.
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, jsonb, jsonb)', v_rules_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables (no physical table to attach a trigger to)
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    -- An is_a or has_a entity has no rule trigger: its rules run inside its
    -- generated write routine, common.record_write_<entity>, over the whole
    -- record. Whether record_rules_<entity> exists decides whether that routine
    -- calls it, so a change in its existence rebuilds the family.
    v_derived := v_entity.id_type IN ('is_a', 'has_a');
    v_had_rules := to_regprocedure(format('common.%I(text, jsonb, jsonb)', v_rules_name)) IS NOT NULL;

    -- Drop any existing trigger + wrapper so we can recreate cleanly. The rule
    -- function is replaced in place further down, not dropped, so the write
    -- routines that call it keep resolving the same function.
    IF NOT v_derived THEN
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trg_name, p_table_name);
        -- A computed field naming the key column gets the table's key checks
        -- repeated behind this trigger, and a rule set without one loses them,
        -- so they follow every change of the rules. Only the late checks: the
        -- key triggers themselves belong to the table (dd_install_id_triggers).
        PERFORM dd_install_key_rule_checks(v_entity.table_name, v_entity.id_column, v_entity.id_type, v_entity.id_prefix);
    END IF;
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);

    -- Both arrays empty → nothing to install
    IF jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) = 0
       AND jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) = 0 THEN
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, jsonb, jsonb)', v_rules_name);
        IF v_derived AND v_had_rules THEN
            PERFORM dd_refresh_family(ARRAY[p_table_name]);
        END IF;
        RETURN;
    END IF;

    v_has_computed := jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) > 0;

    -- $old is built only for entities whose rules read it: it serializes the
    -- whole previous row on every UPDATE and DELETE, for rules that mostly never
    -- look at it. $mode is a lowercased TG_OP and costs nothing, so it is always
    -- present - and it is the variable that guards DELETE, where a missing value
    -- makes a rule such as {"!=":[{"var":"$mode"},"delete"]} pass instead of
    -- blocking the delete.
    --
    -- Whether a rule reads $old is found by walking it (dd_entity_reads), which
    -- counts value_changed too: it never names $old but reads the key itself
    -- and returns true whenever it is absent, so an entity using it would
    -- silently start reporting every field as changed.
    v_needs_old := dd_entity_reads(v_entity, '$old');

    IF v_needs_old THEN
        v_extra_ctx := v_extra_ctx || $CTX$,
        '$old',     COALESCE(p_old, 'null'::jsonb)$CTX$;
    END IF;

    -- $role_ids reads user_roles on every write, so it is built only for the
    -- entities whose rules read it, found the same way (public.jl_role_ids).
    IF dd_entity_reads(v_entity, '$role_ids') THEN
        v_extra_ctx := v_extra_ctx || $CTX$,
        '$role_ids', public.jl_role_ids()$CTX$;
    END IF;

    v_extra_ctx := v_extra_ctx || $CTX$,
        '$mode',    to_jsonb(p_mode)$CTX$;

    -- Computed fields: evaluate each, write result into v_data at name (supports dotted paths)
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.computed_fields -> v_idx;
        v_name := v_item ->> 'name';
        PERFORM dd_check_rule_entry(p_table_name, 'computed_fields', v_idx, v_item);
        -- A rollup column takes its value from other records, and a rule
        -- writing it would run after the rollup guard and overwrite the
        -- aggregate: one derivation per field (the other direction is 90261).
        IF EXISTS (SELECT 1 FROM fields f
                    WHERE f.table_name = p_table_name AND f.field_name = v_name AND f.rollup <> '{}'::jsonb) THEN
            RAISE EXCEPTION 'computed_fields[${index}] on ${table} names the rollup field ${field_name}'
                USING ERRCODE = '90907',
                      HINT = jsonb_build_object('index', v_idx, 'table', p_table_name, 'field_name', v_name)::text;
        END IF;
        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);
        SELECT 'ARRAY[' || string_agg(quote_literal(part), ',') || ']::text[]'
          INTO v_path_sql
          FROM unnest(string_to_array(v_name, '.')) AS part;

        -- The field name is admin-supplied text that lands inside the generated
        -- function body: it is emitted as a quoted literal, so a quote cannot
        -- break out of the string, and the body is wrapped by dd_dollar_quote,
        -- so a dollar tag in it cannot end the body. It is a value handed to
        -- jsonb_build_object, never a RAISE format string, so nothing in it
        -- needs escaping.
        --
        -- WHEN SQLSTATE '90000' catches the whole of class 90, not that one
        -- code: PostgreSQL treats a SQLSTATE ending in three zeroes as a
        -- category and matches every code whose first two characters agree.
        -- Our own catalog errors therefore pass through untouched, and only
        -- everything else is re-raised with the locating keys merged in.
        --
        -- The entity is written into the body as a literal rather than read
        -- from TG_TABLE_NAME: the function is not a trigger, and for an is_a
        -- or has_a entity the table that is being written is <entity>_ext or
        -- a base's, while the hint has to name the entity that owns the rule.
        v_rules_block := v_rules_block || E'\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION
        WHEN SQLSTATE '90000' THEN
            RAISE;
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_err_state  = RETURNED_SQLSTATE,
                v_err_msg    = MESSAGE_TEXT,
                v_err_detail = PG_EXCEPTION_DETAIL,
                v_err_hint   = PG_EXCEPTION_HINT;
            RAISE EXCEPTION '%%', v_err_msg
                USING ERRCODE = v_err_state,
                      DETAIL  = COALESCE(v_err_detail, ''),
                      HINT    = jl_error_hint(v_err_hint, jsonb_build_object(
                                    'entity', %s,
                                    'field',  %s));
    END;
    v_data := jsonb_set(v_data, %s, COALESCE(v_result, 'null'::jsonb), true);
$BLOCK$,
            v_logic_lit,
            quote_literal(p_table_name),
            quote_literal(v_name),
            v_path_sql);
    END LOOP;

    -- Validation rules: evaluate each against post-derivation v_data, raise on falsy
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.validation_rules -> v_idx;
        v_code := v_item ->> 'code';
        v_message := v_item ->> 'message';
        v_rule_hint := v_item ->> 'hint';
        PERFORM dd_check_rule_entry(p_table_name, 'validation_rules', v_idx, v_item);

        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);

        -- code, message and hint are admin-supplied text that lands inside the
        -- generated function body, all three emitted as quoted literals so a
        -- quote cannot break out of the string, inside a body wrapped by
        -- dd_dollar_quote so a dollar tag in them cannot end it. None of them
        -- is a RAISE format string: the message is passed as the argument of a
        -- '%' format instead, which is what lets a rule author write a percent
        -- sign without escaping it.
        --
        -- An error thrown while the rule's logic runs is not the rule failing,
        -- so it travels out as itself; the handler is the one above.
        v_rules_block := v_rules_block || E'\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION
        WHEN SQLSTATE '90000' THEN
            RAISE;
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_err_state  = RETURNED_SQLSTATE,
                v_err_msg    = MESSAGE_TEXT,
                v_err_detail = PG_EXCEPTION_DETAIL,
                v_err_hint   = PG_EXCEPTION_HINT;
            RAISE EXCEPTION '%%', v_err_msg
                USING ERRCODE = v_err_state,
                      DETAIL  = COALESCE(v_err_detail, ''),
                      HINT    = jl_error_hint(v_err_hint, jsonb_build_object(
                                    'entity', %s,
                                    'rule',   %s));
    END;
    IF NOT jl_truthy(v_result) THEN
        RAISE EXCEPTION '%%', %s USING ERRCODE = %s, HINT = %s;
    END IF;
$BLOCK$,
            v_logic_lit,
            quote_literal(p_table_name),
            quote_literal(v_code),
            quote_literal(v_message),
            quote_literal(v_code),
            'jsonb_build_object(''entity'', ' || quote_literal(p_table_name) || ', ''rule'', ' ||
                quote_literal(v_code) ||
                CASE WHEN v_rule_hint IS NULL THEN ''
                     ELSE ', ''hint'', ' || quote_literal(v_rule_hint) END ||
                ')::text');
    END LOOP;

    -- The rules of one entity as a function of the record: p_mode is insert,
    -- update or delete, p_old the previous record (NULL on insert), p_data the
    -- record being written. It returns p_data with the computed fields applied
    -- and raises when a validation rule fails. On delete the result is
    -- discarded; the rules may still abort the delete.
    --
    -- SECURITY DEFINER, as the rule trigger always was: the rule block calls
    -- jl_error_hint, which the request role may not execute, so under invoker
    -- rights a failing rule would surface as 42501 instead of its own code.
    -- Granted to the request role because the write routines of is_a and
    -- has_a entities, which run as the caller, call it. It lives in common,
    -- which PostgREST does not expose, so it is no RPC.
    --
    -- The timezone and intervalstyle settings are part of what the rules mean.
    -- $today and $now come from CURRENT_DATE and CURRENT_TIMESTAMP, and a record
    -- reaches the rules through to_jsonb, so all of them render in the session's
    -- zone and style. A client can change both, and what a rule stores or
    -- compares must not depend on who wrote the row. The same two settings are on
    -- every other function that turns a row into rule data.
    v_body := format($FUNC$
CREATE OR REPLACE FUNCTION common.%I(p_mode text, p_old jsonb, p_data jsonb) RETURNS jsonb AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';
$FUNC$, v_rules_name, dd_dollar_quote(format($RULES$
DECLARE
    v_data jsonb;
    v_result jsonb;
    v_uid_text text;
    v_err_state text;
    v_err_msg text;
    v_err_detail text;
    v_err_hint text;
BEGIN
    -- The delete step of a target deletes a multiple record that lost its last
    -- target past its rules, as a foreign-key cascade would
    -- (common.attached_step_marked).
    IF p_mode = 'delete' AND common.attached_step_marked(%s) THEN
        RETURN p_data;
    END IF;
    -- Derived through rbac (lazy context initialization), never read raw from the
    -- client-writable app.current_user_id setting; NULL when unauthenticated.
    v_uid_text := rbac.user_id_or_null()::text;
    v_data := p_data || jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        '$user_id', CASE
                       WHEN v_uid_text IS NULL OR v_uid_text = '' THEN 'null'::jsonb
                       ELSE to_jsonb(v_uid_text::bigint)
                   END%s
    );
%s
    RETURN v_data - '$today' - '$now' - '$user_id' - '$role_ids' - '$old' - '$mode';
END;
$RULES$, quote_literal(p_table_name), v_extra_ctx, v_rules_block)));

    EXECUTE v_body;
    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I(text, jsonb, jsonb) FROM PUBLIC', v_rules_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION common.%I(text, jsonb, jsonb) TO semantius_user', v_rules_name);
    EXECUTE format(
        'COMMENT ON FUNCTION common.%I(text, jsonb, jsonb) IS %L',
        v_rules_name,
        format('Evaluates the computed_fields and validation_rules of entity "%s" over a record (p_mode insert/update/delete, p_old the previous record, p_data the record written) and returns the record with the computed values applied. Generated by build_record_logic_trigger.', p_table_name));

    IF v_derived THEN
        IF NOT v_had_rules THEN
            PERFORM dd_refresh_family(ARRAY[p_table_name]);
        END IF;
        RETURN;
    END IF;

    -- The trigger of a plain entity (a family root included) is a thin
    -- wrapper: the row as jsonb in, the result back into NEW. Validation rules
    -- never modify the row, so a validation-only entity returns NEW untouched —
    -- no need to rebuild it. An entity WITH computed fields must fold the
    -- derived values back onto NEW.
    --
    -- The rebuild uses a DYNAMIC jsonb_populate_record (EXECUTE, re-planned each
    -- call) rather than a static NEW := jsonb_populate_record(NULL::public.<tbl>, …).
    -- A static call caches the target row type's tuple descriptor in the plpgsql
    -- expression's fn_extra and does NOT refresh it when the table gains a column
    -- LATER in the SAME transaction — so a column added and set after this trigger
    -- first fired (e.g. an order column provisioned and then set in the same install) would be
    -- silently dropped, reverting that write. This only surfaces in a single-txn
    -- install (CREATE EXTENSION / one big script); the per-file migrate path commits
    -- between statements and refreshes the cache. EXECUTE re-resolves the descriptor
    -- every call, so mid-transaction columns survive.
    IF v_has_computed THEN
        v_writeback := $WB$    EXECUTE format('SELECT (jsonb_populate_record(NULL::public.%I, $1)).*', TG_TABLE_NAME) INTO NEW USING v_data;
$WB$;
    ELSE
        v_writeback := '';
    END IF;

    -- On DELETE there is no NEW row; the rules evaluate against the row being
    -- removed (OLD), which is also $old.
    v_body := format($FUNC$
CREATE FUNCTION public.%I() RETURNS TRIGGER AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';
$FUNC$, v_fn_name, dd_dollar_quote(format($TRIG$
DECLARE
    v_data jsonb;
BEGIN
    v_data := common.%I(
        lower(TG_OP),
        %s,
        to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END));
    -- DELETE keeps no computed output; the validation rules above may still abort it.
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
%s    RETURN NEW;
END;
$TRIG$, v_rules_name,
        CASE WHEN v_needs_old
             THEN $OLD$CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END$OLD$
             ELSE 'NULL' END,
        v_writeback)));

    EXECUTE v_body;

    -- Revoke PUBLIC execute on trigger function (security best practice)
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I() FROM PUBLIC', v_fn_name);

    EXECUTE format(
        'COMMENT ON FUNCTION public.%I() IS %L',
        v_fn_name,
        format('Per-row BEFORE INSERT/UPDATE/DELETE trigger function evaluating computed_fields and validation_rules for entity "%s" through common.%s. Generated by build_record_logic_trigger.', p_table_name, v_rules_name));

    -- The firing order of the dictionary's BEFORE row triggers around the
    -- rules. PostgreSQL fires a table's BEFORE triggers of one event in name
    -- order (byte order), so each name below is chosen for its place; this is
    -- the one list of them, and each installer says only why its trigger
    -- stands where it does. Pinned by 0657_test_computed_trigger_order.sql.
    --   INSERT  a_auto_order_<table>   the order column, so the rules see it
    --           a_rollup_guard         the rollup columns, so the rules see them
    --           a_typeid_assign        a typeid key, so the rules see it
    --           b_file_size            the size of a file's contents
    --                                  (0470_tasks_files_comments.sql), so the
    --                                  rules see it
    --           b_label_number         a numbered label, from the id or a
    --                                  counter picked by its prefix, so the key
    --                                  is settled and the rules see the label
    --           compute_validate_trigger
    --           d_attach_check         the target of an attachable record or a
    --                                  link row (0450_attachables.sql), after
    --                                  the rules, so one a rule wrote is checked
    --           zz_key_check_insert    the prefix of a key a rule wrote
    --   UPDATE  a_is_a_dispatch        on an is_a root: a subtype record goes
    --                                  to its write routine, whose own rules
    --                                  run first
    --           a_raci_gate_on_<table> a held state, so the rules judge the
    --                                  state that will be stored
    --           a_rollup_guard         as on INSERT
    --           b_file_size            as on INSERT
    --           b_label_number         a numbered label keeps its stored value
    --           compute_validate_trigger
    --           d_attach_check         a target keeps its stored value
    --           pk_immutable           UPDATE OF <key>: only a key the
    --                                  statement names
    --           raci_gate_on_<table>   a state a rule moved
    --           update_<table>_updated_at
    --                                  compares the row the rules produced with
    --                                  the stored one, so where unchanged
    --                                  writes are skipped, a change only a
    --                                  computed field made still bumps it; a
    --                                  rule reads the previous updated_at, and
    --                                  the new one as $now
    --           zz_key_check_update    a key a rule changed
    --   DELETE  a_has_a_guard          on a has_a base: a base record with
    --                                  extensions is refused before anything
    --                                  else runs
    --           a_is_a_dispatch        as on UPDATE
    --           compute_validate_trigger
    -- An is_a or has_a entity has no rule trigger: its write routine
    -- (dd_build_record_write, 0160_dd_functions.sql) settles the key, holds
    -- the root's gated state on update, runs the rules and checks the key
    -- again, in that order, and its <entity>_ext table refuses any other
    -- writer first (a_ext_write_guard).
    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION public.%I()',
        v_trg_name, p_table_name, v_fn_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION build_record_logic_trigger IS
'Generates (or drops) the rule function common.record_rules_<entity> evaluating an entity''s computed_fields and validation_rules over a record, and for an entity with a table of its own the per-table BEFORE INSERT OR UPDATE OR DELETE trigger wrapping it. On DELETE the rules evaluate against OLD with $mode=delete; computed output is discarded but validation_rules can abort the delete. An is_a or has_a entity gets no trigger: its write routine calls the rule function.';

REVOKE EXECUTE ON FUNCTION build_record_logic_trigger(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 2: Trigger on entities to keep per-row trigger in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_record_logic_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.managed AND (
              jsonb_array_length(COALESCE(NEW.computed_fields, '[]'::jsonb)) > 0
           OR jsonb_array_length(COALESCE(NEW.validation_rules, '[]'::jsonb)) > 0
        ) THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.computed_fields IS DISTINCT FROM NEW.computed_fields
           OR OLD.validation_rules IS DISTINCT FROM NEW.validation_rules
           OR OLD.managed IS DISTINCT FROM NEW.managed
           OR OLD.table_name IS DISTINCT FROM NEW.table_name THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        -- The ctype marker of the fields the rules name follows the rules. A
        -- write that changes nothing of its own runs zz_derive_computed_ctype
        -- on the row, the one place that derives it; only the rows whose
        -- marker would change are written, since every fields write fires
        -- the whole BEFORE and AFTER trigger chain on fields.
        IF OLD.computed_fields IS DISTINCT FROM NEW.computed_fields THEN
            UPDATE fields f
               SET ctype = f.ctype
             WHERE f.table_name = NEW.table_name
               AND coalesce(f.ctype, '') IN ('', 'computed', 'label', 'computed_label', 'number_label')
               AND (coalesce(f.ctype, '') IN ('computed', 'computed_label')) IS DISTINCT FROM
                   EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.computed_fields) c WHERE c ->> 'name' = f.field_name);
        END IF;
        -- Last, so the pass runs through the rule trigger rebuilt above. Removing
        -- a rule writes nothing: its column keeps the last value as ordinary data.
        IF OLD.computed_fields IS DISTINCT FROM NEW.computed_fields
           OR (NEW.managed AND NOT OLD.managed) THEN
            PERFORM computed_backfill(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_fn_name := 'compute_validate_' || OLD.table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, jsonb, jsonb)', 'record_rules_' || OLD.table_name);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION manage_record_logic_trigger IS
'Trigger function on entities that creates/updates/drops the rule function and the per-table BEFORE row trigger for computed_fields and validation_rules.';

-- AFTER INSERT/UPDATE so it runs after create_table_trigger (which creates the
-- physical table). AFTER DELETE so it runs after delete_table_trigger drops the
-- table — at that point only the standalone trigger function survives, which we
-- explicitly drop.
CREATE OR REPLACE TRIGGER manage_record_logic_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_record_logic_trigger();

REVOKE EXECUTE ON FUNCTION manage_record_logic_trigger() FROM PUBLIC;

-- =====================================================
-- STEP 2b: the derived ctype of a computed field
-- =====================================================
-- A field that one of its entity's computed_fields names carries ctype
-- 'computed', as a rollup field carries 'rollup', and the label column carries
-- 'computed_label' instead of 'label'; the label column of an entity whose
-- label_format is number carries 'number_label', which no rule may write
-- (90288). ctype is the one signal a client reads
-- to know the database writes the value: derived from the rule, never sent by
-- a client (fields_ctype_lock runs first and refuses a ctype a caller sends, so
-- the marker never passes through it). 'computed' is not a core marker
-- (dd_ctype_is_core), so the field stays the administrator's to rename and
-- delete; 'computed_label' is, because the label column keeps its protection
-- whether or not a rule writes it.
--
-- input_type is left as the author set it. The rule overwrites whatever a form
-- submits, so a client renders a visible computed field disabled from its
-- ctype; hidden and an input_type_rule keep working as they do on any field,
-- and required keeps its meaning on a computed field too: the required check
-- runs after the rule, so it refuses a write whose rule produced no value
-- (0515_test_required_enforcement.sql).
--
-- BEFORE INSERT OR UPDATE, so a field created after its rule is marked, a
-- renamed field the rule no longer names loses the marker, a field renamed to
-- a name a rule writes gains it, and the no-op write manage_record_logic_trigger
-- issues when the rules change re-derives it. The zz_ name puts it after
-- fields_ctype_lock and validate_field_rename_and_format_trigger (which points
-- entities.label_column at a renamed label field) and before
-- zz_validate_rollup_field, which refuses a rollup on a computed field.
CREATE OR REPLACE FUNCTION zz_derive_computed_ctype()
RETURNS TRIGGER AS $$
DECLARE
    v_named BOOLEAN;
BEGIN
    IF coalesce(NEW.ctype, '') NOT IN ('', 'computed', 'label', 'computed_label', 'number_label') THEN
        RETURN NEW;
    END IF;
    SELECT EXISTS (
        SELECT 1
          FROM entities e, jsonb_array_elements(e.computed_fields) c
         WHERE e.table_name = NEW.table_name
           AND c ->> 'name' = NEW.field_name)
      INTO v_named;
    IF dd_ctype_is_label(NEW.ctype) THEN
        NEW.ctype := CASE WHEN EXISTS (SELECT 1 FROM entities e
                                        WHERE e.table_name = NEW.table_name AND e.label_format = 'number')
                          THEN 'number_label'
                          WHEN v_named THEN 'computed_label'
                          ELSE 'label' END;
    ELSE
        NEW.ctype := CASE WHEN v_named THEN 'computed' ELSE '' END;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION zz_derive_computed_ctype() IS
'BEFORE INSERT OR UPDATE trigger function on fields: sets ctype computed on a field that one of its entity''s computed_fields names, computed_label on such a label column and number_label on the label column of an entity whose label_format is number, and returns the marker to empty or label otherwise. input_type is left as set.';

REVOKE EXECUTE ON FUNCTION zz_derive_computed_ctype() FROM PUBLIC;

CREATE OR REPLACE TRIGGER zz_derive_computed_ctype
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION zz_derive_computed_ctype();

-- =====================================================
-- STEP 2c: applying a rule to the records that already exist
-- =====================================================
-- A backfill recalculates stored values after a rule or a rollup definition
-- changed. Nobody edited those records, so it must not look as if somebody had:
-- no updated_at, no audit row, no queue message, no RACI event, on the table it
-- writes and on every table the write reaches, which is the rest of an is_a or
-- has_a family and any rollup parent above it (a moved line amount moves the
-- order's subtotal, and through a computed field its total).
--
-- The triggers are switched off with ALTER TABLE rather than told through a
-- setting, because a client can write any custom setting and could then skip the
-- audit log. ALTER TABLE takes a lock that conflicts with every writer until the
-- transaction ends, so no other session can write past a disabled trigger, and
-- it rolls back with the transaction. The cost is that those tables take no
-- writes until the transaction that changed the rule commits; a pass with nothing
-- to write never gets here. The RACI gate trigger stays on: it holds a state
-- column during a consultation, which is a constraint, not a side effect.
--
-- Returns the statements that switch the triggers back on. Only triggers that are
-- plainly enabled are touched, so one an operator disabled stays disabled.
-- p_rewrite is for a write that is no edit of the records at all
-- (rename_dd_record_refs, 0170_dd_rename.sql): it switches off every plainly
-- enabled trigger, on the entity's own relation only, which is all such a
-- write touches.
DROP FUNCTION IF EXISTS dd_backfill_mute(TEXT);
CREATE OR REPLACE FUNCTION dd_backfill_mute(p_table TEXT, p_rewrite BOOLEAN DEFAULT FALSE)
RETURNS TEXT[] AS $fn$
DECLARE
    v_undo TEXT[] := ARRAY[]::TEXT[];
    r      RECORD;
BEGIN
    FOR r IN
        WITH RECURSIVE reach(t) AS (
            SELECT p_table
            UNION
            SELECT x.t
              FROM reach, LATERAL (
                  SELECT f.table_name AS t FROM fields f
                   WHERE f.rollup <> '{}'::jsonb
                     AND split_part(f.rollup ->> 'link_field', '.', 1) = reach.t
                  UNION ALL
                  SELECT e.table_name FROM entities e
                   WHERE e.id_refentity = reach.t AND e.id_type IN ('is_a', 'has_a')
                  UNION ALL
                  SELECT e.id_refentity FROM entities e
                   WHERE e.table_name = reach.t AND e.id_type IN ('is_a', 'has_a')
              ) x
             WHERE NOT p_rewrite
        )
        SELECT c.relname, t.tgname
          FROM reach
          JOIN entities e ON e.table_name = reach.t
          JOIN pg_class c ON c.oid = pg_catalog.to_regclass(format('public.%I', dd_relation(e.table_name, e.id_type)))
          JOIN pg_trigger t ON t.tgrelid = c.oid
         WHERE NOT t.tgisinternal
           AND t.tgenabled = 'O'
           AND (p_rewrite
                OR t.tgfoid = ANY (ARRAY[to_regproc('common.update_updated_at_column'),
                                         to_regproc('audit.insert_update_delete_trigger'),
                                         to_regproc('public.queue_build_record_json'),
                                         to_regproc('public.raci_emit_trigger_fn')]::oid[]))
    LOOP
        EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER %I', r.relname, r.tgname);
        v_undo := v_undo || format('ALTER TABLE public.%I ENABLE TRIGGER %I', r.relname, r.tgname);
    END LOOP;
    RETURN v_undo;
END;
$fn$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_backfill_mute(TEXT, BOOLEAN) IS
'Disables the updated_at, audit UPDATE, queue and RACI event triggers on the tables a backfill of the entity can write - with p_rewrite every plainly enabled trigger of the entity''s own relation - and returns the statements that enable them again.';

REVOKE EXECUTE ON FUNCTION dd_backfill_mute(TEXT, BOOLEAN) FROM PUBLIC;

-- The computed rules in order over a record that already carries its context, as
-- the block build_record_logic_trigger generates for each rule does.
CREATE OR REPLACE FUNCTION computed_values(p_rules JSONB, p_data JSONB)
RETURNS JSONB AS $fn$
DECLARE
    v_data JSONB := p_data;
    v_rule JSONB;
BEGIN
    FOR v_rule IN SELECT jsonb_array_elements(p_rules) LOOP
        v_data := jsonb_set(v_data, string_to_array(v_rule ->> 'name', '.'),
                            COALESCE(evaluate_json_logic(v_rule -> 'jsonlogic', v_data), 'null'::jsonb), true);
    END LOOP;
    RETURN v_data;
END;
$fn$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION computed_values(JSONB, JSONB) IS
'Evaluates a computed_fields array over a record and returns the record with the values applied.';

REVOKE EXECUTE ON FUNCTION computed_values(JSONB, JSONB) FROM PUBLIC;

-- One pass over the records of an entity after its computed_fields changed.
--
-- The rules are evaluated here rather than through common.record_rules_<entity>,
-- because that function also runs the validation rules, and a record that fails
-- one must block the change only when its value has to move: a validation added
-- after a record was written is not retroactive, and such a record would
-- otherwise refuse every later rule change on the entity. The context matches the
-- generated function with $mode = 'update' and $old = the record, so an
-- insert-only stamp such as {"if": [{"==": [{"var": "$mode"}, "insert"]},
-- {"var": "$user_id"}, {"var": "$old.created_by"}]} returns what it already holds.
-- A rule that stamps $user_id or $now unconditionally moves on this pass, as it
-- does on any other update.
--
-- A record whose value moves is written through the entity's own write path, the
-- table or the view of an is_a or has_a entity, so the rule trigger validates it
-- and rollups above it follow. One statement per record: the error has to name
-- the record, and a set-based UPDATE fails without saying which row it was on.
--
-- Values are compared as text through the column types, so 163.625 from a rule
-- and 163.63 in a two-decimal column count as equal, and json columns compare at
-- all.
CREATE OR REPLACE FUNCTION computed_backfill(p_table TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_e       entities%ROWTYPE;
    v_cols    TEXT[];
    v_uid     TEXT;
    v_ctx     JSONB;
    v_differs TEXT;
    v_write   TEXT;
    v_old     JSONB;
    v_new     JSONB;
    v_moved   BOOLEAN;
    v_undo    TEXT[];
    v_stmt    TEXT;
    v_state   TEXT;
    v_msg     TEXT;
BEGIN
    SELECT * INTO v_e FROM entities WHERE table_name = p_table;
    IF NOT FOUND OR NOT v_e.managed OR pg_catalog.to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN;
    END IF;

    -- A rule may name a field that does not exist yet; zz_computed_field_added
    -- runs this pass again when it arrives. A dotted name writes into a JSON column.
    SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO v_cols
      FROM pg_attribute a
     WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', p_table))
       AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
       AND a.attname::text IN (SELECT split_part(c ->> 'name', '.', 1)
                                 FROM jsonb_array_elements(v_e.computed_fields) c);
    IF v_cols IS NULL THEN
        RETURN;
    END IF;

    v_uid := rbac.user_id_or_null()::text;
    v_ctx := jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        '$user_id', CASE WHEN v_uid IS NULL OR v_uid = '' THEN 'null'::jsonb ELSE to_jsonb(v_uid::bigint) END,
        '$mode',    'update')
        || CASE WHEN dd_entity_reads(v_e, '$role_ids')
                THEN jsonb_build_object('$role_ids', public.jl_role_ids()) ELSE '{}'::jsonb END;

    v_differs := format(
        'SELECT ROW(%1$s) IS DISTINCT FROM ROW(%2$s) FROM jsonb_populate_record(NULL::public.%3$I, $1) o, jsonb_populate_record(NULL::public.%3$I, $2) n',
        (SELECT string_agg(format('o.%I::text', c), ', ') FROM unnest(v_cols) c),
        (SELECT string_agg(format('n.%I::text', c), ', ') FROM unnest(v_cols) c),
        p_table);
    -- The record is found by its stored key ($2), not by the computed one: a
    -- rule may name the key column, and matching on the value it produces
    -- would skip the record silently, or write another record that happens to
    -- carry that key. Found by the stored key, a moved key reaches the key
    -- checks (pk_immutable, zz_key_check_update) and refuses the change.
    v_write := format(
        'UPDATE public.%1$I x SET (%2$s) = ROW(%3$s) FROM jsonb_populate_record(NULL::public.%1$I, $1) n, jsonb_populate_record(NULL::public.%1$I, $2) o WHERE x.%4$I = o.%4$I',
        p_table,
        (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_cols) c),
        (SELECT string_agg(format('n.%I', c), ', ') FROM unnest(v_cols) c),
        v_e.id_column);

    BEGIN
        -- Two scans, because ALTER TABLE refuses a table this session has a cursor
        -- open on. The first stops at the first record that moves, so a pass with
        -- nothing to write takes no lock and leaves no DDL in the audit log.
        FOR v_old IN EXECUTE format('SELECT to_jsonb(t) FROM public.%I t', p_table) LOOP
            v_new := computed_values(v_e.computed_fields, v_old || v_ctx || jsonb_build_object('$old', v_old));
            EXECUTE v_differs INTO v_moved USING v_old, v_new;
            EXIT WHEN v_moved;
        END LOOP;
        IF NOT COALESCE(v_moved, FALSE) THEN
            RETURN;
        END IF;

        v_undo := dd_backfill_mute(p_table);
        FOR v_old IN EXECUTE format('SELECT to_jsonb(t) FROM public.%I t', p_table) LOOP
            v_new := computed_values(v_e.computed_fields, v_old || v_ctx || jsonb_build_object('$old', v_old));
            EXECUTE v_differs INTO v_moved USING v_old, v_new;
            IF v_moved THEN
                EXECUTE v_write USING v_new, v_old;
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            RAISE EXCEPTION 'computed_fields on ${table} cannot be applied to record ${record_id}: ${problem}'
                USING ERRCODE = '90908',
                      HINT = jsonb_build_object('table', p_table, 'record_id', v_old -> v_e.id_column,
                                                'problem', v_msg, 'cause_code', v_state)::text;
    END;

    FOREACH v_stmt IN ARRAY v_undo LOOP
        EXECUTE v_stmt;
    END LOOP;
END;
$fn$ LANGUAGE plpgsql SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';

COMMENT ON FUNCTION computed_backfill(TEXT) IS
'Applies an entity''s computed_fields to its existing records, writing only those whose value moves, without touching updated_at, the audit log, queues or RACI events. A record that cannot take its new value refuses the change (90908).';

REVOKE EXECUTE ON FUNCTION computed_backfill(TEXT) FROM PUBLIC;

-- The other order of the two steps: a rule that named a field before it existed.
-- zz_ puts it after add_field_trigger, which creates the column. A computed_label
-- row is not handled here: the label column only arrives with its table, from
-- create_dd_table (no records yet) or enable_dd_table, whose switch to managed
-- runs computed_backfill from manage_record_logic_trigger once the rules are built.
CREATE OR REPLACE FUNCTION zz_computed_field_added()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.ctype = 'computed' THEN
        PERFORM computed_backfill(NEW.table_name);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION zz_computed_field_added() IS
'AFTER INSERT trigger function on fields: applies the rule to existing records when a field arrives that a computed rule already names.';

REVOKE EXECUTE ON FUNCTION zz_computed_field_added() FROM PUBLIC;

CREATE OR REPLACE TRIGGER zz_computed_field_added
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION zz_computed_field_added();

-- =====================================================
-- STEP 3: Per-row SELECT policy generator (select_rule)
-- =====================================================
-- When an entity has a non-empty select_rule (a JsonLogic object), this
-- function generates two helper functions and rebuilds the SELECT, UPDATE and
-- DELETE policies so each row is filtered by the rule. The two-argument helper
-- merges the row with a statement context handed to it; the one-argument helper
-- resolves that context itself. Reserved variables are
-- ($today, $now, $user_id, and $role_ids for a rule that reads it — there is
-- no $old/$mode for a read),
-- evaluates the JsonLogic rule, and returns true only when the result is truthy.

-- The reserved JsonLogic variables that do not vary within a statement. RLS
-- quals reach this through an uncorrelated sub-select so the planner turns it
-- into an InitPlan and evaluates it once per statement instead of once per row;
-- 0940_test_policy_subselect_form.sql pins that shape against a well-meaning
-- edit to a bare call.
--
-- rbac.uid() is called directly and first. It is what refuses a session with no
-- valid claims, and this function is the only refusal on the select_rule read
-- path: that policy's USING clause carries no permission conjunct, and the
-- generated predicate swallows every error from rule evaluation. Reaching uid()
-- indirectly is not equivalent - rbac.ensure_context_initialized() returns early
-- on an already-initialized session without calling it, so the gate would hold
-- only on the first statement of a transaction.
--
-- The user id comes from rbac.user_id() rather than from app.current_user_id.
-- That setting is client-writable in a direct SQL session, and rbac.user_id()
-- derives the value instead of believing it. is_raci_actor and has_consultation
-- in 0370_raci.sql still read the setting raw after calling ensure_context_initialized,
-- so this is not the last raw read in the codebase - it is one fewer. Going
-- through the helper also means a subject with no users row raises 42501 here,
-- the same answer the other RLS paths give.
CREATE OR REPLACE FUNCTION public.jl_request_context()
RETURNS JSONB AS $$
DECLARE
    v_uid BIGINT;
BEGIN
    PERFORM rbac.uid();
    v_uid := rbac.user_id();
    RETURN jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        -- rbac.user_id() raises rather than returning NULL, so there is no
        -- unresolved case to fold here.
        '$user_id', to_jsonb(v_uid)
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';

COMMENT ON FUNCTION public.jl_request_context() IS
'Statement-constant JsonLogic context: $today, $now and $user_id ($role_ids is added by the predicates whose rule reads it). Raises insufficient_privilege when the session carries no valid claims. Called from RLS quals through an uncorrelated sub-select so it runs once per statement.';

REVOKE EXECUTE ON FUNCTION public.jl_request_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jl_request_context() TO semantius_user;

-- =====================================================
-- A row being written passes the read rule for that one check
-- =====================================================
-- The write policies of an entity with a select_rule ask the rule about the
-- row as it was (USING) and only the edit permission about the row as it will
-- be (WITH CHECK): a write may move a row out of the writer's own rule, which
-- is what reassigning a record to somebody else is. PostgreSQL adds a check of
-- its own. Whenever the statement reads a column of the table - a WHERE on the
-- key, a RETURNING - it holds the new row to the SELECT policy as well, and
-- refuses the statement with 42501 when the rule hides that row. A client
-- addresses a record by its key, so without what follows it could never move
-- one, and an INSERT of a row outside the rule would work only when the client
-- did not ask for the row back.
--
-- A policy sees the row and the session, and nothing in a row says that it is
-- the one being written. So a trigger says it: zz_row_move, the last BEFORE ROW
-- trigger on the table, runs common.row_move_mark_<entity>, a function
-- build_select_rule_policy generates for the entity, which leaves a token for
-- the row in a transaction-local setting. The rule predicate lets a row through
-- when the token is the row's, and common.row_move_clear empties the setting
-- when the statement ends. From then on the writer can no longer read, update
-- or delete the row it moved; RETURNING hands back the row it just wrote.
--
-- The setting is one a client can write wherever the client runs SQL itself,
-- so its value must be something a client cannot make. The token is the
-- SHA-256 of a secret, the transaction id, the table and the key. The secret
-- is a random value in _settings, which no policy opens to the request role,
-- and neither function that reads it from there is executable by that role.
-- The marking function reads it once per transaction and keeps it for the
-- rows after the first in the transaction-local setting app.row_move_secret,
-- which ends with the transaction and so never reaches the next request on a
-- pooled connection. A setting is no secret from a session that runs its own
-- SQL: a bearer session can read app.row_move_secret with current_setting once
-- one of its writes has kept it there, and with it make the token of any row,
-- which gets it past every select_rule. Behind PostgREST or an app server the
-- client runs no SQL, no RPC reads a setting whose name the caller chooses, and
-- none reads app.row_move_secret.
--
-- An INSERT is marked only when no row with its key is stored. The trigger
-- fires before PostgreSQL finds a key conflict, so a marked INSERT ... ON
-- CONFLICT DO NOTHING of a key that names a hidden row would let the same
-- statement read that row. An UPDATE needs no such test: its row passed the
-- rule before the trigger fired.
CREATE OR REPLACE FUNCTION common.row_move_token(p_secret TEXT, p_xid TEXT, p_rel TEXT, p_key TEXT)
RETURNS TEXT AS $$
    SELECT encode(sha256(convert_to(p_secret || '|' || p_xid || '|' || p_rel || '|' || p_key, 'UTF8')), 'hex');
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.row_move_token(TEXT, TEXT, TEXT, TEXT) IS
'The token that lets one row pass its entity''s select_rule while it is being written: the SHA-256 of the secret, the transaction id, the table and the key. NULL when any of them is.';

-- Called when a rule is saved, so the secret is there before any write needs
-- it: the predicate reads it with the snapshot of the statement it runs in,
-- which would not see a secret the same statement had just created.
CREATE OR REPLACE FUNCTION common.row_move_secret()
RETURNS TEXT AS $$
DECLARE
    v_secret TEXT;
BEGIN
    SELECT value INTO v_secret FROM _settings WHERE name = 'row_move_secret';
    IF NOT FOUND THEN
        INSERT INTO _settings (name, value)
        VALUES ('row_move_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
        ON CONFLICT (name) DO NOTHING;
        SELECT value INTO v_secret FROM _settings WHERE name = 'row_move_secret';
    END IF;
    RETURN v_secret;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.row_move_secret() IS
'The secret the row move tokens are made with, created on first use: a random value in _settings that the request role cannot read.';

CREATE OR REPLACE FUNCTION common.row_move_clear()
RETURNS TRIGGER AS $$
BEGIN
    IF COALESCE(current_setting('app.row_move', true), '') <> '' THEN
        PERFORM set_config('app.row_move', '', true);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.row_move_clear() IS
'AFTER INSERT OR UPDATE statement trigger zz_row_move_clear of an entity with a select_rule: empties app.row_move, so a row the statement moved out of the writer''s rule is hidden again.';

-- Not SECURITY DEFINER, and not granted to the request role: it is called by
-- the generated rule predicate, which runs as the owner, and it reads the
-- secret. A caller that reached it as itself would be refused the function,
-- and behind it the table. A transaction that has written nothing has no
-- transaction id and so no token.
CREATE OR REPLACE FUNCTION common.row_move_matches(p_rel TEXT, p_key TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_token  TEXT := current_setting('app.row_move', true);
    v_xid    xid8 := pg_current_xact_id_if_assigned();
    v_secret TEXT;
BEGIN
    IF COALESCE(v_token, '') = '' OR v_xid IS NULL OR p_key IS NULL THEN
        RETURN FALSE;
    END IF;
    SELECT value INTO v_secret FROM _settings WHERE name = 'row_move_secret';
    RETURN COALESCE(v_token = common.row_move_token(v_secret, v_xid::text, p_rel, p_key), FALSE);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.row_move_matches(TEXT, TEXT) IS
'Whether app.row_move holds the token of the given row for the current transaction, that is, whether this row is the one the running statement is writing. Called by the generated select_rule predicates.';

-- The delete step of a target (common.attached_step, 0450_attachables.sql)
-- removes link rows and deletes the multiple records that lost their last
-- target without asking the attachable entity's rules, as a foreign-key cascade
-- would: whoever deletes the target need not be allowed to change those
-- records, nor learn that they exist. While it runs those deletes it leaves
-- the transaction-local setting app.attached_step, which
-- common.attach_record_rules and the generated rule functions honor for that
-- attachable entity's family alone. A client can write the setting, so its
-- value is a token as the row move's: of the secret, the transaction id and
-- the family's root, which a client cannot make (see above). NULL clears it.
-- The check takes any entity of the family and finds the root itself, so a
-- generated rule function names no other entity than its own.
CREATE OR REPLACE FUNCTION common.attached_step_mark(p_root TEXT)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.attached_step',
                       coalesce(common.row_move_token(common.row_move_secret(), pg_current_xact_id()::text,
                                                      'attached_step', p_root), ''),
                       true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.attached_step_mark(TEXT) IS
'Marks, for the rest of the delete step, that the deletes of the attachable family p_root are a cascade of a target''s delete and pass its rules (app.attached_step); NULL clears the mark.';

-- Not SECURITY DEFINER and not granted to the request role, as
-- common.row_move_matches: its callers run as the owner.
CREATE OR REPLACE FUNCTION common.attached_step_marked(p_entity TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_token  TEXT := current_setting('app.attached_step', true);
    v_xid    xid8 := pg_current_xact_id_if_assigned();
    v_secret TEXT;
BEGIN
    IF COALESCE(v_token, '') = '' OR v_xid IS NULL THEN
        RETURN FALSE;
    END IF;
    SELECT value INTO v_secret FROM _settings WHERE name = 'row_move_secret';
    RETURN COALESCE(v_token = common.row_move_token(v_secret, v_xid::text, 'attached_step',
                                                    (SELECT a.table_name FROM dd_ancestors(p_entity) a WHERE a.depth = 0)),
                    FALSE);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION common.attached_step_marked(TEXT) IS
'Whether the running delete step of a target has marked the deletes of the attachable family of p_entity (common.attached_step_mark), so they pass its rules.';

REVOKE EXECUTE ON FUNCTION common.row_move_token(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.row_move_secret() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.row_move_clear() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.row_move_matches(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.attached_step_mark(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.attached_step_marked(TEXT) FROM PUBLIC;

-- On an upgrade the generated predicates and the dictionary's definer code
-- already run as semantius_owner, while a function new in this file stays owned
-- by the installer until 9900_owner_hardening.sql runs last.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION
            common.row_move_token(TEXT, TEXT, TEXT, TEXT),
            common.row_move_secret(),
            common.row_move_matches(TEXT, TEXT),
            common.attached_step_mark(TEXT),
            common.attached_step_marked(TEXT)
        TO semantius_owner;
    END IF;
END $$;

-- The terms an attachable entity (0450_attachables.sql) adds to its own
-- policies, built from its targets by dd_attach_case_sql
-- (0160_dd_functions.sql); both NULL for any other entity.
--   single, owned_shared   a record follows its target, held in attached_to:
--                          sel, the target is visible to the caller; edit, it
--                          is and the caller holds the edit permission of
--                          every level of it
--   a link entity          a row needs both ends: sel, its attachable record
--                          and its target are visible; edit, the attachable
--                          record is visible (for an owned_shared one, its
--                          owner editable as well) and the target meets the
--                          attach permission
-- A multiple entity's records keep their own permissions and get none. The
-- targets are read as the caller through their own policies, so a target's
-- row-level security applies to every record attached to it.
CREATE OR REPLACE FUNCTION dd_attach_policy_terms(p_table_name TEXT, OUT sel TEXT, OUT edit TEXT) AS $$
DECLARE
    v_entity     entities%ROWTYPE;
    v_attachable entities%ROWTYPE;
    v_rel        TEXT;
    v_ref        TEXT;
    v_record     TEXT;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    v_rel := dd_relation(p_table_name, v_entity.id_type);
    v_ref := format('%I.attached_to', v_rel);

    -- The columns come after the table (0450_attachables.sql adds them to an
    -- entity it has just created); until then there is no record to follow.
    IF EXISTS (SELECT 1
                 FROM unnest(ARRAY['attached_to', v_entity.link_of || '_id']) AS c(name)
                WHERE c.name IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                                   WHERE a.attrelid = to_regclass(format('public.%I', v_rel))
                                     AND a.attname = c.name AND a.attnum > 0 AND NOT a.attisdropped)) THEN
        RETURN;
    END IF;

    IF v_entity.link_of IS NOT NULL THEN
        SELECT * INTO v_attachable FROM entities WHERE table_name = v_entity.link_of;
        IF NOT FOUND THEN
            RETURN;
        END IF;
        v_record := format('EXISTS (SELECT 1 FROM public.%I a WHERE a.%I = %I.%I',
                           dd_relation(v_attachable.table_name, v_attachable.id_type), v_attachable.id_column,
                           v_rel, v_attachable.table_name || '_id');
        sel := v_record || ') AND ' || dd_attach_case_sql(v_attachable.table_name, v_ref, 'visible');
        edit := v_record
                || CASE WHEN v_attachable.attach_mode = 'owned_shared'
                        THEN ' AND ' || dd_attach_case_sql(v_attachable.table_name, 'a.attached_to', 'edit')
                        ELSE '' END
                || ') AND ' || dd_attach_case_sql(v_attachable.table_name, v_ref,
                                   CASE WHEN v_attachable.attach_permission = 'edit' THEN 'edit' ELSE 'visible' END);
    ELSIF v_entity.attach_mode IN ('single', 'owned_shared') THEN
        sel := dd_attach_case_sql(p_table_name, v_ref, 'visible');
        edit := dd_attach_case_sql(p_table_name, v_ref, 'edit');
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_policy_terms(TEXT) IS
'The terms the policies of an attachable entity (single, owned_shared) or of a link entity add to its own: sel for SELECT, edit for UPDATE and DELETE. NULL for every other entity. Used by build_select_rule_policy.';

REVOKE EXECUTE ON FUNCTION dd_attach_policy_terms(TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION build_select_rule_policy(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_policy_name TEXT;
    v_body TEXT;
    v_logic_lit TEXT;
    v_rel TEXT;
    v_row_data TEXT;
    v_predicate TEXT;
    v_write_using TEXT;
    v_parent_pred TEXT;
    v_term JSONB;
    v_arg JSONB;
    v_lead TEXT;
    v_rule_pred TEXT;
    v_attach RECORD;
    v_sel TEXT;
    v_ctx TEXT := 'public.jl_request_context()';
    v_mark_name TEXT := 'row_move_mark_' || p_table_name;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- No entity by that name; drop both overloads if they exist. A DROP that
        -- names only one signature is a silent no-op for the other, and the
        -- CASCADE that removes the dependent policies rides on it. The row move
        -- function goes as well, with the trigger that runs it.
        v_fn_name := 'select_rule_' || p_table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, p_table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, p_table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', v_mark_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    -- The policies and the rule functions belong to the entity's physical
    -- relation, <entity>_ext for an is_a or has_a entity, and are named after
    -- it; the functions keep the entity's name.
    v_rel := dd_relation(p_table_name, v_entity.id_type);
    v_fn_name := 'select_rule_' || p_table_name;
    v_policy_name := v_rel || '_select_policy';

    -- Always drop both overloads before rebuilding (CASCADE removes anything
    -- depending on them). Dropping only one leaves the other behind and the
    -- CREATE below then fails with a duplicate-function error.
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, v_rel);
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, v_rel);

    -- Drop the existing select policy so we can recreate it
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_policy_name, v_rel);

    -- On fields, the row of the field's entity in entities takes the place of the view
    -- permission (the catalog rule, 0150_dd_bootstrap.once.sql): one semi-join on entities,
    -- read as the caller, so the read policy of entities decides. The sub-select is
    -- uncorrelated, so PostgreSQL runs it once per statement, as a hashed SubPlan, rather
    -- than once per row. get_record_by_id in 0160_dd_functions.sql holds a row of fields to
    -- the same question.
    IF p_table_name = 'fields' THEN
        v_parent_pred := '(fields.table_name IN (SELECT p.table_name FROM public.entities p))';
    END IF;

    -- An attachable record that follows its target, and a link row, add the
    -- terms of their targets to every policy below (dd_attach_policy_terms).
    v_attach := dd_attach_policy_terms(p_table_name);

    -- Every rbac.has_permission() below is wrapped in a scalar sub-select: PostgreSQL then
    -- evaluates it once per statement (InitPlan) instead of once per row (1.7 s vs 10 ms on
    -- 100k rows). 0940_test_policy_subselect_form.sql fails on the bare per-row form.
    --
    -- If select_rule is empty, the row a caller may reach is the one its view permission
    -- lets it read, or on fields the semi-join on entities in its place: SELECT on it,
    -- UPDATE and DELETE on edit_permission AND it, no per-row rule.
    IF v_entity.select_rule = '{}'::jsonb THEN
        -- No rule, so no row can leave it: the two row move triggers go, and
        -- the function the first one runs.
        EXECUTE format('DROP TRIGGER IF EXISTS zz_row_move ON %I', v_rel);
        EXECUTE format('DROP TRIGGER IF EXISTS zz_row_move_clear ON %I', v_rel);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I()', v_mark_name);
        v_sel := COALESCE(v_parent_pred, format('(SELECT rbac.has_permission(%L))', v_entity.view_permission));
        IF v_attach.sel IS NOT NULL THEN
            v_sel := v_sel || ' AND ' || v_attach.sel;
        END IF;
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (%s)',
            v_policy_name, v_rel, v_sel);
        -- The view permission has to be in the USING of UPDATE and DELETE itself.
        -- PostgreSQL holds the rows an UPDATE or DELETE touches to the SELECT policy only
        -- when the statement reads a column of the table, so with the edit permission
        -- alone, a caller that may read no row could still overwrite every row with
        -- constants and delete every row: UPDATE t SET c = 'x', DELETE FROM t, WHERE true,
        -- RETURNING 1. The new row of an UPDATE is held to the edit permission only, as an
        -- inserted row is. When the two permissions are the same, one check says it all.
        -- Both parts are quoted with %L before they are joined. Pinned by
        -- 0610_test_select_rule_write_protection.sql. On fields the semi-join on entities
        -- stands in for the view permission here as well.
        v_write_using := format('(SELECT rbac.has_permission(%L))', v_entity.edit_permission);
        IF v_parent_pred IS NOT NULL THEN
            v_write_using := v_write_using || ' AND ' || v_parent_pred;
        ELSIF v_entity.view_permission IS DISTINCT FROM v_entity.edit_permission THEN
            v_write_using := v_write_using
                || format(' AND (SELECT rbac.has_permission(%L))', v_entity.view_permission);
        END IF;
        IF v_attach.edit IS NOT NULL THEN
            v_write_using := v_write_using || ' AND ' || v_attach.edit;
        END IF;
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_rel || '_update_policy', v_rel);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_rel || '_delete_policy', v_rel);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING (%s) WITH CHECK ((SELECT rbac.has_permission(%L)))',
            v_rel || '_update_policy', v_rel, v_write_using, v_entity.edit_permission);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING (%s)',
            v_rel || '_delete_policy', v_rel, v_write_using);
        RETURN;
    END IF;

    v_logic_lit := quote_literal(v_entity.select_rule::text);

    -- $role_ids (public.jl_role_ids) only for a rule that reads it, merged
    -- into the request context of both overloads below; once per statement,
    -- as the rest of the context.
    IF dd_rule_reads(v_entity.select_rule, '$role_ids') THEN
        v_ctx := '(public.jl_request_context() || jsonb_build_object(''$role_ids'', public.jl_role_ids()))';
    END IF;

    -- The data the rule sees. A policy on <entity>_ext hands the function
    -- that table's row, which holds the entity's own fields only, so the rule
    -- of an is_a or has_a entity also gets its base's row - the whole record
    -- up to the root, since the base of an is_a is itself read through its
    -- view - merged under the own row. As the definer, which bypasses RLS, the
    -- base row is read whatever the caller may see: the rule decides about
    -- this part of the record, and the base's own policies decide about the
    -- base's part.
    IF v_rel = p_table_name THEN
        v_row_data := 'to_jsonb(p_row)';
    ELSE
        v_row_data := format(
            'COALESCE((SELECT to_jsonb(b) FROM public.%I b WHERE b.%I = p_row.%I), ''{}''::jsonb) || to_jsonb(p_row)',
            v_entity.id_refentity, v_entity.id_column, v_entity.id_column);
    END IF;

    -- Build the per-row evaluation function in two overloads.
    --
    -- The two-argument form takes the statement-constant context as a parameter
    -- so the policies can hoist it out of the per-row loop. It answers rule
    -- questions for anyone able to supply a context, which is unavoidable: an
    -- RLS qual runs with the querying role's privileges, so semantius_user must
    -- hold EXECUTE. It returns no row data - the caller already holds the row it
    -- passes in, and RLS still filters any relation being scanned. The
    -- permission operators resolve against the session rather than against
    -- $user_id, so a forged context cannot widen what a caller may see. It does
    -- merge the context over the row, so a caller can shadow a column and aim an
    -- operator such as has_consultation at a record it cannot read; the answer
    -- is one boolean, never its contents.
    --
    -- The one-argument form supplies the context itself and is the entry point
    -- for callers outside a policy, get_record_by_id in 0160_dd_functions.sql
    -- among them. It carries the authentication gate for those callers, which is
    -- why it must not be reduced to a convenience wrapper that skips it.
    -- Both bodies are wrapped by dd_dollar_quote: the rule is a quoted literal
    -- inside the first, and a fixed body tag would be ended by the same tag
    -- written into the rule.
    --
    -- A stored rule that is not one operation gets a predicate that is false
    -- for every row. The save refuses such a rule (check_entity_rules), so it
    -- is here only when it was stored past the save, and evaluating it would
    -- return the object itself, which is truthy: every row would be visible
    -- to everyone, whatever the rule was meant to say. Hiding every row is the
    -- failure that gets noticed and that leaks nothing.
    IF jl_is_operation(v_entity.select_rule) THEN
        v_predicate := format($SEL$
DECLARE
    v_data jsonb;
    v_result jsonb;
BEGIN
    -- Without a context there is no caller to decide for. Row and context
    -- merge to NULL, a rule such as "user_id == $user_id" then compares null
    -- with null, and the answer would be true for any row.
    IF p_ctx IS NULL THEN
        RETURN FALSE;
    END IF;

    v_data := %s || p_ctx;

    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        -- A rule that raises hides the row, and says so once per transaction
        -- and entity: with the SQLSTATE, and without the message, which can
        -- quote a value of the very row being hidden. The entities already
        -- named are kept in a transaction-local setting.
        IF NOT (%3$L = ANY(string_to_array(
                    COALESCE(current_setting('app.select_rule_warned', true), ''), ','))) THEN
            RAISE WARNING 'select_rule of %% raised %%: the rows it raises on are hidden', %3$L, SQLSTATE;
            PERFORM set_config('app.select_rule_warned',
                               concat_ws(',', NULLIF(current_setting('app.select_rule_warned', true), ''), %3$L),
                               true);
        END IF;
        RETURN FALSE;
    END;

    IF jl_truthy(v_result) THEN
        RETURN TRUE;
    END IF;
    -- The rule hides the row. It passes all the same when it is the row the
    -- running statement is writing (common.row_move_mark_<entity>). The
    -- setting is tested here so that a read pays nothing more for a hidden row.
    IF COALESCE(current_setting('app.row_move', true), '') = '' THEN
        RETURN FALSE;
    END IF;
    RETURN common.row_move_matches(%L, to_jsonb(p_row) ->> %L);
END;
$SEL$, v_row_data, v_logic_lit, p_table_name, v_rel, v_entity.id_column);
    ELSE
        v_predicate := $SEL$
BEGIN
    RETURN FALSE;
END;
$SEL$;
    END IF;

    v_body := format($FUNC$
CREATE FUNCTION public.%I(p_row public.%I, p_ctx jsonb) RETURNS BOOLEAN AS %s LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';

CREATE FUNCTION public.%I(p_row public.%I) RETURNS BOOLEAN AS %s LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp SET timezone = 'UTC' SET intervalstyle = 'iso_8601';
$FUNC$, v_fn_name, v_rel,
        dd_dollar_quote(v_predicate),
        v_fn_name, v_rel,
        dd_dollar_quote(format($SEL$
    SELECT public.%I(p_row, %s);
$SEL$, v_fn_name, v_ctx)));

    EXECUTE v_body;

    -- Both overloads need their own grants and comment: privileges and comments
    -- attach to a signature, not to a name, so an overload left out is callable
    -- by any role and undocumented. 0900_test_security.sql and
    -- 0910_test_no_unsafe_functions.sql sweep for exactly that.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(public.%I, jsonb) FROM PUBLIC', v_fn_name, v_rel);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(public.%I, jsonb) TO semantius_user', v_fn_name, v_rel);
    EXECUTE format(
        'COMMENT ON FUNCTION public.%I(public.%I, jsonb) IS %L',
        v_fn_name, v_rel,
        format('Per-row FOR SELECT RLS predicate evaluating the select_rule JsonLogic for entity "%s" against a caller-supplied statement context. Generated by build_select_rule_policy.', p_table_name));

    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(public.%I) FROM PUBLIC', v_fn_name, v_rel);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(public.%I) TO semantius_user', v_fn_name, v_rel);
    EXECUTE format(
        'COMMENT ON FUNCTION public.%I(public.%I) IS %L',
        v_fn_name, v_rel,
        format('Per-row FOR SELECT RLS predicate evaluating the select_rule JsonLogic for entity "%s", resolving the request context itself. Generated by build_select_rule_policy.', p_table_name));

    -- The context sub-select is uncorrelated, so the planner lifts it to an
    -- InitPlan and resolves the request once per statement rather than once per
    -- scanned row. It has to appear in all three policies: a USING clause is
    -- evaluated per row for every UPDATE and DELETE as well, so a policy left
    -- with a bare call keeps paying per row on the write path.
    v_rule_pred := format('public.%I(%I.*, (SELECT %s))', v_fn_name, v_rel, v_ctx);

    -- The leading terms of a rule's top-level "or" that are has_permission of a
    -- name written into the rule, such as {"has_permission": "admin"} in the rules
    -- of entities and modules, are checked once per statement as well: each one
    -- goes into the policy as its own uncorrelated sub-select, an InitPlan, ORed in
    -- front of the per-row predicate, so a holder of one of those permissions pays
    -- no per-row evaluation of the rule (a plpgsql call, to_jsonb of the row and
    -- the JsonLogic evaluator, for every row a statement reads). The predicate
    -- still evaluates the whole rule, and the answer is the same: "or" stops at
    -- the first truthy term, left to right, so whenever one of these terms holds
    -- the rule holds and no later term is evaluated, and when none holds the rule
    -- is evaluated as before. Only the leading terms qualify: a term after any
    -- other one is not reached when that one raises, which hides the row, and
    -- hoisting it would admit that row. Only a literal name qualifies, a string: a
    -- name read from the row ({"var": ...}) differs per row and cannot be checked
    -- once. The request context comes first, in a sub-select of its own: it is
    -- what refuses a session without valid claims (jl_request_context calls
    -- rbac.uid()), which a warm has_permission does not ask again, so a statement
    -- is refused exactly where the predicate alone would refuse it. Each name is
    -- quoted with %L, and the terms are joined with || rather than concat_ws():
    -- plpgsql_check's security check (deno task lint-sql) follows quoting through
    -- || and not through concat_ws, and would report the three policy statements
    -- below as built from unsanitized text.
    IF jl_is_operation(v_entity.select_rule)
       AND v_entity.select_rule ? 'or'
       AND jsonb_typeof(v_entity.select_rule -> 'or') = 'array' THEN
        FOR v_term IN
            SELECT t.term
              FROM jsonb_array_elements(v_entity.select_rule -> 'or') WITH ORDINALITY AS t(term, ord)
             ORDER BY t.ord
        LOOP
            v_arg := NULL;
            IF jsonb_typeof(v_term) = 'object' AND v_term - 'has_permission' = '{}'::jsonb
               AND v_term ? 'has_permission' THEN
                v_arg := v_term -> 'has_permission';
            END IF;
            EXIT WHEN v_arg IS NULL OR jsonb_typeof(v_arg) <> 'string';
            v_lead := COALESCE(v_lead || ' OR ', '') || format('(SELECT rbac.has_permission(%L))', v_arg #>> '{}');
        END LOOP;
        IF v_lead IS NOT NULL THEN
            v_rule_pred := format('((((SELECT public.jl_request_context()) IS NOT NULL) AND (%s)) OR %s)',
                                  v_lead, v_rule_pred);
        END IF;
    END IF;

    v_sel := v_rule_pred;
    IF v_attach.sel IS NOT NULL THEN
        v_sel := v_sel || ' AND ' || v_attach.sel;
    END IF;
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (%s)',
        v_policy_name, v_rel, v_sel);

    -- The canonical predicate ALSO gates writes: edit_permission AND the row rule. Because a
    -- policy USING clause is evaluated per-row by PostgreSQL for every UPDATE/DELETE regardless
    -- of statement shape, a bare "UPDATE t SET ..." cannot reach rows the SELECT policy hides.
    -- WITH CHECK is edit_permission only: there is no post-image rule, so a write may move a
    -- row out of its own rule. PostgreSQL holds the new row to the SELECT policy as well
    -- whenever the statement reads a column, and the two triggers below are what let the
    -- row being written pass that check.
    PERFORM common.row_move_secret();

    -- The function zz_row_move runs is generated per entity so that it can read the
    -- key as a column of NEW and look a stored key up with a static statement, which
    -- PL/pgSQL plans once per session: one function for every table would have to
    -- turn the whole row into jsonb to find the key, and plan the lookup again on
    -- every INSERT. It reads the secret from _settings for the first row of a
    -- transaction and keeps it in app.row_move_secret for the rows after it.
    -- set_config(..., true) ends that setting with the transaction, so a pooled
    -- connection never hands it to the next request. The token names TG_TABLE_NAME,
    -- the relation the predicate above passes to common.row_move_matches. The key
    -- column and the relation are quoted with %I, and the body is wrapped by
    -- dd_dollar_quote.
    EXECUTE format($FUNC$
CREATE OR REPLACE FUNCTION common.%I() RETURNS TRIGGER AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
$FUNC$, v_mark_name, dd_dollar_quote(format($MARK$
DECLARE
    v_secret TEXT;
BEGIN
    IF NEW.%1$I IS NULL THEN
        PERFORM set_config('app.row_move', '', true);
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF EXISTS (SELECT 1 FROM public.%2$I t WHERE t.%1$I = NEW.%1$I) THEN
            PERFORM set_config('app.row_move', '', true);
            RETURN NEW;
        END IF;
    END IF;
    v_secret := current_setting('app.row_move_secret', true);
    IF COALESCE(v_secret, '') = '' THEN
        v_secret := common.row_move_secret();
        PERFORM set_config('app.row_move_secret', v_secret, true);
    END IF;
    PERFORM set_config('app.row_move',
                       common.row_move_token(v_secret, pg_current_xact_id()::text,
                                             TG_TABLE_NAME::text, NEW.%1$I::text),
                       true);
    RETURN NEW;
END;
$MARK$, v_entity.id_column, v_rel)));
    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I() FROM PUBLIC', v_mark_name);
    EXECUTE format(
        'COMMENT ON FUNCTION common.%I() IS %L',
        v_mark_name,
        format('BEFORE INSERT OR UPDATE row trigger function of zz_row_move on the table of entity "%s": leaves the token of the row being written in the transaction-local setting app.row_move, so that row passes the select_rule when PostgreSQL holds the new row to the read policy, and keeps the secret it reads in app.row_move_secret for the rest of the transaction. An INSERT whose key is already stored is not marked. Generated by build_select_rule_policy.', p_table_name));

    -- The name zz_row_move sorts after every other BEFORE ROW trigger of an entity
    -- table, so the key is the one the row is stored under: a TypeID is assigned by a
    -- trigger, and a computed field may write the key.
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER zz_row_move BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION common.%I()',
        v_rel, v_mark_name);
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER zz_row_move_clear AFTER INSERT OR UPDATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION common.row_move_clear()',
        v_rel);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_rel || '_update_policy', v_rel);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_rel || '_delete_policy', v_rel);
    IF v_attach.edit IS NOT NULL THEN
        v_rule_pred := v_rule_pred || ' AND ' || v_attach.edit;
    END IF;
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING ((SELECT rbac.has_permission(%L)) AND %s) WITH CHECK ((SELECT rbac.has_permission(%L)))',
        v_rel || '_update_policy', v_rel, v_entity.edit_permission, v_rule_pred, v_entity.edit_permission);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING ((SELECT rbac.has_permission(%L)) AND %s)',
        v_rel || '_delete_policy', v_rel, v_entity.edit_permission, v_rule_pred);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION build_select_rule_policy IS
'The one generator of an entity''s SELECT, UPDATE and DELETE policies, called when the entity is created or made managed and whenever its view_permission, edit_permission or select_rule changes. Generates (or drops) the per-row policy function that evaluates the select_rule JsonLogic against a row, in two overloads - one taking the request context, one without - and builds the three policies on top of it, UPDATE and DELETE as the edit permission and the rule, with the zz_row_move triggers that let a write move a row out of the writer''s own rule and the function common.row_move_mark_<entity> the first of them runs. With no select_rule set, SELECT is the view permission, UPDATE and DELETE are the edit permission and the view permission, and the triggers and that function are dropped. On fields, one semi-join on entities takes the place of the view permission: a row of fields is visible exactly when the row of its entity in entities is. The policies of an attachable entity that follows its target and of a link entity carry the terms of dd_attach_policy_terms as well. The generated functions have EXECUTE revoked from PUBLIC.';

REVOKE EXECUTE ON FUNCTION build_select_rule_policy(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 4: Trigger on entities to keep select_rule policy in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_select_rule_policy()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- The rule function of an is_a or has_a entity reads its base by name.
        -- id_refentity changes only when the base is renamed (ON UPDATE
        -- CASCADE), and a function left reading the old name fails every read
        -- of the entity with 42P01.
        IF OLD.select_rule IS DISTINCT FROM NEW.select_rule
           OR OLD.view_permission IS DISTINCT FROM NEW.view_permission
           OR OLD.managed IS DISTINCT FROM NEW.managed
           OR OLD.table_name IS DISTINCT FROM NEW.table_name
           OR OLD.id_refentity IS DISTINCT FROM NEW.id_refentity THEN
            PERFORM build_select_rule_policy(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    -- DELETE. Both overloads, or the survivor blocks the next CREATE under
    -- this name, and the row move function, which outlives the table it was
    -- the trigger of.
    v_fn_name := 'select_rule_' || OLD.table_name;
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, dd_relation(OLD.table_name, OLD.id_type));
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, dd_relation(OLD.table_name, OLD.id_type));
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', 'row_move_mark_' || OLD.table_name);
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION manage_select_rule_policy IS
'AFTER UPDATE OR DELETE trigger function on entities that keeps the SELECT, UPDATE and DELETE policies and the select_rule functions in step with the entity row: it rebuilds them through build_select_rule_policy when the rule, view_permission (which UPDATE and DELETE check as well), managed, the name or id_refentity changes, and drops the rule functions and the row move function when the entity is deleted. It does not fire on INSERT: create_dd_table builds the policies of a new managed entity itself, through create_entity_policies.';

CREATE OR REPLACE TRIGGER manage_select_rule_policy_trigger
    AFTER UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_select_rule_policy();

REVOKE EXECUTE ON FUNCTION manage_select_rule_policy() FROM PUBLIC;
