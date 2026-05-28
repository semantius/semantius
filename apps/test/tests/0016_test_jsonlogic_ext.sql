BEGIN;

SELECT plan(82);

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

-- =====================================================
-- concat operation tests
-- =====================================================

-- concat: two strings
SELECT is(
    evaluate_json_logic(
        '{"concat":["Hello", " World"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Hello World"'::jsonb,
    'concat: two strings should concatenate'
);

-- concat: single string
SELECT is(
    evaluate_json_logic(
        '{"concat":["Hello"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Hello"'::jsonb,
    'concat: single string should return as-is'
);

-- concat: no arguments
SELECT is(
    evaluate_json_logic(
        '{"concat":[]}'::jsonb,
        '{}'::jsonb
    ),
    '""'::jsonb,
    'concat: no arguments should return empty string'
);

-- concat: empty strings
SELECT is(
    evaluate_json_logic(
        '{"concat":["", ""]}'::jsonb,
        '{}'::jsonb
    ),
    '""'::jsonb,
    'concat: empty strings should return empty string'
);

-- concat: integer values
SELECT is(
    evaluate_json_logic(
        '{"concat":["ID-", 42]}'::jsonb,
        '{}'::jsonb
    ),
    '"ID-42"'::jsonb,
    'concat: string and integer should concatenate'
);

-- concat: float values
SELECT is(
    evaluate_json_logic(
        '{"concat":["Price: $", 19.99]}'::jsonb,
        '{}'::jsonb
    ),
    '"Price: $19.99"'::jsonb,
    'concat: string and float should concatenate'
);

-- concat: boolean true
SELECT is(
    evaluate_json_logic(
        '{"concat":["Active: ", true]}'::jsonb,
        '{}'::jsonb
    ),
    '"Active: true"'::jsonb,
    'concat: string and boolean true should concatenate'
);

-- concat: boolean false
SELECT is(
    evaluate_json_logic(
        '{"concat":["Enabled: ", false]}'::jsonb,
        '{}'::jsonb
    ),
    '"Enabled: false"'::jsonb,
    'concat: string and boolean false should concatenate'
);

-- concat: null treated as empty string
SELECT is(
    evaluate_json_logic(
        '{"concat":["Hello", null, " World"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Hello World"'::jsonb,
    'concat: null between strings should be treated as empty string'
);

-- concat: all nulls
SELECT is(
    evaluate_json_logic(
        '{"concat":[null, null, null]}'::jsonb,
        '{}'::jsonb
    ),
    '""'::jsonb,
    'concat: all nulls should return empty string'
);

-- concat: date string value
SELECT is(
    evaluate_json_logic(
        '{"concat":["Due: ", "2026-01-15"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Due: 2026-01-15"'::jsonb,
    'concat: date string should concatenate as text'
);

-- concat: date-time string value
SELECT is(
    evaluate_json_logic(
        '{"concat":["Created: ", "2026-01-15T10:30:00Z"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Created: 2026-01-15T10:30:00Z"'::jsonb,
    'concat: date-time string should concatenate as text'
);

-- concat: using var to get string field
SELECT is(
    evaluate_json_logic(
        '{"concat":["Name: ", {"var":"name"}]}'::jsonb,
        '{"name": "Alice"}'::jsonb
    ),
    '"Name: Alice"'::jsonb,
    'concat: var string field should concatenate'
);

-- concat: using var to get integer field
SELECT is(
    evaluate_json_logic(
        '{"concat":["Order #", {"var":"order_id"}]}'::jsonb,
        '{"order_id": 1234}'::jsonb
    ),
    '"Order #1234"'::jsonb,
    'concat: var integer field should concatenate'
);

-- concat: using var to get null field
SELECT is(
    evaluate_json_logic(
        '{"concat":["Value: ", {"var":"missing_field"}]}'::jsonb,
        '{"other": 1}'::jsonb
    ),
    '"Value: "'::jsonb,
    'concat: var returning null should be treated as empty string'
);

-- concat: using var to get boolean field
SELECT is(
    evaluate_json_logic(
        '{"concat":["Status: ", {"var":"active"}]}'::jsonb,
        '{"active": true}'::jsonb
    ),
    '"Status: true"'::jsonb,
    'concat: var boolean field should concatenate'
);

-- concat: using var to get date field
SELECT is(
    evaluate_json_logic(
        '{"concat":["Start: ", {"var":"start_date"}]}'::jsonb,
        '{"start_date": "2026-03-01"}'::jsonb
    ),
    '"Start: 2026-03-01"'::jsonb,
    'concat: var date field should concatenate'
);

-- concat: using var to get date-time field
SELECT is(
    evaluate_json_logic(
        '{"concat":["At: ", {"var":"created_at"}]}'::jsonb,
        '{"created_at": "2026-03-01T14:30:00Z"}'::jsonb
    ),
    '"At: 2026-03-01T14:30:00Z"'::jsonb,
    'concat: var date-time field should concatenate'
);

-- concat: multiple types mixed
SELECT is(
    evaluate_json_logic(
        '{"concat":["User ", {"var":"name"}, " (ID:", {"var":"id"}, ") active=", {"var":"active"}]}'::jsonb,
        '{"name": "Bob", "id": 7, "active": false}'::jsonb
    ),
    '"User Bob (ID:7) active=false"'::jsonb,
    'concat: mixed types from var should concatenate correctly'
);

-- concat: null var fields mixed with values
SELECT is(
    evaluate_json_logic(
        '{"concat":[{"var":"first"}, " ", {"var":"middle"}, " ", {"var":"last"}]}'::jsonb,
        '{"first": "John", "middle": null, "last": "Doe"}'::jsonb
    ),
    '"John  Doe"'::jsonb,
    'concat: null var field in middle should be empty string'
);

-- concat: with set_record - load module and concat fields
SELECT is(
    evaluate_json_logic(
        '{"set_record":["mod", "modules", 1001, {"concat":["Module: ", {"var":"mod.module_name"}]}]}'::jsonb,
        '{}'::jsonb
    ),
    '"Module: CRM"'::jsonb,
    'concat: with set_record should concat module fields'
);

-- concat: nested in if condition
SELECT is(
    evaluate_json_logic(
        '{"if":[true, {"concat":["Yes: ", 42]}, "no"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Yes: 42"'::jsonb,
    'concat: nested in if should work'
);

-- concat: with computed argument
SELECT is(
    evaluate_json_logic(
        '{"concat":["Sum is ", {"+":[1, 2, 3]}]}'::jsonb,
        '{}'::jsonb
    ),
    '"Sum is 6"'::jsonb,
    'concat: with computed argument should work'
);

-- concat: with negative number
SELECT is(
    evaluate_json_logic(
        '{"concat":["Balance: ", -100]}'::jsonb,
        '{}'::jsonb
    ),
    '"Balance: -100"'::jsonb,
    'concat: negative number should concatenate'
);

-- concat: with zero
SELECT is(
    evaluate_json_logic(
        '{"concat":["Count: ", 0]}'::jsonb,
        '{}'::jsonb
    ),
    '"Count: 0"'::jsonb,
    'concat: zero should concatenate (not be treated as empty)'
);

-- concat: with false (should not be treated as empty)
SELECT is(
    evaluate_json_logic(
        '{"concat":["Flag: ", false, " done"]}'::jsonb,
        '{}'::jsonb
    ),
    '"Flag: false done"'::jsonb,
    'concat: false should concatenate (not be treated as empty)'
);

-- =====================================================
-- regex operator tests
-- =====================================================

-- regex: basic match
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z]+$", "hello"]}'::jsonb,
        '{}'::jsonb
    ),
    'true'::jsonb,
    'regex: lowercase letters should match ^[a-z]+$'
);

-- regex: no match
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z]+$", "Hello"]}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'regex: uppercase letter should not match ^[a-z]+$'
);

-- regex: slug pattern with hyphen
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z0-9_-]+$", {"var":"slug"}]}'::jsonb,
        '{"slug":"my-module"}'::jsonb
    ),
    'true'::jsonb,
    'regex: slug with hyphen should match slug pattern'
);

-- regex: slug pattern with underscore
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z0-9_-]+$", {"var":"slug"}]}'::jsonb,
        '{"slug":"my_module"}'::jsonb
    ),
    'true'::jsonb,
    'regex: slug with underscore should match slug pattern'
);

-- regex: null value returns false
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z]+$", {"var":"missing"}]}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'regex: null/missing value should return false'
);

-- regex: empty string does not match non-empty pattern
SELECT is(
    evaluate_json_logic(
        '{"regex":["^[a-z0-9_-]+$", ""]}'::jsonb,
        '{}'::jsonb
    ),
    'false'::jsonb,
    'regex: empty string should not match ^[a-z0-9_-]+$'
);

SELECT * FROM finish();
ROLLBACK;