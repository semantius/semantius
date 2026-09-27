-- Test enum default-value and allowed-value handling
-- Validates the four required×default permutations described in the
-- "huge gaps" issue:
--
--   1. NOT required + explicit default  → CHECK includes '', column DEFAULT is the explicit value
--   2. NOT required + no explicit default → CHECK includes '', column DEFAULT is ''
--   3. required + explicit default       → CHECK does NOT include '', column DEFAULT is the explicit value
--   4. required + no explicit default    → CHECK does NOT include '', column DEFAULT is the first enum value
--
-- These four scenarios are exercised by creating a dedicated entity with
-- four enum fields and inspecting the resulting CHECK constraints, column
-- defaults, and the JSON Schema produced by get_schema().
--
-- Also verifies that the enum column COMMENT carries the allowed-value list
-- ("<title> (enum)" + description + values) and re-syncs on enum_values UPDATE.
--
-- Last, entries that are {value, label} pairs: only the value reaches the CHECK
-- constraint, the column default and the comment, while get_schema() returns
-- the entries as stored, with '' appended for a non-required enum as before.
BEGIN;

SELECT plan(36);

-- Authenticate as admin user so we can create entities/fields
SELECT authenticate_as('user3');

-- Create a dedicated test entity for these scenarios
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    module_id, view_permission, edit_permission, id_column, label_column
)
VALUES (
    'enum_default_test',
    'Enum Default Test',
    'enum_default_test',
    'Enum Default Test',
    'Enum Default Tests',
    1,
    'public:read',
    'admin',
    'id',
    'label'
);

-- Scenario 1: NOT required + explicit default (carries a description so the
-- three-part column COMMENT format is exercised below)
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value, description)
VALUES ('enum_default_test', 'status_optional_with_default', 'Status', 'enum',
        'default', '["active", "inactive"]'::jsonb, 'inactive',
        'Account status (active, inactive, etc.)');

-- Scenario 2: NOT required + no explicit default
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'status_optional_no_default', 'Status', 'enum',
        'default', '["red", "green", "blue"]'::jsonb, '');

-- Scenario 3: required + explicit default
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'status_required_with_default', 'Status', 'enum',
        'required', '["low", "medium", "high"]'::jsonb, 'high');

-- Scenario 4: required + no explicit default
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'status_required_no_default', 'Status', 'enum',
        'required', '["draft", "published", "archived"]'::jsonb, '');

-- =====================================================
-- CHECK constraints
-- =====================================================

-- Scenario 1: CHECK should include '' (non-required)
SELECT ok(
    pg_get_constraintdef((SELECT oid FROM pg_constraint
        WHERE conname = 'enum_default_test_status_optional_with_default_check')) LIKE '%''''%',
    'NOT required enum (with default) CHECK should include empty string'
);

-- Scenario 2: CHECK should include ''
SELECT ok(
    pg_get_constraintdef((SELECT oid FROM pg_constraint
        WHERE conname = 'enum_default_test_status_optional_no_default_check')) LIKE '%''''%',
    'NOT required enum (no default) CHECK should include empty string'
);

-- Scenario 3: CHECK should NOT include '' (required)
SELECT ok(
    pg_get_constraintdef((SELECT oid FROM pg_constraint
        WHERE conname = 'enum_default_test_status_required_with_default_check')) NOT LIKE '%''''%',
    'required enum (with default) CHECK should NOT include empty string'
);

-- Scenario 4: CHECK should NOT include ''
SELECT ok(
    pg_get_constraintdef((SELECT oid FROM pg_constraint
        WHERE conname = 'enum_default_test_status_required_no_default_check')) NOT LIKE '%''''%',
    'required enum (no default) CHECK should NOT include empty string'
);

-- =====================================================
-- Column DEFAULT values (PostgreSQL-side)
-- =====================================================

SELECT is(
    (SELECT column_default FROM information_schema.columns
       WHERE table_name = 'enum_default_test' AND column_name = 'status_optional_with_default'),
    '''inactive''::text',
    'NOT required enum (with default) column default should be the explicit value'
);

SELECT is(
    (SELECT column_default FROM information_schema.columns
       WHERE table_name = 'enum_default_test' AND column_name = 'status_optional_no_default'),
    '''''::text',
    'NOT required enum (no default) column default should be empty string'
);

SELECT is(
    (SELECT column_default FROM information_schema.columns
       WHERE table_name = 'enum_default_test' AND column_name = 'status_required_with_default'),
    '''high''::text',
    'required enum (with default) column default should be the explicit value'
);

SELECT is(
    (SELECT column_default FROM information_schema.columns
       WHERE table_name = 'enum_default_test' AND column_name = 'status_required_no_default'),
    '''draft''::text',
    'required enum (no default, required) column default should be the first enum value'
);

-- =====================================================
-- INSERT behavior — empty string allowed only for non-required enums
-- =====================================================

-- Scenario 1: Empty string should be accepted (non-required)
SELECT lives_ok(
    $$INSERT INTO enum_default_test (label, status_optional_with_default,
            status_required_with_default, status_required_no_default)
      VALUES ('row1', '', 'high', 'draft')$$,
    'NOT required enum (with default) should accept empty string'
);

-- Scenario 2: Empty string should be accepted
SELECT lives_ok(
    $$INSERT INTO enum_default_test (label, status_optional_no_default,
            status_required_with_default, status_required_no_default)
      VALUES ('row2', '', 'high', 'draft')$$,
    'NOT required enum (no default) should accept empty string'
);

-- Scenario 3: Empty string should be rejected for required enums
SELECT throws_ok(
    $$INSERT INTO enum_default_test (label, status_required_with_default,
            status_required_no_default)
      VALUES ('row3', '', 'draft')$$,
    '23514',
    NULL,
    'required enum (with default) should reject empty string'
);

SELECT throws_ok(
    $$INSERT INTO enum_default_test (label, status_required_no_default,
            status_required_with_default)
      VALUES ('row4', '', 'high')$$,
    '23514',
    NULL,
    'required enum (no default) should reject empty string'
);

-- =====================================================
-- Default-value behavior — fall back when column omitted from INSERT
-- =====================================================

-- Insert a row that omits all four enum columns; the column DEFAULTs should kick in
INSERT INTO enum_default_test (label) VALUES ('row_defaults');

SELECT is(
    (SELECT status_optional_with_default FROM enum_default_test WHERE label = 'row_defaults'),
    'inactive',
    'NOT required enum (with default) should default to the explicit value'
);

SELECT is(
    (SELECT status_optional_no_default FROM enum_default_test WHERE label = 'row_defaults'),
    '',
    'NOT required enum (no default) should default to empty string'
);

SELECT is(
    (SELECT status_required_with_default FROM enum_default_test WHERE label = 'row_defaults'),
    'high',
    'required enum (with default) should default to the explicit value'
);

SELECT is(
    (SELECT status_required_no_default FROM enum_default_test WHERE label = 'row_defaults'),
    'draft',
    'required enum (no default) should default to the first enum value'
);

-- =====================================================
-- get_schema() should reflect the effective enum/default
-- =====================================================

SELECT ok(
    (public.get_schema('enum_default_test')::jsonb)
        ->'properties'->'status_optional_no_default'->'enum' @> '[""]'::jsonb,
    'get_schema() includes "" in enum array for NOT required enum'
);

SELECT ok(
    NOT ((public.get_schema('enum_default_test')::jsonb)
        ->'properties'->'status_required_no_default'->'enum' @> '[""]'::jsonb),
    'get_schema() does NOT include "" in enum array for required enum'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)
        ->'properties'->'status_required_no_default'->>'default',
    'draft',
    'get_schema() default for required enum without explicit default is the first enum value'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)
        ->'properties'->'status_optional_no_default'->>'default',
    '',
    'get_schema() default for NOT required enum without explicit default is empty string'
);

-- =====================================================
-- Enum column COMMENT carries the allowed value list
-- =====================================================

-- On create, the comment is "<title> (enum)" + description + comma-separated
-- allowed values (the declared list, without the implicit '' for non-required).
SELECT is(
    col_description(
        'public.enum_default_test'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'public.enum_default_test'::regclass
           AND attname = 'status_optional_with_default')
    ),
    E'Status (enum)\n\nAccount status (active, inactive, etc.)\n\nactive, inactive',
    'Enum column comment = "title (enum)" + description + comma-separated allowed values'
);

-- Updating enum_values re-syncs the value list in the column comment
UPDATE fields
SET enum_values = '["active", "inactive", "archived"]'::jsonb
WHERE table_name = 'enum_default_test' AND field_name = 'status_optional_with_default';

SELECT is(
    col_description(
        'public.enum_default_test'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'public.enum_default_test'::regclass
           AND attname = 'status_optional_with_default')
    ),
    E'Status (enum)\n\nAccount status (active, inactive, etc.)\n\nactive, inactive, archived',
    'Enum column comment value list re-syncs when enum_values changes'
);

-- =====================================================
-- {value, label} entries
-- =====================================================

SELECT is(
    enum_value_list('["a", {"value": "b", "label": "B"}]'::jsonb),
    '["a", "b"]'::jsonb,
    'enum_value_list takes the value of a pair and a plain entry as it is'
);

-- Required, no default, the first entry a pair; plain and pair entries mixed
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'priority', 'Priority', 'enum', 'required',
        '[{"value": "p1", "label": "Urgent"}, "p2", {"value": "p3", "label": "Low"}]'::jsonb, '');

-- Not required, pairs only
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'stage', 'Stage', 'enum', 'default',
        '[{"value": "open", "label": "Open"}, {"value": "closed", "label": "Closed"}]'::jsonb, '');

-- Not required, and the empty value itself carries a label
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value)
VALUES ('enum_default_test', 'choice', 'Choice', 'enum', 'default',
        '[{"value": "", "label": "None"}, {"value": "yes", "label": "Yes"}]'::jsonb, '');

SELECT is(
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'enum_default_test_stage_check')),
    $$CHECK ((stage = ANY (ARRAY['open'::text, 'closed'::text, ''::text])))$$,
    'the CHECK of a labeled enum holds the values, plus '''' when not required'
);

SELECT is(
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'enum_default_test_choice_check')),
    $$CHECK ((choice = ANY (ARRAY[''::text, 'yes'::text])))$$,
    'a labeled '''' entry counts as the empty value, which is not added a second time'
);

SELECT is(
    (SELECT column_default FROM information_schema.columns
       WHERE table_name = 'enum_default_test' AND column_name = 'priority'),
    '''p1''::text',
    'required labeled enum without default: column default is the value of the first entry'
);

SELECT lives_ok(
    $$INSERT INTO enum_default_test (label, priority, stage, choice) VALUES ('row_labels', 'p3', 'closed', '')$$,
    'the values of labeled entries are accepted'
);

SELECT throws_ok(
    $$INSERT INTO enum_default_test (label, priority) VALUES ('row_label_text', 'Urgent')$$,
    '23514',
    NULL,
    'a label is not a value'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)->'properties'->'priority'->'enum',
    '[{"value": "p1", "label": "Urgent"}, "p2", {"value": "p3", "label": "Low"}]'::jsonb,
    'get_schema() returns the entries of a required enum as stored'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)->'properties'->'priority'->>'default',
    'p1',
    'get_schema() default of a required labeled enum is the value of the first entry'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)->'properties'->'stage'->'enum',
    '[{"value": "open", "label": "Open"}, {"value": "closed", "label": "Closed"}, ""]'::jsonb,
    'get_schema() appends "" to the entries of a non-required enum'
);

SELECT is(
    (public.get_schema('enum_default_test')::jsonb)->'properties'->'choice'->'enum',
    '[{"value": "", "label": "None"}, {"value": "yes", "label": "Yes"}]'::jsonb,
    'get_schema() does not append "" when a labeled entry already has the empty value'
);

SELECT is(
    col_description(
        'public.enum_default_test'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'public.enum_default_test'::regclass
           AND attname = 'stage')
    ),
    E'Stage (enum)\n\nopen, closed',
    'the column comment lists the values of labeled entries'
);

-- The core enums whose values are codes carry labels, and their hand-written
-- CHECK constraints (0150_dd_bootstrap.once.sql) still hold the values alone.
SELECT is(
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'valid_width')),
    $$CHECK ((width = ANY ('{default,s,m,w}'::text[])))$$,
    'valid_width holds the values of the labeled fields.width enum'
);

SELECT is(
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'valid_ctype')),
    $$CHECK ((ctype = ANY ('{"",id,label,audit,core}'::text[])))$$,
    'valid_ctype holds the values of the labeled fields.ctype enum'
);

SELECT is(
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'valid_reference_delete_mode')),
    $$CHECK ((reference_delete_mode = ANY ('{"",restrict,clear,cascade}'::text[])))$$,
    'valid_reference_delete_mode holds the values of the labeled fields.reference_delete_mode enum'
);

SELECT * FROM finish();
ROLLBACK;
