-- Tests for entities.computed_fields and entities.validation_rules.
-- Verifies trigger generation, computed-field evaluation on INSERT/UPDATE,
-- reserved variables ($today, $now, $user_id), and validation-rule enforcement.
BEGIN;

SELECT plan(30);

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
        {"code": "release_only_when_committed",
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
    '23514',
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
    '23514',
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
    ('cv_reserved_test', 'writer_id', 'Writer Id', 'integer', 30);

INSERT INTO cv_reserved_test (label) VALUES ('probe');

SELECT is(
    (SELECT today_iso FROM cv_reserved_test WHERE label = 'probe'),
    CURRENT_DATE::text,
    '$today reserved variable resolves to server date');

SELECT ok(
    (SELECT now_iso FROM cv_reserved_test WHERE label = 'probe') LIKE
        to_char(CURRENT_DATE, 'YYYY-MM-DD') || '%',
    '$now reserved variable resolves to server timestamp (same date)');

SELECT is(
    (SELECT writer_id FROM cv_reserved_test WHERE label = 'probe'),
    rbac.user_id(),
    '$user_id reserved variable resolves to the writing user');

-- =====================================================
-- Test 2: invalid jsonlogic surfaces with rule name on evaluation
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('cv_bad_logic_test', 'cv_bad', 'Bad', 'Bad', 'Bad logic',
    1, 'public:read', 'admin', 'id', 'label',
    '[
        {"name": "broken", "jsonlogic": {"unknown_op": [1, 2]}}
    ]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('cv_bad_logic_test', 'broken', 'Broken', 'text', 10);

SELECT throws_like(
    $$INSERT INTO cv_bad_logic_test (label) VALUES ('boom')$$,
    '%computed_fields[broken]:%',
    'Evaluation error in computed field surfaces with rule name');

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

SELECT * FROM finish();
ROLLBACK;
