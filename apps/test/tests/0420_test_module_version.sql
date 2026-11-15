-- Test module version tracking
-- Verifies that version is incremented and version_date is set
-- when modules or related tables are modified.
BEGIN;

SELECT plan(32);

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
    INSERT INTO processes (name, process_key, module_id)
    VALUES ('mv_test_process', 'mv_test_process', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));
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
-- TEST: fields changes bump the module version
-- =====================================================
-- A field is part of the model: it is what get_schema() and the cube RPCs
-- return, so a field edit has to move the version or every consumer polling it
-- misses schema changes. fields carries no module_id, so its trigger resolves
-- the module through entities.table_name - which is also why this needs its own
-- test rather than riding on the entities one.

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'mv_field_entity', 'item', 'Item', 'Items',
    'Version test entity for fields',
    (SELECT id FROM modules WHERE module_name = 'MV Test Module'),
    'public:read', 'admin', 'id', 'label'
);

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    INSERT INTO fields (table_name, field_name, title, format, field_order)
    VALUES ('mv_field_entity', 'mv_probe', 'MV Probe', 'string', 30);
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('fields INSERT: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Insert into fields increments module version');

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    UPDATE fields SET title = 'MV Probe Renamed'
    WHERE table_name = 'mv_field_entity' AND field_name = 'mv_probe';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('fields UPDATE: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Update to fields increments module version');

DO $$ DECLARE v_before INTEGER; v_after INTEGER; BEGIN
    SELECT version INTO v_before FROM modules WHERE module_name = 'MV Test Module';
    DELETE FROM fields WHERE table_name = 'mv_field_entity' AND field_name = 'mv_probe';
    SELECT version INTO v_after FROM modules WHERE module_name = 'MV Test Module';
    ASSERT v_after > v_before, format('fields DELETE: expected version > %s, got %s', v_before, v_after);
END $$;

SELECT pass('Delete from fields increments module version');

-- =====================================================
-- TEST: a row moved to another module bumps both modules
-- =====================================================
-- roles.module_id is nullable and updatable, so a role can leave one module for
-- another, for no module, or come from no module. Both modules the row touches
-- change what get_schema() and the module cubes return, so each moves exactly
-- once: the bump of the new module does not bump a second time through its own
-- AFTER trigger on modules (the app.bumping_module_version guard).

INSERT INTO modules (module_name, description, view_permission)
VALUES ('MV Test Module 2', 'Second module, the target of moved rows', 'admin');

INSERT INTO roles (role_name, module_id)
VALUES ('mv_move_role', (SELECT id FROM modules WHERE module_name = 'MV Test Module'));

CREATE TEMP TABLE mv_snapshot AS
SELECT module_name, version FROM modules WHERE module_name LIKE 'MV Test Module%';

UPDATE roles
   SET module_id = (SELECT id FROM modules WHERE module_name = 'MV Test Module 2')
 WHERE role_name = 'mv_move_role';

SELECT is(
    (SELECT m.version - s.version FROM modules m JOIN mv_snapshot s USING (module_name)
      WHERE m.module_name = 'MV Test Module 2'),
    1,
    'A role moved into a module bumps that module once');

SELECT is(
    (SELECT m.version - s.version FROM modules m JOIN mv_snapshot s USING (module_name)
      WHERE m.module_name = 'MV Test Module'),
    1,
    'A role moved out of a module bumps the module it left once');

-- Moving a role to no module leaves the module it was in with one role fewer.
DROP TABLE mv_snapshot;
CREATE TEMP TABLE mv_snapshot AS
SELECT module_name, version FROM modules WHERE module_name LIKE 'MV Test Module%';

UPDATE roles SET module_id = NULL WHERE role_name = 'mv_move_role';

SELECT is(
    (SELECT m.version - s.version FROM modules m JOIN mv_snapshot s USING (module_name)
      WHERE m.module_name = 'MV Test Module 2'),
    1,
    'A role moved out of a module to no module bumps the module it left');

-- A role that belongs to no module is no module's business.
DROP TABLE mv_snapshot;
CREATE TEMP TABLE mv_snapshot AS
SELECT module_name, version FROM modules WHERE module_name LIKE 'MV Test Module%';

SELECT lives_ok(
    $$DELETE FROM roles WHERE role_name = 'mv_move_role'$$,
    'Deleting a role that belongs to no module succeeds');

SELECT is(
    (SELECT count(*)::int FROM roles WHERE role_name = 'mv_move_role'),
    0,
    'The role that belonged to no module is deleted');

SELECT is(
    (SELECT sum(m.version - s.version)::int FROM modules m JOIN mv_snapshot s USING (module_name)),
    0,
    'Deleting a role that belongs to no module bumps no module');

-- =====================================================
-- TEST: the recursion guard silences related-table bumps
-- =====================================================
-- While a bump is in flight (app.bumping_module_version is true) a change to a
-- related row must not bump again, or the UPDATE of modules that the bump itself
-- issues would loop through the triggers.

DROP TABLE mv_snapshot;
CREATE TEMP TABLE mv_snapshot AS
SELECT module_name, version FROM modules WHERE module_name LIKE 'MV Test Module%';

SELECT set_config('app.bumping_module_version', 'true', TRUE);

SELECT lives_ok(
    $$INSERT INTO roles (role_name, module_id)
      VALUES ('mv_guarded_role', (SELECT id FROM modules WHERE module_name = 'MV Test Module'))$$,
    'Inserting a role while a bump is in flight succeeds');

SELECT lives_ok(
    $$UPDATE roles SET description = 'guarded' WHERE role_name = 'mv_guarded_role'$$,
    'Updating a role while a bump is in flight succeeds');

SELECT lives_ok(
    $$DELETE FROM roles WHERE role_name = 'mv_guarded_role'$$,
    'Deleting a role while a bump is in flight succeeds');

SELECT set_config('app.bumping_module_version', 'false', TRUE);

SELECT is(
    (SELECT sum(m.version - s.version)::int FROM modules m JOIN mv_snapshot s USING (module_name)),
    0,
    'A role insert, update and delete during a bump bump no module');

-- =====================================================
-- TEST: bump_module_version tolerates a DELETE trigger
-- =====================================================
-- The function is attached only to INSERT and UPDATE of modules, but it states
-- what a delete does: nothing. A trigger attached to DELETE (here a probe)
-- must not bump any module, the deleted one included.

INSERT INTO modules (module_name, description, view_permission)
VALUES ('MV Test Module 3', 'Module deleted under a bump trigger', 'admin');

DROP TABLE mv_snapshot;
CREATE TEMP TABLE mv_snapshot AS
SELECT module_name, version FROM modules WHERE module_name LIKE 'MV Test Module%';

CREATE TRIGGER mv_probe_delete
    AFTER DELETE ON public.modules
    FOR EACH ROW EXECUTE FUNCTION public.bump_module_version();

SELECT lives_ok(
    $$DELETE FROM modules WHERE module_name = 'MV Test Module 3'$$,
    'Deleting a module under a bump_module_version trigger succeeds');

DROP TRIGGER mv_probe_delete ON public.modules;

SELECT is(
    (SELECT count(*)::int FROM modules WHERE module_name = 'MV Test Module 3'),
    0,
    'The module is deleted');

SELECT is(
    (SELECT sum(m.version - s.version)::int FROM modules m JOIN mv_snapshot s USING (module_name)),
    0,
    'Deleting a module under a bump_module_version trigger bumps no other module');

SELECT * FROM finish();
ROLLBACK;
