-- =====================================================
-- ROLLUP FIELDS
-- =====================================================
-- Repeatable. A rollup field is a field of an ordinary format whose value the
-- database computes over the records of a child entity: sum, min, max, avg or
-- count of a child field, over the child records whose reference or parent
-- field points at the record, optionally narrowed by a filter. The definition
-- is the fields.rollup object (0130_dd_schema.once.sql, described in its field
-- row in 0150_dd_bootstrap.once.sql); the field's ctype is derived as 'rollup',
-- the one managed marker that does not make a core column (dd_ctype_is_core).
--
-- What this file generates for a rollup, all as the dictionary owner:
--   * common.rollup_<child>_<link>(), one per (child table, link field), and
--     the statement-level triggers <name>_ins, _upd, _del and _trc on the child
--     table: per statement it locks the parents the statement touched, then one
--     UPDATE recomputes every rollup column using that link for them, and writes
--     a parent only when a value moved.
--   * common.rollup_guard_<parent>() behind the row trigger a_rollup_guard on
--     the parent table: a rollup column cannot be written by hand. On INSERT it
--     is the empty aggregate, on UPDATE a changed value is recomputed, so the
--     stored value is the truth whoever wrote the row.
--   * The parent's update_<parent>_updated_at and audit_i_u_d triggers carry
--     the rollup columns as ignored columns: a child write that only moves a
--     total is not an edit of the parent record.
--
-- The filter is JsonLogic compiled to SQL by rollup_filter_sql: a fixed subset
-- (and, or, !, !!, ==, ===, !=, !==, <, <=, >, >=, in with a literal list, var
-- naming a column of the child record). Identifiers reach the SQL only after a
-- catalog lookup and through %I, literals only through %L with a cast to the
-- column's catalog type, and everything else is refused when the definition is
-- saved. docs/rollup-fields.md has the rules, docs/jsonlogic-optimization-
-- candidates.md records why this subset exists next to the one interpreter.
--
-- Everything here binds late (PL/pgSQL), so the generated functions reference
-- the tables of the moment they are built; renames and deletes rebuild or drop
-- them through the triggers at the end of this file.

-- =====================================================
-- Errors
-- =====================================================
-- The messages keep their ${placeholders}: a client fills them from the JSON
-- hint, as docs/error-contract.md describes for every code.
CREATE OR REPLACE FUNCTION rollup_refuse(p_code TEXT, p_message TEXT, p_hint JSONB)
RETURNS VOID AS $fn$
BEGIN
    RAISE EXCEPTION USING ERRCODE = p_code, MESSAGE = p_message, HINT = p_hint::text;
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_refuse(TEXT, TEXT, JSONB) IS
'Raises a rollup error of the given code with the error contract''s message template and a JSON hint.';

REVOKE EXECUTE ON FUNCTION rollup_refuse(TEXT, TEXT, JSONB) FROM PUBLIC;

-- =====================================================
-- Names of the generated objects
-- =====================================================
-- An identifier is cut to 63 bytes silently, and two long names cut to the
-- same 63 bytes would be one function replacing the other without a word. A
-- name that would not fit with its longest suffix (_ins, 4 bytes) is shortened
-- and given 8 characters of the md5 of what it names instead.
CREATE OR REPLACE FUNCTION rollup_object_name(p_child TEXT, p_link TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = public
AS $fn$
    SELECT CASE WHEN length('rollup_' || p_child || '_' || p_link) <= 59
                THEN 'rollup_' || p_child || '_' || p_link
                ELSE 'rollup_' || left(p_child || '_' || p_link, 42) || '_' || left(md5(p_child || '.' || p_link), 8)
           END
$fn$;

COMMENT ON FUNCTION rollup_object_name(TEXT, TEXT) IS
'Name of the maintenance function common.rollup_<child>_<link> and the stem of its four triggers; shortened with an md5 tail when the full name would not fit an identifier.';

CREATE OR REPLACE FUNCTION rollup_guard_name(p_parent TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = public
AS $fn$
    SELECT CASE WHEN length('rollup_guard_' || p_parent) <= 59
                THEN 'rollup_guard_' || p_parent
                ELSE 'rollup_guard_' || left(p_parent, 37) || '_' || left(md5(p_parent), 8)
           END
$fn$;

COMMENT ON FUNCTION rollup_guard_name(TEXT) IS
'Name of the guard function common.rollup_guard_<parent> behind the a_rollup_guard trigger; shortened with an md5 tail when the full name would not fit an identifier.';

REVOKE EXECUTE ON FUNCTION rollup_object_name(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_guard_name(TEXT) FROM PUBLIC;

-- =====================================================
-- The filter compiler
-- =====================================================
-- A rollup filter is JsonLogic, but it runs inside a generated SQL aggregate
-- as the dictionary owner, so it is compiled, not interpreted, and compiled
-- from a fixed subset:
--   * a column is {"var": "<name>"}: a plain name, present in pg_attribute of
--     the child table, of a type in the allow-list below, emitted through %I;
--   * a literal is a string, number, boolean or null, emitted through %L with
--     a cast to the catalog type of the column it is compared with (or its own
--     natural type when both sides are literals);
--   * operators are and, or, !, !!, ==, ===, !=, !==, <, <=, >, >= (the last
--     two forms also take three operands), in with a list of literals, and a
--     bare boolean column;
--   * a value may also be one of the date operators, compiled to a call of the
--     interpreter's own function for it (see rollup_filter_date_op).
-- Anything else is refused with 90265 naming what was refused, never
-- approximated. The semantics are SQL's, not the interpreter's coercion: ==
-- and != are IS [NOT] DISTINCT FROM, so null compares as JsonLogic expects,
-- while an ordering comparison with a NULL column excludes the row where
-- evaluate_json_logic would have read NULL as 0, and a string meets a number
-- only through an explicit cast. docs/jsonlogic-optimization-candidates.md
-- records why no larger translation is attempted.
--
-- The compiled text is probed with EXPLAIN when the definition is saved
-- (zz_validate_rollup_field), so a cast that cannot succeed fails there and
-- not at the first child write. There is no depth limit: an absurd filter is
-- the same trusted-administrator cost SECURITY.md accepts for an absurd rule.

CREATE OR REPLACE FUNCTION rollup_filter_problem(p_problem TEXT)
RETURNS VOID AS $fn$
BEGIN
    PERFORM rollup_refuse('90265',
        'Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}',
        jsonb_build_object('problem', p_problem));
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_filter_problem(TEXT) IS
'Raises 90265 for a filter the rollup compiler refuses; rollup_definition adds the field''s table and name to the hint.';

REVOKE EXECUTE ON FUNCTION rollup_filter_problem(TEXT) FROM PUBLIC;

-- A column reference. The lookup is pinned to the child relation, to attnum > 0
-- and to columns that are not dropped, so no other table's column and no system
-- column can be named; a column that exists physically but has no fields row
-- is reachable, which is no leak (the aggregate reads the child's own columns
-- as the owner anyway) and keeps the compiler independent of the dictionary.
CREATE OR REPLACE FUNCTION rollup_filter_column(p_name TEXT, p_rel TEXT, p_alias TEXT)
RETURNS JSONB AS $fn$
DECLARE
    v_oid  OID;
    v_type TEXT;
BEGIN
    IF p_name LIKE '$%' THEN
        PERFORM rollup_filter_problem(format('%s is a request variable; a rollup filter can only use columns of the child record', p_name));
    END IF;
    IF p_name !~ '^[a-z_][a-z0-9_]*$' THEN
        PERFORM rollup_filter_problem(format('var %s is not a plain column name', p_name));
    END IF;
    SELECT a.atttypid, pg_catalog.format_type(a.atttypid, a.atttypmod)
      INTO v_oid, v_type
      FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', p_rel))
       AND a.attname = p_name
       AND a.attnum > 0
       AND NOT a.attisdropped;
    IF NOT FOUND THEN
        PERFORM rollup_filter_problem(format('column %s does not exist on %s', p_name, p_rel));
    END IF;
    -- The catalog type, not the field's format: format_to_data_type falls back
    -- to TEXT for what it does not know, and a wrong type here would surface as
    -- a planner error inside a fields trigger.
    IF v_oid <> ALL (ARRAY['text', 'bool', 'int2', 'int4', 'int8', 'numeric', 'float4', 'float8',
                           'date', 'timestamptz', 'time', 'uuid', 'interval']::regtype[])
       AND v_oid <> 'common.typeid'::regtype THEN
        PERFORM rollup_filter_problem(format('column %s has type %s, which a rollup filter cannot compare', p_name, v_type));
    END IF;
    RETURN jsonb_build_object(
        'sql',    format('%I.%I', p_alias, p_name),
        'type',   v_type,
        'kind',   CASE WHEN v_oid = 'bool'::regtype THEN 'bool'
                       WHEN v_oid = 'common.typeid'::regtype THEN 'typeid'
                       WHEN v_oid = 'interval'::regtype THEN 'interval'
                       ELSE 'other' END,
        'is_var', TRUE);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_column(TEXT, TEXT, TEXT) IS
'Resolves a var of a rollup filter against pg_attribute of the child relation and returns its SQL reference and catalog type, or raises 90265.';

-- A literal, cast to the type of the column it is compared with. The type name
-- comes from format_type, so it is safe to splice; the value goes through %L.
-- A TypeID literal is checked here because the domain's CHECK is not folded
-- at plan time and would slip past the EXPLAIN probe.
--
-- A date literal is resolved to UTC here and written out with an explicit
-- offset. Left as the admin wrote it, a value with no offset would be read in the
-- zone of whichever session writes the child, so the same filter could count
-- different records, and 'today' would change meaning with the day.
CREATE OR REPLACE FUNCTION rollup_filter_literal(p_node JSONB, p_type TEXT, p_kind TEXT)
RETURNS TEXT AS $fn$
DECLARE
    v_text   TEXT := p_node #>> '{}';
    v_moment TIMESTAMP;
BEGIN
    CASE jsonb_typeof(p_node)
        WHEN 'string' THEN
            IF p_kind = 'bool' THEN
                PERFORM rollup_filter_problem(format('string %s compared with a boolean column', v_text));
            END IF;
            IF p_kind = 'typeid' AND NOT common.typeid_check_text(v_text) THEN
                PERFORM rollup_filter_problem(format('%s is not a well-formed TypeID', v_text));
            END IF;
            IF p_type IN ('date', 'timestamp with time zone') THEN
                BEGIN
                    v_moment := jl_date_utc('rollup filter', p_node);
                EXCEPTION WHEN SQLSTATE '90915' OR data_exception THEN
                    PERFORM rollup_filter_problem(format('%s is not an ISO 8601 date or date-time', v_text));
                END;
                RETURN format('%L::%s',
                              to_char(v_moment, CASE p_type WHEN 'date' THEN 'YYYY-MM-DD' ELSE 'YYYY-MM-DD"T"HH24:MI:SS"+00:00"' END),
                              p_type);
            END IF;
            RETURN format('%L::%s', v_text, COALESCE(p_type, 'text'));
        WHEN 'number' THEN
            IF p_kind IN ('bool', 'typeid') THEN
                PERFORM rollup_filter_problem(format('number %s compared with a column of type %s', v_text, p_type));
            END IF;
            RETURN format('%L::%s', v_text, COALESCE(p_type, 'numeric'));
        WHEN 'boolean' THEN
            IF p_type IS NOT NULL AND p_kind <> 'bool' THEN
                PERFORM rollup_filter_problem(format('boolean %s compared with a column of type %s', v_text, p_type));
            END IF;
            RETURN CASE WHEN v_text = 'true' THEN 'TRUE' ELSE 'FALSE' END;
        WHEN 'null' THEN
            RETURN 'NULL';
        ELSE
            PERFORM rollup_filter_problem('a literal must be a string, a number, a boolean or null');
    END CASE;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_literal(JSONB, TEXT, TEXT) IS
'Emits a scalar JSON literal of a rollup filter as a quoted SQL literal cast to the given catalog type (its natural type when none), or raises 90265.';

-- A duration column in ISO 8601 whatever the session's interval style, because
-- that is the only spelling jl_date_add accepts. The generated rollup triggers run
-- in the style of whichever session writes the child.
CREATE OR REPLACE FUNCTION rollup_interval_iso(p_value INTERVAL)
RETURNS JSONB AS $fn$
BEGIN
    RETURN to_jsonb(p_value);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public SET intervalstyle = 'iso_8601';

COMMENT ON FUNCTION rollup_interval_iso(INTERVAL) IS
'An interval as a JSON string in ISO 8601, whatever the session''s interval style. Used by compiled rollup filters.';

-- The date argument of a date operator: a date or date-time column, a literal, or
-- another date operator. Returns its SQL as jsonb and a value of the same kind for
-- rollup_filter_date_op to check the operator with.
CREATE OR REPLACE FUNCTION rollup_filter_date_arg(p_node JSONB, p_rel TEXT, p_alias TEXT)
RETURNS JSONB AS $fn$
DECLARE
    v_arg JSONB;
BEGIN
    IF jsonb_typeof(p_node) = 'string' THEN
        RETURN jsonb_build_object('json_sql', format('%L::jsonb', p_node::text), 'sample', p_node);
    END IF;
    IF jsonb_typeof(p_node) <> 'object' THEN
        PERFORM rollup_filter_problem('a date operator takes a date column, a date literal or another date operator');
    END IF;
    v_arg := rollup_filter_operand(p_node, p_rel, p_alias);
    IF v_arg ->> 'type' NOT IN ('date', 'timestamp with time zone') THEN
        PERFORM rollup_filter_problem(format('%s is not a date', p_node));
    END IF;
    IF v_arg ? 'json_sql' THEN
        RETURN v_arg;
    END IF;
    RETURN jsonb_build_object(
        'json_sql', format('to_jsonb(%s)', v_arg ->> 'sql'),
        'sample',   CASE v_arg ->> 'type' WHEN 'date' THEN '"2000-01-31"'::jsonb
                                          ELSE '"2000-01-31T00:00:00+00:00"'::jsonb END);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_date_arg(JSONB, TEXT, TEXT) IS
'Compiles the date argument of a date operator in a rollup filter to SQL yielding jsonb, or raises 90265.';

-- A date operator used as a value.
--
-- It compiles to a call of the interpreter's own jl_date_* function, not to a
-- native expression, which is what lets a date operator be in this subset at all:
-- a filter and a validation rule cannot disagree about it, because there is no
-- second implementation to keep equivalent. The price is a function call per child
-- of the one parent being recomputed.
--
-- The operator name reaches the SQL only after rollup_filter_operand has matched
-- it against a fixed list, and every literal goes through %L as jsonb.
--
-- The arguments are checked by running the interpreter once, with a value of the
-- right kind in place of each column. That applies its own lists of units, parts
-- and tokens and its refusal of a time of day on a date-only value, so a filter
-- that could never work is refused when it is saved and not at the first child
-- write. A date column cannot fail at run time: it can only hold a real date.
--
-- A duration column against a date column is refused here for that reason. It may
-- hold a time of day in some rows and not others, so it would fail on a child write
-- that has nothing wrong with it.
CREATE OR REPLACE FUNCTION rollup_filter_date_op(p_op TEXT, p_args JSONB, p_rel TEXT, p_alias TEXT)
RETURNS JSONB AS $fn$
DECLARE
    v_args    JSONB := CASE WHEN jsonb_typeof(p_args) = 'array' THEN p_args ELSE jsonb_build_array(p_args) END;
    v_n       INTEGER := jsonb_array_length(CASE WHEN jsonb_typeof(p_args) = 'array' THEN p_args ELSE jsonb_build_array(p_args) END);
    v_sql     TEXT[] := ARRAY[]::TEXT[];
    v_samples JSONB := '[]'::jsonb;
    v_arg     JSONB;
    v_col     JSONB;
    v_result  JSONB;
    v_type    TEXT;
    v_json    TEXT;
BEGIN
    IF NOT ((p_op = 'date_add' AND v_n IN (2, 3))
         OR (p_op = 'date_diff' AND v_n = 3)
         OR (p_op IN ('date_part', 'date_trunc', 'date_format') AND v_n = 2)
         OR (p_op = 'to_date' AND v_n = 1)) THEN
        PERFORM rollup_filter_problem(format('%s has the wrong number of arguments', p_op));
    END IF;

    FOR v_i IN 0 .. v_n - 1 LOOP
        v_arg := v_args -> v_i;
        IF v_i = 0 OR (p_op = 'date_diff' AND v_i = 1) THEN
            v_col := rollup_filter_date_arg(v_arg, p_rel, p_alias);
            v_sql := v_sql || (v_col ->> 'json_sql');
            v_samples := v_samples || jsonb_build_array(v_col -> 'sample');
        ELSIF p_op = 'date_add' AND v_i = 1 AND jsonb_typeof(v_arg) = 'object' THEN
            v_col := rollup_filter_operand(v_arg, p_rel, p_alias);
            IF v_n = 2 THEN
                IF v_col ->> 'kind' IS DISTINCT FROM 'interval' THEN
                    PERFORM rollup_filter_problem(format('%s is not a duration', v_arg));
                END IF;
                IF jl_date_is_date_only(v_samples -> 0) THEN
                    PERFORM rollup_filter_problem('a duration column may hold a time of day, which a date cannot take');
                END IF;
                v_sql := v_sql || format('rollup_interval_iso(%s)', v_col ->> 'sql');
                v_samples := v_samples || '["PT0S"]'::jsonb;
            ELSE
                IF v_col ->> 'type' NOT IN ('smallint', 'integer', 'bigint') THEN
                    PERFORM rollup_filter_problem(format('%s is not a whole number', v_arg));
                END IF;
                v_sql := v_sql || COALESCE(v_col ->> 'json_sql', format('to_jsonb(%s)', v_col ->> 'sql'));
                v_samples := v_samples || jsonb_build_array(COALESCE(v_col -> 'sample', '1'::jsonb));
            END IF;
        ELSIF jsonb_typeof(v_arg) = 'string' OR (p_op = 'date_add' AND v_i = 1 AND jsonb_typeof(v_arg) = 'number') THEN
            v_sql := v_sql || format('%L::jsonb', v_arg::text);
            v_samples := v_samples || jsonb_build_array(v_arg);
        ELSE
            PERFORM rollup_filter_problem(format('%s takes its unit, part, pattern or amount as a literal', p_op));
        END IF;
    END LOOP;

    BEGIN
        v_result := evaluate_json_logic(jsonb_build_object(p_op, v_samples), '{}'::jsonb);
    EXCEPTION
        WHEN SQLSTATE '90915' OR SQLSTATE '90916' OR SQLSTATE '90917' OR SQLSTATE '90918' OR data_exception THEN
            PERFORM rollup_filter_problem(format('%s cannot take the arguments %s', p_op, v_args));
    END;
    -- Columns are checked with values that are never null, so a null here means a
    -- blank literal: the interpreter answers null for one before it looks at the
    -- other arguments, which would leave them unchecked, in a filter whose value
    -- could never be anything but null.
    IF v_result IS NULL OR jsonb_typeof(v_result) = 'null' THEN
        PERFORM rollup_filter_problem(format('%s cannot take a blank date or amount: %s', p_op, v_args));
    END IF;

    IF p_op = 'date_add' AND v_n = 2 THEN
        v_sql := v_sql || 'NULL::jsonb'::text;
    END IF;
    v_type := CASE p_op
        WHEN 'date_diff'   THEN 'bigint'
        WHEN 'date_part'   THEN 'bigint'
        WHEN 'date_format' THEN 'text'
        WHEN 'to_date'     THEN 'date'
        ELSE CASE WHEN jl_date_is_date_only(v_result) THEN 'date' ELSE 'timestamp with time zone' END
    END;
    v_json := format('%s(%s)', CASE p_op WHEN 'to_date' THEN 'jl_to_date' ELSE 'jl_' || p_op END,
                     array_to_string(v_sql, ', '));
    RETURN jsonb_build_object(
        'json_sql', v_json,
        'sql',      format('(%s #>> ''{}'')::%s', v_json, v_type),
        'type',     v_type,
        'kind',     'other',
        'is_var',   TRUE,
        'sample',   v_result);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_date_op(TEXT, JSONB, TEXT, TEXT) IS
'Compiles a date operator used as a value in a rollup filter to a typed call of the interpreter''s jl_date_* function, or raises 90265.';

-- An operand of a comparison: a var, a literal or a date operator. Any other
-- operator object is refused here, which is what keeps arithmetic and the other
-- custom operators out.
CREATE OR REPLACE FUNCTION rollup_filter_operand(p_node JSONB, p_rel TEXT, p_alias TEXT)
RETURNS JSONB AS $fn$
DECLARE
    v_op TEXT;
BEGIN
    IF jsonb_typeof(p_node) = 'object' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(p_node)) <> 1 THEN
            PERFORM rollup_filter_problem('an operator object has exactly one key');
        END IF;
        SELECT k INTO v_op FROM jsonb_object_keys(p_node) k;
        IF v_op = ANY (ARRAY['date_add', 'date_diff', 'date_part', 'date_trunc', 'to_date', 'date_format']) THEN
            RETURN rollup_filter_date_op(v_op, p_node -> v_op, p_rel, p_alias);
        END IF;
        IF v_op <> 'var' THEN
            PERFORM rollup_filter_problem(format('operator %s cannot be used as a value in a rollup filter', v_op));
        END IF;
        IF jsonb_typeof(p_node -> 'var') <> 'string' THEN
            PERFORM rollup_filter_problem('var takes a plain column name, without a path or a default');
        END IF;
        RETURN rollup_filter_column(p_node ->> 'var', p_rel, p_alias);
    ELSIF jsonb_typeof(p_node) IN ('string', 'number', 'boolean', 'null') THEN
        RETURN jsonb_build_object('literal', p_node, 'is_var', FALSE);
    END IF;
    PERFORM rollup_filter_problem('an operand must be a column (var), a literal or null');
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_operand(JSONB, TEXT, TEXT) IS
'Classifies an operand of a rollup filter comparison as a column or a literal, or raises 90265.';

-- The operands of one comparison, as SQL. The first column among them anchors
-- the type every literal is cast to, so '5' meets a numeric column as a number
-- and a date column as a date; with no column the literals keep their own type.
CREATE OR REPLACE FUNCTION rollup_filter_operands(p_args JSONB, p_rel TEXT, p_alias TEXT, p_allow_null BOOLEAN)
RETURNS TEXT[] AS $fn$
DECLARE
    v_node   JSONB;
    v_op     JSONB;
    v_ops    JSONB[] := ARRAY[]::JSONB[];
    v_anchor JSONB;
    v_out    TEXT[] := ARRAY[]::TEXT[];
BEGIN
    FOR v_node IN SELECT a FROM jsonb_array_elements(p_args) a LOOP
        v_op := rollup_filter_operand(v_node, p_rel, p_alias);
        -- A duration column exists here only to be an argument of date_add.
        IF v_op ->> 'kind' = 'interval' THEN
            PERFORM rollup_filter_problem(format('column %s has type interval, which a rollup filter cannot compare', v_node ->> 'var'));
        END IF;
        v_ops := v_ops || v_op;
        IF v_anchor IS NULL AND (v_op ->> 'is_var')::boolean THEN
            v_anchor := v_op;
        END IF;
    END LOOP;
    FOREACH v_op IN ARRAY v_ops LOOP
        IF (v_op ->> 'is_var')::boolean THEN
            v_out := v_out || (v_op ->> 'sql');
        ELSE
            IF jsonb_typeof(v_op -> 'literal') = 'null' AND NOT p_allow_null THEN
                PERFORM rollup_filter_problem('null can only be compared with == or !=');
            END IF;
            v_out := v_out || rollup_filter_literal(v_op -> 'literal', v_anchor ->> 'type', v_anchor ->> 'kind');
        END IF;
    END LOOP;
    RETURN v_out;
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_operands(JSONB, TEXT, TEXT, BOOLEAN) IS
'Compiles the operands of one rollup filter comparison to SQL, casting every literal to the type of the first column among them.';

-- A condition. Recursive for and, or, ! and !!.
CREATE OR REPLACE FUNCTION rollup_filter_cond(p_node JSONB, p_rel TEXT, p_alias TEXT)
RETURNS TEXT AS $fn$
DECLARE
    v_op    TEXT;
    v_args  JSONB;
    v_n     INTEGER;
    v_parts TEXT[];
    v_item  JSONB;
    v_col   JSONB;
BEGIN
    IF jsonb_typeof(p_node) = 'boolean' THEN
        RETURN CASE WHEN (p_node #>> '{}') = 'true' THEN 'TRUE' ELSE 'FALSE' END;
    END IF;
    IF jsonb_typeof(p_node) <> 'object' THEN
        PERFORM rollup_filter_problem('a condition must be a comparison, and, or, !, a boolean column or a boolean');
    END IF;
    IF p_node = '{}'::jsonb THEN
        RETURN 'TRUE';
    END IF;
    -- One key, always: a second key would be silently dropped by a compiler
    -- that read the first, and silently is the one way this must not fail.
    IF (SELECT count(*) FROM jsonb_object_keys(p_node)) <> 1 THEN
        PERFORM rollup_filter_problem('an operator object has exactly one key');
    END IF;
    SELECT k INTO v_op FROM jsonb_object_keys(p_node) k;
    v_args := p_node -> v_op;
    -- JsonLogic lets a single argument stand alone: {"!": x} is {"!": [x]}.
    IF jsonb_typeof(v_args) <> 'array' THEN
        v_args := jsonb_build_array(v_args);
    END IF;
    v_n := jsonb_array_length(v_args);

    CASE v_op
        WHEN 'and', 'or' THEN
            IF v_n < 1 THEN
                PERFORM rollup_filter_problem(format('%s needs at least one condition', v_op));
            END IF;
            SELECT array_agg(rollup_filter_cond(a, p_rel, p_alias) ORDER BY i) INTO v_parts
              FROM jsonb_array_elements(v_args) WITH ORDINALITY AS t(a, i);
            RETURN '(' || array_to_string(v_parts, CASE v_op WHEN 'and' THEN ' AND ' ELSE ' OR ' END) || ')';
        WHEN '!', '!!' THEN
            IF v_n <> 1 THEN
                PERFORM rollup_filter_problem(format('%s takes exactly one condition', v_op));
            END IF;
            RETURN CASE v_op WHEN '!' THEN 'NOT (' ELSE '(' END || rollup_filter_cond(v_args -> 0, p_rel, p_alias) || ')';
        WHEN '==', '===', '!=', '!==' THEN
            IF v_n <> 2 THEN
                PERFORM rollup_filter_problem(format('%s takes exactly two operands', v_op));
            END IF;
            v_parts := rollup_filter_operands(v_args, p_rel, p_alias, TRUE);
            RETURN format('(%s IS %sDISTINCT FROM %s)',
                          v_parts[1], CASE WHEN v_op IN ('==', '===') THEN 'NOT ' ELSE '' END, v_parts[2]);
        WHEN '<', '<=', '>', '>=' THEN
            IF v_n = 3 AND v_op IN ('<', '<=') THEN
                v_parts := rollup_filter_operands(v_args, p_rel, p_alias, FALSE);
                RETURN format('(%s %s %s AND %s %s %s)', v_parts[1], v_op, v_parts[2], v_parts[2], v_op, v_parts[3]);
            END IF;
            IF v_n <> 2 THEN
                PERFORM rollup_filter_problem(format('%s takes two operands (three for < and <=)', v_op));
            END IF;
            v_parts := rollup_filter_operands(v_args, p_rel, p_alias, FALSE);
            RETURN format('(%s %s %s)', v_parts[1], v_op, v_parts[2]);
        WHEN 'in' THEN
            IF v_n <> 2 OR jsonb_typeof(v_args -> 1) <> 'array' THEN
                PERFORM rollup_filter_problem('in takes a value and a list of literals');
            END IF;
            IF jsonb_array_length(v_args -> 1) = 0 THEN
                PERFORM rollup_filter_problem('the list of in is empty');
            END IF;
            FOR v_item IN SELECT a FROM jsonb_array_elements(v_args -> 1) a LOOP
                IF jsonb_typeof(v_item) NOT IN ('string', 'number', 'boolean') THEN
                    PERFORM rollup_filter_problem('the list of in holds literals only');
                END IF;
            END LOOP;
            -- The value comes first, so it anchors the cast of every list entry.
            v_parts := rollup_filter_operands(jsonb_build_array(v_args -> 0) || (v_args -> 1), p_rel, p_alias, FALSE);
            RETURN format('(%s IN (%s))', v_parts[1], array_to_string(v_parts[2:], ', '));
        WHEN 'var' THEN
            v_col := rollup_filter_operand(p_node, p_rel, p_alias);
            IF v_col ->> 'kind' <> 'bool' THEN
                PERFORM rollup_filter_problem(format('column %s is not boolean; compare it with == or similar', p_node ->> 'var'));
            END IF;
            RETURN v_col ->> 'sql';
        ELSE
            PERFORM rollup_filter_problem(format('operator %s is not supported in a rollup filter', v_op));
    END CASE;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_cond(JSONB, TEXT, TEXT) IS
'Compiles one JsonLogic condition of the rollup subset to a parenthesized SQL boolean expression over the child alias, or raises 90265.';

CREATE OR REPLACE FUNCTION rollup_filter_sql(p_filter JSONB, p_rel TEXT, p_alias TEXT)
RETURNS TEXT AS $fn$
BEGIN
    IF p_filter IS NULL OR p_filter = '{}'::jsonb THEN
        RETURN 'TRUE';
    END IF;
    RETURN rollup_filter_cond(p_filter, p_rel, p_alias);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_filter_sql(JSONB, TEXT, TEXT) IS
'Compiles a rollup filter (the JsonLogic subset and, or, !, !!, comparisons, in and var) to a SQL boolean over the given child relation and alias. Identifiers through %I after a catalog lookup, literals through %L cast to the column''s catalog type, every other operator refused with 90265. An empty filter is TRUE.';

REVOKE EXECUTE ON FUNCTION rollup_filter_column(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_literal(JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_interval_iso(INTERVAL) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_date_arg(JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_date_op(TEXT, JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_operand(JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_operands(JSONB, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_cond(JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rollup_filter_sql(JSONB, TEXT, TEXT) FROM PUBLIC;

-- =====================================================
-- The definition, resolved and validated
-- =====================================================
-- The one place that knows the rules of a rollup definition. The BEFORE
-- trigger on fields calls it to refuse a bad definition, and the builders call
-- it to generate from a good one, so the two cannot disagree. Returns NULL for
-- a field without a definition and a JSON record otherwise:
--   table, column            the rollup field
--   child_table, child_rel   the child entity and its physical relation
--   child_managed, child_exists, parent_rel, parent_key, parent_managed,
--   parent_exists, column_exists
--                            what the builders need to decide whether anything
--                            can be generated yet
--   link_column              the child's reference or parent column
--   function, value_column   what to aggregate
--   result_ddl_type          the field's type as field_data_type gives it
--   result_cast_type         the parent column's catalog type when the column
--                            exists, else result_ddl_type: the aggregate is
--                            cast to the column, never to fields.precision, or
--                            a scale mismatch would move the value on every
--                            write
--   empty_value              dd_column_default's zero value for the format, or
--                            NULL for a nullable format
--   precision                the precision the field takes (copied from a
--                            number value field)
--   filter_sql               the compiled filter, NULL while the child table
--                            does not exist yet
--   hidden                   whether the child is more restricted than the parent
CREATE OR REPLACE FUNCTION rollup_definition(p_field fields)
RETURNS JSONB AS $fn$
DECLARE
    c_numeric  CONSTANT TEXT[] := ARRAY['number', 'integer', 'int32', 'int64', 'float', 'double', 'rating'];
    v_def        JSONB := p_field.rollup;
    v_ctx        JSONB := jsonb_build_object('table', p_field.table_name, 'field_name', p_field.field_name);
    v_bad        TEXT;
    v_link       TEXT;
    v_function   TEXT;
    v_value      TEXT;
    v_filter     JSONB;
    v_lf         fields%ROWTYPE;
    v_vf         fields%ROWTYPE;
    v_child      entities%ROWTYPE;
    v_parent     entities%ROWTYPE;
    v_child_rel  TEXT;
    v_parent_rel TEXT;
    v_precision  SMALLINT;
    v_expected   TEXT;
    v_ok         BOOLEAN;
    v_ddl_type   TEXT;
    v_col_type   TEXT;
    v_cast_type  TEXT;
    v_empty      TEXT;
    v_filter_sql TEXT;
    v_hidden     BOOLEAN;
    v_hint       TEXT;
    v_chain      TEXT;
    v_cur_table  TEXT;
    v_cur_field  TEXT;
    v_next       fields%ROWTYPE;
    v_steps      INTEGER := 0;
BEGIN
    -- A definition that is not an object is left to the rollup_is_object CHECK,
    -- which runs after the BEFORE triggers that call this.
    IF v_def IS NULL OR jsonb_typeof(v_def) <> 'object' OR v_def = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    -- Shape. Every key is known, every value has its type, and the field is
    -- one a rollup can live on.
    SELECT string_agg(k, ', ' ORDER BY k) INTO v_bad
      FROM jsonb_object_keys(v_def) k
     WHERE k NOT IN ('link_field', 'function', 'value_field', 'filter', 'include_hidden_rows');
    IF v_bad IS NOT NULL THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'unknown key ' || v_bad));
    END IF;
    IF jsonb_typeof(v_def -> 'link_field') IS DISTINCT FROM 'string' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'link_field must be a string <entity>.<field>'));
    END IF;
    IF jsonb_typeof(v_def -> 'function') IS DISTINCT FROM 'string' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'function must be a string'));
    END IF;
    IF v_def ? 'value_field' AND jsonb_typeof(v_def -> 'value_field') <> 'string' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'value_field must be a string'));
    END IF;
    IF v_def ? 'filter' AND jsonb_typeof(v_def -> 'filter') NOT IN ('object', 'boolean') THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'filter must be a JsonLogic object or a boolean'));
    END IF;
    IF v_def ? 'include_hidden_rows' AND jsonb_typeof(v_def -> 'include_hidden_rows') <> 'boolean' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'include_hidden_rows must be a boolean'));
    END IF;
    IF p_field.is_pk THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'the key of an entity cannot be a rollup'));
    END IF;
    IF dd_ctype_is_core(p_field.ctype) THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'a core field (ctype ' || p_field.ctype || ') cannot be a rollup'));
    END IF;
    -- One derivation per field: a computed rule would run after the guard and
    -- overwrite the aggregate (the other direction is 90907).
    IF p_field.ctype = 'computed' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'a computed field cannot be a rollup'));
    END IF;
    IF dd_is_fk_format(p_field.format) THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              v_ctx || jsonb_build_object('problem', 'a reference or parent field cannot be a rollup'));
    END IF;

    v_link     := v_def ->> 'link_field';
    v_function := v_def ->> 'function';
    v_value    := COALESCE(v_def ->> 'value_field', '');
    v_filter   := v_def -> 'filter';

    -- The link: a reference or parent field of another entity that points here.
    IF v_link ~ '^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$' THEN
        SELECT * INTO v_lf FROM fields
         WHERE table_name = split_part(v_link, '.', 1) AND field_name = split_part(v_link, '.', 2);
    END IF;
    IF v_lf.field_name IS NULL OR NOT dd_is_fk_format(v_lf.format) OR v_lf.reference_table <> p_field.table_name THEN
        PERFORM rollup_refuse('90262',
            'Rollup ${field_name} on ${table}: link_field ${link_field} must name a reference or parent field of another entity that points at ${table}',
            v_ctx || jsonb_build_object('link_field', v_link));
    END IF;
    SELECT * INTO v_child FROM entities WHERE table_name = v_lf.table_name;
    SELECT * INTO v_parent FROM entities WHERE table_name = p_field.table_name;
    -- An is_a or has_a entity is a view over several tables, and a record of
    -- one is written to several tables: neither side of a rollup can be one.
    IF v_child.id_type IN ('is_a', 'has_a') THEN
        PERFORM rollup_refuse('90249', '${feature} is not available for ${id_type} entity ${table}',
            jsonb_build_object('feature', 'rollup', 'id_type', v_child.id_type, 'table', v_child.table_name));
    END IF;
    IF v_parent.id_type IN ('is_a', 'has_a') THEN
        PERFORM rollup_refuse('90249', '${feature} is not available for ${id_type} entity ${table}',
            jsonb_build_object('feature', 'rollup', 'id_type', v_parent.id_type, 'table', v_parent.table_name));
    END IF;
    v_child_rel  := dd_relation(v_child.table_name, v_child.id_type);
    v_parent_rel := dd_relation(v_parent.table_name, v_parent.id_type);

    IF v_function NOT IN ('sum', 'min', 'max', 'avg', 'count') THEN
        PERFORM rollup_refuse('90263', 'Rollup ${field_name} on ${table}: function ${function} is not one of sum, min, max, avg, count',
            v_ctx || jsonb_build_object('function', v_function));
    END IF;

    -- The value: a field of the child that the function can aggregate. sum and
    -- avg need a number; min and max also order text, dates and timestamps.
    -- Keys, booleans, times, durations, UUIDs, binaries and JSON are refused:
    -- nothing a rollup column could hold comes out of them.
    IF v_function = 'count' THEN
        IF v_value <> '' THEN
            PERFORM rollup_refuse('90264',
                'Rollup ${field_name} on ${table}: value_field ${value_field} must name a field of ${link_table} that ${function} can aggregate',
                v_ctx || jsonb_build_object('value_field', v_value, 'link_table', v_lf.table_name, 'function', v_function,
                                            'problem', 'count takes no value_field'));
        END IF;
    ELSE
        IF v_value <> '' THEN
            SELECT * INTO v_vf FROM fields WHERE table_name = v_lf.table_name AND field_name = v_value;
            -- A field that sums itself (a tree's subtree total) names a value
            -- field that is not in fields yet while it is being inserted: it is
            -- this field, and the cycle rule below is the one to answer.
            IF NOT FOUND AND v_lf.table_name = p_field.table_name AND v_value = p_field.field_name THEN
                v_vf := p_field;
            END IF;
        END IF;
        v_ok := v_vf.field_name IS NOT NULL
                AND (v_vf.format = ANY (c_numeric)
                     OR (v_function IN ('min', 'max')
                         AND (format_to_data_type(v_vf.format) = 'TEXT' OR v_vf.format IN ('date', 'date-time'))));
        IF NOT v_ok THEN
            PERFORM rollup_refuse('90264',
                'Rollup ${field_name} on ${table}: value_field ${value_field} must name a field of ${link_table} that ${function} can aggregate',
                v_ctx || jsonb_build_object('value_field', v_value, 'link_table', v_lf.table_name, 'function', v_function,
                                            'problem', CASE WHEN v_value = '' THEN 'value_field is required'
                                                            WHEN v_vf.field_name IS NULL THEN 'no such field'
                                                            ELSE v_function || ' cannot aggregate a ' || v_vf.format || ' field' END));
        END IF;
    END IF;

    -- Decimal places follow the value field: a sum of amounts with three
    -- decimals has three decimals. An avg over integers keeps the field's own.
    v_precision := CASE WHEN v_function <> 'count' AND v_vf.format = 'number' THEN v_vf."precision"
                        ELSE p_field."precision" END;

    -- The result type is the field's format, which has to fit: count is an
    -- integer whatever the base, sum stays numeric, avg is fractional, and min
    -- or max take the value's own type (compared as column types, so email over
    -- text passes while date over date-time does not).
    CASE v_function
        WHEN 'count' THEN
            v_ok := p_field.format IN ('int32', 'int64', 'integer', 'number');
            v_expected := 'int64';
        WHEN 'sum' THEN
            v_ok := p_field.format = ANY (c_numeric);
            v_expected := 'number';
        WHEN 'avg' THEN
            v_ok := p_field.format IN ('number', 'float', 'double');
            v_expected := 'number';
        ELSE
            v_ok := field_data_type(p_field.format, v_precision, '') = field_data_type(v_vf.format, v_vf."precision", '');
            v_expected := v_vf.format;
    END CASE;
    IF NOT v_ok THEN
        PERFORM rollup_refuse('90268',
            'Rollup ${field_name} on ${table}: format ${format} does not fit ${function}; use ${expected_format}',
            v_ctx || jsonb_build_object('format', p_field.format, 'function', v_function,
                                        'expected_format', v_expected, 'value_field', v_value));
    END IF;

    -- A value that is itself a rollup is fine (a total of totals); a value whose
    -- chain of rollups comes back to this field would recompute forever.
    IF v_function <> 'count' THEN
        v_cur_table := v_lf.table_name;
        v_cur_field := v_value;
        v_chain     := p_field.table_name || '.' || p_field.field_name;
        LOOP
            IF (v_cur_table, v_cur_field) = (p_field.table_name, p_field.field_name) OR v_steps > 32 THEN
                PERFORM rollup_refuse('90267', 'Rollup ${field_name} on ${table} depends on itself through ${chain}',
                    v_ctx || jsonb_build_object('chain', v_chain || ' -> ' || v_cur_table || '.' || v_cur_field));
            END IF;
            SELECT * INTO v_next FROM fields
             WHERE table_name = v_cur_table AND field_name = v_cur_field AND rollup <> '{}'::jsonb;
            EXIT WHEN NOT FOUND OR (v_next.rollup ->> 'function') = 'count';
            v_chain     := v_chain || ' -> ' || v_cur_table || '.' || v_cur_field;
            v_steps     := v_steps + 1;
            v_cur_table := split_part(v_next.rollup ->> 'link_field', '.', 1);
            v_cur_field := COALESCE(v_next.rollup ->> 'value_field', '');
        END LOOP;
    END IF;

    -- The aggregate is computed as the owner over every child record and shown
    -- to every reader of the parent. When the child is more restricted than the
    -- parent (its own select_rule, or another view permission, which may be
    -- narrower) that shows readers an aggregate over records their row
    -- security hides, a capability the access-checked set_record never had, so
    -- it takes the administrator's explicit yes in the definition.
    v_hidden := v_child.select_rule <> '{}'::jsonb OR v_child.view_permission <> v_parent.view_permission;
    IF v_hidden AND COALESCE((v_def ->> 'include_hidden_rows')::boolean, FALSE) IS NOT TRUE THEN
        PERFORM rollup_refuse('90269',
            'Rollup ${field_name} on ${table} aggregates rows of ${link_table} that readers of ${table} may not see; set include_hidden_rows to accept that',
            v_ctx || jsonb_build_object('link_table', v_child.table_name));
    END IF;

    -- The column may not exist yet: this runs from the BEFORE trigger that
    -- validates a new field, and from the AFTER trigger of one row of a
    -- multi-row INSERT while the later rows' columns are still to come. The
    -- builders leave such a rollup out until its own row's trigger fires.
    v_ddl_type := field_data_type(p_field.format, v_precision, '');
    SELECT pg_catalog.format_type(a.atttypid, a.atttypmod) INTO v_col_type
      FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', v_parent_rel))
       AND a.attname = p_field.field_name
       AND a.attnum > 0
       AND NOT a.attisdropped;
    v_cast_type := COALESCE(v_col_type, v_ddl_type);
    v_empty := dd_column_default(p_field.format, '', p_field.input_type, p_field.enum_values, v_ddl_type);

    -- The filter can only be compiled against a table that exists.
    IF v_child.managed AND pg_catalog.to_regclass(format('public.%I', v_child_rel)) IS NOT NULL THEN
        BEGIN
            v_filter_sql := rollup_filter_sql(v_filter, v_child_rel, 'c');
        EXCEPTION
            WHEN SQLSTATE '90265' THEN
                GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
                PERFORM rollup_refuse('90265',
                    'Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}',
                    jl_error_hint(v_hint, v_ctx)::jsonb);
        END;
    END IF;

    RETURN jsonb_build_object(
        'table',            p_field.table_name,
        'column',           p_field.field_name,
        'child_table',      v_child.table_name,
        'child_rel',        v_child_rel,
        'child_managed',    v_child.managed,
        'child_exists',     pg_catalog.to_regclass(format('public.%I', v_child_rel)) IS NOT NULL,
        'link_column',      v_lf.field_name,
        'parent_rel',       v_parent_rel,
        'parent_key',       v_parent.id_column,
        'parent_managed',   v_parent.managed,
        'parent_exists',    pg_catalog.to_regclass(format('public.%I', v_parent_rel)) IS NOT NULL,
        'column_exists',    v_col_type IS NOT NULL,
        'function',         v_function,
        'value_column',     NULLIF(v_value, ''),
        'result_ddl_type',  v_ddl_type,
        'result_cast_type', v_cast_type,
        'empty_value',      v_empty,
        'precision',        v_precision,
        'filter_sql',       v_filter_sql,
        'hidden',           v_hidden);
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_definition(fields) IS
'Validates a field''s rollup definition (90261-90269, 90249) and resolves it: child and parent relations, link and value columns, function, result type, empty value, copied precision and the compiled filter. NULL for a field without a definition. The one authority for both the fields trigger and the builders.';

REVOKE EXECUTE ON FUNCTION rollup_definition(fields) FROM PUBLIC;

-- The builders run after validation, and during a cascade that is deleting
-- the child or its fields a definition may no longer resolve. That is not an
-- error to raise from a rebuild: the rollup is on its way out or being
-- re-validated elsewhere, so the builders leave it out.
CREATE OR REPLACE FUNCTION rollup_definition_or_null(p_field fields)
RETURNS JSONB AS $fn$
BEGIN
    RETURN rollup_definition(p_field);
EXCEPTION
    WHEN SQLSTATE '90000' THEN
        RETURN NULL;
END;
$fn$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION rollup_definition_or_null(fields) IS
'rollup_definition for the builders: NULL instead of a rollup error, for a definition that no longer resolves while a cascade removes what it names.';

REVOKE EXECUTE ON FUNCTION rollup_definition_or_null(fields) FROM PUBLIC;

-- =====================================================
-- The aggregate expression
-- =====================================================
-- One expression for the three places that compute a value: the maintenance
-- function, the guard and the backfill. p_key_expr is the SQL that yields the
-- parent key (k.key, NEW.id, p2.id).
CREATE OR REPLACE FUNCTION rollup_value_sql(p_def JSONB, p_key_expr TEXT)
RETURNS TEXT AS $fn$
DECLARE
    v_value TEXT;
    v_agg   TEXT;
    v_inner TEXT;
BEGIN
    IF p_def ->> 'function' = 'count' THEN
        v_agg := 'count(*)';
    ELSE
        -- sum and avg are computed in numeric whatever the value column is, so
        -- an integer sum cannot overflow and a float sum is exact before it is
        -- cast to the column.
        v_value := format('c.%I', p_def ->> 'value_column');
        IF p_def ->> 'function' IN ('sum', 'avg') THEN
            v_value := v_value || '::numeric';
        END IF;
        v_agg := format('%s(%s)', p_def ->> 'function', v_value);
    END IF;
    v_inner := format('(SELECT %s FROM public.%I c WHERE c.%I = %s AND (%s))',
                      v_agg, p_def ->> 'child_rel', p_def ->> 'link_column', p_key_expr,
                      COALESCE(p_def ->> 'filter_sql', 'TRUE'));
    IF p_def ->> 'empty_value' IS NOT NULL THEN
        v_inner := format('COALESCE(%s, %s)', v_inner, p_def ->> 'empty_value');
    END IF;
    RETURN format('(%s)::%s', v_inner, p_def ->> 'result_cast_type');
END;
$fn$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION rollup_value_sql(JSONB, TEXT) IS
'The SQL expression that computes a rollup''s value for the parent key p_key_expr yields: the aggregate over the child records with the compiled filter, the empty value for no records, cast to the parent column''s type.';

REVOKE EXECUTE ON FUNCTION rollup_value_sql(JSONB, TEXT) FROM PUBLIC;

-- The body goes through dd_dollar_quote (0210_computed_validation.sql), like
-- every generated body: a filter literal cannot end it early inside the
-- EXECUTE that creates the function.
CREATE OR REPLACE FUNCTION rollup_create_function(p_name TEXT, p_body TEXT)
RETURNS VOID AS $fn$
BEGIN
    EXECUTE format('CREATE FUNCTION common.%I() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %s',
                   p_name, dd_dollar_quote(p_body));
    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I() FROM PUBLIC', p_name);
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_create_function(TEXT, TEXT) IS
'Creates a generated SECURITY DEFINER trigger function in common from its PL/pgSQL body, wrapped by dd_dollar_quote so no literal in it can end the body early.';

REVOKE EXECUTE ON FUNCTION rollup_create_function(TEXT, TEXT) FROM PUBLIC;

-- =====================================================
-- The maintenance function and its triggers on the child
-- =====================================================
-- One function per (child table, link field), handling every rollup column
-- that aggregates through that link, so a child statement writes each parent
-- once. Statement level with transition tables: a bulk insert of a thousand
-- lines of one order recomputes the order once, and a statement that moved no
-- aggregate writes nothing (IS DISTINCT FROM over the row of rollup columns).
-- One function behind four triggers, each with its own REFERENCING clause,
-- because a trigger with transition tables is defined for one event only
-- (queue_build_record_json, 0340_queue.sql, has the same shape). Only the
-- branch for the firing event is ever planned, so the DELETE branch never
-- names new_rows and the INSERT branch never names old_rows.
--
-- The parents are locked in a statement of their own, before the UPDATE reads the
-- children, because the aggregate has to see the writer ahead. An UPDATE that
-- waits for a row lock keeps the value it computed from its snapshot, which could
-- not see the other writer's children, and rechecks IS DISTINCT FROM against the
-- row that writer committed. Two inserts under a count, or two that add the same
-- amount, compute the same value, so the second skips the row, the guard never
-- runs, and its children are never counted. Locked first, the UPDATE takes its
-- snapshot after every writer ahead of it has committed. Key order makes two
-- statements through this link over the same parents queue rather than deadlock.
-- It orders only this one step, so a second link to the same parent table, or a
-- tree's climb to the next parent, can still deadlock with another writer;
-- PostgreSQL aborts one, which changes nothing, so the totals stay right. The lock
-- cannot be skipped when a total looks unchanged: a writer inserting 3 under a max
-- of 10 sees no change while another deletes the 10 without seeing the 3.
-- pgdocker/pg-rollup-race.sh pins this, since the pgTAP suite runs in one session.
CREATE OR REPLACE FUNCTION rollup_build_link(p_child TEXT, p_link TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_fn      TEXT := rollup_object_name(p_child, p_link);
    v_f       fields%ROWTYPE;
    v_def     JSONB;
    v_defs    JSONB[] := ARRAY[]::JSONB[];
    v_rel     TEXT;
    v_parent  TEXT;
    v_key     TEXT;
    v_sets    TEXT;
    v_sels    TEXT;
    v_cols    TEXT;
    v_tuple_p TEXT;
    v_tuple_s TEXT;
    v_head    TEXT;
    v_tail    TEXT;
    v_ins     TEXT;
    v_del     TEXT;
    v_all     TEXT;
    v_lock_head TEXT;
    v_lock_tail TEXT;
BEGIN
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', v_fn);

    FOR v_f IN
        SELECT f.* FROM fields f
         WHERE f.rollup <> '{}'::jsonb
           AND f.rollup ->> 'link_field' = p_child || '.' || p_link
         ORDER BY f.field_order, f.field_name
    LOOP
        v_def := rollup_definition_or_null(v_f);
        CONTINUE WHEN v_def IS NULL
                   OR NOT (v_def ->> 'child_managed')::boolean  OR NOT (v_def ->> 'child_exists')::boolean
                   OR NOT (v_def ->> 'parent_managed')::boolean OR NOT (v_def ->> 'parent_exists')::boolean
                   OR NOT (v_def ->> 'column_exists')::boolean;
        v_defs := v_defs || v_def;
    END LOOP;
    IF cardinality(v_defs) = 0 THEN
        RETURN;
    END IF;

    v_rel    := v_defs[1] ->> 'child_rel';
    v_parent := v_defs[1] ->> 'parent_rel';
    v_key    := v_defs[1] ->> 'parent_key';
    SELECT string_agg(format('%I = s.%I', d ->> 'column', d ->> 'column'), ', ' ORDER BY i),
           string_agg(format('%s AS %I', rollup_value_sql(d, 'k.key'), d ->> 'column'), ', ' ORDER BY i),
           string_agg(d ->> 'column', ', ' ORDER BY i),
           '(' || string_agg(format('p.%I', d ->> 'column'), ', ' ORDER BY i) || ')',
           '(' || string_agg(format('s.%I', d ->> 'column'), ', ' ORDER BY i) || ')'
      INTO v_sets, v_sels, v_cols, v_tuple_p, v_tuple_s
      FROM unnest(v_defs) WITH ORDINALITY AS t(d, i);

    -- The statement is assembled by concatenation, not through a second
    -- format(): the compiled filter may hold a % in a literal.
    v_head := format('UPDATE public.%I p SET %s FROM (SELECT k.key, %s FROM (', v_parent, v_sets, v_sels);
    v_tail := format(') k(key)) s WHERE p.%I = s.key AND %s IS DISTINCT FROM %s', v_key, v_tuple_p, v_tuple_s);
    v_ins  := format('SELECT DISTINCT n.%I FROM new_rows n WHERE n.%I IS NOT NULL', p_link, p_link);
    v_del  := format('SELECT DISTINCT o.%I FROM old_rows o WHERE o.%I IS NOT NULL', p_link, p_link);
    v_all  := format('SELECT p2.%I FROM public.%I p2', v_key, v_parent);
    v_lock_head := format('PERFORM 1 FROM public.%I p WHERE p.%I IN (', v_parent, v_key);
    v_lock_tail := format(') ORDER BY p.%I FOR NO KEY UPDATE', v_key);

    -- A statement trigger fires for a statement that touched no rows, and the
    -- parent UPDATE below is itself such a statement when no value moved; on a
    -- self-referencing table (a tree) it fires this very function. An empty
    -- transition table therefore returns at once: that is what ends the climb
    -- at the root, and what keeps a no-op from running forever.
    PERFORM rollup_create_function(v_fn, format($B$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM new_rows) THEN RETURN NULL; END IF;
        %s;
        %s;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NOT EXISTS (SELECT 1 FROM new_rows) THEN RETURN NULL; END IF;
        %s;
        %s;
    ELSIF TG_OP = 'DELETE' THEN
        IF NOT EXISTS (SELECT 1 FROM old_rows) THEN RETURN NULL; END IF;
        %s;
        %s;
    ELSE
        %s;
        %s;
    END IF;
    RETURN NULL;
END;
$B$, v_lock_head || v_ins || v_lock_tail, v_head || v_ins || v_tail,
     v_lock_head || v_ins || ' UNION ' || v_del || v_lock_tail, v_head || v_ins || ' UNION ' || v_del || v_tail,
     v_lock_head || v_del || v_lock_tail, v_head || v_del || v_tail,
     v_lock_head || v_all || v_lock_tail, v_head || v_all || v_tail));

    EXECUTE format('COMMENT ON FUNCTION common.%I() IS %L', v_fn,
        format('Statement-level trigger function on %s: locks the parent records a statement touched (every parent after TRUNCATE) in key order, then recomputes for them the rollup columns %s of %s that aggregate over %s.%s. Generated by rollup_build_link.',
               v_rel, v_cols, v_parent, p_child, p_link));
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT ON public.%I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION common.%I()',
                   v_fn || '_ins', v_rel, v_fn);
    EXECUTE format('CREATE TRIGGER %I AFTER UPDATE ON public.%I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION common.%I()',
                   v_fn || '_upd', v_rel, v_fn);
    EXECUTE format('CREATE TRIGGER %I AFTER DELETE ON public.%I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION common.%I()',
                   v_fn || '_del', v_rel, v_fn);
    EXECUTE format('CREATE TRIGGER %I AFTER TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION common.%I()',
                   v_fn || '_trc', v_rel, v_fn);
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_build_link(TEXT, TEXT) IS
'Drops and, when any rollup still aggregates through the link field p_child.p_link between managed tables, regenerates common.rollup_<child>_<link>() and its four statement-level triggers on the child table.';

REVOKE EXECUTE ON FUNCTION rollup_build_link(TEXT, TEXT) FROM PUBLIC;

-- =====================================================
-- The guard and the side effects on the parent
-- =====================================================
-- The guard makes the stored value trustworthy: whoever writes the parent row,
-- a rollup column holds the aggregate. It is SECURITY DEFINER because it reads
-- the child table; as the writing user it would see only the child rows that
-- user's row security allows and store a partial sum. BEFORE INSERT the
-- column is the empty aggregate (no child can reference a key that does not
-- exist yet, and NEW.<key> is not read, so the key may still be unassigned);
-- BEFORE UPDATE a changed value is recomputed, which costs the maintenance
-- function a second computation when a value moves and costs a hand-written
-- value its effect. a_rollup_guard sorts before compute_validate_trigger, so
-- computed fields see the true value.
--
-- The same function keeps the parent's updated_at and audit triggers in step:
-- both take the rollup columns as ignored columns (dd_audit_ignored_columns),
-- so a child write that only moves a total neither bumps updated_at nor logs
-- an audit row, and when the last rollup goes both return to their plain form.
-- With arguments, update_updated_at_column also stops bumping on a write that
-- changed nothing, which is the behavior its comment describes for tables that
-- opt in.
CREATE OR REPLACE FUNCTION rollup_build_guard(p_parent TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_fn    TEXT := rollup_guard_name(p_parent);
    v_e     entities%ROWTYPE;
    v_rel   TEXT;
    v_f     fields%ROWTYPE;
    v_def   JSONB;
    v_defs  JSONB[] := ARRAY[]::JSONB[];
    v_ins   TEXT;
    v_upd   TEXT;
    v_cols  TEXT;
    v_args  TEXT;
BEGIN
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', v_fn);

    SELECT * INTO v_e FROM entities WHERE table_name = p_parent;
    IF NOT FOUND OR NOT v_e.managed THEN
        RETURN;
    END IF;
    v_rel := dd_relation(v_e.table_name, v_e.id_type);
    IF pg_catalog.to_regclass(format('public.%I', v_rel)) IS NULL THEN
        RETURN;
    END IF;

    FOR v_f IN
        SELECT f.* FROM fields f
         WHERE f.table_name = p_parent AND f.rollup <> '{}'::jsonb
         ORDER BY f.field_order, f.field_name
    LOOP
        v_def := rollup_definition_or_null(v_f);
        CONTINUE WHEN v_def IS NULL
                   OR NOT (v_def ->> 'child_managed')::boolean OR NOT (v_def ->> 'child_exists')::boolean
                   OR NOT (v_def ->> 'column_exists')::boolean;
        v_defs := v_defs || v_def;
    END LOOP;

    IF cardinality(v_defs) > 0 THEN
        SELECT string_agg(format('        NEW.%I := %s;', d ->> 'column', COALESCE(d ->> 'empty_value', 'NULL')), E'\n' ORDER BY i),
               string_agg(format('        IF NEW.%1$I IS DISTINCT FROM OLD.%1$I THEN NEW.%1$I := %2$s; END IF;',
                                 d ->> 'column', rollup_value_sql(d, format('NEW.%I', v_e.id_column))), E'\n' ORDER BY i),
               string_agg(d ->> 'column', ', ' ORDER BY i)
          INTO v_ins, v_upd, v_cols
          FROM unnest(v_defs) WITH ORDINALITY AS t(d, i);

        PERFORM rollup_create_function(v_fn, format($B$
BEGIN
    IF TG_OP = 'INSERT' THEN
%s
    ELSE
%s
    END IF;
    RETURN NEW;
END;
$B$, v_ins, v_upd));
        EXECUTE format('COMMENT ON FUNCTION common.%I() IS %L', v_fn,
            format('BEFORE INSERT OR UPDATE row trigger function on %s: keeps the rollup columns %s at their computed value, whoever writes the row. Generated by rollup_build_guard.', v_rel, v_cols));
        EXECUTE format('CREATE TRIGGER a_rollup_guard BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION common.%I()',
                       v_rel, v_fn);
    END IF;

    SELECT string_agg(quote_literal(c), ', ') INTO v_args FROM unnest(dd_audit_ignored_columns(p_parent)) AS c;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'update_' || v_rel || '_updated_at', v_rel);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column(%s)',
                   'update_' || v_rel || '_updated_at', v_rel, COALESCE(v_args, ''));
    IF v_e.audit_log THEN
        -- enable_tracking creates only the triggers that are missing, so
        -- dropping the UPDATE trigger first replaces exactly that one.
        EXECUTE format('DROP TRIGGER IF EXISTS audit_i_u_d ON public.%I', v_rel);
        PERFORM audit.enable_tracking(format('public.%I', v_rel)::regclass, dd_audit_ignored_columns(p_parent));
    END IF;
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_build_guard(TEXT) IS
'Drops and, when the managed entity has rollup columns over existing child tables, regenerates common.rollup_guard_<parent>() with its a_rollup_guard trigger; in every case re-creates the entity''s updated_at trigger and audit UPDATE trigger with the rollup columns as ignored columns.';

REVOKE EXECUTE ON FUNCTION rollup_build_guard(TEXT) FROM PUBLIC;

-- =====================================================
-- Backfill
-- =====================================================
-- One pass over the parent table when a rollup is created or its definition
-- changes. Row locks on the rows whose value changes only, no table rewrite;
-- the guard recomputes each changed row once more. The rollup column itself is
-- an ignored column of the updated_at and audit triggers, but a computed field
-- over it is not, and queue mappings look at no column at all, so the pass is
-- muted (dd_backfill_mute); the EXISTS keeps a pass with nothing to write from
-- taking its lock.
CREATE OR REPLACE FUNCTION rollup_backfill(p_table TEXT, p_field TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_f     fields%ROWTYPE;
    v_def   JSONB;
    v_value TEXT;
    v_moved BOOLEAN;
    v_undo  TEXT[];
    v_stmt  TEXT;
BEGIN
    SELECT * INTO v_f FROM fields WHERE table_name = p_table AND field_name = p_field;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    v_def := rollup_definition_or_null(v_f);
    IF v_def IS NULL
       OR NOT (v_def ->> 'child_managed')::boolean  OR NOT (v_def ->> 'child_exists')::boolean
       OR NOT (v_def ->> 'parent_managed')::boolean OR NOT (v_def ->> 'parent_exists')::boolean
       OR NOT (v_def ->> 'column_exists')::boolean THEN
        RETURN;
    END IF;
    v_value := rollup_value_sql(v_def, format('p2.%I', v_def ->> 'parent_key'));
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I p2 WHERE p2.%2$I IS DISTINCT FROM %3$s)',
                   v_def ->> 'parent_rel', p_field, v_value)
       INTO v_moved;
    IF NOT v_moved THEN
        RETURN;
    END IF;
    v_undo := dd_backfill_mute(p_table);
    EXECUTE format('UPDATE public.%1$I p SET %2$I = s.v FROM (SELECT p2.%3$I AS k, %4$s AS v FROM public.%1$I p2) s WHERE p.%3$I = s.k AND p.%2$I IS DISTINCT FROM s.v',
                   v_def ->> 'parent_rel', p_field, v_def ->> 'parent_key', v_value);
    FOREACH v_stmt IN ARRAY v_undo LOOP
        EXECUTE v_stmt;
    END LOOP;
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_backfill(TEXT, TEXT) IS
'Recomputes one rollup column for every parent record whose stored value differs from the aggregate. Run when a rollup is created or its definition changes.';

REVOKE EXECUTE ON FUNCTION rollup_backfill(TEXT, TEXT) FROM PUBLIC;

-- Everything a rollup field needs after a change of its own row.
CREATE OR REPLACE FUNCTION rollup_sync_field(p_field fields, p_backfill BOOLEAN)
RETURNS VOID AS $fn$
DECLARE
    v_def JSONB := rollup_definition(p_field);
BEGIN
    IF v_def IS NULL THEN
        RETURN;
    END IF;
    PERFORM rollup_build_link(v_def ->> 'child_table', v_def ->> 'link_column');
    PERFORM rollup_build_guard(p_field.table_name);
    IF p_backfill THEN
        PERFORM rollup_backfill(p_field.table_name, p_field.field_name);
    END IF;
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_sync_field(fields, BOOLEAN) IS
'Rebuilds the maintenance function of a rollup field''s link and the guard of its entity, and backfills the column when asked.';

REVOKE EXECUTE ON FUNCTION rollup_sync_field(fields, BOOLEAN) FROM PUBLIC;

-- The renamed field p_table.p_old is named by other rollups: as their link
-- field, as their value field, or as a var in their filter. The definitions
-- are rewritten, which rebuilds them through zz_rollup_field_change; the
-- maintenance function named after the old link field is dropped first, as
-- the rebuild creates it under the new name. The filter is rewritten by text
-- the way rename_dd_jsonlogic_refs rewrites set_record names: jsonb prints a
-- var as "var": "<name>", which is the one form a plain column reference has.
CREATE OR REPLACE FUNCTION rollup_rename_field_refs(p_table TEXT, p_old TEXT, p_new TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_old_var TEXT := format('"var": %s', to_jsonb(p_old)::text);
    v_new_var TEXT := format('"var": %s', to_jsonb(p_new)::text);
BEGIN
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', rollup_object_name(p_table, p_old));
    UPDATE fields
       SET rollup = jsonb_set(rollup, '{link_field}', to_jsonb(p_table || '.' || p_new))
     WHERE rollup ->> 'link_field' = p_table || '.' || p_old;
    UPDATE fields
       SET rollup = jsonb_set(rollup, '{value_field}', to_jsonb(p_new))
     WHERE rollup <> '{}'::jsonb
       AND split_part(rollup ->> 'link_field', '.', 1) = p_table
       AND rollup ->> 'value_field' = p_old;
    UPDATE fields
       SET rollup = jsonb_set(rollup, '{filter}', replace((rollup -> 'filter')::text, v_old_var, v_new_var)::jsonb)
     WHERE rollup <> '{}'::jsonb
       AND split_part(rollup ->> 'link_field', '.', 1) = p_table
       AND (rollup -> 'filter')::text LIKE '%' || v_old_var || '%';
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_rename_field_refs(TEXT, TEXT, TEXT) IS
'After a field rename, rewrites every rollup definition that names the field as link_field, value_field or a filter var, which rebuilds those rollups.';

REVOKE EXECUTE ON FUNCTION rollup_rename_field_refs(TEXT, TEXT, TEXT) FROM PUBLIC;

-- A change to a builder in this file replaces the builder, not what it
-- generated. The .once. file such a change ships with (RELEASE.md) calls this.
CREATE OR REPLACE FUNCTION rollup_rebuild_all()
RETURNS VOID AS $fn$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT DISTINCT split_part(rollup ->> 'link_field', '.', 1) AS child,
                        split_part(rollup ->> 'link_field', '.', 2) AS link
          FROM fields WHERE rollup <> '{}'::jsonb
    LOOP
        PERFORM rollup_build_link(r.child, r.link);
    END LOOP;
    FOR r IN SELECT DISTINCT table_name FROM fields WHERE rollup <> '{}'::jsonb LOOP
        PERFORM rollup_build_guard(r.table_name);
    END LOOP;
END;
$fn$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION rollup_rebuild_all() IS
'Regenerates every rollup maintenance function and guard from the current fields rows. For the .once. file that accompanies a change to the builders in 0440_rollup.sql.';

REVOKE EXECUTE ON FUNCTION rollup_rebuild_all() FROM PUBLIC;

-- =====================================================
-- Lifecycle: fields
-- =====================================================
-- BEFORE INSERT OR UPDATE. The zz_ name puts it after every other BEFORE
-- trigger on fields: after fields_ctype_lock, which forces ctype to '' for a
-- caller that is not the dictionary and refuses any change a caller sends, so
-- the marker derived here never passes back through the lock and a client
-- never sends it; and after validate_field_rename_and_format_trigger, which
-- has renamed the column by then.
CREATE OR REPLACE FUNCTION zz_validate_rollup_field()
RETURNS TRIGGER AS $fn$
DECLARE
    v_def JSONB;
    v_err TEXT;
BEGIN
    -- A table rename cascades to fields.table_name while the link field's
    -- reference_table still carries the old name; zz_rollup_entity_change
    -- validates and rebuilds once the rename is complete.
    IF TG_OP = 'UPDATE'
       AND current_setting('dd.table_rename', TRUE) IS NOT DISTINCT FROM OLD.table_name || ':' || NEW.table_name THEN
        RETURN NEW;
    END IF;

    -- Not a rollup (any more): the derived marker goes with the definition. A
    -- definition that is not an object is left to the rollup_is_object CHECK.
    IF jsonb_typeof(NEW.rollup) <> 'object' OR NEW.rollup = '{}'::jsonb THEN
        IF NEW.ctype = 'rollup' THEN
            NEW.ctype := '';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.rollup = NEW.rollup AND OLD.format = NEW.format AND OLD."precision" = NEW."precision"
       AND OLD.field_name = NEW.field_name AND OLD.ctype = NEW.ctype AND OLD.input_type = NEW.input_type
       AND OLD.searchable = NEW.searchable AND OLD.unique_value = NEW.unique_value AND OLD.is_pk = NEW.is_pk THEN
        RETURN NEW;
    END IF;

    v_def := rollup_definition(NEW);

    IF NEW.input_type = 'required' THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
            jsonb_build_object('table', NEW.table_name, 'field_name', NEW.field_name,
                               'problem', 'a rollup field cannot be required: its value is computed'));
    END IF;
    -- The generated search vector would move with every total and defeat the
    -- audit exclusion (the audit gate compares the row with search_vector in it).
    IF NEW.searchable THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
            jsonb_build_object('table', NEW.table_name, 'field_name', NEW.field_name,
                               'problem', 'a rollup field cannot be searchable'));
    END IF;
    -- Two parents reaching the same total would fail the maintenance UPDATE.
    IF NEW.unique_value THEN
        PERFORM rollup_refuse('90261', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
            jsonb_build_object('table', NEW.table_name, 'field_name', NEW.field_name,
                               'problem', 'a rollup field cannot be unique'));
    END IF;

    NEW.ctype := 'rollup';
    NEW."precision" := (v_def ->> 'precision')::smallint;
    -- The guard makes user input meaningless, and a form must not even submit
    -- the value: disabled, not readonly, because an HTML readonly input is still
    -- part of the submission while a disabled one is not. hidden stays as set.
    IF NEW.input_type IN ('default', 'readonly') THEN
        NEW.input_type := 'disabled';
    END IF;

    -- A cast the compiler cannot judge ('abc' against a numeric column) is
    -- caught by the planner here, at save time, not at the first child write.
    IF v_def ->> 'filter_sql' IS NOT NULL THEN
        BEGIN
            EXECUTE format('EXPLAIN SELECT 1 FROM public.%I c WHERE %s', v_def ->> 'child_rel', v_def ->> 'filter_sql');
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
                PERFORM rollup_refuse('90265', 'Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}',
                    jsonb_build_object('table', NEW.table_name, 'field_name', NEW.field_name, 'problem', v_err));
        END;
    END IF;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION zz_validate_rollup_field() IS
'BEFORE INSERT OR UPDATE trigger function on fields: validates a rollup definition through rollup_definition, derives ctype rollup, copies the value field''s precision, coerces input_type default and readonly to disabled, refuses required, searchable and unique rollups, and probes the compiled filter with EXPLAIN.';

CREATE OR REPLACE TRIGGER zz_validate_rollup_field
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION zz_validate_rollup_field();

-- BEFORE DELETE. A field another entity's rollup aggregates through or over
-- cannot go: the rollup would name nothing. Mirrors 90260 in delete_dd_table:
-- the joins on entities and modules leave out a dependent whose entity or
-- module row is already gone, which is the module-delete cascade taking both
-- sides along, in whatever order it reaches them.
CREATE OR REPLACE FUNCTION a_rollup_field_delete_guard()
RETURNS TRIGGER AS $fn$
DECLARE
    v_deps TEXT;
BEGIN
    SELECT string_agg(f.table_name || '.' || f.field_name, ', ' ORDER BY f.table_name, f.field_name)
      INTO v_deps
      FROM fields f
      JOIN entities d ON d.table_name = f.table_name
      JOIN modules m ON m.id = d.module_id
     WHERE f.rollup <> '{}'::jsonb
       AND NOT (f.table_name = OLD.table_name AND f.field_name = OLD.field_name)
       AND (f.rollup ->> 'link_field' = OLD.table_name || '.' || OLD.field_name
            OR (split_part(f.rollup ->> 'link_field', '.', 1) = OLD.table_name
                AND f.rollup ->> 'value_field' = OLD.field_name));
    IF v_deps IS NOT NULL THEN
        PERFORM rollup_refuse('90266', 'Field ${field_name} on ${table} cannot be deleted while rollups ${rollups} depend on it',
            jsonb_build_object('table', OLD.table_name, 'field_name', OLD.field_name, 'rollups', v_deps));
    END IF;
    RETURN OLD;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION a_rollup_field_delete_guard() IS
'BEFORE DELETE trigger function on fields: refuses (90266) deleting a field that a rollup of another entity names as its link or value field, unless that entity or its module is already being deleted.';

CREATE OR REPLACE TRIGGER a_rollup_field_delete_guard
    BEFORE DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION a_rollup_field_delete_guard();

-- AFTER INSERT OR UPDATE OR DELETE. The zz_ name puts it after add_field_trigger
-- and update_field_trigger, so the column exists under its current name when
-- the generated functions are built.
CREATE OR REPLACE FUNCTION zz_rollup_field_change()
RETURNS TRIGGER AS $fn$
DECLARE
    v_old_link TEXT;
    v_new_link TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.rollup <> '{}'::jsonb THEN
            PERFORM rollup_sync_field(NEW, TRUE);
        END IF;
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF OLD.rollup <> '{}'::jsonb THEN
            -- The row is gone: the link is rebuilt without it (dropped when it
            -- was the last), and so is the guard, which also returns the
            -- parent's updated_at and audit triggers to their plain form.
            PERFORM rollup_build_link(split_part(OLD.rollup ->> 'link_field', '.', 1),
                                      split_part(OLD.rollup ->> 'link_field', '.', 2));
            PERFORM rollup_build_guard(OLD.table_name);
        END IF;
        RETURN NULL;
    END IF;

    -- UPDATE. Inside a table rename cascade zz_rollup_entity_change does the work.
    IF current_setting('dd.table_rename', TRUE) IS NOT DISTINCT FROM OLD.table_name || ':' || NEW.table_name THEN
        RETURN NULL;
    END IF;

    v_old_link := CASE WHEN OLD.rollup <> '{}'::jsonb THEN OLD.rollup ->> 'link_field' END;
    v_new_link := CASE WHEN NEW.rollup <> '{}'::jsonb THEN NEW.rollup ->> 'link_field' END;
    IF (v_old_link IS NOT NULL OR v_new_link IS NOT NULL)
       AND (OLD.rollup IS DISTINCT FROM NEW.rollup OR OLD.format <> NEW.format
            OR OLD."precision" <> NEW."precision" OR OLD.field_name <> NEW.field_name) THEN
        IF v_old_link IS NOT NULL AND v_old_link IS DISTINCT FROM v_new_link THEN
            PERFORM rollup_build_link(split_part(v_old_link, '.', 1), split_part(v_old_link, '.', 2));
        END IF;
        IF v_new_link IS NOT NULL THEN
            -- A rename alone needs no backfill; a changed definition or type does.
            PERFORM rollup_sync_field(NEW, OLD.rollup IS DISTINCT FROM NEW.rollup OR OLD.format <> NEW.format);
        ELSE
            PERFORM rollup_build_guard(NEW.table_name);
        END IF;
    END IF;

    -- A renamed field that other rollups name as their link or value field, or in a filter.
    IF OLD.field_name <> NEW.field_name THEN
        PERFORM rollup_rename_field_refs(NEW.table_name, OLD.field_name, NEW.field_name);
    END IF;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION zz_rollup_field_change() IS
'AFTER INSERT OR UPDATE OR DELETE trigger function on fields: builds, rebuilds, backfills or drops the generated objects of a rollup field, and rewrites the rollups that name a renamed field.';

CREATE OR REPLACE TRIGGER zz_rollup_field_change
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION zz_rollup_field_change();

-- =====================================================
-- Lifecycle: entities
-- =====================================================
-- BEFORE DELETE, sorting before delete_table_trigger: the refusal comes before
-- any DDL rather than from the fields cascade after DROP TABLE already ran.
CREATE OR REPLACE FUNCTION a_rollup_entity_delete_guard()
RETURNS TRIGGER AS $fn$
DECLARE
    v_deps  TEXT;
    v_field TEXT;
BEGIN
    SELECT string_agg(f.table_name || '.' || f.field_name, ', ' ORDER BY f.table_name, f.field_name),
           min(split_part(f.rollup ->> 'link_field', '.', 2))
      INTO v_deps, v_field
      FROM fields f
      JOIN entities d ON d.table_name = f.table_name
      JOIN modules m ON m.id = d.module_id
     WHERE f.rollup <> '{}'::jsonb
       AND f.table_name <> OLD.table_name
       AND split_part(f.rollup ->> 'link_field', '.', 1) = OLD.table_name;
    IF v_deps IS NOT NULL THEN
        PERFORM rollup_refuse('90266', 'Field ${field_name} on ${table} cannot be deleted while rollups ${rollups} depend on it',
            jsonb_build_object('table', OLD.table_name, 'field_name', v_field, 'rollups', v_deps));
    END IF;
    RETURN OLD;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION a_rollup_entity_delete_guard() IS
'BEFORE DELETE trigger function on entities: refuses (90266) deleting an entity whose fields another entity''s rollups aggregate through or over, unless that entity or its module is already being deleted.';

CREATE OR REPLACE TRIGGER a_rollup_entity_delete_guard
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION a_rollup_entity_delete_guard();

-- AFTER UPDATE, after the RI cascade has moved the fields rows to a new
-- table_name and rename_reference_tables_trigger has rewritten reference_table.
CREATE OR REPLACE FUNCTION zz_rollup_entity_change()
RETURNS TRIGGER AS $fn$
DECLARE
    r   RECORD;
    v_f fields%ROWTYPE;
BEGIN
    IF OLD.table_name <> NEW.table_name THEN
        -- The objects named after the old name go first; the rebuilds below
        -- create them under the new one.
        FOR r IN
            SELECT DISTINCT split_part(rollup ->> 'link_field', '.', 2) AS link
              FROM fields
             WHERE rollup <> '{}'::jsonb AND split_part(rollup ->> 'link_field', '.', 1) = OLD.table_name
        LOOP
            EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', rollup_object_name(OLD.table_name, r.link));
        END LOOP;
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', rollup_guard_name(OLD.table_name));
        -- The rollups that aggregate over this entity: the definitions name it,
        -- and the rewrite rebuilds them (zz_rollup_field_change).
        UPDATE fields
           SET rollup = jsonb_set(rollup, '{link_field}',
                                  to_jsonb(NEW.table_name || '.' || split_part(rollup ->> 'link_field', '.', 2)))
         WHERE rollup <> '{}'::jsonb AND split_part(rollup ->> 'link_field', '.', 1) = OLD.table_name;
        -- The rollups of this entity: their generated bodies name the parent.
        FOR v_f IN SELECT * FROM fields WHERE table_name = NEW.table_name AND rollup <> '{}'::jsonb LOOP
            PERFORM rollup_sync_field(v_f, FALSE);
        END LOOP;
    END IF;

    IF OLD.managed <> NEW.managed THEN
        -- Managed: the tables exist now (enable_table_trigger ran before this),
        -- so everything involving the entity is built and backfilled. Unmanaged:
        -- the builders find nothing to generate and drop what there was.
        FOR v_f IN
            SELECT * FROM fields
             WHERE rollup <> '{}'::jsonb
               AND (table_name = NEW.table_name OR split_part(rollup ->> 'link_field', '.', 1) = NEW.table_name)
        LOOP
            PERFORM rollup_sync_field(v_f, NEW.managed);
        END LOOP;
    END IF;

    -- A child that becomes more restricted than its parent turns an existing
    -- rollup into a leak: re-validated, so the change is refused (90269) until
    -- the rollup opts in or goes.
    IF OLD.select_rule IS DISTINCT FROM NEW.select_rule OR OLD.view_permission <> NEW.view_permission THEN
        FOR v_f IN
            SELECT * FROM fields
             WHERE rollup <> '{}'::jsonb
               AND (table_name = NEW.table_name OR split_part(rollup ->> 'link_field', '.', 1) = NEW.table_name)
        LOOP
            PERFORM rollup_definition(v_f);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION zz_rollup_entity_change() IS
'AFTER UPDATE trigger function on entities: on a rename rewrites the rollups that name the entity and regenerates their objects, on a managed change builds or drops them, and on a select_rule or view_permission change re-validates the rollups that involve the entity.';

CREATE OR REPLACE TRIGGER zz_rollup_entity_change
    AFTER UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION zz_rollup_entity_change();

-- AFTER DELETE. DROP TABLE CASCADE took the triggers and the fields cascade
-- rebuilt or dropped the maintenance functions; the guard function of a plain
-- entity survives its table (precedent: is_a_dispatch_<t> in delete_dd_table).
CREATE OR REPLACE FUNCTION zz_rollup_entity_delete()
RETURNS TRIGGER AS $fn$
BEGIN
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', rollup_guard_name(OLD.table_name));
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION zz_rollup_entity_delete() IS
'AFTER DELETE trigger function on entities: drops the guard function the deleted entity''s table left behind.';

CREATE OR REPLACE TRIGGER zz_rollup_entity_delete
    AFTER DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION zz_rollup_entity_delete();

REVOKE EXECUTE ON FUNCTION zz_validate_rollup_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION a_rollup_field_delete_guard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zz_rollup_field_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION a_rollup_entity_delete_guard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zz_rollup_entity_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zz_rollup_entity_delete() FROM PUBLIC;
