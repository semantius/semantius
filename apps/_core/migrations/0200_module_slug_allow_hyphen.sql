-- =====================================================
-- MIGRATION: Allow hyphen (-) in module_slug
-- =====================================================
-- Hyphens are valid URL and UI identifiers.
-- Update the CHECK constraint and add a JsonLogic
-- validation rule to the modules entity.

-- =====================================================
-- STEP 1: Add regex operation to evaluate_json_logic
-- =====================================================
-- {"regex": ["pattern", value]} — returns true when value matches
-- the POSIX regular expression pattern (case-sensitive).

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
    IF op = 'set_record' THEN
        var_key := vals ->> 0;
        txt_a := vals ->> 1;
        result := evaluate_json_logic(vals -> 2, data);
        nav := get_record_by_id(txt_a, jl_to_number(result)::integer);
        RETURN evaluate_json_logic(vals -> 3, data || jsonb_build_object(var_key, COALESCE(nav, 'null'::jsonb)));
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

    -- ===================== throw_error =====================
    -- Raises an exception with the given message.
    -- Usage: {"throw_error":"message"}
    IF op = 'throw_error' THEN
        RAISE EXCEPTION '%', jl_to_text(a) USING ERRCODE = '23514';
    END IF;

    -- ===================== regex =====================
    -- Tests whether a string matches a POSIX regular expression pattern.
    -- Usage: {"regex": ["pattern", {"var": "field"}]}
    -- Returns true when the string matches the pattern, false otherwise.
    -- Returns false when the string is null.
    IF op = 'regex' THEN
        IF b IS NULL OR jsonb_typeof(b) = 'null' THEN
            RETURN 'false'::jsonb;
        END IF;
        txt_a := jl_to_text(a);  -- pattern
        txt_b := jl_to_text(b);  -- string to match
        RETURN to_jsonb(txt_b ~ txt_a);
    END IF;


    -- Unknown operator
    RAISE EXCEPTION 'Unrecognized operation: %', op;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- =====================================================
-- STEP 2: Update valid_module_slug CHECK constraint
-- =====================================================
-- Allow hyphens in addition to lowercase letters, digits, and underscores.

ALTER TABLE modules DROP CONSTRAINT valid_module_slug;
ALTER TABLE modules ADD CONSTRAINT valid_module_slug
    CHECK (module_slug = '' OR module_slug ~ '^[a-z0-9_-]+$');

-- =====================================================
-- STEP 3: Add JsonLogic validation rule for module_slug
-- =====================================================
-- The rule enforces the same pattern as the CHECK constraint,
-- providing a user-friendly error message through the validation layer.

UPDATE entities
SET validation_rules = '[{"code":"valid_module_slug","message":"module_slug must only contain lowercase letters, digits, underscores, and hyphens","source_module":"platform","jsonlogic":{"or":[{"==":[{"var":"module_slug"},""]},{"regex":["^[a-z0-9_-]+$",{"var":"module_slug"}]}]}}]'::jsonb
WHERE table_name = 'modules';

-- Rebuild the per-row trigger so the new rule is active
SELECT build_record_logic_trigger('modules');
