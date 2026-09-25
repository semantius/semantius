-- Test the field format list.
--
-- dd_formats() (0120_dd_formats.sql) holds SemSchema's formats.json and is the only list of
-- formats in the database: valid_format, the fields.format enum_values and
-- format_to_json_type() are all derived from it, and get_schema() reports every
-- property's format. These assertions pin the derivations, not the list's
-- content, so a new formats.json needs no test change beyond the key count.
BEGIN;

SELECT plan(10);

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

SELECT * FROM finish();
ROLLBACK;
