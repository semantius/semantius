-- Test unique_value boolean flag on fields
-- Verify that fields with unique_value=TRUE enforce a partial unique index
-- For string types: empty string is excluded from uniqueness enforcement
-- (explicit NULL is rejected on every TEXT column, so it is never inserted here)
--
-- Target: nwind territories.territory_id (TEXT, unique_value=TRUE, required)
BEGIN;

SELECT plan(8);

-- Authenticate as admin user (writes territories and fields)
SELECT authenticate_as('user3');

-- =====================================================
-- TEST: unique index exists for territories.territory_id
-- =====================================================

-- Test 1: Unique index was created for territories.territory_id (unique_value=TRUE)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'territories'
          AND indexname = 'territories_territory_id_unique'
    ),
    'Unique index territories_territory_id_unique should exist'
);

-- =====================================================
-- TEST: Two records without territory_id can be inserted (column defaults to '', excluded from uniqueness)
-- =====================================================

-- Test 2: Insert first territory omitting territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, region_id)
      VALUES ('No Code Territory 1', 1)$$,
    'Should allow inserting territory without territory_id (defaults to empty string, not enforced by unique index)'
);

-- Test 3: Insert second territory omitting territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, region_id)
      VALUES ('No Code Territory 2', 1)$$,
    'Should allow inserting second territory without territory_id (uniqueness not enforced for empty string)'
);

-- Test 4: Insert territory with explicit empty string territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('No Code Territory 3', '', 1)$$,
    'Should allow inserting territory with empty string territory_id (not enforced by unique index)'
);

-- Test 5: Insert second territory with explicit empty string territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('No Code Territory 4', '', 1)$$,
    'Should allow inserting second territory with empty string territory_id (uniqueness not enforced for empty string)'
);

-- =====================================================
-- TEST: Duplicate non-empty territory_id is rejected
-- =====================================================

-- Test 6: Insert a territory with territory_id 01581 (Westboro, already exists) should fail
SELECT throws_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('Duplicate Westboro', '01581', 1)$$,
    '23505',
    NULL,
    'Should reject duplicate territory_id 01581 (unique constraint violation)'
);

-- =====================================================
-- TEST: unique_value flag controls index creation via trigger
-- =====================================================

-- Test 7: Updating unique_value to FALSE on territories.territory_id drops the unique index
SELECT lives_ok(
    $$UPDATE fields SET unique_value = FALSE WHERE table_name = 'territories' AND field_name = 'territory_id'$$,
    'Should allow setting unique_value=FALSE on territories.territory_id'
);

-- Test 8: Unique index should no longer exist after setting unique_value=FALSE
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'territories'
          AND indexname = 'territories_territory_id_unique'
    ),
    'Unique index territories_territory_id_unique should be dropped after unique_value set to FALSE'
);

SELECT * FROM finish();
ROLLBACK;
