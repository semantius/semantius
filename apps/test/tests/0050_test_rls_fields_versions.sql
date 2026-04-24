-- Test RLS policies for fields table and _versions table
BEGIN;

SELECT plan(8);

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
    SELECT name INTO STRICT v_original_name FROM _versions WHERE name = '_core.0010_create_core';
    
    -- Try to update (should be blocked by RLS)
    UPDATE _versions SET name = 'modified_name' WHERE name = '_core.0010_create_core';
    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    
    -- Verify RLS blocked the update (0 rows affected)
    IF v_rows_affected != 0 THEN
        RAISE EXCEPTION 'UPDATE affected % rows when it should have affected 0 (RLS should block)', v_rows_affected;
    END IF;
    
    -- Verify name is unchanged
    IF NOT EXISTS (SELECT 1 FROM _versions WHERE name = '_core.0010_create_core') THEN
        RAISE EXCEPTION 'Name was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user3 (admin) cannot update _versions table (verified data unchanged)');

SELECT * FROM finish();
ROLLBACK;
