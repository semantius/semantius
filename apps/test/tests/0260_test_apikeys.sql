-- Test API key generation and validation
-- Seeded UAT key for user 1002: sk-seed001002-ab12cd340123456789abcdef01234567
-- Seeded UAT key for user 1003: sk-seed001003-ad22cd340123456789abcdef01234567
SELECT 'Seeded API key for user 1002 (UAT): sk-seed001002-ab12cd340123456789abcdef01234567' AS info;
SELECT 'Seeded API key for user 1003 (UAT): sk-seed001003-ad22cd340123456789abcdef01234567' AS info;

BEGIN;

SELECT plan(16);

-- =====================================================
-- TEST: _apikeys table exists
-- =====================================================

-- Test 1: _apikeys table exists in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = '_apikeys' AND table_schema = 'public')),
    '_apikeys table should exist in database'
);

-- Test 2: _apikeys table has RLS enabled
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = '_apikeys'),
    '_apikeys table should have RLS enabled'
);

-- Test 3: _apikeys is NOT in entities metadata (internal table)
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM entities WHERE table_name = '_apikeys')),
    '_apikeys should NOT be in entities metadata'
);

-- Test 4: _apikeys has key_id unique index
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_apikeys_key_id'
    )),
    'Unique index on key_id should exist'
);

-- =====================================================
-- TEST: seeded API key for user 1002 persists from migration
-- =====================================================

RESET ROLE;

-- Test 5: seeded key record exists in _apikeys for user 1002
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM _apikeys WHERE user_id = 1002 AND key_id = 'sk-seed001002')),
    'Seeded API key record should exist for user 1002'
);

-- Test 6: seeded key validates correctly and returns user_id 1002
SELECT ok(
    (SELECT validate_api_key('sk-seed001002-ab12cd340123456789abcdef01234567') = 1002),
    'validate_api_key should return 1002 for the seeded UAT key'
);

-- Test 6b: seeded key record exists in _apikeys for user 1003
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM _apikeys WHERE user_id = 1003 AND key_id = 'sk-seed001003')),
    'Seeded API key record should exist for user 1003'
);

-- Test 6c: seeded key validates correctly and returns user_id 1003
SELECT ok(
    (SELECT validate_api_key('sk-seed001003-ad22cd340123456789abcdef01234567') = 1003),
    'validate_api_key should return 1003 for the seeded UAT key'
);

-- =====================================================
-- TEST: generate_api_key for current user (user3 = admin)
-- =====================================================

-- Authenticate as admin user (user3 has Administrator role)
SELECT authenticate_as('user3');

-- Test 7: Generate API key for current user (p_user_id=0)
SELECT ok(
    (SELECT generate_api_key(0) LIKE 'uk-%'),
    'generate_api_key(0) should return a key starting with uk-'
);

-- Test 8: Generated key is stored in _apikeys
-- Reset to superuser to read _apikeys (RLS blocks semantius_user)
RESET ROLE;
SELECT ok(
    (SELECT COUNT(*) >= 1 FROM _apikeys WHERE user_id = 1003),
    'API key record should exist for user3 (id 1003)'
);

-- =====================================================
-- TEST: generate_api_key for specific user (admin only)
-- =====================================================

-- Authenticate as admin again
SELECT authenticate_as('user3');

-- Test 9: Admin can generate key for another user
SELECT ok(
    (SELECT generate_api_key(1001) LIKE 'sk-%'),
    'generate_api_key(1001) by admin should return a key starting with sk-'
);

-- =====================================================
-- TEST: Non-admin cannot generate key for another user
-- =====================================================

-- Authenticate as non-admin user
SELECT authenticate_as('user1');

-- Test 10: Non-admin cannot generate key for another user
SELECT throws_ok(
    $$ SELECT generate_api_key(1002) $$,
    '42501',
    NULL,
    'Non-admin should not be able to generate key for another user'
);

-- =====================================================
-- TEST: validate_api_key
-- =====================================================

-- Authenticate as admin to generate a known key
SELECT authenticate_as('user3');

-- Generate a new key and validate it
-- Need superuser to call validate_api_key (not granted to semantius_user)
DO $$
DECLARE
    v_key TEXT;
    v_user_id INTEGER;
BEGIN
    -- Generate key as authenticated user
    v_key := generate_api_key(0);

    -- Switch to superuser to call validate_api_key
    RESET ROLE;

    -- Validate the key
    v_user_id := validate_api_key(v_key);

    -- Store results for test assertions
    PERFORM set_config('test.generated_key', v_key, true);
    PERFORM set_config('test.validated_user_id', COALESCE(v_user_id::TEXT, ''), true);
END $$;

-- Test 11: validate_api_key returns correct user_id for valid key
SELECT ok(
    (SELECT current_setting('test.validated_user_id', true) = '1003'),
    'validate_api_key should return user_id 1003 for a valid key generated by user3'
);

-- Test 12: validate_api_key returns NULL for invalid key
RESET ROLE;
SELECT ok(
    (SELECT validate_api_key('uk-invalid-invalidinvalidinvalidinvalid') IS NULL),
    'validate_api_key should return NULL for an invalid key'
);

-- Test 13: validate_api_key returns NULL for empty string
SELECT ok(
    (SELECT validate_api_key('') IS NULL),
    'validate_api_key should return NULL for empty string'
);

-- Test 14: validate_api_key returns NULL for NULL input
SELECT ok(
    (SELECT validate_api_key(NULL) IS NULL),
    'validate_api_key should return NULL for NULL input'
);

SELECT * FROM finish();
ROLLBACK;
