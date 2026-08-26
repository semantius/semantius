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
BEGIN;

SELECT plan(22);

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

SELECT * FROM finish();
ROLLBACK;
