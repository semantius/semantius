-- Test module_slug auto-generation and uniqueness
BEGIN;

SELECT plan(9);

-- =====================================================
-- TEST: Seeded modules have auto-generated module_slug values
-- =====================================================

-- _core → auto-generated slug from '_core' = 'core' (leading underscore trimmed)
SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = '_core'),
    'core',
    '_core module should have module_slug = "core" (auto-generated from module_name)'
);

-- _public → auto-generated slug = 'public'
SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = '_public'),
    'public',
    '_public module should have module_slug = "public" (auto-generated from module_name)'
);

-- =====================================================
-- TEST: Auto-generation from module_name with spaces and special chars
-- =====================================================

-- Insert a module without providing module_slug
INSERT INTO modules (module_name, description) VALUES ('Test Module!', 'test');

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'Test Module!'),
    'test_module',
    'Module with spaces and special chars should get slug with underscores'
);

-- Insert a module with consecutive special characters to test underscore collapsing
INSERT INTO modules (module_name, description) VALUES ('Hello!!World', 'test consecutive special chars');

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'Hello!!World'),
    'hello_world',
    'Module with consecutive special chars should get slug with single underscores (collapsed)'
);

-- Insert a module with a manually specified module_slug
INSERT INTO modules (module_name, module_slug, description) VALUES ('Another Module', 'custom_slug', 'test');

SELECT is(
    (SELECT module_slug FROM modules WHERE module_name = 'Another Module'),
    'custom_slug',
    'Module with explicit module_slug should keep the provided value'
);

-- =====================================================
-- TEST: module_slug uniqueness constraint
-- =====================================================

-- Attempt to insert a module with a duplicate slug should fail
SELECT throws_ok(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Duplicate Test', 'custom_slug')$$,
    '23505',
    NULL,
    'duplicate module_slug should raise a unique constraint error'
);

-- =====================================================
-- TEST: module_slug is valid for URLs (only lowercase alphanumeric + underscores)
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO modules (module_name, module_slug) VALUES ('Invalid Slug Test', 'Invalid Slug!')$$,
    '23514',
    NULL,
    'invalid module_slug with uppercase and special chars should raise a check constraint error'
);

-- =====================================================
-- TEST: get_user_modules() returns module_slug
-- =====================================================

select authenticate_as('user3');

SELECT ok(
    (SELECT public.get_user_modules() @> '[{"module_name": "_core"}]'::jsonb),
    'get_user_modules() should return _core module for admin'
);

SELECT ok(
    (SELECT module->>'module_slug' IS NOT NULL AND module->>'module_slug' != ''
     FROM jsonb_array_elements(public.get_user_modules()) AS module
     WHERE module->>'module_name' = '_core'
     LIMIT 1),
    '_core module in get_user_modules() should have a non-empty module_slug'
);

SELECT * FROM finish();
ROLLBACK;
