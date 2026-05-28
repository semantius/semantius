-- Test module_slug validation
--
-- module_slug must be explicitly provided. The format is validated by a
-- JsonLogic rule on the modules entity (see 0200_module_slug_validation.sql).
-- Allowed: lowercase a-z, 0-9, '-', '_'. First character must be a-z or 0-9.
-- Empty string is allowed (column default).

BEGIN;

SELECT plan(21);

-- =====================================================
-- TEST: Seeded modules have correct module_slug values
-- =====================================================

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = '_core'),
    'admin',
    '_core module should have module_slug = "admin"'
);

-- =====================================================
-- TEST: Explicit module_slug is preserved verbatim
-- =====================================================

INSERT INTO modules (module_name, module_slug, description) VALUES ('Custom Slug Module', 'custom_slug', 'test');

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'Custom Slug Module'),
    'custom_slug',
    'module_slug provided explicitly is preserved verbatim'
);

-- =====================================================
-- TEST: No auto-generation — slug stays empty when not provided
-- =====================================================
-- Empty is allowed by validation. Only one row can hold the empty string
-- because the column is UNIQUE; this row consumes it for the test scope.

INSERT INTO modules (module_name, description) VALUES ('No Slug Module', 'no slug provided');

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'No Slug Module'),
    '',
    'module_slug stays empty when not provided (no auto-generation)'
);

-- =====================================================
-- TEST: Uniqueness still enforced
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Duplicate Test', 'custom_slug')$$,
    '23505',
    NULL,
    'duplicate module_slug raises a unique constraint error'
);

-- =====================================================
-- TEST: Valid slugs accepted
-- =====================================================

INSERT INTO modules (module_name, module_slug) VALUES ('Hyphen Module',      'my-module');
INSERT INTO modules (module_name, module_slug) VALUES ('Underscore Module',  'my_module');
INSERT INTO modules (module_name, module_slug) VALUES ('Mixed Module',       'my-cool_module');
INSERT INTO modules (module_name, module_slug) VALUES ('Single Letter',      'a');
INSERT INTO modules (module_name, module_slug) VALUES ('Starts With Digit',  '1app');
INSERT INTO modules (module_name, module_slug) VALUES ('Digits Only',        '123');
INSERT INTO modules (module_name, module_slug) VALUES ('Long Slug',          'a-very-long_slug-with-mixed_chars_123');

SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Hyphen Module'),     'my-module',                          'slug with hyphens is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Underscore Module'), 'my_module',                          'slug with underscores is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Mixed Module'),      'my-cool_module',                     'slug mixing hyphens and underscores is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Single Letter'),     'a',                                  'single-letter slug is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Starts With Digit'), '1app',                               'slug starting with a digit is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Digits Only'),       '123',                                'all-digit slug is accepted');
SELECT is((SELECT module_slug FROM modules WHERE module_name = 'Long Slug'),         'a-very-long_slug-with-mixed_chars_123', 'long mixed-char slug is accepted');

-- =====================================================
-- TEST: Invalid slugs rejected by JsonLogic validation
-- =====================================================
-- The JsonLogic validation rule raises with ERRCODE '23514' and a message
-- starting with "module_slug must be lowercase...".

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Leading Hyphen', '-invalid')$$,
    '%module_slug must be lowercase%',
    'slug starting with hyphen is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Leading Underscore', '_invalid')$$,
    '%module_slug must be lowercase%',
    'slug starting with underscore is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Uppercase Slug', 'Invalid')$$,
    '%module_slug must be lowercase%',
    'slug containing uppercase letters is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Special Chars', 'invalid!')$$,
    '%module_slug must be lowercase%',
    'slug containing special characters is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Space In Slug', 'invalid slug')$$,
    '%module_slug must be lowercase%',
    'slug containing a space is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Dot In Slug', 'invalid.slug')$$,
    '%module_slug must be lowercase%',
    'slug containing a dot is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Slash In Slug', 'invalid/slug')$$,
    '%module_slug must be lowercase%',
    'slug containing a slash is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Umlaut Slug', 'mödul')$$,
    '%module_slug must be lowercase%',
    'slug containing a non-ASCII letter (ä/ö/ü) is rejected'
);

SELECT throws_like(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Emoji Slug', 'happy☺')$$,
    '%module_slug must be lowercase%',
    'slug containing an emoji is rejected'
);

-- =====================================================
-- TEST: get_user_modules() returns module_slug
-- =====================================================

SELECT authenticate_as('user3');

SELECT ok(
    (SELECT module->>'module_slug' = 'admin'
     FROM jsonb_array_elements(public.get_user_modules()) AS module
     WHERE module->>'module_name' = '_core'
     LIMIT 1),
    'get_user_modules() returns module_slug = "admin" for the _core module'
);

SELECT * FROM finish();
ROLLBACK;
