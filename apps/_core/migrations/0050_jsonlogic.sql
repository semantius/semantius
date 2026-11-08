-- Helper: JsonLogic truthy semantics
-- false, null, 0, "" and empty arrays are falsy; everything else is truthy
CREATE OR REPLACE FUNCTION jl_truthy(val jsonb) RETURNS boolean AS $$
BEGIN
    IF val IS NULL THEN RETURN false; END IF;
    CASE jsonb_typeof(val)
        WHEN 'boolean' THEN RETURN val::text = 'true';
        WHEN 'null'    THEN RETURN false;
        WHEN 'number'  THEN RETURN val::text::numeric <> 0;
        WHEN 'string'  THEN RETURN val #>> '{}' <> '';
        WHEN 'array'   THEN RETURN jsonb_array_length(val) > 0;
        ELSE RETURN true; -- objects are truthy
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Helper: coerce jsonb value to numeric (for arithmetic / comparisons)
-- The numeric value of a jsonb, or SQL NULL where there is none. This is
-- JavaScript's NaN, and it exists because two callers need opposite things from
-- it: arithmetic wants a number whatever it was handed, while equality must not
-- invent one. jl_to_number below folds NULL to 0 for the first; jl_loose_eq
-- answers false for the second, which is what JavaScript does when it compares
-- against NaN.
CREATE OR REPLACE FUNCTION jl_try_number(val jsonb) RETURNS numeric AS $$
DECLARE
    txt_val text;
BEGIN
    IF val IS NULL THEN RETURN NULL; END IF;

    CASE jsonb_typeof(val)
        WHEN 'number' THEN
            RETURN val::text::numeric;

        WHEN 'string' THEN
            txt_val := val #>> '{}';

            -- First try numeric coercion to preserve original JsonLogic behavior.
            -- data_exception is the whole 22xxx class: bad syntax, overflow,
            -- anything the cast can raise on caller-supplied text.
            BEGIN
                RETURN txt_val::numeric;
            EXCEPTION WHEN data_exception THEN
                NULL;
            END;

            -- Number('') and Number('   ') are 0 in JavaScript, not NaN, and the
            -- numeric cast above raises on both. Without this an empty string
            -- would stop comparing equal to 0 and to false.
            IF trim(txt_val) = '' THEN
                RETURN 0::numeric;
            END IF;

            -- Then try timestamp/date coercion for ISO-like date strings. This is
            -- a Semantius extension (JavaScript would give NaN); it makes the
            -- function STABLE, not IMMUTABLE, because the parse follows DateStyle.
            BEGIN
                RETURN extract(epoch FROM txt_val::timestamp)::numeric;
            EXCEPTION WHEN data_exception THEN
                RETURN NULL;
            END;

        WHEN 'boolean' THEN RETURN CASE WHEN val::text = 'true' THEN 1::numeric ELSE 0::numeric END;
        WHEN 'null' THEN RETURN NULL;
        ELSE RETURN NULL;
    END CASE;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

CREATE OR REPLACE FUNCTION jl_to_number(val jsonb) RETURNS numeric AS $$
BEGIN
    RETURN COALESCE(jl_try_number(val), 0::numeric);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- Helper: coerce jsonb value to text (for cat, substr, in-string)
CREATE OR REPLACE FUNCTION jl_to_text(val jsonb) RETURNS text AS $$
BEGIN
    IF val IS NULL THEN RETURN ''; END IF;
    CASE jsonb_typeof(val)
        WHEN 'string' THEN RETURN val #>> '{}';
        WHEN 'null'   THEN RETURN '';
        ELSE RETURN val::text;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Helper: loose equality (==) mimicking JS type coercion
-- Numbers are compared as numbers; if either side is a number and the other a string, coerce string to number.
CREATE OR REPLACE FUNCTION jl_loose_eq(a jsonb, b jsonb) RETURNS boolean AS $$
DECLARE
    ta text; tb text;
BEGIN
    IF a IS NULL AND b IS NULL THEN RETURN true; END IF;
    IF a IS NULL OR b IS NULL THEN RETURN false; END IF;
    ta := jsonb_typeof(a);
    tb := jsonb_typeof(b);
    -- Same type: direct comparison
    IF ta = tb THEN RETURN a = b; END IF;
    -- null == null only (already handled), null != anything else
    IF ta = 'null' OR tb = 'null' THEN RETURN false; END IF;
    -- number vs string: coerce string to number. jl_try_number, not
    -- jl_to_number: a string that carries no number at all has none to compare,
    -- and reading it as 0 would make "abc" == 0 true. JavaScript coerces it to
    -- NaN and answers false.
    IF (ta = 'number' AND tb = 'string') OR (ta = 'string' AND tb = 'number') THEN
        RETURN jl_try_number(a) IS NOT NULL
           AND jl_try_number(b) IS NOT NULL
           AND jl_try_number(a) = jl_try_number(b);
    END IF;
    -- boolean vs other: coerce boolean to number then compare. Only a string
    -- side can fail to produce one; an array or object keeps the historical 0,
    -- and JavaScript's own answer for false == [] is true as well.
    IF ta = 'boolean' OR tb = 'boolean' THEN
        IF (ta = 'string' AND jl_try_number(a) IS NULL)
           OR (tb = 'string' AND jl_try_number(b) IS NULL) THEN
            RETURN false;
        END IF;
        RETURN jl_to_number(a) = jl_to_number(b);
    END IF;
    RETURN a = b;
END;
-- STABLE, not IMMUTABLE: it calls jl_to_number, whose date cast follows DateStyle.
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- =====================================================
-- Date operators
-- =====================================================
-- Every value becomes a UTC timestamp WITHOUT a time zone before any arithmetic.
-- Interval addition, date_trunc, extract, age and to_char all follow the session's
-- time zone when handed a timestamptz, and evaluate_json_logic runs in whatever
-- zone its caller has, so a timestamptz here would make a stored result depend on
-- who wrote the row. On a plain timestamp none of those functions consults the
-- session at all, which holds without a SET clause on any of these helpers.

-- Null and the empty string both mean "no date": a nullable date column reads as
-- null and a cleared form control sends "". Neither may fail a write, or a record
-- that has no date yet could not be saved.
CREATE OR REPLACE FUNCTION jl_date_is_blank(p_value jsonb) RETURNS boolean AS $$
BEGIN
    RETURN p_value IS NULL OR jsonb_typeof(p_value) = 'null' OR p_value = '""'::jsonb;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

CREATE OR REPLACE FUNCTION jl_date_is_date_only(p_value jsonb) RETURNS boolean AS $$
BEGIN
    RETURN jsonb_typeof(p_value) = 'string'
       AND (p_value #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- The regular expressions are what keep this strict. The casts alone also accept
-- 'today', 'infinity', 'J2461406' and, depending on DateStyle, '01/02/2026', and a
-- stored value must not depend on the day a rule ran or on a session setting.
--
-- There is no EXCEPTION block: it would cost a subtransaction per value on every
-- row a select_rule reads. A value of the right shape that is no real date, such
-- as 2026-02-30, therefore travels out as PostgreSQL's own 22008.
--
-- Fractions of a second are dropped on the way in rather than on the way out, so
-- date_diff cannot disagree with what the same two values render as, and so the
-- browser evaluator, whose clock stops at milliseconds, reaches the same answer.
CREATE OR REPLACE FUNCTION jl_date_utc(p_op text, p_value jsonb) RETURNS timestamp AS $$
DECLARE
    v_moment CONSTANT text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?';
    v_text text;
BEGIN
    IF jsonb_typeof(p_value) = 'string' THEN
        v_text := p_value #>> '{}';
        IF jl_date_is_date_only(p_value) THEN
            RETURN v_text::date::timestamp;
        END IF;
        -- No offset means UTC, so the session's zone must not be applied to it.
        IF v_text ~ (v_moment || '$') THEN
            RETURN date_trunc('second', v_text::timestamp);
        END IF;
        IF v_text ~ (v_moment || '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$') THEN
            RETURN date_trunc('second', v_text::timestamptz AT TIME ZONE 'UTC');
        END IF;
    END IF;
    RAISE EXCEPTION '${operator} needs an ISO 8601 date or date-time, not ${value}'
        USING ERRCODE = '90915',
              HINT = jsonb_build_object('operator', p_op, 'value', p_value)::text;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- The offset is written out rather than left to to_jsonb, which would render the
-- session's zone, and the seconds carry no fraction, as jl_date_utc promises.
CREATE OR REPLACE FUNCTION jl_date_render(p_moment timestamp, p_date_only boolean) RETURNS jsonb AS $$
BEGIN
    IF p_date_only THEN
        RETURN to_jsonb(p_moment::date);
    END IF;
    RETURN to_jsonb(to_char(p_moment, 'YYYY-MM-DD"T"HH24:MI:SS"+00:00"'));
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

CREATE OR REPLACE FUNCTION jl_date_bad_unit(p_op text, p_unit jsonb) RETURNS void AS $$
BEGIN
    RAISE EXCEPTION '${operator} cannot use ${unit} on this value'
        USING ERRCODE = '90916',
              HINT = jsonb_build_object('operator', p_op, 'unit', p_unit)::text;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- A date-only value has no time of day to move or read, and answering as though
-- it were midnight would silently invent one.
--
-- v_units is compared against the list in sem-schema's operators.ts by that
-- package's backend sync test, which finds it by this declaration.
CREATE OR REPLACE FUNCTION jl_date_unit(p_op text, p_unit jsonb, p_date_only boolean) RETURNS text AS $$
DECLARE
    v_units CONSTANT text[] := ARRAY['year','quarter','month','week','day','hour','minute','second'];
    v_unit text;
BEGIN
    IF jsonb_typeof(p_unit) = 'string' THEN
        v_unit := p_unit #>> '{}';
    END IF;
    IF v_unit IS NULL OR NOT (v_unit = ANY(v_units))
       OR (p_date_only AND v_unit IN ('hour', 'minute', 'second')) THEN
        PERFORM jl_date_bad_unit(p_op, p_unit);
    END IF;
    RETURN v_unit;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"date_add":[date, amount, unit]} or {"date_add":[date, duration]}.
--
-- A duration is limited to the canonical ISO 8601 order plus the per-field minus
-- signs PostgreSQL's iso_8601 style emits, which is what a duration column holds
-- in rule data. The interval cast alone would also take '1 day' and '@ 1 ago',
-- which the browser evaluator would have to parse identically.
CREATE OR REPLACE FUNCTION jl_date_add(p_date jsonb, p_amount jsonb, p_unit jsonb) RETURNS jsonb AS $$
DECLARE
    v_date_only boolean := jl_date_is_date_only(p_date);
    v_moment timestamp;
    v_span interval;
    v_text text;
    v_number numeric;
    v_count int;
BEGIN
    IF jl_date_is_blank(p_date) OR jl_date_is_blank(p_amount) THEN
        RETURN 'null'::jsonb;
    END IF;
    v_moment := jl_date_utc('date_add', p_date);
    v_text := p_amount #>> '{}';

    IF p_unit IS NULL THEN
        IF jsonb_typeof(p_amount) = 'number' THEN
            PERFORM jl_date_bad_unit('date_add', 'null'::jsonb);
        END IF;
        IF jsonb_typeof(p_amount) <> 'string'
           OR v_text !~ '^P(-?[0-9]+Y)?(-?[0-9]+M)?(-?[0-9]+W)?(-?[0-9]+D)?(T(-?[0-9]+H)?(-?[0-9]+M)?(-?[0-9]+(\.[0-9]+)?S)?)?$'
           OR v_text ~ '^PT?$' OR v_text ~ 'T$' THEN
            RAISE EXCEPTION '${operator} needs a whole number or an ISO 8601 duration, not ${value}'
                USING ERRCODE = '90918',
                      HINT = jsonb_build_object('operator', 'date_add', 'value', p_amount)::text;
        END IF;
        v_span := v_text::interval;
        IF v_date_only AND date_trunc('day', v_span) <> v_span THEN
            PERFORM jl_date_bad_unit('date_add', p_amount);
        END IF;
        RETURN jl_date_render(v_moment + v_span, v_date_only);
    END IF;

    v_text := jl_date_unit('date_add', p_unit, v_date_only);
    IF jsonb_typeof(p_amount) = 'number'
       OR (jsonb_typeof(p_amount) = 'string' AND (p_amount #>> '{}') ~ '^-?[0-9]+(\.0+)?$') THEN
        v_number := (p_amount #>> '{}')::numeric;
    END IF;
    IF v_number IS NULL OR v_number <> trunc(v_number) THEN
        RAISE EXCEPTION '${operator} needs a whole number or an ISO 8601 duration, not ${value}'
            USING ERRCODE = '90918',
                  HINT = jsonb_build_object('operator', 'date_add', 'value', p_amount)::text;
    END IF;
    v_count := v_number::int;

    v_span := CASE v_text
        WHEN 'year'    THEN make_interval(years  => v_count)
        WHEN 'quarter' THEN make_interval(months => v_count * 3)
        WHEN 'month'   THEN make_interval(months => v_count)
        WHEN 'week'    THEN make_interval(weeks  => v_count)
        WHEN 'day'     THEN make_interval(days   => v_count)
        WHEN 'hour'    THEN make_interval(hours  => v_count)
        WHEN 'minute'  THEN make_interval(mins   => v_count)
        ELSE                make_interval(secs   => v_count)
    END;
    RETURN jl_date_render(v_moment + v_span, v_date_only);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"date_diff":[end, start, unit]}: whole elapsed units, truncated toward zero, in
-- the argument order of "-". Calendar units go through age(), so a month has
-- elapsed only when the day of the month has been reached again: Jan 31 to Feb 28
-- is 0 months even though adding a month to Jan 31 lands on Feb 28.
CREATE OR REPLACE FUNCTION jl_date_diff(p_end jsonb, p_start jsonb, p_unit jsonb) RETURNS jsonb AS $$
DECLARE
    v_unit text;
    v_end timestamp;
    v_start timestamp;
    v_age interval;
BEGIN
    IF jl_date_is_blank(p_end) OR jl_date_is_blank(p_start) THEN
        RETURN 'null'::jsonb;
    END IF;
    v_unit := jl_date_unit('date_diff', p_unit, false);
    v_end := jl_date_utc('date_diff', p_end);
    v_start := jl_date_utc('date_diff', p_start);

    IF v_unit IN ('year', 'quarter', 'month') THEN
        v_age := age(v_end, v_start);
        RETURN to_jsonb(trunc(
            (extract(year FROM v_age)::numeric * 12 + extract(month FROM v_age)::numeric)
            / CASE v_unit WHEN 'year' THEN 12 WHEN 'quarter' THEN 3 ELSE 1 END
        )::bigint);
    END IF;
    RETURN to_jsonb(trunc(
        extract(epoch FROM v_end - v_start)::numeric
        / CASE v_unit WHEN 'week' THEN 604800 WHEN 'day' THEN 86400
                      WHEN 'hour' THEN 3600 WHEN 'minute' THEN 60 ELSE 1 END
    )::bigint);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"date_part":[date, part]}. v_parts is checked by the same sync test as v_units.
CREATE OR REPLACE FUNCTION jl_date_part(p_date jsonb, p_part jsonb) RETURNS jsonb AS $$
DECLARE
    v_parts CONSTANT text[] := ARRAY['year','iso_year','quarter','month','week','day','weekday','day_of_year','hour','minute','second','epoch'];
    v_part text;
    v_moment timestamp;
BEGIN
    IF jl_date_is_blank(p_date) THEN
        RETURN 'null'::jsonb;
    END IF;
    v_moment := jl_date_utc('date_part', p_date);
    IF jsonb_typeof(p_part) = 'string' THEN
        v_part := p_part #>> '{}';
    END IF;
    IF v_part IS NULL OR NOT (v_part = ANY(v_parts))
       OR (jl_date_is_date_only(p_date) AND v_part IN ('hour', 'minute', 'second')) THEN
        PERFORM jl_date_bad_unit('date_part', p_part);
    END IF;
    RETURN to_jsonb((CASE v_part
        WHEN 'year'        THEN extract(year    FROM v_moment)
        WHEN 'iso_year'    THEN extract(isoyear FROM v_moment)
        WHEN 'quarter'     THEN extract(quarter FROM v_moment)
        WHEN 'month'       THEN extract(month   FROM v_moment)
        WHEN 'week'        THEN extract(week    FROM v_moment)
        WHEN 'day'         THEN extract(day     FROM v_moment)
        WHEN 'weekday'     THEN extract(isodow  FROM v_moment)
        WHEN 'day_of_year' THEN extract(doy     FROM v_moment)
        WHEN 'hour'        THEN extract(hour    FROM v_moment)
        WHEN 'minute'      THEN extract(minute  FROM v_moment)
        WHEN 'second'      THEN extract(second  FROM v_moment)
        ELSE                    extract(epoch   FROM v_moment)
    END)::bigint);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"date_trunc":[date, unit]}: the start of the period; a week starts on Monday.
CREATE OR REPLACE FUNCTION jl_date_trunc(p_date jsonb, p_unit jsonb) RETURNS jsonb AS $$
DECLARE
    v_date_only boolean := jl_date_is_date_only(p_date);
    v_moment timestamp;
BEGIN
    IF jl_date_is_blank(p_date) THEN
        RETURN 'null'::jsonb;
    END IF;
    v_moment := jl_date_utc('date_trunc', p_date);
    RETURN jl_date_render(date_trunc(jl_date_unit('date_trunc', p_unit, v_date_only), v_moment), v_date_only);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"to_date":[value]}. A number is read as UTC because that exactly reverses the
-- epoch conversion in jl_try_number, which is what lets the epoch integers that
-- date arithmetic, max and min produce become dates again.
CREATE OR REPLACE FUNCTION jl_to_date(p_value jsonb) RETURNS jsonb AS $$
BEGIN
    IF jl_date_is_blank(p_value) THEN
        RETURN 'null'::jsonb;
    END IF;
    IF jsonb_typeof(p_value) = 'number' THEN
        RETURN to_jsonb((to_timestamp((p_value #>> '{}')::double precision) AT TIME ZONE 'UTC')::date);
    END IF;
    RETURN to_jsonb(jl_date_utc('to_date', p_value)::date);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- {"date_format":[date, pattern]}.
--
-- A fixed token list rather than to_char's own patterns, because the browser
-- evaluator has no to_char and has to produce the same text. TM-prefixed patterns
-- would also make a stored label follow lc_time.
--
-- Tokens are rendered one at a time. Handing the whole pattern to to_char would
-- misread adjacent tokens: DD followed by Dy is DDDy to to_char, which reads DDD,
-- the day of the year. FM removes the blank padding to_char adds to Month and Day.
--
-- The list is longest-first so that a token is never read as a shorter one, and
-- v_tokens is checked by the same sync test as v_units.
CREATE OR REPLACE FUNCTION jl_date_format(p_date jsonb, p_pattern jsonb) RETURNS jsonb AS $$
DECLARE
    v_tokens CONSTANT text[] := ARRAY['YYYY','Month','HH24','Mon','Day','YY','MM','DD','Dy','MI','SS','Q'];
    v_token_re CONSTANT text := array_to_string(v_tokens, '|') || '|[ /.:,-]';
    v_moment timestamp;
    v_pattern text;
    v_match text[];
    v_out text := '';
BEGIN
    IF jl_date_is_blank(p_date) THEN
        RETURN 'null'::jsonb;
    END IF;
    v_moment := jl_date_utc('date_format', p_date);
    IF jsonb_typeof(p_pattern) = 'string' THEN
        v_pattern := p_pattern #>> '{}';
    END IF;
    IF v_pattern IS NULL OR v_pattern !~ ('^(' || v_token_re || ')+$')
       OR (jl_date_is_date_only(p_date) AND v_pattern ~ '(HH24|MI|SS)') THEN
        RAISE EXCEPTION '${operator} cannot use the pattern ${pattern}'
            USING ERRCODE = '90917',
                  HINT = jsonb_build_object('operator', 'date_format', 'pattern', p_pattern)::text;
    END IF;
    FOR v_match IN SELECT regexp_matches(v_pattern, '(' || v_token_re || ')', 'g') LOOP
        v_out := v_out || CASE
            WHEN v_match[1] IN ('Month', 'Day') THEN to_char(v_moment, 'FM' || v_match[1])
            WHEN v_match[1] = ANY(v_tokens)     THEN to_char(v_moment, v_match[1])
            ELSE v_match[1]
        END;
    END LOOP;
    RETURN to_jsonb(v_out);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- is_raci_actor and has_consultation call functions defined in 0370_raci.sql; no rule
-- evaluated during install uses those operators.
CREATE OR REPLACE FUNCTION evaluate_json_logic(rule jsonb, data jsonb)
RETURNS jsonb AS $$
DECLARE
    op text;
    vals jsonb;
    arr_len int;
    pos int;
    current_val jsonb;
    a jsonb; b jsonb; c jsonb;
    num_a numeric; num_b numeric; num_c numeric;
    cmp_ab int; cmp_bc int;
    result jsonb;
    scoped_data jsonb;
    scoped_logic jsonb;
    initial_val jsonb;
    -- The groups below name the operator each variable was introduced for, not
    -- the operator that owns it: this function is one dispatch in a single
    -- scope, so a slot is reused wherever it fits. var_key and nav serve
    -- set_record as well as var, elem serves cat as well as merge, and txt_a and
    -- txt_b are borrowed by every operator that handles text.
    -- var
    var_key text;
    sub_props text[];
    nav jsonb;
    -- missing
    missing_arr jsonb;
    keys_arr jsonb;
    looked_up jsonb;
    -- merge
    merge_result jsonb;
    elem jsonb;
    -- substr
    src text;
    start_pos int;
    end_len int;
    temp_str text;
    -- text ops
    txt_a text; txt_b text;
    -- throw_error
    err_code text; err_hint jsonb; err_name text; err_value jsonb;
BEGIN
    -- Handle NULL rule
    IF rule IS NULL THEN RETURN 'null'::jsonb; END IF;

    -- Arrays with possible logic inside: recursively evaluate each element
    IF jsonb_typeof(rule) = 'array' THEN
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(rule) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(rule -> i, data));
        END LOOP;
        RETURN result;
    END IF;

    -- Anything that is not an object is a value, not logic. A multi-key
    -- object is not logic either, and the single-key test below is where that
    -- is decided.
    IF jsonb_typeof(rule) <> 'object' THEN RETURN rule; END IF;
    -- Must have exactly one key to be logic.
    -- Read the key with an expression, never a query. jsonb_object_keys is
    -- set-returning, so any use of it needs a FROM clause, and a FROM clause
    -- puts the statement outside PL/pgSQL's simple-expression path: it is handed
    -- to the SQL engine to be planned and executed like any other query. This
    -- runs once per node, and a rule as small as {"==": [{"var": "c"}, "x"]} has
    -- two of them, on every row.
    --
    -- `rule - op` removing the key we found leaves '{}' exactly when it was the
    -- only one, which is the whole single-key test. Which key $.keyvalue()
    -- picks out of a multi-key object does not matter: any such object is
    -- returned unchanged whichever key came first.
    --
    -- The NULL guard is required, not decorative: an empty object {} has no key
    -- to find, so op is NULL, and without the guard the next line evaluates
    -- `rule -> NULL`. An object with no keys is not logic and belongs with the
    -- other pass-through cases. The OR is safe either way round - `NULL <> '{}'`
    -- is NULL, and TRUE OR NULL is TRUE - so it does not depend on
    -- short-circuit evaluation, which SQL does not promise.
    op := jsonb_path_query_first(rule, '$.keyvalue().key') #>> '{}';
    IF op IS NULL OR rule - op <> '{}'::jsonb THEN RETURN rule; END IF;

    vals := rule -> op;
    -- Normalize: if vals is not an array, wrap it
    IF jsonb_typeof(vals) <> 'array' THEN
        vals := jsonb_build_array(vals);
    END IF;
    arr_len := jsonb_array_length(vals);

    -- ===================== if / ?: =====================
    -- These twelve operators have to be dispatched BEFORE the depth-first
    -- argument evaluation further down. They either short-circuit (if, and, or)
    -- or bind their own scope (let, map, filter, reduce, all, none, some,
    -- set_record), so their arguments must not be evaluated eagerly.
    --
    -- The membership test in front of them is what keeps that cheap for
    -- everyone else. What follows is a run of separate IF statements, not an
    -- ELSIF chain, so without the test every other operator - var, ==, +, cat,
    -- all of them - evaluates twelve conditions that cannot match before
    -- reaching its own, on every node of every rule on every row.
    --
    -- The list must stay exactly the set of operators implemented between here
    -- and the barrier. Adding one without listing it here does not fail quietly:
    -- the operator falls through to the eager section, matches nothing, and
    -- raises 'Unrecognized operation' at the foot of this function, which every
    -- operator's own test case catches.
    --
    -- The bodies below are indented as though this guard were not around them,
    -- which is cosmetic and stays that way: re-indenting them would rewrite
    -- every line of the dispatch to no effect.
    --
    -- Ordering the operators by frequency instead of by this membership test is
    -- worth 0-2% where the test is worth 5, so they stay in the order they read
    -- best.
    IF op = ANY(ARRAY['if','?:','and','or','filter','map','reduce','all','none','some','let','set_record']) THEN

    IF op = 'if' OR op = '?:' THEN
        pos := 0;
        WHILE pos < arr_len - 1 LOOP
            IF jl_truthy(evaluate_json_logic(vals -> pos, data)) THEN
                RETURN evaluate_json_logic(vals -> (pos + 1), data);
            END IF;
            pos := pos + 2;
        END LOOP;
        -- Remaining single element = else clause
        IF arr_len = pos + 1 THEN
            RETURN evaluate_json_logic(vals -> pos, data);
        END IF;
        RETURN 'null'::jsonb;
    END IF;

    -- ===================== and =====================
    IF op = 'and' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF NOT jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== or =====================
    IF op = 'or' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== filter =====================
    IF op = 'filter' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                result := result || jsonb_build_array(scoped_data -> i);
            END IF;
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== map =====================
    IF op = 'map' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(scoped_logic, scoped_data -> i));
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== reduce =====================
    IF op = 'reduce' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF arr_len >= 3 THEN
            initial_val := evaluate_json_logic(vals -> 2, data);
        ELSE
            initial_val := 'null'::jsonb;
        END IF;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN initial_val;
        END IF;
        current_val := initial_val;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            current_val := evaluate_json_logic(
                scoped_logic,
                jsonb_build_object('current', scoped_data -> i, 'accumulator', current_val)
            );
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== all =====================
    IF op = 'all' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF NOT jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== none =====================
    IF op = 'none' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'true'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== some =====================
    IF op = 'some' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'true'::jsonb;
            END IF;
        END LOOP;
        RETURN 'false'::jsonb;
    END IF;

    -- ===================== let =====================
    -- Binds a named variable into data and evaluates a logic expression.
    -- Usage: {"let":["name", value, logic]}
    IF op = 'let' THEN
        var_key := vals ->> 0;
        result := evaluate_json_logic(vals -> 1, data);
        RETURN evaluate_json_logic(vals -> 2, data || jsonb_build_object(var_key, result));
    END IF;

    -- ===================== set_record =====================
    -- Loads an entity record by id and stores it in data under the given name.
    -- Usage: {"set_record":["varName", "entityName", idExpression, logic]}
    -- Calls get_record_by_id(entityName, id) and stores the result like let.
    -- The id goes over as text, so a text, uuid or TypeID key works as well as
    -- a number; get_record_by_id casts it to the key's type. A whole JSON
    -- number is written without its fraction first (5.0 -> 5), because
    -- arithmetic in a rule yields 5.0 and '5.0' is not a valid bigint. A
    -- malformed id raises get_record_by_id's 90238.
    IF op = 'set_record' THEN
        var_key := vals ->> 0;
        txt_a := vals ->> 1;
        result := evaluate_json_logic(vals -> 2, data);
        IF jsonb_typeof(result) = 'number' AND (result::numeric) = trunc(result::numeric) THEN
            txt_b := trunc(result::numeric)::text;
        ELSE
            txt_b := result #>> '{}';
        END IF;
        nav := get_record_by_id(txt_a, txt_b);
        RETURN evaluate_json_logic(vals -> 3, data || jsonb_build_object(var_key, COALESCE(nav, 'null'::jsonb)));
    END IF;

    END IF;   -- end of the pre-evaluation operator group

    -- =====================================================
    -- All remaining operators: depth-first evaluate arguments
    -- =====================================================
    -- Evaluate all arguments first
    result := '[]'::jsonb;
    FOR i IN 0 .. arr_len - 1 LOOP
        result := result || jsonb_build_array(evaluate_json_logic(vals -> i, data));
    END LOOP;
    vals := result;
    arr_len := jsonb_array_length(vals);

    -- Get convenience references
    a := vals -> 0;
    IF arr_len > 1 THEN b := vals -> 1; ELSE b := NULL; END IF;
    IF arr_len > 2 THEN c := vals -> 2; ELSE c := NULL; END IF;

    -- ===================== var =====================
    IF op = 'var' THEN
        -- a = the key/path, b = default value
        -- If a is undefined/null/empty string, return data itself
        IF a IS NULL OR jsonb_typeof(a) = 'null' OR (jsonb_typeof(a) = 'string' AND a #>> '{}' = '') THEN
            RETURN data;
        END IF;
        var_key := jl_to_text(a);
        sub_props := string_to_array(var_key, '.');
        nav := data;
        FOR i IN 1 .. array_length(sub_props, 1) LOOP
            IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
                -- not found, return default
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
            -- Try object key or array index
            IF jsonb_typeof(nav) = 'array' THEN
                BEGIN
                    nav := nav -> sub_props[i]::int;
                EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
                    IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
                END;
            ELSE
                nav := nav -> sub_props[i];
            END IF;
            IF nav IS NULL THEN
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
        END LOOP;
        RETURN nav;
    END IF;

    -- ===================== missing =====================
    IF op = 'missing' THEN
        -- Arguments can be individual keys or a single array of keys
        IF arr_len = 1 AND jsonb_typeof(a) = 'array' THEN
            keys_arr := a;
        ELSE
            keys_arr := vals;
        END IF;
        missing_arr := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(keys_arr) - 1 LOOP
            looked_up := evaluate_json_logic(jsonb_build_object('var', keys_arr -> i), data);
            IF jsonb_typeof(looked_up) = 'null' OR (jsonb_typeof(looked_up) = 'string' AND looked_up #>> '{}' = '') THEN
                missing_arr := missing_arr || jsonb_build_array(keys_arr -> i);
            END IF;
        END LOOP;
        RETURN missing_arr;
    END IF;

    -- ===================== missing_some =====================
    IF op = 'missing_some' THEN
        -- a = need_count, b = array of keys
        num_a := jl_to_number(a);
        -- Compute missing using the missing operator
        missing_arr := evaluate_json_logic(jsonb_build_object('missing', b), data);
        IF jsonb_array_length(b) - jsonb_array_length(missing_arr) >= num_a THEN
            RETURN '[]'::jsonb;
        ELSE
            RETURN missing_arr;
        END IF;
    END IF;

    -- ===================== == =====================
    IF op = '==' THEN
        RETURN to_jsonb(jl_loose_eq(a, b));
    END IF;

    -- ===================== === =====================
    IF op = '===' THEN
        -- Strict equality: types must match
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'false'::jsonb; END IF;
        RETURN to_jsonb(a = b);
    END IF;

    -- ===================== != =====================
    IF op = '!=' THEN
        RETURN to_jsonb(NOT jl_loose_eq(a, b));
    END IF;

    -- ===================== !== =====================
    IF op = '!==' THEN
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'true'::jsonb; END IF;
        RETURN to_jsonb(a <> b);
    END IF;

    -- ===================== ! =====================
    IF op = '!' THEN
        RETURN to_jsonb(NOT jl_truthy(a));
    END IF;

    -- ===================== !! =====================
    IF op = '!!' THEN
        RETURN to_jsonb(jl_truthy(a));
    END IF;

    -- ===================== > >= < <= =====================
    -- Two strings compare as text in code-point order (COLLATE "C"); any other
    -- pair is coerced to numbers through jl_to_number, so "10" > "9" is false
    -- and "10" > 9 is true. JavaScript orders strings by UTF-16 code unit, which
    -- is the same order for every character in the Basic Multilingual Plane and
    -- a different one above U+FFFF, where a surrogate pair sorts below U+E000
    -- there and above it here. The
    -- three-argument between form of < and <= applies the rule to each pair.
    IF op = '>' OR op = '>=' OR op = '<' OR op = '<=' THEN
        IF jsonb_typeof(a) = 'string' AND jsonb_typeof(b) = 'string' THEN
            txt_a := a #>> '{}';
            txt_b := b #>> '{}';
            cmp_ab := CASE WHEN txt_a COLLATE "C" < txt_b THEN -1
                           WHEN txt_a COLLATE "C" > txt_b THEN 1
                           ELSE 0 END;
        ELSE
            num_a := jl_to_number(a);
            num_b := jl_to_number(b);
            cmp_ab := CASE WHEN num_a < num_b THEN -1
                           WHEN num_a > num_b THEN 1
                           ELSE 0 END;
        END IF;
        IF op = '>' THEN RETURN to_jsonb(cmp_ab > 0); END IF;
        IF op = '>=' THEN RETURN to_jsonb(cmp_ab >= 0); END IF;
        IF c IS NULL THEN
            RETURN to_jsonb(CASE WHEN op = '<' THEN cmp_ab < 0 ELSE cmp_ab <= 0 END);
        END IF;
        IF jsonb_typeof(b) = 'string' AND jsonb_typeof(c) = 'string' THEN
            txt_a := b #>> '{}';
            txt_b := c #>> '{}';
            cmp_bc := CASE WHEN txt_a COLLATE "C" < txt_b THEN -1
                           WHEN txt_a COLLATE "C" > txt_b THEN 1
                           ELSE 0 END;
        ELSE
            num_b := jl_to_number(b);
            num_c := jl_to_number(c);
            cmp_bc := CASE WHEN num_b < num_c THEN -1
                           WHEN num_b > num_c THEN 1
                           ELSE 0 END;
        END IF;
        IF op = '<' THEN RETURN to_jsonb(cmp_ab < 0 AND cmp_bc < 0); END IF;
        RETURN to_jsonb(cmp_ab <= 0 AND cmp_bc <= 0);
    END IF;

    -- ===================== % =====================
    IF op = '%' THEN
        RETURN to_jsonb(jl_to_number(a) % jl_to_number(b));
    END IF;

    -- ===================== + =====================
    IF op = '+' THEN
        num_a := 0;
        FOR i IN 0 .. arr_len - 1 LOOP
            num_a := num_a + jl_to_number(vals -> i);
        END LOOP;
        -- Return integer if result is integer
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== * =====================
    IF op = '*' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_a := num_a * jl_to_number(vals -> i);
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== - =====================
    IF op = '-' THEN
        IF arr_len = 1 THEN
            num_a := -jl_to_number(a);
        ELSE
            num_a := jl_to_number(a) - jl_to_number(b);
        END IF;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== / =====================
    IF op = '/' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF num_b = 0 THEN RETURN 'null'::jsonb; END IF;
        num_c := num_a / num_b;
        IF num_c = trunc(num_c) THEN
            RETURN to_jsonb(num_c::bigint);
        ELSE
            RETURN to_jsonb(num_c);
        END IF;
    END IF;

    -- ===================== max =====================
    IF op = 'max' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b > num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== min =====================
    IF op = 'min' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b < num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== in =====================
    IF op = 'in' THEN
        IF b IS NULL THEN RETURN 'false'::jsonb; END IF;
        IF jsonb_typeof(b) = 'array' THEN
            -- Check if a is in the array
            FOR i IN 0 .. jsonb_array_length(b) - 1 LOOP
                IF a = b -> i THEN
                    RETURN 'true'::jsonb;
                END IF;
            END LOOP;
            RETURN 'false'::jsonb;
        ELSIF jsonb_typeof(b) = 'string' THEN
            -- Substring check
            txt_a := jl_to_text(a);
            txt_b := jl_to_text(b);
            RETURN to_jsonb(position(txt_a in txt_b) > 0);
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== cat =====================
    IF op = 'cat' THEN
        txt_a := '';
        FOR i IN 0 .. arr_len - 1 LOOP
            txt_a := txt_a || jl_to_text(vals -> i);
        END LOOP;
        RETURN to_jsonb(txt_a);
    END IF;

    -- ===================== substr =====================
    IF op = 'substr' THEN
        src := jl_to_text(a);
        start_pos := jl_to_number(b)::int;
        -- Handle negative start: count from end
        IF start_pos < 0 THEN
            start_pos := length(src) + start_pos;
            IF start_pos < 0 THEN start_pos := 0; END IF;
        END IF;
        IF arr_len >= 3 THEN
            end_len := jl_to_number(c)::int;
            IF end_len < 0 THEN
                -- Negative length: from start_pos, take chars until end_len from end
                temp_str := substring(src FROM start_pos + 1);
                RETURN to_jsonb(substring(temp_str FROM 1 FOR length(temp_str) + end_len));
            ELSE
                RETURN to_jsonb(substring(src FROM start_pos + 1 FOR end_len));
            END IF;
        ELSE
            RETURN to_jsonb(substring(src FROM start_pos + 1));
        END IF;
    END IF;

    -- ===================== merge =====================
    IF op = 'merge' THEN
        merge_result := '[]'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            elem := vals -> i;
            IF jsonb_typeof(elem) = 'array' THEN
                -- Concatenate array elements
                FOR j IN 0 .. jsonb_array_length(elem) - 1 LOOP
                    merge_result := merge_result || jsonb_build_array(elem -> j);
                END LOOP;
            ELSE
                merge_result := merge_result || jsonb_build_array(elem);
            END IF;
        END LOOP;
        RETURN merge_result;
    END IF;

    -- ===================== log =====================
    IF op = 'log' THEN
        RAISE NOTICE 'jsonlogic log: %', a;
        RETURN a;
    END IF;

    -- ===================== has_permission =====================
    -- Calls rbac.has_permission with the given permission name.
    -- Returns true when the user has the permission; false otherwise.
    IF op = 'has_permission' THEN
        IF rbac.has_permission(jl_to_text(a)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== require_permission =====================
    -- Calls rbac.require_permission with the given permission name.
    -- Returns true when the user has the permission; throws an error otherwise.
    IF op = 'require_permission' THEN
        PERFORM rbac.require_permission(jl_to_text(a));
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== value_changed =====================
    -- Checks if a field value has changed compared to $old.
    -- Reads $old without the rule ever naming it. build_record_logic_trigger in
    -- 0210_computed_validation.sql decides whether to build $old by searching the
    -- rule text for "$old" or for this operator's name, so any new operator that
    -- reads $old implicitly has to be added to that search or its rules will
    -- silently see no previous row.
    -- When $old is missing or null in data, always returns true (new record).
    -- When $old is present, compares $old.<field> with current <field>.
    IF op = 'value_changed' THEN
        var_key := jl_to_text(a);
        nav := data -> '$old';
        -- If $old is absent or null, treat as new record => always changed
        IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
            RETURN 'true'::jsonb;
        END IF;
        -- Compare old value with current value
        IF (nav -> var_key) IS DISTINCT FROM (data -> var_key) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== concat =====================
    -- Concatenates all arguments into a single string.
    -- Like SQL CONCAT: NULL/null → empty string, accepts all types.
    -- Non-string types are converted via their JSON text representation.
    -- Usage: {"concat":["Hello ", {"var":"name"}, " #", {"var":"id"}]}
    IF op = 'concat' THEN
        txt_a := '';
        FOR i IN 0 .. arr_len - 1 LOOP
            elem := vals -> i;
            IF elem IS NULL OR jsonb_typeof(elem) = 'null' THEN
                -- NULL/null → empty string
                CONTINUE;
            ELSIF jsonb_typeof(elem) = 'string' THEN
                txt_a := txt_a || (elem #>> '{}');
            ELSE
                -- numbers, booleans, arrays, objects → JSON text
                txt_a := txt_a || elem::text;
            END IF;
        END LOOP;
        RETURN to_jsonb(txt_a);
    END IF;

    -- ===================== is_match =====================
    -- Tests whether a string value matches a regular expression pattern.
    -- Returns true when the value matches, false otherwise.
    -- Null values always return false.
    -- Usage: {"is_match":[{"var":"email"}, "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"]}
    IF op = 'is_match' THEN
        -- The null test is on the jsonb, not on the converted text. jl_to_text
        -- renders JSON null as the empty string, so a text-level test cannot
        -- tell a missing value from an empty one and {"is_match":[null,"^$"]}
        -- would report a match.
        IF a IS NULL OR b IS NULL
           OR jsonb_typeof(a) = 'null' OR jsonb_typeof(b) = 'null' THEN
            RETURN 'false'::jsonb;
        END IF;
        txt_a := jl_to_text(a);
        txt_b := jl_to_text(b);
        RETURN to_jsonb(regexp_match(txt_a, txt_b) IS NOT NULL);
    END IF;

    -- ===================== throw_error =====================
    -- Raises an error the client can localize rather than print: the message is
    -- a template, the code says which translation to look up, and the parameters
    -- travel beside it keeping the JSON type their expression produced, so the
    -- client can substitute them into its own wording.
    -- Usage: {"throw_error":"Order is already shipped"}
    --        {"throw_error":["Order ${id} is already shipped", "99017",
    --                        ["id", {"var":"id"}]]}
    --
    -- The parameters are a FLAT list of name, value, name, value rather than an
    -- object, because JsonLogic reads a single-key object as an operator call:
    -- {"id": 3} would be dispatched as the operator `id` and die with
    -- "Unrecognized operation". The list arrives already evaluated by the
    -- depth-first pass above, so each value keeps the type its expression
    -- produced - which is the point: ICU selects plurals on the JSON type, and
    -- a number arriving as "3" would neither pluralize nor localize.
    IF op = 'throw_error' THEN
        err_code := CASE WHEN b IS NULL OR jsonb_typeof(b) = 'null'
                         THEN '99000' ELSE jl_to_text(b) END;
        IF err_code !~ '^99[0-9]{3}$' THEN
            RAISE EXCEPTION 'throw_error code must be a class 99 number, not ${code_given}'
                USING ERRCODE = '90911',
                      HINT = jsonb_build_object('code_given', err_code)::text;
        END IF;

        err_hint := '{}'::jsonb;
        IF c IS NOT NULL AND jsonb_typeof(c) = 'array' THEN
            IF jsonb_array_length(c) % 2 <> 0 THEN
                RAISE EXCEPTION 'throw_error parameters must be a flat list of name and value pairs'
                    USING ERRCODE = '90914';
            END IF;
            FOR i IN 0 .. jsonb_array_length(c) / 2 - 1 LOOP
                err_name  := c ->> (i * 2);
                err_value := c -> (i * 2 + 1);
                -- The generated validation trigger merges entity, rule and
                -- field into this object, and its merge keeps whatever is
                -- already there, so a rule that set one of them would win over
                -- the trigger that actually knows where the error happened.
                -- hint and code are the contract's other two reserved keys.
                IF err_name IN ('hint', 'code', 'entity', 'rule', 'field') THEN
                    RAISE EXCEPTION 'throw_error parameter ${name} uses a reserved name'
                        USING ERRCODE = '90912',
                              HINT = jsonb_build_object('name', err_name)::text;
                END IF;
                IF jsonb_typeof(err_value) IN ('object', 'array') THEN
                    RAISE EXCEPTION 'throw_error parameter ${name} must be a scalar value, not ${json_type}'
                        USING ERRCODE = '90913',
                              HINT = jsonb_build_object('name', err_name,
                                                        'json_type', jsonb_typeof(err_value))::text;
                END IF;
                err_hint := err_hint || jsonb_build_object(err_name, err_value);
            END LOOP;
        END IF;

        RAISE EXCEPTION '%', jl_to_text(a)
            USING ERRCODE = err_code, HINT = err_hint::text;
    END IF;

    -- ===================== is_raci_actor =====================
    -- Returns true when the current user holds a role with the given
    -- RACI letter for the process governing (entity, to_state).
    -- Usage: {"is_raci_actor": ["table_name", "state", "accountable"]}
    IF op = 'is_raci_actor' THEN
        IF is_raci_actor(jl_to_text(a), jl_to_text(b), jl_to_text(c)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== has_consultation =====================
    -- Returns true when an acted consulted raci_events row exists for
    -- the record under (entity, to_state). Backs C-block gates.
    -- Usage: {"has_consultation": ["table_name", "state", {"var":"id"}]}
    IF op = 'has_consultation' THEN
        IF has_consultation(jl_to_text(a), jl_to_text(b), jl_to_text(c)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== date operators =====================
    -- The work is in the jl_date_* helpers. Each operator keeps a comparison of
    -- its own here, because the operator table in sem-schema is checked against
    -- this function by searching for that exact form.
    IF op = 'date_add' THEN RETURN jl_date_add(a, b, c); END IF;
    IF op = 'date_diff' THEN RETURN jl_date_diff(a, b, c); END IF;
    IF op = 'date_part' THEN RETURN jl_date_part(a, b); END IF;
    IF op = 'date_trunc' THEN RETURN jl_date_trunc(a, b); END IF;
    IF op = 'to_date' THEN RETURN jl_to_date(a); END IF;
    IF op = 'date_format' THEN RETURN jl_date_format(a, b); END IF;

    -- Unknown operator
    RAISE EXCEPTION 'Unrecognized operation: ${op}'
        USING ERRCODE = '90910',
              HINT = jsonb_build_object('op', op)::text;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION jl_truthy(jsonb) IS
'JsonLogic truthiness of a JSONB value (JavaScript-style): false for null, false, 0, "" and empty arrays/objects; true otherwise.';
COMMENT ON FUNCTION jl_try_number(jsonb) IS
'Numeric value of a JSONB value under JsonLogic/JavaScript rules, or NULL where there is none - JavaScript''s NaN. Used by jl_loose_eq, which must not read a non-numeric string as 0.';
COMMENT ON FUNCTION jl_to_number(jsonb) IS
'Coerces a JSONB value to numeric using JsonLogic/JavaScript rules (used by arithmetic and comparison operators). Reads anything without a numeric value as 0.';
COMMENT ON FUNCTION jl_to_text(jsonb) IS
'Coerces a JSONB value to text using JsonLogic/JavaScript rules (used by string operators and loose comparisons).';
COMMENT ON FUNCTION jl_loose_eq(jsonb, jsonb) IS
'JsonLogic loose equality (==): compares two JSONB values with JavaScript-style type coercion.';
COMMENT ON FUNCTION jl_date_is_blank(jsonb) IS
'True when a JSONB value means no date: SQL NULL, JSON null or the empty string.';
COMMENT ON FUNCTION jl_date_is_date_only(jsonb) IS
'True when a JSONB value is a date with no time of day (YYYY-MM-DD).';
COMMENT ON FUNCTION jl_date_utc(text, jsonb) IS
'The UTC timestamp, in whole seconds, of an ISO 8601 date or date-time. Raises 90915 for anything else.';
COMMENT ON FUNCTION jl_date_render(timestamp, boolean) IS
'Renders a UTC timestamp as a JSON date, or as a date-time with an explicit +00:00 offset.';
COMMENT ON FUNCTION jl_date_bad_unit(text, jsonb) IS
'Raises 90916 for a date unit or part an operator cannot use on its value.';
COMMENT ON FUNCTION jl_date_unit(text, jsonb, boolean) IS
'Returns a date unit as text after checking it is known and usable on the value. Raises 90916 otherwise.';
COMMENT ON FUNCTION jl_date_add(jsonb, jsonb, jsonb) IS
'JsonLogic date_add: adds a whole amount of a unit, or an ISO 8601 duration, to a date in UTC.';
COMMENT ON FUNCTION jl_date_diff(jsonb, jsonb, jsonb) IS
'JsonLogic date_diff: whole elapsed units between two dates in UTC, truncated toward zero.';
COMMENT ON FUNCTION jl_date_part(jsonb, jsonb) IS
'JsonLogic date_part: one integer field of a date in UTC.';
COMMENT ON FUNCTION jl_date_trunc(jsonb, jsonb) IS
'JsonLogic date_trunc: the start of the period containing a date in UTC.';
COMMENT ON FUNCTION jl_to_date(jsonb) IS
'JsonLogic to_date: the UTC date of a date, date-time or epoch number.';
COMMENT ON FUNCTION jl_date_format(jsonb, jsonb) IS
'JsonLogic date_format: renders a date in UTC through a fixed token list. Raises 90917 for any other pattern.';
COMMENT ON FUNCTION evaluate_json_logic(jsonb, jsonb) IS
'Evaluates a JsonLogic rule against a data object and returns the JSONB result. Core engine for computed fields, validation rules and select rules.';

-- Revoke public execute on all jsonlogic functions
REVOKE EXECUTE ON FUNCTION jl_truthy(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_try_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_text(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_loose_eq(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_is_blank(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_is_date_only(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_utc(text, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_render(timestamp, boolean) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_bad_unit(text, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_unit(text, jsonb, boolean) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_add(jsonb, jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_diff(jsonb, jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_part(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_trunc(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_date(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_format(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION evaluate_json_logic(jsonb, jsonb) FROM public;

-- Grant execute to semantius_user for jsonlogic functions
-- Required for require_permission and value_changed operators which need an authenticated user context
GRANT EXECUTE ON FUNCTION jl_truthy(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_try_number(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_number(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_text(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_loose_eq(jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_is_blank(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_is_date_only(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_utc(text, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_render(timestamp, boolean) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_bad_unit(text, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_unit(text, jsonb, boolean) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_add(jsonb, jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_diff(jsonb, jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_part(jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_trunc(jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_date(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_format(jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION evaluate_json_logic(jsonb, jsonb) TO semantius_user;
