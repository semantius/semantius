-- Row-level security basics: the rbac context smoke test and the RLS
-- policies on the fields and _versions catalog tables.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. RLS / rbac context smoke test
--   2. RLS on fields and _versions
BEGIN;

SELECT plan(20);

-- =====================================================
-- PART 1: RLS / rbac context smoke test
-- =====================================================
-- Basic RLS / rbac context smoke test.
--
-- Fixtures: harness identities from apps/test (user1 = 1001, User role only;
-- user2 = 1002, User + Northwind Sales) and the persisted nwind module
-- (products = 77 rows, view_permission 'nwind:view').
-- Also hosts the read-only lookup asserts for rbac.get_user_by_external_id()
-- (formerly in 0080_test_readonly_rls.sql).

select authenticate_as('user1');

-- Test that will pass
SELECT has_table('public', 'users', 'Users table should exist');

-- Test rbac.user_id() returns 1001
SELECT is(
    rbac.user_id(),
    1001::bigint,
    'rbac.user_id() should return 1001'
);

-- Test rbac.uid() returns user1
SELECT is(
    rbac.uid(),
    'user1',
    'rbac.uid() should return user1'
);

-- Test webhook_receivers count - RLS should prevent access (requires admin permission), so count should be 0
SELECT is(
    (SELECT COUNT(*)::integer FROM webhook_receivers),
    0,
    'webhook_receivers table should contain 0 records (user1 lacks admin permission)'
);

-- Test that user1 has not nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    false,
    'user1 should not have nwind:view permission'
);

-- check that insert is blocked by RLS (roles requires admin permission).
-- module_id = 1 (_core) is a literal on purpose: user1 cannot see any module
-- row, so a slug subquery would resolve to NULL and the failure would no
-- longer isolate the RLS policy.
SELECT throws_ok(
    $$
    INSERT INTO roles (role_name, description, module_id)
    VALUES ('Should Fail', 'user1 lacks admin permission', 1);
    $$,
    '42501',
    NULL,
    'Insert into roles should fail because user1 lacks admin permission'
);

-- Read-only lookup helper (used by RLS in read-only transactions).
-- The subject is confined: user1 may look itself up, and anything else raises,
-- which is what stops a plain user from enumerating external ids. The whole rule,
-- including the administrator's view of it and the NULL-for-unknown answer they
-- still get, is in 0310_test_rbac_helpers.sql.
SELECT is(
    rbac.get_user_by_external_id('user1'),
    1001::bigint,
    'rbac.get_user_by_external_id should return 1001 for user1'
);

SELECT throws_ok(
    $$SELECT rbac.get_user_by_external_id('does_not_exist')$$,
    '42501',
    NULL,
    'rbac.get_user_by_external_id should refuse a subject that is not the caller'
);

select authenticate_as('user2');

-- Test rbac.uid() returns user2
SELECT is(
    rbac.uid(),
    'user2',
    'rbac.uid() should return user2'
);

-- Test product count - RLS should allow access (user2 holds nwind:view), so count should be 77
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    77,
    'Products table should contain 77 products for user2'
);

-- Test that user2 has nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    true,
    'user2 should have nwind:view permission'
);

-- Test that an unknown permission name is simply false
SELECT is(
    rbac.has_permission('nwind:NOTEXISTANT'),
    false,
    'user2 should not have nwind:NOTEXISTANT'
);

-- =====================================================
-- PART 2: RLS on fields and _versions
-- =====================================================
-- Test RLS policies for fields table and _versions table

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST FIELDS TABLE RLS
-- =====================================================

-- Test as user1 (non-admin, has public:read)
SELECT authenticate_as('user1');

-- Test that user1 can read fields
SELECT ok(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'entities') > 0,
    'user1 should be able to read fields table'
);

-- Test that user1 cannot modify fields (insert)
SELECT throws_ok(
    $$
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width)
    VALUES ('tables', 'test_field', 'Test Field', 'text', FALSE, 999, 'default', 'default');
    $$,
    '42501',
    NULL,
    'user1 should not be able to insert into fields table'
);

-- Test that user1 cannot modify fields (update)
-- Store the original title value and verify UPDATE affects 0 rows due to RLS
DO $$ 
DECLARE
    v_original_title TEXT;
    v_rows_affected INTEGER;
BEGIN
    -- First, verify the record exists and we can read it
    SELECT title INTO STRICT v_original_title FROM fields WHERE table_name = 'entities' AND field_name = 'table_name';
    
    -- Try to update (should be blocked by RLS)
    UPDATE fields SET title = 'Modified Title' WHERE table_name = 'entities' AND field_name = 'table_name';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the update (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'UPDATE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Verify value is unchanged
    IF (SELECT title FROM fields WHERE table_name = 'entities' AND field_name = 'table_name') != v_original_title THEN
        RAISE EXCEPTION 'Title was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user1 cannot update fields table (verified data unchanged)');

-- Test that user1 cannot modify fields (delete)
-- Verify DELETE affects 0 rows due to RLS
DO $$
DECLARE
    v_count_before INTEGER;
    v_rows_affected INTEGER;
    v_record_exists BOOLEAN;
BEGIN
    -- Verify the record exists that we're trying to delete (use 'description' field which exists for entities)
    SELECT EXISTS(SELECT 1 FROM fields WHERE table_name = 'entities' AND field_name = 'description') INTO STRICT v_record_exists;
    IF NOT v_record_exists THEN
        RAISE EXCEPTION 'Test setup error: record to delete does not exist';
    END IF;
    
    -- Get count before delete attempt
    SELECT COUNT(*) INTO v_count_before FROM fields WHERE table_name = 'entities';
    IF v_count_before = 0 THEN
        RAISE EXCEPTION 'Test setup error: no fields found for entities table';
    END IF;
    
    -- Try to delete (should be blocked by RLS)
    DELETE FROM fields WHERE table_name = 'entities' AND field_name = 'description';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the delete (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'DELETE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Double-check count didn't change
    IF (SELECT COUNT(*) FROM fields WHERE table_name = 'entities') != v_count_before THEN
        RAISE EXCEPTION 'Record count changed when it should not have';
    END IF;
END $$;

SELECT ok(true, 'user1 cannot delete from fields table (verified data unchanged)');

-- =====================================================
-- TEST _VERSIONS TABLE RLS - user1 (non-admin)
-- =====================================================

-- Test that user1 cannot query _versions
SELECT is(
    (SELECT COUNT(*)::integer FROM _versions),
    0,
    'user1 should not be able to read _versions table (RLS should return 0 rows)'
);

-- =====================================================
-- TEST _VERSIONS TABLE RLS - user3 (admin)
-- =====================================================

-- Switch to user3 (admin)
SELECT authenticate_as('user3');

-- Test that user3 can query _versions
SELECT ok(
    (SELECT COUNT(*)::integer FROM _versions) > 0,
    'user3 (admin) should be able to read _versions table'
);

-- Test that user3 cannot insert into _versions
SELECT throws_ok(
    $$
    INSERT INTO _versions (name) VALUES ('test_version');
    $$,
    '42501',
    NULL,
    'user3 (admin) should not be able to insert into _versions table'
);

-- Test that user3 cannot update _versions
-- Verify UPDATE affects 0 rows due to RLS
DO $$
DECLARE
    v_original_name TEXT;
    v_rows_affected INTEGER;
BEGIN
    -- Verify the record exists
    SELECT name INTO STRICT v_original_name FROM _versions WHERE name = '_core.0010_core.sql';
    
    -- Try to update (should be blocked by RLS)
    UPDATE _versions SET name = 'modified_name' WHERE name = '_core.0010_core.sql';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the update (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'UPDATE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Verify name is unchanged
    IF NOT EXISTS (SELECT 1 FROM _versions WHERE name = '_core.0010_core.sql') THEN
        RAISE EXCEPTION 'Name was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user3 (admin) cannot update _versions table (verified data unchanged)');

SELECT * FROM finish();
ROLLBACK;
