-- Field formats: the format list and what is derived from it, and the
-- jsonlogic format.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. The field format list
--   2. The jsonlogic format
BEGIN;

SELECT plan(19);

-- =====================================================
-- PART 1: The field format list
-- =====================================================
-- Test the field format list.
--
-- dd_formats() (0120_dd_formats.sql) holds SemSchema's formats.json and is the only list of
-- formats in the database: valid_format, the fields.format enum_values and
-- format_to_json_type() are all derived from it, and get_schema() reports every
-- property's format. These assertions pin the derivations, not the list's
-- content, so a new formats.json needs no test change beyond the key count.

-- The ordered key list, captured as the owner: dd_formats() is not granted to
-- the request role, and the get_schema() checks below run as user3.
CREATE TEMP TABLE fmt_keys ON COMMIT DROP AS
    SELECT k, n FROM json_object_keys(dd_formats()) WITH ORDINALITY AS t(k, n);
GRANT SELECT ON fmt_keys TO PUBLIC;

-- =====================================================
-- The list
-- =====================================================
SELECT is(
    (SELECT count(*)::int FROM fmt_keys), 44,
    'dd_formats() should hold the 44 formats of formats.json'
);

SELECT ok(
    (SELECT array_agg(k) FROM fmt_keys) @> ARRAY['iri', 'iri-reference', 'idn-email', 'idn-hostname'],
    'dd_formats() should include iri, iri-reference, idn-email and idn-hostname'
);

SELECT ok(
    NOT (dd_formats()::jsonb ? 'null'),
    'dd_formats() should not include null'
);

-- =====================================================
-- format_to_json_type() reads the types from the list
-- =====================================================
SELECT is_empty(
    $$ SELECT k FROM fmt_keys WHERE format_to_json_type(k) IS DISTINCT FROM dd_formats()::jsonb -> k -> 'type' $$,
    'format_to_json_type() should return the list''s type for every format'
);

SELECT ok(
    format_to_json_type('null') IS NULL,
    'format_to_json_type(''null'') should be NULL'
);

-- =====================================================
-- valid_format and the enum are built from the list
-- =====================================================
SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'fields' AND field_name = 'format'),
    (SELECT jsonb_agg(k ORDER BY n) FROM fmt_keys),
    'fields.format enum_values should be the list''s keys in order'
);

SELECT is(
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid = 'public.fields'::regclass AND conname = 'valid_format'),
    format('CHECK ((format = ANY (%L::text[])))', (SELECT array_agg(k ORDER BY n) FROM fmt_keys)),
    'valid_format should allow exactly the list''s keys'
);

SELECT throws_ok(
    $$ INSERT INTO fields (table_name, field_name, title, format) VALUES ('users', 'fmt_null_probe', 'Probe', 'null') $$,
    '23514',
    'new row for relation "fields" violates check constraint "valid_format"',
    'a field with format null should be refused by valid_format'
);

-- =====================================================
-- get_schema() publishes the enum and every property's format
-- =====================================================
select authenticate_as('user3');

SELECT is(
    (public.get_schema('fields')::jsonb) -> 'properties' -> 'format' -> 'enum',
    (SELECT jsonb_agg(k ORDER BY n) FROM fmt_keys),
    'get_schema(''fields'') should offer the list''s keys as the format enum'
);

SELECT is_empty(
    $$ SELECT f.field_name FROM fields f
        WHERE f.table_name = 'fields'
          AND (public.get_schema('fields')::jsonb) -> 'properties' -> f.field_name ->> 'format' IS DISTINCT FROM f.format $$,
    'every get_schema(''fields'') property with a fields row should carry that row''s format'
);

-- =====================================================
-- PART 2: The jsonlogic format
-- =====================================================
-- Test the jsonlogic field format.
--
-- jsonlogic sits next to jsonata as a custom format, but it is stored like json:
-- a JsonLogic rule is a JSON value that evaluate_json_logic() walks as jsonb,
-- while a JSONata expression is source text. The dictionary's own rule columns
-- carry the format so a UI can offer a rule editor instead of a raw JSON box.
--
-- Fixtures: ONE ephemeral entity `jl_fmt_probe` created in-tx as user3 (module
-- _core, public:read / admin, managed) with a single jsonlogic field.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- The format is known to the dictionary
-- =====================================================
SELECT ok(
    (SELECT enum_values ? 'jsonlogic' FROM fields WHERE table_name = 'fields' AND field_name = 'format'),
    'fields.format enum_values should list jsonlogic'
);

SELECT is(
    format_to_data_type('jsonlogic'), 'JSONB',
    'jsonlogic should map to a JSONB column'
);

SELECT is(
    format_to_json_type('jsonlogic'), format_to_json_type('json'),
    'jsonlogic should accept any JSON type, like json'
);

-- =====================================================
-- The dictionary columns that hold JsonLogic use it
-- =====================================================
SELECT set_eq(
    $$SELECT id FROM fields WHERE format = 'jsonlogic' AND table_name IN ('entities', 'fields')$$,
    ARRAY['entities.computed_fields', 'entities.validation_rules', 'entities.select_rule', 'fields.input_type_rule'],
    'the four JsonLogic rule columns should have format jsonlogic'
);

-- =====================================================
-- A jsonlogic field on a managed entity
-- =====================================================
select authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES (
    'jl_fmt_probe', 'jl_fmt_probe', 'jl_fmt_probes', 'JsonLogic Probe', 'JsonLogic Probes',
    'Ephemeral probe for the jsonlogic format',
    1, 'public:read', 'admin', 'id', 'label', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
VALUES ('jl_fmt_probe', 'rule', 'Rule', 'jsonlogic', 'default', 30);

SELECT is(
    (SELECT data_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'jl_fmt_probe' AND column_name = 'rule'),
    'jsonb',
    'a jsonlogic field should create a jsonb column'
);

SELECT is(
    public.get_schema('jl_fmt_probe')::jsonb #>> '{properties,rule,format}',
    'jsonlogic',
    'get_schema should emit format jsonlogic'
);

SELECT is(
    public.get_schema('jl_fmt_probe')::jsonb #> '{properties,rule,default}',
    '{}'::jsonb,
    'get_schema should default a jsonlogic property to {} like json'
);

SELECT ok(
    NOT (public.get_schema('jl_fmt_probe')::jsonb -> 'required') ? 'rule',
    'a jsonlogic property should not be required, like json'
);

INSERT INTO jl_fmt_probe (label, rule) VALUES ('probe', '{"==":[{"var":"label"},"probe"]}');

SELECT is(
    (SELECT evaluate_json_logic(rule, to_jsonb(p)) FROM jl_fmt_probe p WHERE label = 'probe'),
    'true'::jsonb,
    'a stored jsonlogic value should evaluate as a rule'
);

SELECT * FROM finish();
ROLLBACK;
