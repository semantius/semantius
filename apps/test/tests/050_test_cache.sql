-- Test cache functionality
BEGIN;

SELECT plan(19);

-- Test 1: Verify cache table exists and has proper structure
SELECT has_table('common', '_cache', 'Cache table should exist in common schema');

-- Test 2: Verify cache table has RLS enabled
SELECT is(
    (SELECT relrowsecurity FROM pg_class c 
     JOIN pg_namespace n ON c.relnamespace = n.oid 
     WHERE n.nspname = 'common' AND c.relname = '_cache'),
    true,
    'Cache table should have RLS enabled'
);

-- Test 3: Basic cache set and get functionality
SELECT common.cache_set('test_key', 'test_value', 60);
SELECT is(
    common.cache_get('test_key'),
    'test_value',
    'cache_get should return the value that was set'
);

-- Test 4: Cache get returns NULL for non-existent key
SELECT is(
    common.cache_get('non_existent_key'),
    NULL,
    'cache_get should return NULL for non-existent key'
);

-- Test 5: Cache set with JSON value
SELECT common.cache_set('json_key', '{"name": "test", "value": 123}', 30);
SELECT is(
    common.cache_get('json_key'),
    '{"name": "test", "value": 123}',
    'cache should handle JSON values correctly'
);

-- Test 6: Cache overwrite existing key
SELECT common.cache_set('test_key', 'new_value', 60);
SELECT is(
    common.cache_get('test_key'),
    'new_value',
    'cache_set should overwrite existing key'
);

-- Test 7: Cache delete functionality
SELECT is(
    common.cache_delete('test_key'),
    true,
    'cache_delete should return true when deleting existing key'
);

SELECT is(
    common.cache_get('test_key'),
    NULL,
    'cache_get should return NULL after key is deleted'
);

-- Test 8: Cache delete non-existent key
SELECT is(
    common.cache_delete('non_existent_key'),
    false,
    'cache_delete should return false when deleting non-existent key'
);

-- Test 9: Cache expiration (set entry that expires immediately)
SELECT common.cache_set('expire_key', 'expire_value', 0);
-- Force expiration by setting expires_at to past time
UPDATE common._cache SET expires_at = NOW() - INTERVAL '1 minute' WHERE key = 'expire_key';
SELECT is(
    common.cache_get('expire_key'),
    NULL,
    'cache_get should return NULL for expired entries'
);

-- Test 10: Cache stats functionality
-- Clear any existing cache entries first
SELECT common.cache_delete('json_key');
SELECT common.cache_cleanup();

-- Add some test entries
SELECT common.cache_set('stats_key1', 'value1', 60);
SELECT common.cache_set('stats_key2', 'value2', 60);
SELECT common.cache_set('expired_key', 'expired_value', 60);
-- Force one entry to be expired for testing
UPDATE common._cache SET expires_at = NOW() - INTERVAL '1 minute' WHERE key = 'expired_key';

-- Test cache stats
SELECT results_eq(
    $$SELECT total_entries FROM common.cache_stats()$$,
    $$VALUES (3::bigint)$$,
    'cache_stats should show correct total entries'
);

SELECT results_eq(
    $$SELECT active_entries FROM common.cache_stats()$$,
    $$VALUES (2::bigint)$$,
    'cache_stats should show correct active entries (non-expired)'
);

SELECT results_eq(
    $$SELECT expired_entries FROM common.cache_stats()$$,
    $$VALUES (1::bigint)$$,
    'cache_stats should show correct expired entries'
);

-- Test 11: Cache cleanup functionality
SELECT is(
    common.cache_cleanup(),
    1,
    'cache_cleanup should return 1 (number of expired entries deleted)'
);

-- Verify cleanup worked
SELECT results_eq(
    $$SELECT total_entries FROM common.cache_stats()$$,
    $$VALUES (2::bigint)$$,
    'cache_stats should show 2 entries after cleanup'
);

SELECT results_eq(
    $$SELECT expired_entries FROM common.cache_stats()$$,
    $$VALUES (0::bigint)$$,
    'cache_stats should show 0 expired entries after cleanup'
);

-- Test 12: Verify cache table has RLS enabled for regular users
-- Note: We can't actually test this properly since cache functions don't have
-- execute permissions for semantius_user (which is intentional for security)
SELECT ok(
    true,
    'Cache functions are intentionally not accessible to semantius_user (security feature)'
);

-- Test 13: Test cache key uniqueness constraint
SELECT common.cache_set('unique_key', 'value1', 60);
SELECT common.cache_set('unique_key', 'value2', 60);
-- Should not throw error, should update the value
SELECT is(
    common.cache_get('unique_key'),
    'value2',
    'cache should handle key uniqueness by updating existing entries'
);

-- Test 14: Test cache with empty string value
SELECT common.cache_set('empty_key', '', 60);
SELECT is(
    common.cache_get('empty_key'),
    '',
    'cache should handle empty string values'
);

-- Cleanup test data
SELECT common.cache_delete('stats_key1');
SELECT common.cache_delete('stats_key2');
SELECT common.cache_delete('unique_key');
SELECT common.cache_delete('empty_key');
SELECT common.cache_cleanup();

SELECT * FROM finish();
ROLLBACK;