BEGIN;

SELECT plan(10);

-- Rule under test:
-- target_start_date is null OR target_completion_date is null OR target_start_date <= target_completion_date

SELECT is(
    evaluate_json_logic(
        '{"or":[{"==":[{"var":"target_start_date"},null]},{"==":[{"var":"target_completion_date"},null]},{"<=":[{"var":"target_start_date"},{"var":"target_completion_date"}]}]}'::jsonb,
        '{"target_start_date":null,"target_completion_date":"2026-01-05"}'::jsonb
    ),
    'true'::jsonb,
    'date rule: null start date should pass'
);

SELECT is(
    evaluate_json_logic(
        '{"or":[{"==":[{"var":"target_start_date"},null]},{"==":[{"var":"target_completion_date"},null]},{"<=":[{"var":"target_start_date"},{"var":"target_completion_date"}]}]}'::jsonb,
        '{"target_start_date":"2026-01-01","target_completion_date":null}'::jsonb
    ),
    'true'::jsonb,
    'date rule: null completion date should pass'
);

SELECT is(
    evaluate_json_logic(
        '{"or":[{"==":[{"var":"target_start_date"},null]},{"==":[{"var":"target_completion_date"},null]},{"<=":[{"var":"target_start_date"},{"var":"target_completion_date"}]}]}'::jsonb,
        '{"target_start_date":"2026-01-01","target_completion_date":"2026-01-05"}'::jsonb
    ),
    'true'::jsonb,
    'date rule: ordered dates should pass'
);

SELECT is(
    evaluate_json_logic(
        '{"or":[{"==":[{"var":"target_start_date"},null]},{"==":[{"var":"target_completion_date"},null]},{"<=":[{"var":"target_start_date"},{"var":"target_completion_date"}]}]}'::jsonb,
        '{"target_start_date":"2026-01-05","target_completion_date":"2026-01-01"}'::jsonb
    ),
    'false'::jsonb,
    'date rule: reversed dates should fail'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-01'::date))
    ),
    'true'::jsonb,
    'iso compare: SQL date value should compare correctly with ISO date string literal'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-10'::date))
    ),
    'false'::jsonb,
    'iso compare: SQL date value greater than ISO date string literal should fail'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05T00:00:00Z"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-01'::date))
    ),
    'true'::jsonb,
    'iso compare (Z): SQL date value should compare correctly with YYYY-MM-DDTHH:MM:SSZ'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05T00:00:00Z"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-10'::date))
    ),
    'false'::jsonb,
    'iso compare (Z): SQL date value greater than YYYY-MM-DDTHH:MM:SSZ should fail'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05T00:00:00+02:00"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-01'::date))
    ),
    'true'::jsonb,
    'iso compare (+02:00): SQL date value should compare correctly with YYYY-MM-DDTHH:MM:SS+02:00'
);

SELECT is(
    evaluate_json_logic(
        '{"<=":[{"var":"target_start_date"},"2026-01-05T00:00:00+02:00"]}'::jsonb,
        jsonb_build_object('target_start_date', to_jsonb('2026-01-10'::date))
    ),
    'false'::jsonb,
    'iso compare (+02:00): SQL date value greater than YYYY-MM-DDTHH:MM:SS+02:00 should fail'
);

SELECT * FROM finish();
ROLLBACK;