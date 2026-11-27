-- Helper: JsonLogic truthy semantics
-- false, null, 0, "" and empty arrays are falsy; everything else is truthy,
-- an empty object included
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
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- Helper: coerce jsonb value to numeric (for arithmetic / comparisons)
-- The numeric value of a jsonb, or SQL NULL where there is none. This is
-- JavaScript's NaN, and it exists because its callers need opposite things from
-- it: arithmetic wants a number whatever it was handed, while equality and
-- ordering must not invent one. jl_to_number below folds NULL to 0 for the
-- first; jl_loose_eq and the ordering operators answer false for the second,
-- which is what JavaScript does when it compares against NaN.
--
-- A string is a number when JavaScript's Number() reads it as one, and the
-- patterns are what keep it to that. The casts alone accept much more: NaN,
-- inf, infinity in any case, 1_000, and through the date parser today, now,
-- and whatever the session's DateStyle makes of 01/02/2026. None of those may
-- count, because the browser evaluates the same rule and a stored result must
-- not depend on the day a rule ran or on a session setting.
--
-- An ISO 8601 date or date-time is a number as well: its epoch seconds. This is
-- a Semantius extension (JavaScript gives NaN), and it reads the three shapes
-- jl_date_utc reads, the same way: a date is UTC midnight, a date-time without
-- an offset is UTC, and an offset moves the instant. A string of one of those
-- shapes that is no real date (2026-02-30) has no number. The date casts are
-- what make the function STABLE rather than IMMUTABLE.
--
-- The EXCEPTION block costs a subtransaction, so it encloses the date casts
-- alone, which only a date-shaped string reaches.
CREATE OR REPLACE FUNCTION jl_try_number(val jsonb) RETURNS numeric AS $$
DECLARE
    v_moment CONSTANT text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?';
    txt_val text;
BEGIN
    IF val IS NULL THEN RETURN NULL; END IF;

    CASE jsonb_typeof(val)
        WHEN 'number' THEN
            RETURN val::text::numeric;

        WHEN 'string' THEN
            txt_val := val #>> '{}';

            -- Number('') and Number('   ') are 0 in JavaScript, not NaN.
            IF txt_val ~ '^[[:space:]]*$' THEN
                RETURN 0::numeric;
            END IF;

            -- A decimal number with an optional sign, fraction and exponent;
            -- Infinity in exactly that spelling; a hexadecimal, octal or binary
            -- integer, which takes no sign.
            IF txt_val ~ ('^[[:space:]]*('
                          || '[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?'
                          || '|[+-]?Infinity'
                          || '|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+'
                          || ')[[:space:]]*$') THEN
                -- Number() has no range error: an exponent beyond what it
                -- holds is Infinity, with the sign of the number, and one
                -- below it is 0. numeric raises 22003 for both. Only a number
                -- written with an exponent can get there, so only that form
                -- pays for the subtransaction of the EXCEPTION block.
                IF txt_val ~ '[0-9.][eE]' THEN
                    BEGIN
                        RETURN txt_val::numeric;
                    EXCEPTION WHEN numeric_value_out_of_range THEN
                        IF txt_val ~ '[eE]-' OR txt_val !~ '[1-9].*[eE]' THEN
                            RETURN 0::numeric;
                        END IF;
                        RETURN CASE WHEN txt_val ~ '^[[:space:]]*-' THEN '-Infinity'::numeric
                                    ELSE 'Infinity'::numeric END;
                    END;
                END IF;
                RETURN txt_val::numeric;
            END IF;

            IF txt_val ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN
                BEGIN
                    IF txt_val ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
                        RETURN extract(epoch FROM txt_val::date::timestamp)::numeric;
                    END IF;
                    -- No offset means UTC, so the session's zone must not be applied to it.
                    IF txt_val ~ (v_moment || '$') THEN
                        RETURN extract(epoch FROM txt_val::timestamp)::numeric;
                    END IF;
                    IF txt_val ~ (v_moment || '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$') THEN
                        RETURN extract(epoch FROM (txt_val::timestamptz AT TIME ZONE 'UTC'))::numeric;
                    END IF;
                EXCEPTION WHEN data_exception THEN
                    RETURN NULL;
                END;
            END IF;

            RETURN NULL;

        WHEN 'boolean' THEN RETURN CASE WHEN val::text = 'true' THEN 1::numeric ELSE 0::numeric END;
        WHEN 'null' THEN RETURN NULL;
        ELSE RETURN NULL;
    END CASE;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION jl_to_number(val jsonb) RETURNS numeric AS $$
BEGIN
    RETURN COALESCE(jl_try_number(val), 0::numeric);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

-- What an arithmetic operator returns for the number it computed.
--
-- A result that is not a finite number is an error, as a division by zero is in
-- SQL. JSON has no Infinity and no NaN, so the alternative would be null, and
-- a rule that answered null would store "no value" where its author made a
-- mistake. The error is the evaluator's own rather than the bare 22012 or
-- 22003 of the arithmetic underneath, so a client can translate it.
--
-- A whole number is returned without a fraction (5, not 5.0). It stays a
-- numeric: narrowing it to bigint would raise for a value beyond that range,
-- and neither JSON nor JavaScript has such a limit.
CREATE OR REPLACE FUNCTION jl_no_finite_result(p_op text) RETURNS jsonb AS $$
BEGIN
    RAISE EXCEPTION '${operator} has no finite result'
        USING ERRCODE = '90920',
              HINT = jsonb_build_object('operator', p_op)::text;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- The number an arithmetic operator computes with. Null, the empty string
-- and a missing argument count as 0, as Number(null) and Number('') do: a
-- field left empty is no mistake. Text that carries no number is one.
-- JavaScript computes with NaN there and answers NaN, which is no finite
-- result, so the operator raises as it does for a division by zero; reading
-- the text as 0 would let a rule compute with a mistyped value as if nothing
-- were wrong. An array or an object counts as 0.
CREATE OR REPLACE FUNCTION jl_operand(p_op text, val jsonb) RETURNS numeric AS $$
DECLARE
    v_number numeric := jl_try_number(val);
BEGIN
    IF v_number IS NULL AND jsonb_typeof(val) = 'string' THEN
        PERFORM jl_no_finite_result(p_op);
    END IF;
    RETURN COALESCE(v_number, 0::numeric);
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION jl_number_result(p_op text, p_value numeric) RETURNS jsonb AS $$
BEGIN
    IF p_value IN ('Infinity'::numeric, '-Infinity'::numeric, 'NaN'::numeric) THEN
        RETURN jl_no_finite_result(p_op);
    END IF;
    IF p_value = trunc(p_value) THEN
        RETURN to_jsonb(trunc(p_value));
    END IF;
    RETURN to_jsonb(p_value);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- Helper: an array as the text JavaScript makes of it, Array.prototype.join:
-- the elements joined by commas, null as nothing, a nested array the same way.
CREATE OR REPLACE FUNCTION jl_array_text(a jsonb) RETURNS text AS $$
    SELECT COALESCE(string_agg(
               CASE jsonb_typeof(t.e)
                    WHEN 'null'   THEN ''
                    WHEN 'string' THEN t.e #>> '{}'
                    WHEN 'array'  THEN jl_array_text(t.e)
                    WHEN 'object' THEN '[object Object]'
                    ELSE t.e::text
               END, ',' ORDER BY t.ord), '')
      FROM jsonb_array_elements(a) WITH ORDINALITY AS t(e, ord);
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

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
    -- array vs number or string: JavaScript turns the array into text first,
    -- its elements joined by commas, and compares that. So [] is the empty
    -- string and equals 0, and [5] equals 5 and '5'.
    IF ta = 'array' AND tb IN ('number', 'string') THEN
        RETURN jl_loose_eq(to_jsonb(jl_array_text(a)), b);
    END IF;
    IF tb = 'array' AND ta IN ('number', 'string') THEN
        RETURN jl_loose_eq(a, to_jsonb(jl_array_text(b)));
    END IF;
    RETURN a = b;
END;
-- STABLE, not IMMUTABLE: it calls jl_to_number, whose date cast follows DateStyle.
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION jl_date_is_date_only(p_value jsonb) RETURNS boolean AS $$
BEGIN
    RETURN jsonb_typeof(p_value) = 'string'
       AND (p_value #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

-- The offset is written out rather than left to to_jsonb, which would render the
-- session's zone, and the seconds carry no fraction, as jl_date_utc promises.
CREATE OR REPLACE FUNCTION jl_date_render(p_moment timestamp, p_date_only boolean) RETURNS jsonb AS $$
BEGIN
    IF p_date_only THEN
        RETURN to_jsonb(p_moment::date);
    END IF;
    RETURN to_jsonb(to_char(p_moment, 'YYYY-MM-DD"T"HH24:MI:SS"+00:00"'));
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION jl_date_bad_unit(p_op text, p_unit jsonb) RETURNS void AS $$
BEGIN
    RAISE EXCEPTION '${operator} cannot use ${unit} on this value'
        USING ERRCODE = '90916',
              HINT = jsonb_build_object('operator', p_op, 'unit', p_unit)::text;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

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
    -- The name is added to data only when data is an object. Inside map,
    -- filter, all, none and some the data is the element, which can be a
    -- number, a text, a boolean, null or a list, and jsonb || appends an object
    -- to any of those as a list item that var cannot read by name: the body
    -- would read the name as null and the rule would return a plausible wrong
    -- value. Such data is replaced by an object that holds only the name, so
    -- {"var":""} in the body returns that object, and the element is read
    -- through a name bound to it: {"let":["x", {"var":""}, ...]}.
    IF op = 'let' THEN
        var_key := vals ->> 0;
        result := evaluate_json_logic(vals -> 1, data);
        RETURN evaluate_json_logic(vals -> 2,
            CASE WHEN jsonb_typeof(data) = 'object' THEN data ELSE '{}'::jsonb END
            || jsonb_build_object(var_key, result));
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
        RETURN evaluate_json_logic(vals -> 3,
            CASE WHEN jsonb_typeof(data) = 'object' THEN data ELSE '{}'::jsonb END
            || jsonb_build_object(var_key, COALESCE(nav, 'null'::jsonb)));
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
                -- Only digits are an index. PostgreSQL counts a negative one
                -- from the end; JavaScript reads a[-1] as a property that is
                -- not there, and so does this.
                IF sub_props[i] !~ '^[0-9]+$' THEN
                    IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
                END IF;
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
    -- An argument that was not given is JavaScript's undefined, which is
    -- strictly equal to nothing but another undefined.
    IF op = '===' THEN
        IF a IS NULL OR b IS NULL THEN RETURN to_jsonb(a IS NULL AND b IS NULL); END IF;
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
        IF a IS NULL OR b IS NULL THEN RETURN to_jsonb(NOT (a IS NULL AND b IS NULL)); END IF;
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
    -- pair is coerced to numbers, so "10" > "9" is false and "10" > 9 is true.
    -- A string that carries no number is NaN in JavaScript, and every
    -- comparison with NaN is false, so such a pair is false under all four
    -- operators: reading "abc" as 0 would make "abc" < 5 true. Null and the
    -- empty string are 0 there and here, as is everything that is no string.
    -- JavaScript orders strings by UTF-16 code unit, which
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
            num_a := CASE WHEN jsonb_typeof(a) = 'string' THEN jl_try_number(a) ELSE jl_to_number(a) END;
            num_b := CASE WHEN jsonb_typeof(b) = 'string' THEN jl_try_number(b) ELSE jl_to_number(b) END;
            IF num_a IS NULL OR num_b IS NULL THEN RETURN 'false'::jsonb; END IF;
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
            num_b := CASE WHEN jsonb_typeof(b) = 'string' THEN jl_try_number(b) ELSE jl_to_number(b) END;
            num_c := CASE WHEN jsonb_typeof(c) = 'string' THEN jl_try_number(c) ELSE jl_to_number(c) END;
            IF num_b IS NULL OR num_c IS NULL THEN RETURN 'false'::jsonb; END IF;
            cmp_bc := CASE WHEN num_b < num_c THEN -1
                           WHEN num_b > num_c THEN 1
                           ELSE 0 END;
        END IF;
        IF op = '<' THEN RETURN to_jsonb(cmp_ab < 0 AND cmp_bc < 0); END IF;
        RETURN to_jsonb(cmp_ab <= 0 AND cmp_bc <= 0);
    END IF;

    -- ===================== % =====================
    -- A zero divisor is an error of the evaluator's own (jl_number_result).
    IF op = '%' THEN
        num_b := jl_operand(op, b);
        IF num_b = 0 THEN RETURN jl_no_finite_result(op); END IF;
        RETURN jl_number_result(op, jl_operand(op, a) % num_b);
    END IF;

    -- ===================== + =====================
    IF op = '+' THEN
        num_a := 0;
        FOR i IN 0 .. arr_len - 1 LOOP
            num_a := num_a + jl_operand(op, vals -> i);
        END LOOP;
        RETURN jl_number_result(op, num_a);
    END IF;

    -- ===================== * =====================
    IF op = '*' THEN
        num_a := jl_operand(op, vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_a := num_a * jl_operand(op, vals -> i);
        END LOOP;
        RETURN jl_number_result(op, num_a);
    END IF;

    -- ===================== - =====================
    IF op = '-' THEN
        IF arr_len = 1 THEN
            num_a := -jl_operand(op, a);
        ELSE
            num_a := jl_operand(op, a) - jl_operand(op, b);
        END IF;
        RETURN jl_number_result(op, num_a);
    END IF;

    -- ===================== / =====================
    IF op = '/' THEN
        num_a := jl_operand(op, a);
        num_b := jl_operand(op, b);
        IF num_b = 0 THEN RETURN jl_no_finite_result(op); END IF;
        RETURN jl_number_result(op, num_a / num_b);
    END IF;

    -- ===================== max =====================
    IF op = 'max' THEN
        num_a := jl_operand(op, vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_operand(op, vals -> i);
            IF num_b > num_a THEN num_a := num_b; END IF;
        END LOOP;
        RETURN jl_number_result(op, num_a);
    END IF;

    -- ===================== min =====================
    IF op = 'min' THEN
        num_a := jl_operand(op, vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_operand(op, vals -> i);
            IF num_b < num_a THEN num_a := num_b; END IF;
        END LOOP;
        RETURN jl_number_result(op, num_a);
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
            -- Substring check. JavaScript searches for the needle as text, and
            -- null as text is 'null'. jl_to_text reads null as the empty text,
            -- which every string contains, so a null or missing needle would be
            -- found everywhere.
            txt_a := CASE WHEN jsonb_typeof(a) = 'null' THEN 'null' ELSE jl_to_text(a) END;
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
                -- A length that reaches back past the start leaves nothing.
                temp_str := substring(src FROM start_pos + 1);
                RETURN to_jsonb(substring(temp_str FROM 1 FOR GREATEST(length(temp_str) + end_len, 0)));
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
                IF err_name = ANY(jl_reserved_error_parameters()) THEN
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
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

-- =====================================================
-- Checking a rule without running it
-- =====================================================
-- evaluate_json_logic learns that a rule names an operator it does not
-- implement only when a record reaches that node, which for a branch of an
-- `if` can be long after the rule was saved, on a write that has nothing to do
-- with the mistake. The functions below answer the same question from the
-- rule alone, so the dictionary can refuse the rule when it is saved.
--
-- The list is the set of operators evaluate_json_logic dispatches on, written
-- a second time, because that dispatch is a run of IF statements and cannot be
-- asked what it knows. 0110_test_jsonlogic_ext.sql compares the two, so an
-- operator added to one and not to the other fails the suite.
CREATE OR REPLACE FUNCTION jl_operators() RETURNS text[] AS $$
    SELECT ARRAY[
        'if', '?:', 'and', 'or', 'filter', 'map', 'reduce', 'all', 'none', 'some',
        'let', 'set_record',
        'var', 'missing', 'missing_some',
        '==', '===', '!=', '!==', '!', '!!',
        '>', '>=', '<', '<=',
        '%', '+', '*', '-', '/', 'max', 'min',
        'in', 'cat', 'substr', 'merge', 'log',
        'has_permission', 'require_permission', 'value_changed', 'concat', 'is_match',
        'throw_error', 'is_raci_actor', 'has_consultation',
        'date_add', 'date_diff', 'date_part', 'date_trunc', 'to_date', 'date_format'
    ];
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- An object with exactly one key is an operation; everything else is a value.
-- The same test evaluate_json_logic makes before it dispatches.
CREATE OR REPLACE FUNCTION jl_is_operation(p_rule jsonb) RETURNS boolean AS $$
DECLARE
    v_op text;
BEGIN
    IF p_rule IS NULL OR jsonb_typeof(p_rule) <> 'object' THEN
        RETURN FALSE;
    END IF;
    v_op := jsonb_path_query_first(p_rule, '$.keyvalue().key') #>> '{}';
    RETURN v_op IS NOT NULL AND p_rule - v_op = '{}'::jsonb;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- Walks a rule the way evaluate_json_logic reads it: an array is a list of
-- rules, an object with one key is an operation whose arguments are rules, and
-- anything else - a scalar, an empty object, an object with several keys - is
-- a value and is not looked into, because the evaluator returns it as it
-- stands. Two argument positions hold a name, not a rule, and are skipped: the
-- variable name of `let`, and the variable name and the entity of
-- `set_record`. A name that happens to look like an operation would otherwise
-- be refused although it is never evaluated.
CREATE OR REPLACE FUNCTION jl_unknown_operator(p_rule jsonb) RETURNS text AS $$
DECLARE
    v_op    text;
    v_args  jsonb;
    v_found text;
BEGIN
    IF p_rule IS NULL THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_rule) = 'array' THEN
        FOR i IN 0 .. jsonb_array_length(p_rule) - 1 LOOP
            v_found := jl_unknown_operator(p_rule -> i);
            IF v_found IS NOT NULL THEN
                RETURN v_found;
            END IF;
        END LOOP;
        RETURN NULL;
    END IF;

    IF NOT jl_is_operation(p_rule) THEN
        RETURN NULL;
    END IF;

    v_op := jsonb_path_query_first(p_rule, '$.keyvalue().key') #>> '{}';
    IF NOT (v_op = ANY(jl_operators())) THEN
        RETURN v_op;
    END IF;

    v_args := p_rule -> v_op;
    IF jsonb_typeof(v_args) <> 'array' THEN
        v_args := jsonb_build_array(v_args);
    END IF;

    FOR i IN (CASE v_op WHEN 'let' THEN 1 WHEN 'set_record' THEN 2 ELSE 0 END)
             .. jsonb_array_length(v_args) - 1 LOOP
        v_found := jl_unknown_operator(v_args -> i);
        IF v_found IS NOT NULL THEN
            RETURN v_found;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- =====================================================
-- The rest of what a rule gets wrong without an error
-- =====================================================
-- An unknown operator is one mistake the evaluator meets only when a record
-- reaches it. These are the others, and the evaluator does not even raise on
-- them; it answers, and the answer is wrong:
--   * an object with several keys, which it reads as a value, and a value is
--     truthy;
--   * an operator given a number of arguments it does not take, whose extra
--     arguments it ignores and whose missing ones it reads as null;
--   * a literal argument of the wrong kind: a misspelled date unit, a RACI
--     letter no role holds, a throw_error code outside class 99;
--   * a variable with no value where it is read: a $ name the rules are not
--     given, or a name read inside the logic of map, filter, reduce, all, none
--     or some that only exists outside it.
-- jl_rule_problem finds them from the rule alone, so the dictionary can refuse
-- the rule when it is saved. It refuses exactly what the checker of the
-- Semantius app refuses (sem-schema's jsonlogic/validate.ts): a rule that one
-- of the two accepts must not be refused by the other.
-- 0115_test_jsonlogic_check.json holds the cases both of them run.

-- The arguments each operator takes, as [min, max], max null when there is no
-- upper bound. >= has no three-argument "between" form as < and <= do, so
-- {">=": [x, lo, hi]} silently drops hi. The keys are exactly jl_operators(),
-- which 0110_test_jsonlogic_ext.sql checks.
CREATE OR REPLACE FUNCTION jl_operator_arity() RETURNS jsonb AS $$
    SELECT '{
        "if": [1, null], "?:": [1, null], "and": [1, null], "or": [1, null],
        "filter": [2, 2], "map": [2, 2], "reduce": [2, 3], "all": [2, 2], "none": [2, 2], "some": [2, 2],
        "let": [3, 3], "set_record": [4, 4],
        "var": [0, 2], "missing": [0, null], "missing_some": [2, 2],
        "==": [2, 2], "===": [2, 2], "!=": [2, 2], "!==": [2, 2], "!": [1, 1], "!!": [1, 1],
        ">": [2, 2], ">=": [2, 2], "<": [2, 3], "<=": [2, 3],
        "%": [2, 2], "+": [1, null], "*": [1, null], "-": [1, 2], "/": [2, 2], "max": [1, null], "min": [1, null],
        "in": [2, 2], "cat": [0, null], "substr": [2, 3], "merge": [0, null], "log": [1, 1],
        "has_permission": [1, 1], "require_permission": [1, 1], "value_changed": [1, 1],
        "concat": [0, null], "is_match": [2, 2],
        "throw_error": [1, 3], "is_raci_actor": [3, 3], "has_consultation": [3, 3],
        "date_add": [2, 3], "date_diff": [3, 3], "date_part": [2, 2], "date_trunc": [2, 2],
        "to_date": [1, 1], "date_format": [2, 2]
    }'::jsonb;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- The $ names build_record_logic_trigger gives the rules of an entity. Any
-- other $ name reads null.
CREATE OR REPLACE FUNCTION jl_reserved_variables() RETURNS text[] AS $$
    SELECT ARRAY['$today', '$now', '$user_id', '$role_ids', '$old', '$mode'];
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- The parameter names throw_error refuses (90912). The generated validation
-- trigger merges entity, rule and field into the hint, and its merge keeps a
-- key that is already there, so a parameter of one of those names would win
-- over the trigger that knows where the error happened. hint and code are the
-- contract's other two reserved keys.
CREATE OR REPLACE FUNCTION jl_reserved_error_parameters() RETURNS text[] AS $$
    SELECT ARRAY['hint', 'code', 'entity', 'rule', 'field'];
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- The letters is_raci_actor compares with raci_assignments.raci. A letter no
-- assignment can hold makes the operator false for everyone, without an
-- error. 0110_test_jsonlogic_ext.sql compares the list with that field's enum.
CREATE OR REPLACE FUNCTION jl_raci_letters() RETURNS text[] AS $$
    SELECT ARRAY['responsible', 'accountable', 'consulted', 'informed'];
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- One more segment of a JSON pointer (RFC 6901), the form in which the app's
-- checker names a place in a rule: ~ is written ~0 and / is written ~1, so the
-- operator / is the segment ~1.
CREATE OR REPLACE FUNCTION jl_pointer(p_path text, p_segment text) RETURNS text AS $$
    SELECT p_path || '/' || replace(replace(p_segment, '~', '~0'), '/', '~1');
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- The place of an operation's argument. An argument that is not an array is
-- the only one, {"var": "a"} standing for {"var": ["a"]}, so it has no index of
-- its own and its place is the operation's.
CREATE OR REPLACE FUNCTION jl_argument_path(p_operation_path text, p_raw jsonb, p_index int) RETURNS text AS $$
    SELECT CASE WHEN jsonb_typeof(p_raw) = 'array'
                THEN jl_pointer(p_operation_path, p_index::text)
                ELSE p_operation_path END;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

-- An argument that is there and is no operation. Only such an argument can be
-- checked: what an operation yields is known when it runs.
CREATE OR REPLACE FUNCTION jl_is_literal(p_value jsonb) RETURNS boolean AS $$
BEGIN
    RETURN p_value IS NOT NULL AND NOT jl_is_operation(p_value);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

-- Whether a literal is a unit, a part, a pattern or a duration the date
-- operators take. The operators' own checks answer, so each list exists once:
-- the operator runs over a fixed date-time, on which every unit, part and
-- token can be used, and only the error that names a bad unit, pattern or
-- amount says no. Any other error, such as a duration too long for an
-- interval, is no more visible to the app's checker than to this one, and is
-- left to the evaluator.
CREATE OR REPLACE FUNCTION jl_date_literal_ok(p_kind text, p_value jsonb) RETURNS boolean AS $$
DECLARE
    v_moment CONSTANT jsonb := '"2000-01-01T00:00:00"';
BEGIN
    CASE p_kind
        WHEN 'unit'    THEN PERFORM jl_date_unit('date_trunc', p_value, false);
        WHEN 'part'    THEN PERFORM jl_date_part(v_moment, p_value);
        WHEN 'pattern' THEN PERFORM jl_date_format(v_moment, p_value);
        ELSE                PERFORM jl_date_add(v_moment, p_value, NULL);
    END CASE;
    RETURN TRUE;
EXCEPTION
    WHEN SQLSTATE '90916' OR SQLSTATE '90917' OR SQLSTATE '90918' THEN
        RETURN FALSE;
    WHEN OTHERS THEN
        RETURN TRUE;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

-- The first mistake in a rule, as an object of its code, its path and its
-- parameters, or NULL when there is none. The path is the JSON pointer to the
-- mistake inside the rule, '' for the rule itself.
--   90909  an operator the evaluator does not implement: op
--   90921  an argument count outside jl_operator_arity: op, count, min, max
--   90922  a literal argument of the wrong kind: op, expected
--   90923  an object with several keys: key_count
--   90924  a variable with no value where it is read: variable, reason, op
--
-- The walk is the evaluator's: an array is a list of rules, an object with
-- one key an operation, anything else a value. The count comes first, then
-- the literal arguments, then the arguments themselves, the order the app's
-- checker reports them in. The names of let and set_record are checked
-- whatever they hold and never walked, because they are never evaluated.
--
-- The last three parameters are the scope var reads in. A let binds its name
-- in its body (argument 2), a set_record in argument 3. The logic of map,
-- filter, reduce, all, none and some (argument 1) is evaluated against each
-- element, {current, accumulator} for reduce, so there the record and its $
-- variables are gone, and so is every name bound outside: p_array_op names the
-- operator and p_outside those names. Any other name there is a key of the
-- element. Their first argument, and the initial value of reduce, are
-- evaluated against the data outside.
CREATE OR REPLACE FUNCTION jl_rule_problem(
    p_rule jsonb,
    p_path text DEFAULT '',
    p_bound text[] DEFAULT '{}',
    p_outside text[] DEFAULT '{}',
    p_array_op text DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
    v_op         text;
    v_raw        jsonb;
    v_args       jsonb;
    v_n          int;
    v_op_path    text;
    v_arity      jsonb;
    v_arg        jsonb;
    v_at         int;
    v_at_path    text;
    v_expected   text;
    v_params     jsonb;
    v_root       text;
    v_reason     text;
    v_bound      text[];
    v_outside    text[];
    v_array_op   text;
    v_found      jsonb;
BEGIN
    IF p_rule IS NULL THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_rule) = 'array' THEN
        FOR i IN 0 .. jsonb_array_length(p_rule) - 1 LOOP
            v_found := jl_rule_problem(p_rule -> i, jl_pointer(p_path, i::text), p_bound, p_outside, p_array_op);
            IF v_found IS NOT NULL THEN
                RETURN v_found;
            END IF;
        END LOOP;
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_rule) <> 'object' OR p_rule = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    -- What is inside such an object is never evaluated, so it is not looked at.
    IF NOT jl_is_operation(p_rule) THEN
        RETURN jsonb_build_object('code', '90923', 'path', p_path,
            'key_count', (SELECT count(*)::int FROM jsonb_object_keys(p_rule)));
    END IF;

    v_op := jsonb_path_query_first(p_rule, '$.keyvalue().key') #>> '{}';
    IF NOT (v_op = ANY(jl_operators())) THEN
        RETURN jsonb_build_object('code', '90909', 'path', p_path, 'op', v_op);
    END IF;

    v_raw := p_rule -> v_op;
    v_args := CASE WHEN jsonb_typeof(v_raw) = 'array' THEN v_raw ELSE jsonb_build_array(v_raw) END;
    v_n := jsonb_array_length(v_args);
    v_op_path := jl_pointer(p_path, v_op);

    v_arity := jl_operator_arity() -> v_op;
    IF v_n < (v_arity ->> 0)::int OR v_n > COALESCE((v_arity ->> 1)::int, v_n) THEN
        RETURN jsonb_build_object('code', '90921', 'path', v_op_path, 'op', v_op, 'count', v_n,
            'min', v_arity -> 0, 'max', v_arity -> 1);
    END IF;

    -- A literal argument of the wrong kind: v_at is its position and
    -- v_expected names what it has to be. Each CASE below reads a value only
    -- once its type is known, because the operands of OR and AND may be
    -- evaluated in any order. A CASE in an IF condition is in parentheses:
    -- PL/pgSQL ends the condition at the first THEN outside them.
    IF v_op = 'var' THEN
        v_arg := v_args -> 0;
        IF jl_is_literal(v_arg) AND jsonb_typeof(v_arg) NOT IN ('string', 'number', 'null') THEN
            v_at := 0; v_expected := 'var_path';
        END IF;
    ELSIF v_op = 'missing_some' THEN
        IF jl_is_literal(v_args -> 0) AND jsonb_typeof(v_args -> 0) <> 'number' THEN
            v_at := 0; v_expected := 'number';
        ELSIF jl_is_literal(v_args -> 1) AND jsonb_typeof(v_args -> 1) <> 'array' THEN
            v_at := 1; v_expected := 'array';
        END IF;
    ELSIF v_op IN ('let', 'set_record') THEN
        FOR i IN 0 .. (CASE v_op WHEN 'let' THEN 0 ELSE 1 END) LOOP
            IF jsonb_typeof(v_args -> i) <> 'string' OR v_args -> i = '""'::jsonb THEN
                v_at := i; v_expected := 'name';
                EXIT;
            END IF;
        END LOOP;
    ELSIF v_op IN ('has_permission', 'require_permission', 'value_changed') THEN
        v_arg := v_args -> 0;
        IF jl_is_literal(v_arg) AND (jsonb_typeof(v_arg) <> 'string' OR v_arg = '""'::jsonb) THEN
            v_at := 0;
            v_expected := CASE v_op WHEN 'value_changed' THEN 'field' ELSE 'permission' END;
        END IF;
    ELSIF v_op = 'is_match' THEN
        IF jl_is_literal(v_args -> 1) AND jsonb_typeof(v_args -> 1) <> 'string' THEN
            v_at := 1; v_expected := 'string';
        END IF;
    ELSIF v_op IN ('is_raci_actor', 'has_consultation') THEN
        IF jl_is_literal(v_args -> 0) AND (jsonb_typeof(v_args -> 0) <> 'string' OR v_args -> 0 = '""'::jsonb) THEN
            v_at := 0; v_expected := 'entity';
        ELSIF jl_is_literal(v_args -> 1) AND jsonb_typeof(v_args -> 1) <> 'string' THEN
            v_at := 1; v_expected := 'string';
        ELSIF v_op = 'is_raci_actor' AND jl_is_literal(v_args -> 2)
              AND NOT (CASE WHEN jsonb_typeof(v_args -> 2) = 'string'
                            THEN (v_args ->> 2) = ANY(jl_raci_letters()) ELSE FALSE END) THEN
            v_at := 2; v_expected := 'raci_letter';
        END IF;
    ELSIF v_op = 'throw_error' THEN
        v_arg := v_args -> 1;
        IF jl_is_literal(v_arg) AND NOT (CASE jsonb_typeof(v_arg)
                WHEN 'null'   THEN TRUE
                WHEN 'string' THEN (v_arg #>> '{}') ~ '^99[0-9]{3}$'
                WHEN 'number' THEN (v_arg #>> '{}')::numeric BETWEEN 99000 AND 99999
                                   AND (v_arg #>> '{}')::numeric = trunc((v_arg #>> '{}')::numeric)
                ELSE FALSE END) THEN
            v_at := 1; v_expected := 'error_code';
        ELSIF jl_is_literal(v_args -> 2) THEN
            -- The checks throw_error makes when it raises: 90914, 90912, 90913.
            v_params := v_args -> 2;
            IF jsonb_typeof(v_params) <> 'array' THEN
                v_at := 2; v_expected := 'error_parameters';
            ELSIF jsonb_array_length(v_params) % 2 <> 0 THEN
                v_at := 2; v_expected := 'parameter_pairs';
            ELSE
                FOR i IN 0 .. jsonb_array_length(v_params) - 1 BY 2 LOOP
                    v_arg := v_params -> i;
                    IF (CASE WHEN jsonb_typeof(v_arg) = 'string'
                             THEN (v_arg #>> '{}') = ANY(jl_reserved_error_parameters())
                             ELSE NOT jl_is_operation(v_arg) END) THEN
                        v_at_path := jl_pointer(jl_argument_path(v_op_path, v_raw, 2), i::text);
                        v_expected := 'parameter_name';
                        EXIT;
                    END IF;
                    IF jsonb_typeof(v_params -> (i + 1)) = 'array' THEN
                        v_at_path := jl_pointer(jl_argument_path(v_op_path, v_raw, 2), (i + 1)::text);
                        v_expected := 'parameter_value';
                        EXIT;
                    END IF;
                END LOOP;
            END IF;
        END IF;
    ELSIF v_op = 'date_add' THEN
        -- Two arguments are a date and a duration, three a date, an amount and a unit.
        IF v_n = 2 THEN
            IF jl_is_literal(v_args -> 1) AND NOT jl_date_literal_ok('duration', v_args -> 1) THEN
                v_at := 1; v_expected := 'duration';
            END IF;
        ELSIF jl_is_literal(v_args -> 2) AND NOT jl_date_literal_ok('unit', v_args -> 2) THEN
            v_at := 2; v_expected := 'date_unit';
        END IF;
    ELSIF v_op IN ('date_diff', 'date_trunc') THEN
        v_at := CASE v_op WHEN 'date_diff' THEN 2 ELSE 1 END;
        IF jl_is_literal(v_args -> v_at) AND NOT jl_date_literal_ok('unit', v_args -> v_at) THEN
            v_expected := 'date_unit';
        END IF;
    ELSIF v_op = 'date_part' THEN
        IF jl_is_literal(v_args -> 1) AND NOT jl_date_literal_ok('part', v_args -> 1) THEN
            v_at := 1; v_expected := 'date_part';
        END IF;
    ELSIF v_op = 'date_format' THEN
        IF jl_is_literal(v_args -> 1) AND NOT jl_date_literal_ok('pattern', v_args -> 1) THEN
            v_at := 1; v_expected := 'date_pattern';
        END IF;
    END IF;

    IF v_expected IS NOT NULL THEN
        RETURN jsonb_build_object('code', '90922',
            'path', COALESCE(v_at_path, jl_argument_path(v_op_path, v_raw, v_at)),
            'op', v_op, 'expected', v_expected);
    END IF;

    -- Only the name before the first dot says where var reads from.
    IF v_op = 'var' AND jsonb_typeof(v_args -> 0) = 'string' AND v_args -> 0 <> '""'::jsonb THEN
        v_root := split_part(v_args ->> 0, '.', 1);
        IF NOT (v_root = ANY(p_bound)) THEN
            IF p_array_op IS NOT NULL THEN
                IF starts_with(v_root, '$') THEN
                    v_reason := 'array_element';
                ELSIF v_root = ANY(p_outside) THEN
                    v_reason := 'bound_outside';
                END IF;
            ELSIF starts_with(v_root, '$') AND NOT (v_root = ANY(jl_reserved_variables())) THEN
                v_reason := 'unknown';
            END IF;
        END IF;
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('code', '90924', 'path', jl_argument_path(v_op_path, v_raw, 0),
                'variable', v_root, 'reason', v_reason, 'op', COALESCE(p_array_op, ''));
        END IF;
    END IF;

    FOR i IN 0 .. v_n - 1 LOOP
        CONTINUE WHEN (v_op = 'let' AND i = 0) OR (v_op = 'set_record' AND i <= 1);
        v_bound := p_bound;
        v_outside := p_outside;
        v_array_op := p_array_op;
        IF (v_op = 'let' AND i = 2) OR (v_op = 'set_record' AND i = 3) THEN
            IF jsonb_typeof(v_args -> 0) = 'string' THEN
                v_bound := p_bound || (v_args ->> 0);
            END IF;
        ELSIF i = 1 AND v_op IN ('map', 'filter', 'reduce', 'all', 'none', 'some') THEN
            v_outside := p_outside || p_bound;
            v_bound := '{}';
            v_array_op := v_op;
        END IF;
        v_found := jl_rule_problem(v_args -> i, jl_argument_path(v_op_path, v_raw, i), v_bound, v_outside, v_array_op);
        IF v_found IS NOT NULL THEN
            RETURN v_found;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

-- The keys a rule reads from the data it is evaluated on: the key of every
-- var, missing and missing_some, and the field of every value_changed, which
-- reads the same field of $old as well. A key that is not written out comes
-- back as NULL: one that is computed, and the empty key, which stands for the
-- whole data. Such a rule can read anything, and its caller has to assume so.
--
-- The walk follows the evaluator, as jl_unknown_operator does, with two more
-- things it has to know. A name bound by `let` or `set_record` is no key of
-- the data inside the body that binds it, so a path that starts with one is
-- left out. And the second argument of filter, map, all, none and some, and
-- of reduce, is evaluated on an element of the list, not on the data: a key
-- read there is a key of the element.
CREATE OR REPLACE FUNCTION jl_row_keys(p_rule jsonb, p_bound text[] DEFAULT '{}') RETURNS SETOF text AS $$
DECLARE
    v_op   text;
    v_args jsonb;
    v_keys jsonb;
    v_key  jsonb;
    v_text text;
BEGIN
    IF p_rule IS NULL THEN
        RETURN;
    END IF;

    IF jsonb_typeof(p_rule) = 'array' THEN
        FOR i IN 0 .. jsonb_array_length(p_rule) - 1 LOOP
            RETURN QUERY SELECT jl_row_keys(p_rule -> i, p_bound);
        END LOOP;
        RETURN;
    END IF;

    IF NOT jl_is_operation(p_rule) THEN
        RETURN;
    END IF;

    v_op := jsonb_path_query_first(p_rule, '$.keyvalue().key') #>> '{}';
    v_args := p_rule -> v_op;
    IF jsonb_typeof(v_args) <> 'array' THEN
        v_args := jsonb_build_array(v_args);
    END IF;

    IF v_op IN ('var', 'missing', 'missing_some', 'value_changed') THEN
        -- The keys of the operation, as a list: the one of var and of
        -- value_changed, every argument of missing or the one list it is
        -- given, and the list that is the second argument of missing_some.
        v_keys := CASE
            WHEN v_op IN ('var', 'value_changed') THEN jsonb_build_array(COALESCE(v_args -> 0, 'null'::jsonb))
            WHEN v_op = 'missing_some' THEN
                CASE WHEN jsonb_typeof(v_args -> 1) = 'array' THEN v_args -> 1
                     ELSE jsonb_build_array(COALESCE(v_args -> 1, 'null'::jsonb)) END
            WHEN jsonb_array_length(v_args) = 1 AND jsonb_typeof(v_args -> 0) = 'array' THEN v_args -> 0
            ELSE v_args
        END;

        FOR i IN 0 .. jsonb_array_length(v_keys) - 1 LOOP
            v_key := v_keys -> i;
            IF jsonb_typeof(v_key) IN ('string', 'number') AND v_key #>> '{}' <> '' THEN
                v_text := v_key #>> '{}';
                IF NOT (split_part(v_text, '.', 1) = ANY(p_bound)) THEN
                    RETURN NEXT v_text;
                END IF;
            ELSE
                RETURN NEXT NULL;
                RETURN QUERY SELECT jl_row_keys(v_key, p_bound);
            END IF;
        END LOOP;

        IF v_op = 'value_changed' THEN
            RETURN NEXT '$old';
        ELSIF v_op = 'var' THEN
            -- The default of a var is a rule.
            RETURN QUERY SELECT jl_row_keys(v_args -> 1, p_bound);
        ELSIF v_op = 'missing_some' THEN
            RETURN QUERY SELECT jl_row_keys(v_args -> 0, p_bound);
        END IF;
        RETURN;
    END IF;

    IF v_op = 'let' THEN
        RETURN QUERY SELECT jl_row_keys(v_args -> 1, p_bound);
        RETURN QUERY SELECT jl_row_keys(v_args -> 2, p_bound || (v_args ->> 0));
        RETURN;
    END IF;

    IF v_op = 'set_record' THEN
        RETURN QUERY SELECT jl_row_keys(v_args -> 2, p_bound);
        RETURN QUERY SELECT jl_row_keys(v_args -> 3, p_bound || (v_args ->> 0));
        RETURN;
    END IF;

    IF v_op IN ('filter', 'map', 'all', 'none', 'some', 'reduce') THEN
        RETURN QUERY SELECT jl_row_keys(v_args -> 0, p_bound);
        IF v_op = 'reduce' THEN
            RETURN QUERY SELECT jl_row_keys(v_args -> 2, p_bound);
        END IF;
        RETURN;
    END IF;

    FOR i IN 0 .. jsonb_array_length(v_args) - 1 LOOP
        RETURN QUERY SELECT jl_row_keys(v_args -> i, p_bound);
    END LOOP;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION jl_row_keys(jsonb, text[]) IS
'The keys a JsonLogic rule reads from its data: those of var, missing, missing_some and value_changed, wherever the evaluator would evaluate them on the data itself. NULL for a key that is computed or empty, which can read anything; $old for a value_changed. p_bound holds the names bound by an enclosing let or set_record.';

COMMENT ON FUNCTION jl_truthy(jsonb) IS
'JsonLogic truthiness of a JSONB value: false for null, false, 0, "" and an empty array; true otherwise, an empty object included.';
COMMENT ON FUNCTION jl_try_number(jsonb) IS
'Numeric value of a JSONB value under JsonLogic/JavaScript rules, or NULL where there is none - JavaScript''s NaN. A string counts when JavaScript''s Number() reads it, or when it is an ISO 8601 date or date-time, whose number is its epoch seconds in UTC. Used by jl_loose_eq and the ordering operators, which must not read a non-numeric string as 0.';
COMMENT ON FUNCTION jl_to_number(jsonb) IS
'Coerces a JSONB value to numeric using JsonLogic/JavaScript rules (used by the arithmetic operators). Reads anything without a numeric value as 0.';
COMMENT ON FUNCTION jl_operand(text, jsonb) IS
'The number an arithmetic operator computes with: jl_try_number of the value, 0 for null, the empty string, an array and an object, and error 90920 for text that carries no number.';
COMMENT ON FUNCTION jl_array_text(jsonb) IS
'A JSON array as the text JavaScript makes of it: its elements joined by commas, null as nothing. Used by jl_loose_eq to compare an array with a number or a string.';
COMMENT ON FUNCTION jl_no_finite_result(text) IS
'Raises 90920 for an arithmetic operator whose result is not a finite number: a zero divisor, or a result of Infinity or NaN.';
COMMENT ON FUNCTION jl_number_result(text, numeric) IS
'The JSON number an arithmetic operator returns: a whole number without a fraction, whatever its size. Raises 90920 for Infinity and NaN.';
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
COMMENT ON FUNCTION jl_operators() IS
'The operators evaluate_json_logic implements, as a list a rule can be checked against without being run.';
COMMENT ON FUNCTION jl_is_operation(jsonb) IS
'True when a JSONB value is a JsonLogic operation: an object with exactly one key. Everything else is a value to the evaluator.';
COMMENT ON FUNCTION jl_unknown_operator(jsonb) IS
'The first operator in a JsonLogic rule that evaluate_json_logic does not implement, or NULL when it knows them all. Walks every argument the evaluator would evaluate, and none it would not.';
COMMENT ON FUNCTION jl_operator_arity() IS
'The number of arguments each JsonLogic operator takes, as {"op": [min, max]}, max null when there is no upper bound.';
COMMENT ON FUNCTION jl_reserved_variables() IS
'The $ variables the rules of an entity are given: $today, $now, $user_id, $role_ids, $old and $mode.';
COMMENT ON FUNCTION jl_reserved_error_parameters() IS
'The parameter names throw_error refuses (90912), because the error hint reserves them.';
COMMENT ON FUNCTION jl_raci_letters() IS
'The RACI letters is_raci_actor accepts, the values of raci_assignments.raci.';
COMMENT ON FUNCTION jl_pointer(text, text) IS
'Appends one segment to a JSON pointer (RFC 6901), escaping ~ as ~0 and / as ~1.';
COMMENT ON FUNCTION jl_argument_path(text, jsonb, int) IS
'The JSON pointer of argument p_index of the operation at p_operation_path: the operation''s own pointer when its argument is not an array.';
COMMENT ON FUNCTION jl_is_literal(jsonb) IS
'True when a JSONB value is present and is no JsonLogic operation, so its value is known before the rule runs.';
COMMENT ON FUNCTION jl_date_literal_ok(text, jsonb) IS
'Whether a literal is a unit, part, pattern or duration (p_kind) the date operators accept, answered by the operators'' own checks.';
COMMENT ON FUNCTION jl_rule_problem(jsonb, text, text[], text[], text) IS
'The first mistake in a JsonLogic rule that the evaluator would not report, as {"code", "path", ...parameters}, or NULL: an unknown operator (90909), an argument count (90921), a literal argument (90922), an object with several keys (90923), a variable with no value (90924). Call it with the rule alone; the other parameters carry the walk.';
COMMENT ON FUNCTION evaluate_json_logic(jsonb, jsonb) IS
'Evaluates a JsonLogic rule against a data object and returns the JSONB result. Core engine for computed fields, validation rules and select rules.';

-- Revoke public execute on all jsonlogic functions
REVOKE EXECUTE ON FUNCTION jl_truthy(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_try_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_no_finite_result(text) FROM public;
REVOKE EXECUTE ON FUNCTION jl_operand(text, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_array_text(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_number_result(text, numeric) FROM public;
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
REVOKE EXECUTE ON FUNCTION jl_operators() FROM public;
REVOKE EXECUTE ON FUNCTION jl_is_operation(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_unknown_operator(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_row_keys(jsonb, text[]) FROM public;
REVOKE EXECUTE ON FUNCTION jl_operator_arity() FROM public;
REVOKE EXECUTE ON FUNCTION jl_reserved_variables() FROM public;
REVOKE EXECUTE ON FUNCTION jl_reserved_error_parameters() FROM public;
REVOKE EXECUTE ON FUNCTION jl_raci_letters() FROM public;
REVOKE EXECUTE ON FUNCTION jl_pointer(text, text) FROM public;
REVOKE EXECUTE ON FUNCTION jl_argument_path(text, jsonb, int) FROM public;
REVOKE EXECUTE ON FUNCTION jl_is_literal(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_date_literal_ok(text, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_rule_problem(jsonb, text, text[], text[], text) FROM public;

-- Grant execute to semantius_user for jsonlogic functions
-- Required for require_permission and value_changed operators which need an authenticated user context
GRANT EXECUTE ON FUNCTION jl_truthy(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_try_number(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_number(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_no_finite_result(text) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_operand(text, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_array_text(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_number_result(text, numeric) TO semantius_user;
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
GRANT EXECUTE ON FUNCTION jl_reserved_error_parameters() TO semantius_user;
-- The check of an entity's rules runs as whoever saves the entity.
GRANT EXECUTE ON FUNCTION jl_operators() TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_is_operation(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_unknown_operator(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_operator_arity() TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_reserved_variables() TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_raci_letters() TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_pointer(text, text) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_argument_path(text, jsonb, int) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_is_literal(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_date_literal_ok(text, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_rule_problem(jsonb, text, text[], text[], text) TO semantius_user;

-- On an upgrade the dictionary's definer code already runs as semantius_owner,
-- while a function new in this file stays owned by the installer until
-- 9900_owner_hardening.sql runs last. A .jsonc file in between writes entities
-- through that code, which checks their rules with jl_operators,
-- jl_is_operation, jl_unknown_operator and jl_rule_problem with its helpers,
-- reads what they name with jl_row_keys and evaluates them with the rest.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION
            jl_no_finite_result(text),
            jl_number_result(text, numeric),
            jl_operand(text, jsonb),
            jl_array_text(jsonb),
            jl_operators(),
            jl_is_operation(jsonb),
            jl_unknown_operator(jsonb),
            jl_row_keys(jsonb, text[]),
            jl_operator_arity(),
            jl_reserved_variables(),
            jl_reserved_error_parameters(),
            jl_raci_letters(),
            jl_pointer(text, text),
            jl_argument_path(text, jsonb, int),
            jl_is_literal(jsonb),
            jl_date_literal_ok(text, jsonb),
            jl_rule_problem(jsonb, text, text[], text[], text)
        TO semantius_owner;
    END IF;
END $$;
