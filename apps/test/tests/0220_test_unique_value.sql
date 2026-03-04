-- Test unique_value boolean flag on fields
-- Verify that fields with unique_value=TRUE enforce a partial unique index
-- For string types: NULL and empty string are excluded from uniqueness enforcement
BEGIN;

SELECT plan(8);

-- Set context as admin user to bypass RLS
SELECT rbac.set_request_context('{"sub": "user3"}');

-- =====================================================
-- TEST: unique index exists for customers.email
-- =====================================================

-- Test 1: Unique index was created for customers.email (unique_value=TRUE)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'customers'
          AND indexname = 'customers_email_unique'
    ),
    'Unique index customers_email_unique should exist'
);

-- =====================================================
-- TEST: Two records without email can be inserted (NULL excluded from uniqueness)
-- =====================================================

-- Test 2: Insert first customer without email (NULL) should succeed
SELECT lives_ok(
    $$INSERT INTO customers (customer_name, status, total_orders)
      VALUES ('No Email Customer 1', 'active', 0)$$,
    'Should allow inserting customer with NULL email (not enforced by unique index)'
);

-- Test 3: Insert second customer without email (NULL) should succeed
SELECT lives_ok(
    $$INSERT INTO customers (customer_name, status, total_orders)
      VALUES ('No Email Customer 2', 'active', 0)$$,
    'Should allow inserting second customer with NULL email (uniqueness not enforced for NULL)'
);

-- Test 4: Insert customer with empty string email should succeed
SELECT lives_ok(
    $$INSERT INTO customers (customer_name, email, status, total_orders)
      VALUES ('No Email Customer 3', '', 'active', 0)$$,
    'Should allow inserting customer with empty string email (not enforced by unique index)'
);

-- Test 5: Insert second customer with empty string email should succeed
SELECT lives_ok(
    $$INSERT INTO customers (customer_name, email, status, total_orders)
      VALUES ('No Email Customer 4', '', 'active', 0)$$,
    'Should allow inserting second customer with empty string email (uniqueness not enforced for empty string)'
);

-- =====================================================
-- TEST: Duplicate non-empty email is rejected
-- =====================================================

-- Test 6: Insert a customer with soren.eriksen@example.com (already exists) should fail
SELECT throws_ok(
    $$INSERT INTO customers (customer_name, email, status, total_orders)
      VALUES ('Duplicate Soren', 'soren.eriksen@example.com', 'active', 0)$$,
    '23505',
    NULL,
    'Should reject duplicate email soren.eriksen@example.com (unique constraint violation)'
);

-- =====================================================
-- TEST: unique_value flag controls index creation via trigger
-- =====================================================

-- Test 7: Updating unique_value to FALSE on customers.email drops the unique index
SELECT lives_ok(
    $$UPDATE fields SET unique_value = FALSE WHERE table_name = 'customers' AND field_name = 'email'$$,
    'Should allow setting unique_value=FALSE on customers.email'
);

-- Test 8: Unique index should no longer exist after setting unique_value=FALSE
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'customers'
          AND indexname = 'customers_email_unique'
    ),
    'Unique index customers_email_unique should be dropped after unique_value set to FALSE'
);

SELECT * FROM finish();
ROLLBACK;
