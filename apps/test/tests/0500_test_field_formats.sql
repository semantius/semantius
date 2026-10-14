-- Field formats: the format list and what is derived from it, and the
-- jsonlogic format.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. The field format list
--   2. The jsonlogic format
--   3. The color, icon and rating formats
BEGIN;

SELECT plan(27);

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
    (SELECT count(*)::int FROM fmt_keys), 47,
    'dd_formats() should hold the 47 formats of formats.json'
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

-- =====================================================
-- PART 3: The color, icon and rating formats
-- =====================================================
-- Test the color, icon and rating field formats.
--
-- color and icon are TEXT and take any string (an icon is a lucide icon name or
-- a URL). rating is an INTEGER from 0 to 5, but by decision the database only
-- maps the column type: the range and "a required rating is not 0" are checked
-- by SemSchema, not by a CHECK constraint.
--
-- Fixtures: ONE ephemeral entity `cir_fmt_probe` created in-tx as user3 (module
-- _core, public:read / admin, managed) with a color, an icon, a rating and an
-- int32 field.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- The formats are in the list, right after enum
-- =====================================================
SELECT is(
    (SELECT array_agg(k ORDER BY n) FROM fmt_keys
      WHERE n > (SELECT n FROM fmt_keys WHERE k = 'enum')
        AND n <= (SELECT n FROM fmt_keys WHERE k = 'enum') + 3),
    ARRAY['color', 'icon', 'rating'],
    'dd_formats() should list color, icon and rating right after enum'
);

SELECT is(
    ARRAY[format_to_json_type('color')::text, format_to_json_type('icon')::text, format_to_json_type('rating')::text],
    ARRAY['"string"', '"string"', '"integer"'],
    'color and icon should be strings and rating an integer'
);

SELECT is(
    ARRAY[format_to_data_type('color'), format_to_data_type('icon'), format_to_data_type('rating')],
    ARRAY['TEXT', 'TEXT', 'INTEGER'],
    'color and icon should map to TEXT columns and rating to an INTEGER column'
);

-- =====================================================
-- Fields of each format on a managed entity
-- =====================================================
select authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES (
    'cir_fmt_probe', 'cir_fmt_probe', 'cir_fmt_probes', 'Format Probe', 'Format Probes',
    'Ephemeral probe for the color, icon and rating formats',
    1, 'public:read', 'admin', 'id', 'label', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
VALUES ('cir_fmt_probe', 'shade', 'Shade', 'color', 'default', 30),
       ('cir_fmt_probe', 'glyph', 'Glyph', 'icon', 'default', 40),
       ('cir_fmt_probe', 'stars', 'Stars', 'rating', 'required', 50),
       ('cir_fmt_probe', 'level', 'Level', 'int32', 'default', 60);

SELECT is(
    (SELECT jsonb_object_agg(column_name, jsonb_build_array(data_type, is_nullable, column_default))
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'cir_fmt_probe'
        AND column_name IN ('shade', 'glyph', 'stars')),
    jsonb_build_object(
        'shade', jsonb_build_array('text', 'NO', '''''::text'),
        'glyph', jsonb_build_array('text', 'NO', '''''::text'),
        'stars', jsonb_build_array('integer', 'NO', '0')
    ),
    'color and icon fields should create NOT NULL text columns defaulting to '''', a rating field a NOT NULL integer column defaulting to 0'
);

SELECT lives_ok(
    $$INSERT INTO cir_fmt_probe (label, shade, glyph, stars) VALUES ('probe', 'not a color name', '/icons/probe.svg', 7)$$,
    'the database should accept any string for color and icon and any integer for rating (no range CHECK)'
);

SELECT lives_ok(
    $$UPDATE fields SET format = 'rating' WHERE table_name = 'cir_fmt_probe' AND field_name = 'level'$$,
    'an int32 field should be changeable to rating'
);

SELECT is(
    (SELECT data_type FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'cir_fmt_probe' AND column_name = 'level'),
    'integer',
    'changing int32 to rating should keep the integer column'
);

SELECT is(
    (SELECT jsonb_object_agg(f, jsonb_build_array(s #>> ARRAY['properties', f, 'format'], s #>> ARRAY['properties', f, 'type']))
       FROM (SELECT public.get_schema('cir_fmt_probe')::jsonb AS s) AS schema,
            unnest(ARRAY['shade', 'glyph', 'stars', 'level']) AS f),
    '{"shade": ["color", "string"], "glyph": ["icon", "string"], "stars": ["rating", "integer"], "level": ["rating", "integer"]}'::jsonb,
    'get_schema should emit the format and type of color, icon and rating fields'
);

SELECT * FROM finish();
ROLLBACK;
