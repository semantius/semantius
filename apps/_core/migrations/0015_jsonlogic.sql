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
CREATE OR REPLACE FUNCTION jl_to_number(val jsonb) RETURNS numeric AS $$
DECLARE
    txt_val text;
BEGIN
    IF val IS NULL THEN RETURN 0; END IF;

    CASE jsonb_typeof(val)
        WHEN 'number' THEN
            RETURN val::text::numeric;

        WHEN 'string' THEN
            txt_val := val #>> '{}';

            -- First try numeric coercion to preserve original JsonLogic behavior.
            BEGIN
                RETURN txt_val::numeric;
            EXCEPTION WHEN invalid_text_representation THEN
                NULL;
            END;

            -- Then try timestamp/date coercion for ISO-like date strings.
            BEGIN
                RETURN extract(epoch FROM txt_val::timestamp)::numeric;
            EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
                RETURN 0;
            END;

        WHEN 'boolean' THEN RETURN CASE WHEN val::text = 'true' THEN 1 ELSE 0 END;
        WHEN 'null' THEN RETURN 0;
        ELSE RETURN 0;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

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
    -- number vs string: coerce string to number
    IF (ta = 'number' AND tb = 'string') OR (ta = 'string' AND tb = 'number') THEN
        RETURN jl_to_number(a) = jl_to_number(b);
    END IF;
    -- boolean vs other: coerce boolean to number then compare
    IF ta = 'boolean' OR tb = 'boolean' THEN
        RETURN jl_to_number(a) = jl_to_number(b);
    END IF;
    RETURN a = b;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

CREATE OR REPLACE FUNCTION evaluate_json_logic(rule jsonb, data jsonb)
RETURNS jsonb AS $$
DECLARE
    op text;
    vals jsonb;
    arr_len int;
    i int;
    current_val jsonb;
    a jsonb; b jsonb; c jsonb;
    num_a numeric; num_b numeric; num_c numeric;
    result jsonb;
    scoped_data jsonb;
    scoped_logic jsonb;
    initial_val jsonb;
    -- for var
    var_key text;
    sub_props text[];
    nav jsonb;
    -- for missing
    missing_arr jsonb;
    keys_arr jsonb;
    key_val text;
    looked_up jsonb;
    -- for merge
    merge_result jsonb;
    elem jsonb;
    j int;
    -- for substr
    src text;
    start_pos int;
    end_len int;
    temp_str text;
    -- for text ops
    txt_a text; txt_b text;
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

    -- Not an object or multi-key object => pass through (primitive)
    IF jsonb_typeof(rule) <> 'object' THEN RETURN rule; END IF;
    -- Must have exactly one key to be logic
    SELECT key INTO op FROM jsonb_object_keys(rule) AS key LIMIT 1;
    IF (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1 THEN RETURN rule; END IF;

    vals := rule -> op;
    -- Normalize: if vals is not an array, wrap it
    IF jsonb_typeof(vals) <> 'array' THEN
        vals := jsonb_build_array(vals);
    END IF;
    arr_len := jsonb_array_length(vals);

    -- ===================== if / ?: =====================
    IF op = 'if' OR op = '?:' THEN
        i := 0;
        WHILE i < arr_len - 1 LOOP
            IF jl_truthy(evaluate_json_logic(vals -> i, data)) THEN
                RETURN evaluate_json_logic(vals -> (i + 1), data);
            END IF;
            i := i + 2;
        END LOOP;
        -- Remaining single element = else clause
        IF arr_len = i + 1 THEN
            RETURN evaluate_json_logic(vals -> i, data);
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
            key_val := keys_arr ->> i;
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

    -- ===================== > =====================
    IF op = '>' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a > num_b);
    END IF;

    -- ===================== >= =====================
    IF op = '>=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a >= num_b);
    END IF;

    -- ===================== < =====================
    IF op = '<' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a < num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a < num_b AND num_b < num_c);
        END IF;
    END IF;

    -- ===================== <= =====================
    IF op = '<=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a <= num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a <= num_b AND num_b <= num_c);
        END IF;
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

    -- Unknown operator
    RAISE EXCEPTION 'Unrecognized operation: %', op;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Revoke public execute on all jsonlogic functions
REVOKE EXECUTE ON FUNCTION jl_truthy(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_text(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_loose_eq(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION evaluate_json_logic(jsonb, jsonb) FROM public;
