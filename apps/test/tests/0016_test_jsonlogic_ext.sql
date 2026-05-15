BEGIN;

SELECT plan(50);

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

-- =====================================================
-- value_changed tests
-- =====================================================

-- value_changed: no $old key => always true (new record)
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"status":"approved"}'::jsonb
    ),
    'true'::jsonb,
    'value_changed: no $old in data should return true (new record)'
);

-- value_changed: $old is null => always true
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"status":"approved","$old":null}'::jsonb
    ),
    'true'::jsonb,
    'value_changed: $old is null should return true'
);

-- value_changed: value actually changed
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"status":"approved","$old":{"status":"pending"}}'::jsonb
    ),
    'true'::jsonb,
    'value_changed: status changed from pending to approved should return true'
);

-- value_changed: value did NOT change
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"status":"pending","$old":{"status":"pending"}}'::jsonb
    ),
    'false'::jsonb,
    'value_changed: status unchanged should return false'
);

-- value_changed: field missing in $old but present in current => changed
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"status":"approved","$old":{}}'::jsonb
    ),
    'true'::jsonb,
    'value_changed: field missing in $old but present in current should return true'
);

-- value_changed: field present in $old but missing in current => changed
SELECT is(
    evaluate_json_logic(
        '{"value_changed":"status"}'::jsonb,
        '{"$old":{"status":"pending"}}'::jsonb
    ),
    'true'::jsonb,
    'value_changed: field in $old but missing in current should return true'
);

-- =====================================================
-- has_permission tests (returns true/false, never throws)
-- =====================================================

-- user3 (admin) should return true for has_permission admin
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"has_permission":"admin"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'has_permission: user3 (admin) should return true for admin'
);

-- user2 (sales) should return true for has_permission sales:read
SELECT authenticate_as('user2');

SELECT is(
    evaluate_json_logic(
        '{"has_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'has_permission: user2 (sales) should return true for sales:read'
);

-- user1 (basic user) should return false for has_permission admin (no exception)
SELECT authenticate_as('user1');

SELECT is(
    evaluate_json_logic(
        '{"has_permission":"admin"}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'has_permission: user1 should return false for admin (no exception)'
);

-- user1 should return false for has_permission sales:read
SELECT is(
    evaluate_json_logic(
        '{"has_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'has_permission: user1 should return false for sales:read'
);

-- user2 (sales) should return false for has_permission admin
SELECT authenticate_as('user2');

SELECT is(
    evaluate_json_logic(
        '{"has_permission":"admin"}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'has_permission: user2 (sales) should return false for admin'
);

-- user3 (admin) should also return true for sales:read (admin implies all)
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"has_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'has_permission: user3 (admin) should return true for sales:read (admin implies all)'
);

-- =====================================================
-- require_permission tests
-- =====================================================

-- user3 (admin) should succeed with require_permission admin
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"require_permission":"admin"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'require_permission: user3 (admin) should pass admin check'
);

-- user2 (sales) should succeed with require_permission sales:read
SELECT authenticate_as('user2');

SELECT is(
    evaluate_json_logic(
        '{"require_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'require_permission: user2 (sales) should pass sales:read check'
);

-- user1 (basic user) should fail with require_permission admin
SELECT authenticate_as('user1');

SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"require_permission":"admin"}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '42501',
    NULL,
    'require_permission: user1 should fail admin check'
);

-- user1 should fail with require_permission sales:read
SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"require_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '42501',
    NULL,
    'require_permission: user1 should fail sales:read check'
);

-- user2 (sales) should fail with require_permission admin
SELECT authenticate_as('user2');

SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"require_permission":"admin"}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '42501',
    NULL,
    'require_permission: user2 (sales) should fail admin check'
);

-- user3 (admin) should also pass sales:read (admin implies all)
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"require_permission":"sales:read"}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'require_permission: user3 (admin) should pass sales:read check (admin implies all)'
);

-- =====================================================
-- Complex: when status changed AND new status is "approved"
--          => require_permission admin
-- Rule: {"if":[{"and":[{"value_changed":"status"},{"==": [{"var":"status"},"approved"]}]}, {"require_permission":"admin"}, true]}
-- =====================================================

-- Case 1: value changed=YES, user has permission=YES => true
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"approved","$old":{"status":"pending"}}'::jsonb
    ),
    'true'::jsonb,
    'complex: status changed to approved, admin user => true (permission passes)'
);

-- Case 2: value changed=YES, user lacks permission=NO => error
SELECT authenticate_as('user1');

SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"approved","$old":{"status":"pending"}}'::jsonb
    )
    $$,
    '42501',
    NULL,
    'complex: status changed to approved, non-admin user => error'
);

-- Case 3: value changed=NO, user has permission=YES => true (skip permission check)
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"approved","$old":{"status":"approved"}}'::jsonb
    ),
    'true'::jsonb,
    'complex: status NOT changed, admin user => true (condition false, returns default)'
);

-- Case 4: value changed=NO, user lacks permission=NO => true (skip permission check)
SELECT authenticate_as('user1');

SELECT is(
    evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"approved","$old":{"status":"approved"}}'::jsonb
    ),
    'true'::jsonb,
    'complex: status NOT changed, non-admin user => true (condition false, skip permission)'
);

-- Case 5: value changed=YES but new status is NOT approved, admin user => true (skip)
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"pending","$old":{"status":"draft"}}'::jsonb
    ),
    'true'::jsonb,
    'complex: status changed but not to approved, admin => true (condition false)'
);

-- Case 6: value changed=YES but new status is NOT approved, non-admin user => true (skip)
SELECT authenticate_as('user1');

SELECT is(
    evaluate_json_logic(
        '{"if":[{"and":[{"value_changed":"status"},{"==":[{"var":"status"},"approved"]}]},{"require_permission":"admin"},true]}'::jsonb,
        '{"status":"pending","$old":{"status":"draft"}}'::jsonb
    ),
    'true'::jsonb,
    'complex: status changed but not to approved, non-admin => true (condition false)'
);

-- =====================================================
-- get_record_by_id tests
-- =====================================================

-- get_record_by_id: existing entity and existing record
SELECT authenticate_as('user3');

SELECT isnt(
    get_record_by_id('modules', 1001),
    NULL,
    'get_record_by_id: should return a record for existing module 1001'
);

SELECT is(
    (get_record_by_id('modules', 1001)) ->> 'module_name',
    'CRM',
    'get_record_by_id: returned module 1001 should have module_name CRM'
);

-- get_record_by_id: existing entity but non-existing record
SELECT is(
    get_record_by_id('modules', 999999),
    NULL,
    'get_record_by_id: should return NULL for non-existing record id'
);

-- get_record_by_id: non-existing entity
SELECT is(
    get_record_by_id('nonexistent_table', 1),
    NULL,
    'get_record_by_id: should return NULL for non-existing entity'
);

-- =====================================================
-- let operation tests
-- =====================================================

-- let: bind a value and use it in logic
SELECT is(
    evaluate_json_logic(
        '{"let":["x", 42, {"var":"x"}]}'::jsonb,
        '{}'::jsonb
    ),
    '42'::jsonb,
    'let: bind x=42 and read via var should return 42'
);

-- let: bind a computed value and use in arithmetic
SELECT is(
    evaluate_json_logic(
        '{"let":["total", {"+":[10, 20]}, {"*":[{"var":"total"}, 2]}]}'::jsonb,
        '{}'::jsonb
    ),
    '60'::jsonb,
    'let: bind total=30 and multiply by 2 should return 60'
);

-- let: bound value should merge with existing data
SELECT is(
    evaluate_json_logic(
        '{"let":["y", 100, {"+":[{"var":"x"}, {"var":"y"}]}]}'::jsonb,
        '{"x": 5}'::jsonb
    ),
    '105'::jsonb,
    'let: bound y=100 merged with data x=5 should sum to 105'
);

-- =====================================================
-- set_record operation tests
-- =====================================================

-- set_record: load a module record and access its fields
SELECT is(
    evaluate_json_logic(
        '{"set_record":["mod", "modules", 1001, {"var":"mod.module_name"}]}'::jsonb,
        '{}'::jsonb
    ),
    '"CRM"'::jsonb,
    'set_record: load module 1001 and read module_name should return CRM'
);

-- set_record: load non-existing record, variable should be null
SELECT is(
    evaluate_json_logic(
        '{"set_record":["mod", "modules", 999999, {"var":"mod"}]}'::jsonb,
        '{}'::jsonb
    ),
    'null'::jsonb,
    'set_record: non-existing record should set variable to null'
);

-- set_record: load record and use id from data
SELECT is(
    evaluate_json_logic(
        '{"set_record":["mod", "modules", {"var":"module_id"}, {"var":"mod.module_name"}]}'::jsonb,
        '{"module_id": 1001}'::jsonb
    ),
    '"CRM"'::jsonb,
    'set_record: load module by id from data should return CRM'
);

-- set_record: non-existing entity should set variable to null
SELECT is(
    evaluate_json_logic(
        '{"set_record":["rec", "nonexistent_table", 1, {"var":"rec"}]}'::jsonb,
        '{}'::jsonb
    ),
    'null'::jsonb,
    'set_record: non-existing entity should set variable to null'
);

-- =====================================================
-- throw_error operation tests
-- =====================================================

-- throw_error: should raise an exception
SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"throw_error":"Order is already shipped"}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '23514',
    'Order is already shipped',
    'throw_error: should raise exception with given message'
);

-- throw_error: used in if condition (should not throw when condition is false)
SELECT is(
    evaluate_json_logic(
        '{"if":[false, {"throw_error":"should not happen"}, true]}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'throw_error: should not throw when if condition is false'
);

-- throw_error: should throw when if condition is true
SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"if":[true, {"throw_error":"condition met"}, true]}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '23514',
    'condition met',
    'throw_error: should throw when if condition is true'
);

-- =====================================================
-- Complex scenario: set_record + throw_error for validation
-- Load a module, check a condition, throw error if met
-- =====================================================

-- Scenario: load module by id, if description contains "Customer", throw error
SELECT throws_ok(
    $$
    SELECT evaluate_json_logic(
        '{"set_record":["mod", "modules", 1001, {"if":[{"in":["Customer", {"var":"mod.description"}]}, {"throw_error":"Cannot modify customer module"}, true]}]}'::jsonb,
        '{}'::jsonb
    )
    $$,
    '23514',
    'Cannot modify customer module',
    'complex: set_record + throw_error should throw when condition matches'
);

-- Scenario: load module by id, if description contains "NonExistent", should pass
SELECT is(
    evaluate_json_logic(
        '{"set_record":["mod", "modules", 1001, {"if":[{"in":["NonExistent", {"var":"mod.description"}]}, {"throw_error":"Should not happen"}, true]}]}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'complex: set_record + throw_error should not throw when condition does not match'
);

SELECT * FROM finish();
ROLLBACK;