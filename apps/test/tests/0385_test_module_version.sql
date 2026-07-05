-- Test module version tracking
-- Verifies that version is incremented and version_date is set
-- when modules or related tables are modified.
BEGIN;

SELECT plan(19);

-- =====================================================
-- SETUP: Use superuser context for DDL operations
-- =====================================================
RESET ROLE;

-- Create a fresh test module to have a known starting version
INSERT INTO modules (module_name, description, view_permission)
VALUES ('MV Test Module', 'Module version tracking test', 'admin');

-- Record initial version (will be 1 since the INSERT trigger bumps it)
SELECT is(
    (SELECT version FROM modules WHERE module_name = 'MV Test Module'),
    1,
    'New module starts at version 1 after insert trigger'
);

SELECT ok(
    (SELECT version_date IS NOT NULL FROM modules WHERE module_name = 'MV Test Module'),
    'New module has version_date set after insert'
);

-- =====================================================
-- TEST: Direct module update bumps version
-- =====================================================

UPDATE modules SET description = 'Updated description' WHERE module_name = 'MV Test Module';

SELECT is(
    (SELECT version FROM modules WHERE module_name = 'MV Test Module'),
    2,
    'Direct update to modules increments version to 2'
);

SELECT ok(
    (SELECT version_date IS NOT NULL FROM modules WHERE module_name = 'MV Test Module'),
    'Direct update to modules sets version_date'
);

-- =====================================================
-- TEST: Insert into entities bumps module version
-- =====================================================
-- Note: inserting into entities can cause cascading field inserts etc.
-- so we check that version increases by at least 1

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';

    INSERT INTO entities (
        table_name, singular, singular_label, plural_label,
        description, module_id, view_permission, edit_permission,
        id_column, label_column
    ) VALUES (
        'mv_test_entity', 'item', 'Item', 'Items',
        'Version test entity',
        (SELECT id FROM modules WHERE module_name = 'MV Test Module'),
        'public:read', 'admin', 'id', 'label'
    );

    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('entities INSERT: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Insert into entities increments module version');

-- =====================================================
-- TEST: Update entities bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE entities SET description = 'Updated description' WHERE table_name = 'mv_test_entity';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('entities UPDATE: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Update to entities increments module version');

-- =====================================================
-- TEST: Delete from entities bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM entities WHERE table_name = 'mv_test_entity';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('entities DELETE: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Delete from entities increments module version');

-- =====================================================
-- TEST: Insert into roles bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    INSERT INTO roles (role_name, module_id)
    VALUES ('mv_test_role', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('roles INSERT: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Insert into roles increments module version');

-- =====================================================
-- TEST: Update roles bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE roles SET description = 'Updated role' WHERE role_name = 'mv_test_role';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('roles UPDATE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Update to roles increments module version');

-- =====================================================
-- TEST: Delete from roles bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM roles WHERE role_name = 'mv_test_role';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('roles DELETE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Delete from roles increments module version');

-- =====================================================
-- TEST: Insert into permissions bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    INSERT INTO permissions (permission_name, module_id)
    VALUES ('mv_test_perm', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('permissions INSERT: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Insert into permissions increments module version');

-- =====================================================
-- TEST: Update permissions bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE permissions SET description = 'Updated perm' WHERE permission_name = 'mv_test_perm';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('permissions UPDATE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Update to permissions increments module version');

-- =====================================================
-- TEST: Delete from permissions bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM permissions WHERE permission_name = 'mv_test_perm';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('permissions DELETE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Delete from permissions increments module version');

-- =====================================================
-- TEST: Insert into processes bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    INSERT INTO processes (name, module_id)
    VALUES ('mv_test_process', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('processes INSERT: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Insert into processes increments module version');

-- =====================================================
-- TEST: Update processes bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE processes SET description = 'Updated process' WHERE name = 'mv_test_process';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('processes UPDATE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Update to processes increments module version');

-- =====================================================
-- TEST: Delete from processes bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM processes WHERE name = 'mv_test_process';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('processes DELETE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Delete from processes increments module version');

-- =====================================================
-- TEST: Insert into dashboards bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    INSERT INTO dashboards (label, module_id)
    VALUES ('mv_test_dashboard', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('dashboards INSERT: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Insert into dashboards increments module version');

-- =====================================================
-- TEST: Update dashboards bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE dashboards SET label = 'mv_test_dashboard_updated' WHERE label = 'mv_test_dashboard';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('dashboards UPDATE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Update to dashboards increments module version');

-- =====================================================
-- TEST: Delete from dashboards bumps module version
-- =====================================================

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM dashboards WHERE label = 'mv_test_dashboard_updated';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after = v_before + 1, format('dashboards DELETE: expected version = %s, got %s', v_before + 1, v_after);
END $$;

SELECT pass('Delete from dashboards increments module version');

SELECT * FROM finish();
ROLLBACK;
