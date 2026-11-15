-- Field formats: the format list and what is derived from it, and the
-- jsonlogic format.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. The field format list
--   2. The jsonlogic format
--   3. The color, icon and rating formats
--   4. The string formats that only name a syntax
--   5. The time format
BEGIN;

SELECT plan(51);

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

-- =====================================================
-- PART 4: The string formats that only name a syntax
-- =====================================================
-- html, uri, uri-reference, uri-template, iri, iri-reference, email-like and
-- host-like names (idn-email, hostname, idn-hostname), ipv4, ipv6, regex,
-- json-pointer, json-pointer-uri-fragment, relative-json-pointer, byte and
-- password map to a TEXT column, like text: the dictionary stores the string and gives the format
-- to get_schema, and a client (SemSchema) checks the syntax. The column takes
-- any string, a required field refuses a blank one, and a default is the
-- column's default.
--
-- Fixtures: ONE ephemeral entity `txt_fmt_req` with a required field of each
-- format and an explicit default, and ONE `txt_fmt_opt` with an optional field
-- of each, both created in-tx as user3 (module _core, public:read / admin,
-- managed).

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- One row per format: a value that is valid for it (also the field's default),
-- a second valid value, and a value that is not valid for it.
CREATE TEMP TABLE fmt_samples (ord INTEGER PRIMARY KEY, field_name TEXT, format TEXT, good TEXT, alt TEXT, odd TEXT);
INSERT INTO fmt_samples VALUES
    (1,  'f_html',    'html',                      '<p>Hello</p>',              '<b>bold</b>',                'no tag at all'),
    (2,  'f_uri',     'uri',                       'https://example.com/a?b=c', 'urn:isbn:0451450523',        'not a uri'),
    (3,  'f_uriref',  'uri-reference',             '/a/b?c=d#e',                '../up',                      'http://[bad'),
    (4,  'f_uritpl',  'uri-template',              '/users/{id}{?page}',        'https://example.com/{+path}', '/users/{id'),
    (5,  'f_ipv4',    'ipv4',                      '192.168.0.1',               '10.0.0.255',                 '999.1.1.1'),
    (6,  'f_ipv6',    'ipv6',                      '2001:db8::1',               '::1',                        'not:an:address'),
    (7,  'f_regex',   'regex',                     '^[a-z]+\d{2,}$',            '(a|b)*',                     '(unclosed'),
    (8,  'f_jptr',    'json-pointer',              '/a/0/b~1c',                 '/x',                         'no leading slash'),
    (9,  'f_jptrfr',  'json-pointer-uri-fragment', '#/a/0',                     '#/b',                        'x'),
    (10, 'f_rjptr',   'relative-json-pointer',     '1/a',                       '0#',                         '/absolute'),
    (11, 'f_byte',    'byte',                      'SGVsbG8gd29ybGQ=',          'AAECAw==',                   '!!!not base64'),
    (12, 'f_pw',      'password',                  's3cr3t-p@ss',               'another secret',             'x'),
    (13, 'f_iri',     'iri',                       U&'https://m\00FCller.de/stra\00DFe', 'urn:example:a',      'not an iri'),
    (14, 'f_iriref',  'iri-reference',             U&'/stra\00DFe#top',         '../up',                      'http://[bad'),
    (15, 'f_idnmail', 'idn-email',                 U&'j\00F6rg@m\00FCller.de',  'a@b.example',                'not an email'),
    (16, 'f_host',    'hostname',                  'example.com',               'xn--mller-kva.de',           'not a host name!'),
    (17, 'f_idnhost', 'idn-hostname',              U&'m\00FCller.de',           'example.org',                '-bad-');
GRANT SELECT ON fmt_samples TO PUBLIC;

SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES
    ('txt_fmt_req', 'txt_fmt_req', 'txt_fmt_reqs', 'Required Probe', 'Required Probes',
     'Ephemeral probe for the string formats, required fields', 1, 'public:read', 'admin', 'id', 'label', TRUE),
    ('txt_fmt_opt', 'txt_fmt_opt', 'txt_fmt_opts', 'Optional Probe', 'Optional Probes',
     'Ephemeral probe for the string formats, optional fields', 1, 'public:read', 'admin', 'id', 'label', TRUE);

INSERT INTO fields (table_name, field_name, title, format, input_type, default_value, field_order)
SELECT 'txt_fmt_req', field_name, 'Probe ' || format, format, 'required', good, 20 + ord * 10
  FROM fmt_samples;

INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
SELECT 'txt_fmt_opt', field_name, 'Probe ' || format, format, 'default', 20 + ord * 10
  FROM fmt_samples;

-- =====================================================
-- The column and its default
-- =====================================================
SELECT is(
    (SELECT jsonb_object_agg(column_name, jsonb_build_array(data_type, is_nullable, column_default))
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'txt_fmt_req'
        AND column_name IN (SELECT field_name FROM fmt_samples)),
    (SELECT jsonb_object_agg(field_name,
                jsonb_build_array('text', 'NO', '''' || replace(good, '''', '''''') || '''::text'))
       FROM fmt_samples),
    'a required string-format field should create a NOT NULL text column defaulting to its default_value'
);

SELECT is(
    (SELECT jsonb_object_agg(column_name, jsonb_build_array(data_type, is_nullable, column_default))
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'txt_fmt_opt'
        AND column_name IN (SELECT field_name FROM fmt_samples)),
    (SELECT jsonb_object_agg(field_name, jsonb_build_array('text', 'NO', '''''::text')) FROM fmt_samples),
    'an optional string-format field should create a NOT NULL text column defaulting to '''''
);

INSERT INTO txt_fmt_req (label) VALUES ('defaults');
INSERT INTO txt_fmt_opt (label) VALUES ('defaults');

SELECT is(
    (SELECT to_jsonb(p) - ARRAY['id', 'label', 'created_at', 'updated_at', 'search_vector']
       FROM txt_fmt_req p WHERE label = 'defaults'),
    (SELECT jsonb_object_agg(field_name, good) FROM fmt_samples),
    'a row that leaves out the required string-format fields should get their defaults'
);

SELECT is(
    (SELECT to_jsonb(p) - ARRAY['id', 'label', 'created_at', 'updated_at', 'search_vector']
       FROM txt_fmt_opt p WHERE label = 'defaults'),
    (SELECT jsonb_object_agg(field_name, '') FROM fmt_samples),
    'a row that leaves out the optional string-format fields should get the empty string'
);

-- =====================================================
-- Writing and reading a value
-- =====================================================
SELECT lives_ok(
    (SELECT format('INSERT INTO txt_fmt_req (label, %s) VALUES (%L, %s)',
                   string_agg(quote_ident(field_name), ', ' ORDER BY ord), 'written',
                   string_agg(quote_literal(alt), ', ' ORDER BY ord))
       FROM fmt_samples),
    'a value valid for each string format should be accepted'
);

SELECT is(
    (SELECT to_jsonb(p) - ARRAY['id', 'label', 'created_at', 'updated_at', 'search_vector']
       FROM txt_fmt_req p WHERE label = 'written'),
    (SELECT jsonb_object_agg(field_name, alt) FROM fmt_samples),
    'a value written to a string-format field should be read back unchanged'
);

SELECT is(
    (SELECT jsonb_object_agg(f.field_name, p.value ->> 'format')
       FROM fmt_samples f,
            LATERAL (SELECT (public.get_schema('txt_fmt_req')::jsonb -> 'properties') -> f.field_name AS value) p),
    (SELECT jsonb_object_agg(field_name, format) FROM fmt_samples),
    'get_schema should emit the format of each string-format property'
);

SELECT is(
    (SELECT jsonb_object_agg(f.field_name, jsonb_build_array(p.value ->> 'type', p.value ->> 'default'))
       FROM fmt_samples f,
            LATERAL (SELECT (public.get_schema('txt_fmt_req')::jsonb -> 'properties') -> f.field_name AS value) p),
    (SELECT jsonb_object_agg(field_name, jsonb_build_array('string', good)) FROM fmt_samples),
    'get_schema should emit type string and the default of each string-format property'
);

-- By decision the database only maps the column type, as for color, icon and
-- rating above: a value that is not valid for its format is stored as written,
-- and SemSchema is what checks the syntax.
SELECT lives_ok(
    (SELECT format('INSERT INTO txt_fmt_req (label, %s) VALUES (%L, %s)',
                   string_agg(quote_ident(field_name), ', ' ORDER BY ord), 'odd',
                   string_agg(quote_literal(odd), ', ' ORDER BY ord))
       FROM fmt_samples),
    'the database should accept a value that is not valid for its string format'
);

SELECT is(
    (SELECT to_jsonb(p) - ARRAY['id', 'label', 'created_at', 'updated_at', 'search_vector']
       FROM txt_fmt_req p WHERE label = 'odd'),
    (SELECT jsonb_object_agg(field_name, odd) FROM fmt_samples),
    'a value that is not valid for its string format should be read back unchanged'
);

-- =====================================================
-- Required
-- =====================================================
-- A blank value of one field, every other field holding a valid value. The
-- check names the field that was blank.
SELECT is(
    (SELECT string_agg(t.field_name || '=' || coalesce(c.e ->> 'code', 'none') || ' ' ||
                       coalesce((c.e ->> 'hint')::jsonb ->> 'field_name', ''), ', ' ORDER BY t.ord)
       FROM fmt_samples t
       CROSS JOIN LATERAL (
           SELECT format('INSERT INTO txt_fmt_req (label, %s) VALUES (%L, %s)',
                         string_agg(quote_ident(s.field_name), ', ' ORDER BY s.ord), 'blank',
                         string_agg(quote_literal(CASE WHEN s.field_name = t.field_name THEN '' ELSE s.good END),
                                    ', ' ORDER BY s.ord)) AS q
             FROM fmt_samples s) b
       CROSS JOIN LATERAL (SELECT catch_error(b.q) AS e) c),
    (SELECT string_agg(field_name || '=90258 ' || field_name, ', ' ORDER BY ord) FROM fmt_samples),
    'a required string-format field should refuse a blank value with 90258 naming the field'
);

SELECT is(
    catch_error($$INSERT INTO txt_fmt_req (label, f_html) VALUES ('blank', '   ')$$) ->> 'message',
    'Field ${field_name} on ${table} is required',
    'a required string-format field should refuse a value of only spaces'
);

SELECT lives_ok(
    $$INSERT INTO txt_fmt_opt (label, f_html, f_ipv4, f_byte) VALUES ('blank', '', '', '')$$,
    'an optional string-format field should accept a blank value'
);

-- =====================================================
-- PART 5: The time format
-- =====================================================
-- time is a TIME column: unlike the string formats, the database checks the
-- value.
--
-- Fixtures: `tm_fmt_probe` with an optional and a required time field, both
-- with a default, `tm_fmt_bare` with one time field and no default, and
-- `tm_fmt_rows`, a table with rows that time fields are added to; all created
-- in-tx as user3.

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES
    ('tm_fmt_probe', 'tm_fmt_probe', 'tm_fmt_probes', 'Time Probe', 'Time Probes',
     'Ephemeral probe for the time format', 1, 'public:read', 'admin', 'id', 'label', TRUE),
    ('tm_fmt_bare', 'tm_fmt_bare', 'tm_fmt_bares', 'Bare Time Probe', 'Bare Time Probes',
     'Ephemeral probe for a time field without a default', 1, 'public:read', 'admin', 'id', 'label', TRUE),
    ('tm_fmt_rows', 'tm_fmt_rows', 'tm_fmt_rowss', 'Rows Time Probe', 'Rows Time Probes',
     'Ephemeral table with rows that time fields are added to', 1, 'public:read', 'admin', 'id', 'label', TRUE);

INSERT INTO fields (table_name, field_name, title, format, input_type, default_value, field_order)
VALUES ('tm_fmt_probe', 't_open', 'Opens', 'time', 'default', '09:30', 30),
       ('tm_fmt_probe', 't_close', 'Closes', 'time', 'required', '12:00', 40);

SELECT is(
    (SELECT jsonb_object_agg(column_name, jsonb_build_array(data_type, is_nullable, column_default))
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'tm_fmt_probe' AND column_name IN ('t_open', 't_close')),
    jsonb_build_object(
        't_open',  jsonb_build_array('time without time zone', 'YES', '''09:30:00''::time without time zone'),
        't_close', jsonb_build_array('time without time zone', 'YES', '''12:00:00''::time without time zone')
    ),
    'a time field should create a nullable time column defaulting to its default_value'
);

INSERT INTO tm_fmt_probe (label) VALUES ('defaults');

SELECT is(
    (SELECT t_open::text || ' ' || t_close::text FROM tm_fmt_probe WHERE label = 'defaults'),
    '09:30:00 12:00:00',
    'a row that leaves out the time fields should get their defaults'
);

INSERT INTO tm_fmt_probe (label, t_open, t_close) VALUES ('written', '14:30:00', '23:59:59.5');

SELECT is(
    (SELECT t_open::text || ' ' || t_close::text FROM tm_fmt_probe WHERE label = 'written'),
    '14:30:00 23:59:59.5',
    'a time written to a time field should be read back, fractional seconds included'
);

-- The format's own example, RFC 3339 with a zone: the TIME column keeps the
-- time of day and drops the zone.
INSERT INTO tm_fmt_probe (label, t_open) VALUES ('zoned', '14:30:00Z');

SELECT is(
    (SELECT t_open::text FROM tm_fmt_probe WHERE label = 'zoned'),
    '14:30:00',
    'a time field should accept the RFC 3339 example 14:30:00Z and keep 14:30:00'
);

SELECT is(
    catch_error($$INSERT INTO tm_fmt_probe (label, t_open) VALUES ('bad', 'not a time')$$) -> 'message',
    to_jsonb('invalid input syntax for type time: "not a time"'::text),
    'a time field should refuse text that is not a time'
);

SELECT is(
    catch_error($$INSERT INTO tm_fmt_probe (label, t_open) VALUES ('bad', '25:00:00')$$) ->> 'code',
    '22008',
    'a time field should refuse a time of day out of range'
);

SELECT is(
    (SELECT jsonb_build_array(p ->> 'format', p ->> 'type', p ->> 'default')
       FROM (SELECT (public.get_schema('tm_fmt_probe')::jsonb -> 'properties') -> 't_open' AS p) s),
    '["time", "string", "09:30"]'::jsonb,
    'get_schema should emit format time, type string and the default of a time property'
);

-- A time has no zero value: midnight is a time of day like any other. So the
-- column is nullable, as a date column is, and NULL means that no time was
-- given. A time field with no default_value therefore takes a row that leaves
-- it out. A required one cannot be added to a table that has rows unless it
-- brings a default, as for every required field: the rows that are there
-- would have no value for it.
INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
VALUES ('tm_fmt_bare', 't_open', 'Opens', 'time', 'default', 30);

SELECT lives_ok(
    $$INSERT INTO tm_fmt_bare (label) VALUES ('without a time')$$,
    'a time field without a default_value should take a row that leaves it out'
);

INSERT INTO tm_fmt_rows (label) VALUES ('first'), ('second');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
      VALUES ('tm_fmt_rows', 't_close', 'Closes', 'time', 'required', 30)$$,
    '90259', NULL,
    'a required time field without a default_value should be refused on a table that has rows'
);

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, input_type, default_value, field_order)
      VALUES ('tm_fmt_rows', 't_start', 'Starts', 'time', 'required', '09:30', 40)$$,
    'a required time field with a default_value should be added to a table that has rows'
);

SELECT is(
    (SELECT string_agg(t_start::text, ', ' ORDER BY id) FROM tm_fmt_rows),
    '09:30:00, 09:30:00',
    'the rows that were there should take the default of a time field added later'
);

SELECT * FROM finish();
ROLLBACK;
