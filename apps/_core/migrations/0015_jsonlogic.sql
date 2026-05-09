CREATE OR REPLACE FUNCTION evaluate_json_logic(rule jsonb, data jsonb)
RETURNS jsonb AS $$
BEGIN
    -- A jsonb value is "logic" only if it is a single-key object.
    -- Anything else (primitive, array, multi-key object) passes through unchanged.
    IF rule IS NULL
       OR jsonb_typeof(rule) <> 'object'
       OR (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1
    THEN
        RETURN rule;
    END IF;

    -- TODO: dispatch on the single key (the operator) and evaluate.
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
