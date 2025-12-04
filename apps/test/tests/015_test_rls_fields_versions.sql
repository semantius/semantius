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
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'tables') > 0,
    'user1 should be able to read fields table'
);

-- Test that user1 cannot modify fields (insert)
SELECT throws_ok(
    $$
    INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order)
    VALUES ('tables', 'test_field', 'Test Field', 'string', FALSE, TRUE, 999);
    $$,
    '42501',
    NULL,
    'user1 should not be able to insert into fields table'
);

-- Test that user1 cannot modify fields (update)
-- Store the original title value
DO $$ 
DECLARE
    v_original_title TEXT;
BEGIN
    SELECT title INTO v_original_title FROM fields WHERE table_name = 'tables' AND field_name = 'table_name';
    -- Try to update
    UPDATE fields SET title = 'Modified Title' WHERE table_name = 'tables' AND field_name = 'table_name';
    -- Verify it wasn't changed
    IF (SELECT title FROM fields WHERE table_name = 'tables' AND field_name = 'table_name') != v_original_title THEN
        RAISE EXCEPTION 'Title was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user1 cannot update fields table (verified data unchanged)');

-- Test that user1 cannot modify fields (delete)
-- Store the count before delete attempt
DO $$
DECLARE
    v_count_before INTEGER;
    v_count_after INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count_before FROM fields WHERE table_name = 'tables';
    -- Try to delete
    DELETE FROM fields WHERE table_name = 'tables' AND field_name = 'title';
    SELECT COUNT(*) INTO v_count_after FROM fields WHERE table_name = 'tables';
    -- Verify count didn't change
    IF v_count_before != v_count_after THEN
        RAISE EXCEPTION 'Record was deleted when it should not have been';
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
-- Store the original name value
DO $$
DECLARE
    v_original_name TEXT;
BEGIN
    SELECT name INTO v_original_name FROM _versions WHERE name = '_core.0010_create_core';
    -- Try to update
    UPDATE _versions SET name = 'modified_name' WHERE name = '_core.0010_create_core';
    -- Verify it wasn't changed
    IF NOT EXISTS (SELECT 1 FROM _versions WHERE name = '_core.0010_create_core') THEN
        RAISE EXCEPTION 'Name was modified when it should not have been';
    END IF;
END $$;

SELECT ok(true, 'user3 (admin) cannot update _versions table (verified data unchanged)');

SELECT * FROM finish();
ROLLBACK;
