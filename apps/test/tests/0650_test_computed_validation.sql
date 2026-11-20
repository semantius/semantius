-- Tests for entities.computed_fields and entities.validation_rules.
-- Verifies trigger generation, computed-field evaluation on INSERT/UPDATE,
-- reserved variables ($today, $now, $user_id), and validation-rule enforcement.
-- Then the rule itself: the save refuses an unknown operator and a validation
-- rule that is not one operator object, an error a rule raises on a write
-- keeps its identity, and a stored rule with an unknown operator still builds
-- and raises on a write.
-- The next part covers the rules of an is_a entity, which run over the whole
-- record inside its write routine. The last parts cover the definition errors
-- a save raises, the hint merge the generated trigger relies on, and the
-- builder where no entity row backs it.
BEGIN;

SELECT plan(109);

SELECT authenticate_as('user3');

-- =====================================================
-- Columns and defaults
-- =====================================================

SELECT has_column('public', 'entities', 'computed_fields',
    'entities.computed_fields column exists');
SELECT has_column('public', 'entities', 'validation_rules',
    'entities.validation_rules column exists');

-- Default is '[]'::jsonb — verify by inserting a minimal entity and reading it back.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_default_probe', 'cv_default_probe', 'Probe', 'Probe', 'default-value probe',
    1, 'public:read', 'admin', 'id', 'label');

SELECT is(
    (SELECT computed_fields FROM entities WHERE table_name = 'cv_default_probe'),
    '[]'::jsonb,
    'computed_fields defaults to empty JSON array');
SELECT is(
    (SELECT validation_rules FROM entities WHERE table_name = 'cv_default_probe'),
    '[]'::jsonb,
    'validation_rules defaults to empty JSON array');

-- =====================================================
-- Test 1: Create entity WITHOUT new properties — no trigger function
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_plain_test', 'cv_plain', 'Plain', 'Plain', 'Entity without rules',
    1, 'public:read', 'admin', 'id', 'label');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc
                WHERE pronamespace = 'public'::regnamespace
                  AND proname = 'compute_validate_cv_plain_test'),
    'No trigger function generated when both arrays are empty');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgrelid = 'public.cv_plain_test'::regclass
                  AND tgname = 'compute_validate_trigger'),
    'No row trigger attached when both arrays are empty');

-- =====================================================
-- Test 1b / 3 / 5: Create entity WITH computed fields and validation rules
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields, validation_rules)
VALUES ('cv_features_test', 'cv_feature', 'Feature', 'Features', 'Feature scoring',
    1, 'public:read', 'admin', 'id', 'label',
    '[
        {"name": "rice_score", "jsonlogic": {
            "if": [
                {"and": [
                    {"!=": [{"var": "effort_score"}, null]},
                    {">":  [{"var": "effort_score"}, 0]}
                ]},
                {"/": [
                    {"*": [{"var": "reach_score"}, {"var": "impact_score"}, {"var": "confidence_score"}]},
                    {"var": "effort_score"}
                ]},
                null
            ]
        }},
        {"name": "tier", "jsonlogic": {
            "if": [
                {">=": [{"var": "rice_score"}, 100]}, "high",
                {">=": [{"var": "rice_score"}, 10]},  "medium",
                "low"
            ]
        }},
        {"name": "is_high", "jsonlogic": {
            "==": [{"var": "tier"}, "high"]
        }}
    ]'::jsonb,
    '[
        {"code": "99003",
         "message": "release_id only allowed once feature is planned, in_progress, or shipped",
         "jsonlogic": {
            "or": [
                {"==": [{"var": "release_id"}, null]},
                {"in": [{"var": "feature_status"}, ["planned", "in_progress", "shipped"]]}
            ]
         }}
    ]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES
    ('cv_features_test', 'reach_score',      'Reach',      'integer', 10),
    ('cv_features_test', 'impact_score',     'Impact',     'integer', 20),
    ('cv_features_test', 'confidence_score', 'Confidence', 'integer', 30),
    ('cv_features_test', 'effort_score',     'Effort',     'integer', 40),
    ('cv_features_test', 'rice_score',       'RICE',       'number',  50),
    ('cv_features_test', 'tier',             'Tier',       'text',    60),
    ('cv_features_test', 'is_high',          'Is High',    'boolean', 70),
    ('cv_features_test', 'release_id',       'Release',    'text',    80),
    ('cv_features_test', 'feature_status',   'Status',     'text',    90);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc
            WHERE pronamespace = 'public'::regnamespace
              AND proname = 'compute_validate_cv_features_test'),
    'Trigger function generated when arrays are non-empty');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_trigger
            WHERE tgrelid = 'public.cv_features_test'::regclass
              AND tgname = 'compute_validate_trigger'),
    'BEFORE row trigger attached to cv_features_test');

-- Test 3: computed fields applied on INSERT
INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score, feature_status)
VALUES ('Feature A', 100, 5, 80, 4, 'planned');

SELECT is(
    (SELECT rice_score FROM cv_features_test WHERE label = 'Feature A'),
    10000.0::numeric(18,2),
    'rice_score computed on INSERT (100*5*80/4 = 10000)');

-- Test 5: different result types — text and boolean computed fields
SELECT is(
    (SELECT tier FROM cv_features_test WHERE label = 'Feature A'),
    'high',
    'text-typed computed field "tier" populated correctly');

SELECT is(
    (SELECT is_high FROM cv_features_test WHERE label = 'Feature A'),
    TRUE,
    'boolean-typed computed field "is_high" populated correctly');

-- Lower-magnitude inputs land in the "low" tier branch
INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score, feature_status)
VALUES ('Feature B', 1, 1, 5, 10, 'planned');

SELECT is(
    (SELECT rice_score FROM cv_features_test WHERE label = 'Feature B'),
    0.5::numeric(18,2),
    'rice_score computed for Feature B (1*1*5/10 = 0.5)');

SELECT is(
    (SELECT tier FROM cv_features_test WHERE label = 'Feature B'),
    'low',
    'tier resolves to "low" when rice_score < 10');

-- =====================================================
-- Test 4: computed fields recomputed on UPDATE
-- =====================================================

UPDATE cv_features_test SET reach_score = 1, impact_score = 2, confidence_score = 5, effort_score = 1
 WHERE label = 'Feature A';

SELECT is(
    (SELECT rice_score FROM cv_features_test WHERE label = 'Feature A'),
    10.0::numeric(18,2),
    'rice_score recomputed on UPDATE (1*2*5/1 = 10)');

SELECT is(
    (SELECT tier FROM cv_features_test WHERE label = 'Feature A'),
    'medium',
    'tier recomputed on UPDATE');

SELECT is(
    (SELECT is_high FROM cv_features_test WHERE label = 'Feature A'),
    FALSE,
    'is_high recomputed on UPDATE');

-- =====================================================
-- Test 7: validation passes for valid data
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score,
        feature_status, release_id)
      VALUES ('Feature C', 10, 3, 70, 2, 'shipped', 'r-1.0')$$,
    'Validation passes when feature_status is "shipped" and release_id set');

SELECT lives_ok(
    $$INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score,
        feature_status)
      VALUES ('Feature D', 10, 3, 70, 2, 'planned')$$,
    'Validation passes when feature_status is "planned" and release_id is unset');

-- =====================================================
-- Test 8 / 9: validation fails — exception raised, row not saved
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score,
        feature_status, release_id)
      VALUES ('Feature E', 10, 3, 70, 2, 'idea', 'r-2.0')$$,
    '99003',
    'release_id only allowed once feature is planned, in_progress, or shipped',
    'INSERT rejected when release_id set on non-committed feature_status');

SELECT is(
    (SELECT count(*)::int FROM cv_features_test WHERE label = 'Feature E'),
    0,
    'No row persisted when validation fails on INSERT');

-- Validation also fires on UPDATE
SELECT throws_ok(
    $$UPDATE cv_features_test
        SET feature_status = 'idea', release_id = 'r-3.0'
      WHERE label = 'Feature C'$$,
    '99003',
    'release_id only allowed once feature is planned, in_progress, or shipped',
    'UPDATE rejected when validation fails');

SELECT is(
    (SELECT feature_status FROM cv_features_test WHERE label = 'Feature C'),
    'shipped',
    'Original row not modified when UPDATE validation fails');

-- =====================================================
-- Test 6: reserved variables ($today, $now, $user_id) inside computed fields
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_reserved_test', 'cv_reserved', 'Reserved', 'Reserved', 'Reserved-vars probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[
        {"name": "today_iso",   "jsonlogic": {"var": "$today"}},
        {"name": "now_iso",     "jsonlogic": {"var": "$now"}},
        {"name": "writer_id",   "jsonlogic": {"var": "$user_id"}}
    ]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES
    ('cv_reserved_test', 'today_iso', 'Today',     'text',    10),
    ('cv_reserved_test', 'now_iso',   'Now',       'text',    20),
    ('cv_reserved_test', 'writer_id', 'Writer Id', 'int64',   30);

INSERT INTO cv_reserved_test (label) VALUES ('probe');

SELECT is(
    (SELECT today_iso FROM cv_reserved_test WHERE label = 'probe'),
    (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date::text,
    '$today reserved variable resolves to the UTC date');

SELECT ok(
    (SELECT now_iso FROM cv_reserved_test WHERE label = 'probe') LIKE
        to_char(CURRENT_TIMESTAMP AT TIME ZONE 'UTC', 'YYYY-MM-DD') || '%',
    '$now reserved variable resolves to the UTC timestamp (same date)');

SELECT is(
    (SELECT writer_id FROM cv_reserved_test WHERE label = 'probe'),
    rbac.user_id(),
    '$user_id reserved variable resolves to the writing user');

-- =====================================================
-- Test: $old reserved variable — null on INSERT, previous values on UPDATE
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_old_test', 'cv_old', 'Old', 'Olds', '$old reserved-var probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[
        {"name": "old_label",  "jsonlogic": {"if": [{"var": "$old"}, {"var": "$old.label"}, ""]}},
        {"name": "old_is_null","jsonlogic": {"==": [{"var": "$old"}, null]}}
    ]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES
    ('cv_old_test', 'old_label',   'Old Label',   'text',    10),
    ('cv_old_test', 'old_is_null', 'Old Is Null', 'boolean', 20);

-- INSERT: $old should be null
INSERT INTO cv_old_test (label) VALUES ('first');

SELECT is(
    (SELECT old_label FROM cv_old_test WHERE label = 'first'),
    '',
    '$old.label is empty string (default) on INSERT because $old is null');

SELECT is(
    (SELECT old_is_null FROM cv_old_test WHERE label = 'first'),
    TRUE,
    '$old is null on INSERT');

-- UPDATE: $old should contain previous row values
UPDATE cv_old_test SET label = 'second' WHERE label = 'first';

SELECT is(
    (SELECT old_label FROM cv_old_test WHERE label = 'second'),
    'first',
    '$old.label contains previous label value on UPDATE');

SELECT is(
    (SELECT old_is_null FROM cv_old_test WHERE label = 'second'),
    FALSE,
    '$old is not null on UPDATE');

-- UPDATE again: $old should reflect the row before this update
UPDATE cv_old_test SET label = 'third' WHERE label = 'second';

SELECT is(
    (SELECT old_label FROM cv_old_test WHERE label = 'third'),
    'second',
    '$old.label contains previous label value on second UPDATE');

-- =====================================================
-- $old where the rule does not spell it
-- =====================================================
-- The previous row is serialized only for an entity whose rules can read it.
-- A rule can read it without the name standing in its text: the key of a var,
-- of missing and of missing_some may itself be computed. Such a rule cannot be
-- told from its text, so it gets $old like a rule that names it. value_changed
-- never names $old either and reads it all the same.

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_old_var_list', 'cv_old_var_list', 'Old Var List', 'Old Var Lists', 'var with a computed key and a default',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "prev", "jsonlogic": {"var": [{"cat": ["$ol", "d.label"]}, "none"]}}]'::jsonb),
       ('cv_old_missing', 'cv_old_missing', 'Old Missing', 'Old Missings', 'missing with a computed key',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "seen", "jsonlogic": {"if": [{"missing": [{"cat": ["$ol", "d.label"]}]}, "missing", "present"]}}]'::jsonb),
       ('cv_old_changed', 'cv_old_changed', 'Old Changed', 'Old Changeds', 'value_changed',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "changed", "jsonlogic": {"value_changed": "label"}}]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES
    ('cv_old_var_list', 'prev',    'Prev',    'text',    10),
    ('cv_old_missing',  'seen',    'Seen',    'text',    10),
    ('cv_old_changed',  'changed', 'Changed', 'boolean', 10),
    ('cv_old_changed',  'note',    'Note',    'text',    20);

INSERT INTO cv_old_var_list (label) VALUES ('first');
UPDATE cv_old_var_list SET label = 'second' WHERE label = 'first';

SELECT is(
    (SELECT prev FROM cv_old_var_list WHERE label = 'second'),
    'first',
    'a var whose key is computed, written with a default, reads $old on UPDATE');

INSERT INTO cv_old_missing (label) VALUES ('first');
UPDATE cv_old_missing SET label = 'second' WHERE label = 'first';

SELECT is(
    (SELECT seen FROM cv_old_missing WHERE label = 'second'),
    'present',
    'missing with a computed key finds $old.label on UPDATE');

INSERT INTO cv_old_changed (label) VALUES ('first');
UPDATE cv_old_changed SET note = 'edited' WHERE label = 'first';

SELECT is(
    (SELECT changed FROM cv_old_changed WHERE label = 'first'),
    FALSE,
    'value_changed reads $old: an UPDATE that leaves the label alone reports no change');

-- =====================================================
-- An input_type_rule is checked when the field is saved
-- =====================================================
-- The browser evaluates it for every record it shows and falls back to the
-- static input_type when the rule raises, so a misspelled operator would turn
-- a required or hidden field into an ordinary one without a word. The save
-- refuses it like the rules of an entity. A rule yields an input type, so it
-- may be a literal, and the empty object means no rule.

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_itr_test', 'cv_itr', 'Itr', 'Itrs', 'input_type_rule probe',
    1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type_rule)
VALUES ('cv_itr_test', 'kept', 'Kept', 'text', 10, '{"if": [{"var": "label"}, "required", "hidden"]}');

SELECT is(
    COALESCE(catch_error($$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type_rule)
        VALUES ('cv_itr_test', 'top', 'Top', 'text', 20, '{"unknown_op": [1, 2]}')$$) ->> 'code', 'no error'),
    '90909',
    'save: a field whose input_type_rule is an unknown operator is refused');

SELECT is(
    catch_error_hint($$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type_rule)
        VALUES ('cv_itr_test', 'top_hint', 'Top Hint', 'text', 25, '{"unknown_op": [1, 2]}')$$),
    '{"rule": "top_hint.input_type_rule", "table": "cv_itr_test", "op": "unknown_op"}'::jsonb,
    'save: and the hint names the field''s rule, the table and the operator');

SELECT is(
    COALESCE(catch_error($$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type_rule)
        VALUES ('cv_itr_test', 'nested', 'Nested', 'text', 30,
                '{"if": [{"var": "label"}, {"unknown_op": [1, 2]}, "hidden"]}')$$) ->> 'code', 'no error'),
    '90909',
    'save: an unknown operator below the top of an input_type_rule is refused as well');

SELECT is(
    COALESCE(catch_error($$UPDATE fields SET input_type_rule = '{"unknown_op": [1, 2]}'
                            WHERE table_name = 'cv_itr_test' AND field_name = 'kept'$$) ->> 'code', 'no error'),
    '90909',
    'save: an update that brings an unknown operator into an input_type_rule is refused');

SELECT is(
    COALESCE(catch_error($$UPDATE fields SET input_type_rule = '{"if": [{"unknown_op": [1, 2]}, "required", "hidden"]}'
                            WHERE table_name = 'cv_itr_test' AND field_name = 'kept'$$) ->> 'code', 'no error'),
    '90909',
    'save: and so is an update that brings one in below the top');

SELECT is(
    (SELECT input_type_rule FROM fields WHERE table_name = 'cv_itr_test' AND field_name = 'kept'),
    '{"if": [{"var": "label"}, "required", "hidden"]}'::jsonb,
    'save: a rule of known operators is saved, and the refused updates left it as it was');

-- =====================================================
-- A rule is checked when the entity is saved
-- =====================================================
-- An operator the interpreter does not know raises on the first write that
-- reaches it, inside a trigger, on a record that has nothing to do with the
-- mistake. A validation rule that is not one operator object is worse: the
-- interpreter reads an object with two keys as data, data is truthy, and the
-- rule passes every record. So the save refuses both, wherever in the rule the
-- operator stands, on an insert and on an update alike. Each save names an
-- entity of its own, so a save that goes through changes nothing another
-- assertion reads.

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, computed_fields)
        VALUES ('cv_save_computed', 'cv_save_computed', 'Save Computed', 'Save Computeds', 'Refused at save', 1,
                '[{"name": "broken", "jsonlogic": {"unknown_op": [1, 2]}}]'::jsonb)$$) ->> 'code',
    '90909',
    'save: a computed field with an unknown operator is refused');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, computed_fields)
        VALUES ('cv_save_nested', 'cv_save_nested', 'Save Nested', 'Save Nesteds', 'Refused at save', 1,
                '[{"name": "broken", "jsonlogic": {"if": [{"var": "label"}, {"unknown_op": [1, 2]}, null]}}]'::jsonb)$$) ->> 'code',
    '90909',
    'save: an unknown operator below the top of a rule is refused as well');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_save_rule_op', 'cv_save_rule_op', 'Save Rule Op', 'Save Rule Ops', 'Refused at save', 1,
                '[{"code": "99030", "message": "m", "jsonlogic": {"unknown_op": [1, 2]}}]'::jsonb)$$) ->> 'code',
    '90909',
    'save: a validation rule with an unknown operator is refused');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_save_rule_shape', 'cv_save_rule_shape', 'Save Rule Shape', 'Save Rule Shapes', 'Refused at save', 1,
                '[{"code": "99031", "message": "m", "jsonlogic": {"==": [1, 1], "x": 2}}]'::jsonb)$$) ->> 'code',
    '90919',
    'save: a validation rule that is an object with two keys is refused');

-- A literal in place of the operator is read the same way as the two-key
-- object: as data. A condition typed as text is a non-empty string, which is
-- truthy, so the rule passes every record and nobody notices it never ran. A
-- rule that is meant to hold always or never has no use that deleting it, or
-- the edit permission, does not serve better, so true is refused with the rest.
SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_save_rule_text', 'cv_save_rule_text', 'Save Rule Text', 'Save Rule Texts', 'Refused at save', 1,
                '[{"code": "99033", "message": "m", "jsonlogic": "label == ok"}]'::jsonb)$$) ->> 'code',
    '90919',
    'save: a validation rule whose condition is a text literal is refused');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_save_rule_true', 'cv_save_rule_true', 'Save Rule True', 'Save Rule Trues', 'Refused at save', 1,
                '[{"code": "99034", "message": "m", "jsonlogic": true}]'::jsonb)$$) ->> 'code',
    '90919',
    'save: a validation rule whose condition is the literal true is refused');

SELECT is(
    ARRAY(SELECT n
            FROM unnest(ARRAY['cv_save_computed', 'cv_save_nested', 'cv_save_rule_op', 'cv_save_rule_shape',
                              'cv_save_rule_text', 'cv_save_rule_true']) AS n
           WHERE EXISTS (SELECT 1 FROM entities WHERE table_name = n)
              OR to_regclass('public.' || n) IS NOT NULL),
    '{}'::text[],
    'save: a refused insert leaves neither the entity row nor its table behind');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_save_update', 'cv_save_update', 'Save Update', 'Save Updates', 'Refused at update',
    1, 'public:read', 'admin', 'id', 'label');

SELECT is(
    catch_error($$UPDATE entities
        SET validation_rules = '[{"code": "99032", "message": "m", "jsonlogic": {"unknown_op": [1, 2]}}]'::jsonb
      WHERE table_name = 'cv_save_update'$$) ->> 'code',
    '90909',
    'save: the same refusal when a rule is added to an existing entity');

SELECT is(
    (SELECT validation_rules FROM entities WHERE table_name = 'cv_save_update'),
    '[]'::jsonb,
    'save: and the refused update leaves the entity without the rule');

-- =====================================================
-- A rule that is new or changed is checked further
-- =====================================================
-- The interpreter answers the mistakes below without an error, and the answer
-- is wrong: >= ignores a third argument, an object with several keys is a
-- truthy value, a misspelled unit is no unit, and a $ name the rules are not
-- given reads null. The save refuses them, with the place inside the rule in
-- the hint. Which mistakes count, and where, is the shared case list of
-- 0115_test_jsonlogic_check.json; these assertions are the save around it.

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, computed_fields)
        VALUES ('cv_detail_count', 'cv_detail_count', 'Detail Count', 'Detail Counts', 'Refused at save', 1,
                '[{"name": "label", "jsonlogic": {"if": [{">=": [{"var": "a"}, 1, 10]}, "in", "out"]}}]'::jsonb)$$) - 'hint',
    '{"code": "90921", "message": "${rule} on ${table} gives ${op} ${count} arguments, a number it does not take", "details": ""}'::jsonb,
    'detail: a computed field giving an operator an argument count it does not take is refused');

SELECT is(
    catch_error_hint($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                             module_id, computed_fields)
        VALUES ('cv_detail_count', 'cv_detail_count', 'Detail Count', 'Detail Counts', 'Refused at save', 1,
                '[{"name": "label", "jsonlogic": {"if": [{">=": [{"var": "a"}, 1, 10]}, "in", "out"]}}]'::jsonb)$$),
    '{"rule": "computed_fields[0]", "table": "cv_detail_count", "path": "/if/0/>=",
      "op": ">=", "count": 3, "min": 2, "max": 2}'::jsonb,
    'detail: and the hint names the rule, the place in it and the counts, as numbers');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_detail_unit', 'cv_detail_unit', 'Detail Unit', 'Detail Units', 'Refused at save', 1,
                '[{"code": "99040", "message": "m",
                   "jsonlogic": {"<": [{"date_diff": [{"var": "$today"}, {"var": "due"}, "days"]}, 30]}}]'::jsonb)$$) ->> 'code',
    '90922',
    'detail: a validation rule with a misspelled date unit is refused');

SELECT is(
    catch_error_hint($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                             module_id, computed_fields)
        VALUES ('cv_detail_keys', 'cv_detail_keys', 'Detail Keys', 'Detail Keys', 'Refused at save', 1,
                '[{"name": "meta", "jsonlogic": {"if": [{"var": "a"}, {"x": 1, "y": 2}, null]}}]'::jsonb)$$),
    '{"rule": "computed_fields[0]", "table": "cv_detail_keys", "path": "/if/1", "key_count": 2}'::jsonb,
    'detail: an object with several keys below the top of a computed field is refused, a constant object included');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_detail_var', 'cv_detail_var', 'Detail Var', 'Detail Vars', 'Refused at save', 1,
                '[{"code": "99041", "message": "m",
                   "jsonlogic": {"all": [{"var": "lines"}, {"<=": [{"var": "qty"}, {"var": "$old.qty"}]}]}}]'::jsonb)$$) - 'hint',
    '{"code": "90924", "message": "${rule} on ${table} reads ${variable}, which has no value where it is read", "details": ""}'::jsonb,
    'detail: a validation rule reading a $ variable inside the logic of an array operator is refused');

SELECT is(
    catch_error_hint($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                             module_id, validation_rules)
        VALUES ('cv_detail_var', 'cv_detail_var', 'Detail Var', 'Detail Vars', 'Refused at save', 1,
                '[{"code": "99041", "message": "m",
                   "jsonlogic": {"all": [{"var": "lines"}, {"<=": [{"var": "qty"}, {"var": "$old.qty"}]}]}}]'::jsonb)$$),
    '{"rule": "validation_rules[0]", "table": "cv_detail_var", "path": "/all/1/<=/1/var",
      "variable": "$old", "reason": "array_element", "op": "all"}'::jsonb,
    'detail: and the hint says which variable, why it has no value, and under which operator');

SELECT is(
    COALESCE(catch_error($$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type_rule)
        VALUES ('cv_itr_test', 'detail', 'Detail', 'text', 40,
                '{"if": [{"var": "$state"}, "hidden", "default"]}')$$) ->> 'code', 'no error'),
    '90924',
    'detail: a field whose input_type_rule reads an unknown $ variable is refused');

SELECT is(
    COALESCE(catch_error($$UPDATE fields SET input_type_rule = '{"if": [{"!": [{"var": "label"}, 1]}, "required", "hidden"]}'
                            WHERE table_name = 'cv_itr_test' AND field_name = 'kept'$$) ->> 'code', 'no error'),
    '90921',
    'detail: and so is an update that gives an operator of an input_type_rule an argument too many');

-- The entry around the rule is held to what the app's checker demands: a
-- name and a message are text. The builder alone would read 5 as "5".
SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, computed_fields)
        VALUES ('cv_detail_name', 'cv_detail_name', 'Detail Name', 'Detail Names', 'Refused at save', 1,
                '[{"name": 5, "jsonlogic": {"var": "label"}}]'::jsonb)$$) ->> 'code',
    '90900',
    'detail: a computed field whose name is not text is refused');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                        module_id, validation_rules)
        VALUES ('cv_detail_message', 'cv_detail_message', 'Detail Message', 'Detail Messages', 'Refused at save', 1,
                '[{"code": "99042", "message": 5, "jsonlogic": {"!=": [{"var": "label"}, ""]}}]'::jsonb)$$) ->> 'code',
    '90903',
    'detail: a validation rule whose message is not text is refused');

-- A rule stored without having passed these checks keeps working: a write
-- that leaves it alone is not refused for it, and neither is a change to the
-- rules beside it. Changing the rule itself is refused until it is put right.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_stored_detail', 'cv_stored_detail', 'Stored Detail', 'Stored Details', 'Rule stored past the checks',
    1, 'public:read', 'admin', 'id', 'label');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

ALTER TABLE entities DISABLE TRIGGER USER;
UPDATE entities
   SET validation_rules = '[{"code": "99043", "message": "label in range",
                             "jsonlogic": {">=": [{"var": "label"}, "a", "m"]}}]'::jsonb
 WHERE table_name = 'cv_stored_detail';
ALTER TABLE entities ENABLE TRIGGER USER;

SELECT authenticate_as('user3');

SELECT lives_ok(
    $$UPDATE entities SET description = 'Edited after the upgrade' WHERE table_name = 'cv_stored_detail'$$,
    'stored detail: a save of the entity that leaves the rule alone goes through');

SELECT lives_ok(
    $$UPDATE entities
         SET validation_rules = '[{"code": "99044", "message": "label set", "jsonlogic": {"!=": [{"var": "label"}, ""]}}]'::jsonb
                                || validation_rules
       WHERE table_name = 'cv_stored_detail'$$,
    'stored detail: so does a rule added in front of it, which moves it to another place');

SELECT is(
    COALESCE(catch_error($$UPDATE entities
                              SET validation_rules = jsonb_set(validation_rules, '{1,message}', '"label from a to m"')
                            WHERE table_name = 'cv_stored_detail'$$) ->> 'code', 'no error'),
    '90921',
    'stored detail: a change to the rule itself is refused until the rule is put right');

-- =====================================================
-- An error of ours raised by a rule on a write
-- =====================================================
-- A rule that is sound when saved can still fail on a record: date_add over a
-- label that is no date. The generated trigger adds where an error happened
-- and changes nothing else. An error of class 90 is one of ours, so it travels
-- as itself, keys and all, because the number is already the whole identity;
-- and the message is the evaluator's own, unprefixed, because the message is
-- what a client falls back to when it has no translation for the code, and a
-- prefix is an interpolation. docs/error-contract.md, "The generated trigger".

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_passthrough_test', 'cv_passthrough', 'Passthrough', 'Passthroughs', 'Rule failing on the record',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "due", "jsonlogic": {"date_add": [{"var": "label"}, 1, "day"]}}]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cv_passthrough_test', 'due', 'Due', 'text', 10);

SELECT is(
    catch_error($$INSERT INTO cv_passthrough_test (label) VALUES ('boom')$$) - 'hint',
    '{"code": "90915", "message": "${operator} needs an ISO 8601 date or date-time, not ${value}", "details": ""}'::jsonb,
    'A class 90 error out of a computed field keeps its code and its own message, unprefixed');

SELECT is(
    catch_error_hint($$INSERT INTO cv_passthrough_test (label) VALUES ('boom')$$),
    '{"operator": "date_add", "value": "boom"}'::jsonb,
    'A class 90 error out of a computed field keeps its hint, with no key added');

-- PostgreSQL's own errors do get stamped, because nothing else in them says
-- which rule produced them. A date of the right shape that is no real date is
-- the shortest way to raise one from inside a computed field: the date
-- operators hand it to PostgreSQL's cast, which answers 22008.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_divzero_test', 'cv_divzero', 'Div', 'Divs', 'PostgreSQL error probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "ratio", "jsonlogic": {"date_part": ["2026-02-30", "day"]}}]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cv_divzero_test', 'ratio', 'Ratio', 'integer', 10);

SELECT is(
    catch_error_hint($$INSERT INTO cv_divzero_test (label) VALUES ('boom')$$),
    '{"entity": "cv_divzero_test", "field": "ratio"}'::jsonb,
    'A PostgreSQL error out of a computed field is stamped with the entity and the field');

-- =====================================================
-- A stored rule with an unknown operator
-- =====================================================
-- A rule can be in the dictionary without having passed a save: a restored
-- dump, or a row written while the triggers of entities are off, which is how
-- this one gets there. The builder installs the rule as it stands, so the
-- generators can be run again over such an installation, and the operator
-- surfaces where the rule is evaluated: a write raises the interpreter's own
-- error, which passes through like any other of class 90. The entity itself
-- cannot be saved again until the rule is put right.

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_stored_op_test', 'cv_stored_op', 'Stored Op', 'Stored Ops', 'Rule stored past the save',
    1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cv_stored_op_test', 'broken', 'Broken', 'text', 10);

-- Turning the triggers of entities off takes its owner, and the builder is the
-- owner's as well.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

ALTER TABLE entities DISABLE TRIGGER USER;
UPDATE entities
   SET computed_fields = '[{"name": "broken", "jsonlogic": {"unknown_op": [1, 2]}}]'::jsonb
 WHERE table_name = 'cv_stored_op_test';
ALTER TABLE entities ENABLE TRIGGER USER;

SELECT lives_ok($$SELECT public.build_record_logic_trigger('cv_stored_op_test')$$,
    'stored rule: the builder installs a rule with an unknown operator as it stands');

SELECT authenticate_as('user3');

SELECT is(
    catch_error($$INSERT INTO cv_stored_op_test (label) VALUES ('boom')$$) - 'hint',
    '{"code": "90910", "message": "Unrecognized operation: ${op}", "details": ""}'::jsonb,
    'stored rule: a write raises the unknown operator under its own code and message, unprefixed');

SELECT is(
    catch_error_hint($$INSERT INTO cv_stored_op_test (label) VALUES ('boom')$$),
    '{"op": "unknown_op"}'::jsonb,
    'stored rule: and its hint names the operator, with no key added');

SELECT is(
    COALESCE(catch_error($$UPDATE entities SET description = 'Edited after the upgrade'
                            WHERE table_name = 'cv_stored_op_test'$$) ->> 'code', 'no error'),
    '90909',
    'stored rule: a save of the entity that leaves the rule alone is refused all the same');

-- =====================================================
-- An error raised inside a validation rule keeps its identity
-- =====================================================
-- The rule did not fail here - something inside its logic raised - so the error
-- travels out as itself and only gains the two keys that say where it came
-- from.

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    validation_rules)
VALUES ('cv_rule_error_test', 'cv_rule_error', 'Rule Error', 'Rule Errors', 'Raising rule',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"code": "99001", "message": "never reached",
       "jsonlogic": {"throw_error": "Order is already shipped"}}]'::jsonb);

SELECT is(
    catch_error($$INSERT INTO cv_rule_error_test (label) VALUES ('x')$$) - 'hint',
    '{"code": "99000", "message": "Order is already shipped", "details": ""}'::jsonb,
    'Error raised inside a rule keeps its SQLSTATE, message and DETAIL');

SELECT is(
    catch_error_hint($$INSERT INTO cv_rule_error_test (label) VALUES ('x')$$),
    '{"entity": "cv_rule_error_test", "rule": "99001"}'::jsonb,
    'Error raised inside a rule is stamped with the entity and the rule');

-- =====================================================
-- A rule code has to be a SQLSTATE
-- =====================================================
-- The code is what the failure raises, so a name that PL/pgSQL cannot raise is
-- refused when the entity is saved rather than when the rule first fires on
-- somebody's write.

SELECT throws_ok(
    $$UPDATE entities SET validation_rules =
        '[{"code": "must_be_positive", "message": "m", "jsonlogic": {"==": [1, 1]}}]'::jsonb
      WHERE table_name = 'cv_rule_error_test'$$,
    '90905',
    'validation_rules[${index}] on ${table} must carry a class 99 code, not ${rule_code}',
    'a rule code outside class 99 is rejected when the entity is saved');

SELECT throws_ok(
    $$UPDATE entities SET validation_rules =
        '[{"code": "99009", "message": "m", "source_module": "platform", "jsonlogic": {"==": [1, 1]}}]'::jsonb
      WHERE table_name = 'cv_rule_error_test'$$,
    '90906',
    'validation_rules[${index}] on ${table} is a platform rule, so its code must be a class 90 number, not ${rule_code}',
    'a platform rule carrying a class 99 code is rejected when the entity is saved');

-- =====================================================
-- A cascaded write names the innermost entity
-- =====================================================
-- A row trigger on one entity can write a second one, whose own compute/validate
-- trigger may fail. The keys must name the entity whose rule actually raised,
-- because that is what scopes the translation of a class 99 code.

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    validation_rules)
VALUES ('cv_cascade_inner', 'cv_cascade_inner', 'Inner', 'Inners', 'Inner entity',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"code": "99002", "message": "never reached",
       "jsonlogic": {"throw_error": "inner rule refused the write"}}]'::jsonb);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_cascade_outer', 'cv_cascade_outer', 'Outer', 'Outers', 'Outer entity',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "echo", "jsonlogic": {"var": "label"}}]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cv_cascade_outer', 'echo', 'Echo', 'text', 10);

-- CREATE TRIGGER needs the TRIGGER privilege on the table, which the request
-- role does not hold, so the cascade is wired as the owner and only the write
-- below is made as the user.
RESET ROLE;

CREATE FUNCTION public.cv_cascade_fn() RETURNS TRIGGER AS $CASCADE$
BEGIN
    INSERT INTO public.cv_cascade_inner (label) VALUES (NEW.label);
    RETURN NEW;
END;
$CASCADE$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER cv_cascade_trigger AFTER INSERT ON cv_cascade_outer
    FOR EACH ROW EXECUTE FUNCTION public.cv_cascade_fn();

SET ROLE semantius_user;

SELECT is(
    catch_error_hint($$INSERT INTO cv_cascade_outer (label) VALUES ('x')$$),
    '{"entity": "cv_cascade_inner", "rule": "99002"}'::jsonb,
    'A cascaded write is stamped with the innermost entity and its rule');

-- =====================================================
-- Trigger drop on entity update / delete
-- =====================================================

UPDATE entities SET computed_fields = '[]'::jsonb, validation_rules = '[]'::jsonb
 WHERE table_name = 'cv_features_test';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc
                WHERE pronamespace = 'public'::regnamespace
                  AND proname = 'compute_validate_cv_features_test'),
    'Trigger function dropped when both arrays cleared');

-- Now that the trigger is gone, an otherwise-invalid write succeeds (no rules in force).
SELECT lives_ok(
    $$INSERT INTO cv_features_test (label, reach_score, impact_score, confidence_score, effort_score,
        feature_status, release_id)
      VALUES ('Feature Post-Clear', 1, 1, 1, 1, 'idea', 'r-x')$$,
    'Validation no longer runs after clearing rules');

-- Restore rules then delete entity — function should be cleaned up
UPDATE entities
   SET computed_fields = '[{"name": "rice_score", "jsonlogic": {"var": "reach_score"}}]'::jsonb
 WHERE table_name = 'cv_features_test';

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc
            WHERE pronamespace = 'public'::regnamespace
              AND proname = 'compute_validate_cv_features_test'),
    'Trigger function recreated after re-adding computed_fields');

DELETE FROM entities WHERE table_name = 'cv_features_test';

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc
                WHERE pronamespace = 'public'::regnamespace
                  AND proname = 'compute_validate_cv_features_test'),
    'Trigger function dropped after entity deletion');

-- =====================================================
-- A computed date, stored as a date
-- =====================================================
-- Why the date operators exist: a deadline derived from the row's own fields
-- cannot go stale, and as a real date it can be filtered and sorted.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('cv_renewal_test', 'cv_renewal', 'Renewal', 'Renewals', 'Computed date probe',
    1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES
    ('cv_renewal_test', 'term_end',        'Term End',        'date',      10),
    ('cv_renewal_test', 'notice_days',     'Notice Days',     'int32',     20),
    ('cv_renewal_test', 'notice_deadline', 'Notice Deadline', 'date',      30),
    ('cv_renewal_test', 'reviewed_at',     'Reviewed At',     'date-time', 40),
    ('cv_renewal_test', 'review_due',      'Review Due',      'date-time', 50),
    ('cv_renewal_test', 'grace_end',       'Grace End',       'date',      70);

INSERT INTO fields (table_name, field_name, title, format, default_value, field_order)
VALUES ('cv_renewal_test', 'grace', 'Grace', 'duration', 'PT0S', 60);

INSERT INTO cv_renewal_test (label, term_end, notice_days) VALUES ('before the rule', '2026-12-31', 30);

UPDATE entities
   SET computed_fields = '[
        {"name": "notice_deadline", "jsonlogic": {"date_add": [{"var": "term_end"}, {"-": [0, {"var": "notice_days"}]}, "day"]}},
        {"name": "review_due",      "jsonlogic": {"date_add": [{"var": "reviewed_at"}, 1, "month"]}},
        {"name": "grace_end",       "jsonlogic": {"date_add": [{"var": "term_end"}, {"var": "grace"}]}}
    ]'::jsonb
 WHERE table_name = 'cv_renewal_test';

SELECT is((SELECT notice_deadline FROM cv_renewal_test WHERE label = 'before the rule'), '2026-12-01'::date,
    'computed date: adding the rule fills the records that already exist');

INSERT INTO cv_renewal_test (label, term_end, notice_days) VALUES ('written', '2027-01-31', 31);
SELECT is((SELECT notice_deadline FROM cv_renewal_test WHERE label = 'written'), '2026-12-31'::date,
    'computed date: date_add stores into a date column');

INSERT INTO cv_renewal_test (label, notice_days) VALUES ('no term', 30);
SELECT ok((SELECT notice_deadline IS NULL FROM cv_renewal_test WHERE label = 'no term'),
    'computed date: a record with no source date saves, with no deadline');

SELECT is((SELECT count(*)::int FROM cv_renewal_test WHERE notice_deadline <= '2026-12-15'), 1,
    'computed date: the stored value filters as a date');

-- The two zones are on different calendar days from each other at every instant,
-- so at least one of them differs from UTC.
SET LOCAL timezone = 'Pacific/Kiritimati';
INSERT INTO cv_renewal_test (label, reviewed_at) VALUES ('east', '2026-01-31T23:30:00Z');
INSERT INTO cv_reserved_test (label) VALUES ('east');
SET LOCAL timezone = 'Pacific/Pago_Pago';
INSERT INTO cv_renewal_test (label, reviewed_at) VALUES ('west', '2026-01-31T23:30:00Z');
INSERT INTO cv_reserved_test (label) VALUES ('west');
SET LOCAL timezone = 'UTC';

SELECT is((SELECT review_due FROM cv_renewal_test WHERE label = 'east'), '2026-02-28T23:30:00Z'::timestamptz,
    'computed date-time at UTC+14: the month is added in UTC');
SELECT is((SELECT review_due FROM cv_renewal_test WHERE label = 'west'), '2026-02-28T23:30:00Z'::timestamptz,
    'computed date-time at UTC-11: the month is added in UTC');
SELECT is((SELECT today_iso FROM cv_reserved_test WHERE label = 'east'), (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date::text,
    '$today at UTC+14 is the UTC date');
SELECT is((SELECT today_iso FROM cv_reserved_test WHERE label = 'west'), (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date::text,
    '$today at UTC-11 is the UTC date');

-- The rule reads the column through to_jsonb, which follows IntervalStyle.
SET LOCAL intervalstyle = 'postgres';
INSERT INTO cv_renewal_test (label, term_end, grace) VALUES ('grace', '2026-01-31', '1 mon 1 day');
SET LOCAL intervalstyle = 'iso_8601';
SELECT is((SELECT grace_end FROM cv_renewal_test WHERE label = 'grace'), '2026-03-01'::date,
    'computed date: a duration column works whatever the session''s interval style');

-- =====================================================
-- Rules of an is_a entity: over the whole record
-- =====================================================
-- An is_a entity's rules live in common.record_rules_<entity>, which its write
-- routine calls with the whole record - inherited columns, a full $old and
-- $mode - before the root's own rule trigger checks the final root row.
-- rl_premium derives the root's amount from its own factor; the root caps the
-- amount; rl_premium keeps the root's note write-once.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      edit_permission, validation_rules)
VALUES ('rl_accounts', 'Account', 'Accounts', 1, 'typeid', 'rlacc', 'nwind:manage',
        '[{"code":"99801","message":"amount too high","jsonlogic":{"<=":[{"var":"amount"},100]}}]'::jsonb);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rl_accounts', 'amount', 'Amount', 'int32', 30),
       ('rl_accounts', 'note', 'Note', 'text', 40);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      edit_permission)
VALUES ('rl_premium', 'Premium Account', 'Premium Accounts', 1, 'is_a', 'rlprm', 'rl_accounts', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rl_premium', 'factor', 'Factor', 'int32', 30);
UPDATE entities
   SET computed_fields = '[{"name":"amount","jsonlogic":{"*":[{"var":"factor"},10]}}]'::jsonb,
       validation_rules = '[{"code":"99803","message":"note is write-once",
                             "jsonlogic":{"if":[{"==":[{"var":"$old"},null]},true,
                                                {"==":[{"var":"note"},{"var":"$old.note"}]}]}}]'::jsonb
 WHERE table_name = 'rl_premium';

INSERT INTO rl_premium (label, factor, note) VALUES ('p1', 5, 'first');
SELECT is((SELECT amount FROM rl_accounts WHERE label = 'p1'), 50,
    'is_a rules: a computed field of the subtype sets a column its root stores');

SELECT throws_ok($$ INSERT INTO rl_premium (label, factor) VALUES ('p2', 20) $$,
    '99801', NULL,
    'is_a rules: the root''s rules run after the subtype''s, on the final root row');

SELECT throws_ok($$ UPDATE rl_accounts SET note = 'second' WHERE label = 'p1' $$,
    '99803', NULL,
    'is_a rules: $old is the whole record, and a write through the root runs the subtype''s rules');

SELECT authenticate_as('user2');
SELECT throws_ok($$ UPDATE rl_premium SET note = 'third' WHERE label = 'p1' $$,
    '99803', NULL,
    'is_a rules: for the request role a failing subtype rule raises its own code, not 42501');

RESET ROLE;
SELECT ok(
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rl_accounts'::regclass AND tgname = 'compute_validate_trigger')
    AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rl_premium_ext'::regclass AND tgname = 'compute_validate_trigger')
    AND (SELECT prosecdef FROM pg_proc WHERE oid = 'common.record_rules_rl_premium(text, jsonb, jsonb)'::regprocedure)
    AND to_regprocedure('public.compute_validate_rl_premium()') IS NULL,
    'is_a rules: the root keeps its rule trigger; the subtype''s rules are a SECURITY DEFINER function and no trigger');

-- =====================================================
-- A rule with a required key missing is refused when the entity is saved
-- =====================================================
-- The trigger builder checks the shape of each element before it writes
-- anything, so the save that would install a broken rule fails with the
-- catalog code of the missing key, the index of the element and the entity,
-- and the change is not made. A name or a code that is present but empty counts
-- as missing. Each assertion compares the code, the message and the parsed
-- hint; the DETAIL is empty for all of them.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

CREATE FUNCTION pg_temp.cv_refusal(p_sql TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT (catch_error(p_sql) - 'details') || jsonb_build_object('hint', catch_error_hint(p_sql))
$$;

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    validation_rules)
VALUES ('cv_shape_probe', 'cv_shape_probe', 'Shape Probe', 'Shape Probes', 'Rule-shape probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"code": "99020", "message": "kept", "jsonlogic": {"==": [1, 1]}}]'::jsonb);

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET computed_fields = '[{"name": "a", "jsonlogic": true}, {"jsonlogic": true}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90900", "message": "computed_fields[${index}] on ${table} is missing required \"name\"",
      "hint": {"index": 1, "table": "cv_shape_probe"}}'::jsonb,
    '90900: a computed field without a name is refused, naming its index and the entity');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET computed_fields = '[{"name": "", "jsonlogic": true}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90900", "message": "computed_fields[${index}] on ${table} is missing required \"name\"",
      "hint": {"index": 0, "table": "cv_shape_probe"}}'::jsonb,
    '90900: an empty name counts as missing');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET computed_fields = '[{"name": "a"}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90901", "message": "computed_fields[${index}] on ${table} is missing required \"jsonlogic\"",
      "hint": {"index": 0, "table": "cv_shape_probe"}}'::jsonb,
    '90901: a computed field without a rule is refused');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET validation_rules = '[{"code": "99020", "message": "m", "jsonlogic": {"==": [1, 1]}}, {"message": "m", "jsonlogic": {"==": [1, 1]}}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90902", "message": "validation_rules[${index}] on ${table} is missing required \"code\"",
      "hint": {"index": 1, "table": "cv_shape_probe"}}'::jsonb,
    '90902: a validation rule without a code is refused, naming its index and the entity');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET validation_rules = '[{"code": "", "message": "m", "jsonlogic": {"==": [1, 1]}}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90902", "message": "validation_rules[${index}] on ${table} is missing required \"code\"",
      "hint": {"index": 0, "table": "cv_shape_probe"}}'::jsonb,
    '90902: an empty code counts as missing');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET validation_rules = '[{"code": "99020", "jsonlogic": {"==": [1, 1]}}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90903", "message": "validation_rules[${index}] on ${table} is missing required \"message\"",
      "hint": {"index": 0, "table": "cv_shape_probe"}}'::jsonb,
    '90903: a validation rule without a message is refused');

SELECT is(
    pg_temp.cv_refusal($$UPDATE entities
        SET validation_rules = '[{"code": "99020", "message": "m"}]'::jsonb
      WHERE table_name = 'cv_shape_probe'$$),
    '{"code": "90904", "message": "validation_rules[${index}] on ${table} is missing required \"jsonlogic\"",
      "hint": {"index": 0, "table": "cv_shape_probe"}}'::jsonb,
    '90904: a validation rule without a rule body is refused');

SELECT ok(
    (SELECT computed_fields = '[]'::jsonb
        AND validation_rules = '[{"code": "99020", "message": "kept", "jsonlogic": {"==": [1, 1]}}]'::jsonb
       FROM entities WHERE table_name = 'cv_shape_probe')
    AND to_regprocedure('public.compute_validate_cv_shape_probe()') IS NOT NULL,
    'the refused saves left the entity with the rules it had, and its trigger function in place');

-- The same check on an insert: the new entity and its table are rolled back
-- with the refused statement.
SELECT is(
    pg_temp.cv_refusal($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                                                module_id, computed_fields)
        VALUES ('cv_shape_new', 'cv_shape_new', 'Shape New', 'Shape News', 'Refused at insert', 1,
                '[{"jsonlogic": true}]'::jsonb)$$),
    '{"code": "90900", "message": "computed_fields[${index}] on ${table} is missing required \"name\"",
      "hint": {"index": 0, "table": "cv_shape_new"}}'::jsonb,
    '90900: the same refusal on an insert');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'cv_shape_new')
    AND to_regclass('public.cv_shape_new') IS NULL,
    'and a refused insert leaves neither the entity row nor its table behind');

-- =====================================================
-- The hint of an error being re-raised
-- =====================================================
-- jl_error_hint merges the locating keys into the hint of an error a rule
-- raised. A hint that is not a JSON object - PostgreSQL's own advice is plain
-- text, and text that opens with a brace can still be malformed - is kept as
-- the "hint" key, and an object keeps every key it already has, so the entity
-- of the innermost failure wins. The function is the owner's.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is(
    public.jl_error_hint('Check the argument types', '{"entity": "e", "field": "f"}'::jsonb)::jsonb,
    '{"hint": "Check the argument types", "entity": "e", "field": "f"}'::jsonb,
    'a plain-text hint is kept under "hint" next to the added keys');

SELECT is(
    public.jl_error_hint('{oops', '{"entity": "e", "field": "f"}'::jsonb)::jsonb,
    '{"hint": "{oops", "entity": "e", "field": "f"}'::jsonb,
    'text that opens with a brace and is not JSON is kept as text too, and the cast failure raises nothing');

SELECT is(
    public.jl_error_hint('[1, 2]', '{"entity": "e", "field": "f"}'::jsonb)::jsonb,
    '{"hint": "[1, 2]", "entity": "e", "field": "f"}'::jsonb,
    'JSON that is not an object is kept as text as well');

SELECT is(
    public.jl_error_hint('{"entity": "inner", "code": "90101"}', '{"entity": "outer", "rule": "r"}'::jsonb)::jsonb,
    '{"entity": "inner", "code": "90101", "rule": "r"}'::jsonb,
    'an object hint keeps its own keys and gains only the missing ones');

SELECT is(
    public.jl_error_hint(NULL, '{"entity": "e", "rule": "r"}'::jsonb)::jsonb,
    '{"entity": "e", "rule": "r"}'::jsonb,
    'no hint at all gives just the added keys');

-- =====================================================
-- The builder asked about a name that is no entity
-- =====================================================
-- It drops whatever rule function and trigger function exist under that name
-- and leaves. No entity can leave them behind, so they are made by hand as the
-- owner; the builder runs as the dictionary's owner, which drops only what it
-- owns.

CREATE FUNCTION public.compute_validate_cv_stale() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RETURN NEW; END;
$$;
CREATE FUNCTION common.record_rules_cv_stale(p_mode text, p_old jsonb, p_data jsonb) RETURNS jsonb
    LANGUAGE sql AS $$ SELECT p_data $$;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER FUNCTION public.compute_validate_cv_stale() OWNER TO semantius_owner;
        ALTER FUNCTION common.record_rules_cv_stale(text, jsonb, jsonb) OWNER TO semantius_owner;
    END IF;
END $$;

SELECT ok(
    to_regprocedure('public.compute_validate_cv_stale()') IS NOT NULL
    AND to_regprocedure('common.record_rules_cv_stale(text, jsonb, jsonb)') IS NOT NULL,
    'no entity: the stale trigger function and rule function exist before the builder runs');

SELECT lives_ok($$ SELECT public.build_record_logic_trigger('cv_stale') $$,
    'no entity: the builder accepts a name the dictionary does not know');

SELECT ok(
    to_regprocedure('public.compute_validate_cv_stale()') IS NULL
    AND to_regprocedure('common.record_rules_cv_stale(text, jsonb, jsonb)') IS NULL,
    'no entity: and drops both generated functions');

SELECT * FROM finish();
ROLLBACK;
