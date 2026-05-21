-- Tests for entity changes: permission updates, rename + permission changes,
-- and validation/select rule updates.
--
-- Verifies that RLS policies are correctly updated when:
--   1. edit_permission is changed
--   2. view_permission is changed
--   3. entity is renamed
--   4. edit_permission and rename happen together
--   5. view_permission and rename happen together
--   6. select_rule is updated
--   7. validation_rules are updated
--
-- Uses deliberately unique names to avoid conflicts with other tests:
--   entity: eptest1 → eptest2 → eptest3 → eptest4
BEGIN;

SELECT plan(32);

SELECT authenticate_as('user3');

-- =====================================================
-- SETUP: Create entity for permission-change tests
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'eptest1', 'eptest1_item', 'EP Test Item', 'EP Test Items',
    'Entity permission test',
    1001, 'public:read', 'sales:manage', 'id', 'item_name'
);

-- =====================================================
-- TEST 1: Verify initial RLS policies use correct permissions
-- =====================================================

SELECT ok(
    (SELECT with_check FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_insert_policy')
    LIKE '%sales:manage%',
    'INSERT policy should reference sales:manage initially'
);

SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_select_policy')
    LIKE '%public:read%',
    'SELECT policy should reference public:read initially'
);

-- =====================================================
-- TEST 2: Change edit_permission and verify policies update
-- =====================================================

UPDATE entities SET edit_permission = 'admin'
WHERE table_name = 'eptest1';

-- INSERT policy should now reference 'admin'
SELECT ok(
    (SELECT with_check FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_insert_policy')
    LIKE '%admin%',
    'INSERT policy should reference admin after edit_permission change'
);

-- INSERT policy should no longer reference 'sales:manage'
SELECT ok(
    NOT (
        (SELECT with_check FROM pg_policies
         WHERE tablename = 'eptest1' AND schemaname = 'public'
           AND policyname = 'eptest1_insert_policy')
        LIKE '%sales:manage%'
    ),
    'INSERT policy should NOT reference sales:manage after edit_permission change to admin'
);

-- UPDATE policy should now reference 'admin'
SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_update_policy')
    LIKE '%admin%',
    'UPDATE policy USING should reference admin after edit_permission change'
);

-- DELETE policy should now reference 'admin'
SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_delete_policy')
    LIKE '%admin%',
    'DELETE policy should reference admin after edit_permission change'
);

-- =====================================================
-- TEST 3: Change view_permission and verify SELECT policy updates
-- =====================================================

UPDATE entities SET view_permission = 'sales:read'
WHERE table_name = 'eptest1';

SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_select_policy')
    LIKE '%sales:read%',
    'SELECT policy should reference sales:read after view_permission change'
);

SELECT ok(
    NOT (
        (SELECT qual FROM pg_policies
         WHERE tablename = 'eptest1' AND schemaname = 'public'
           AND policyname = 'eptest1_select_policy')
        LIKE '%public:read%'
    ),
    'SELECT policy should NOT reference public:read after view_permission change to sales:read'
);

-- =====================================================
-- TEST 4: Change edit_permission back and verify
-- =====================================================

UPDATE entities SET edit_permission = 'sales:manage'
WHERE table_name = 'eptest1';

SELECT ok(
    (SELECT with_check FROM pg_policies
     WHERE tablename = 'eptest1' AND schemaname = 'public'
       AND policyname = 'eptest1_insert_policy')
    LIKE '%sales:manage%',
    'INSERT policy should reference sales:manage after reverting edit_permission'
);

-- =====================================================
-- TEST 5: Rename entity — policies should be renamed
-- =====================================================

UPDATE entities SET table_name = 'eptest2'
WHERE table_name = 'eptest1';

-- Old policies should not exist
SELECT is_empty(
    $$SELECT policyname FROM pg_policies
      WHERE schemaname = 'public'
        AND policyname LIKE '%eptest1%'$$,
    'No policies should reference eptest1 after rename'
);

-- New policies should exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'eptest2' AND schemaname = 'public'
          AND policyname = 'eptest2_insert_policy'
    ),
    'eptest2_insert_policy should exist after rename'
);

-- Policies should still reference the correct permission (sales:manage)
SELECT ok(
    (SELECT with_check FROM pg_policies
     WHERE tablename = 'eptest2' AND schemaname = 'public'
       AND policyname = 'eptest2_insert_policy')
    LIKE '%sales:manage%',
    'INSERT policy should still reference sales:manage after rename (permission unchanged)'
);

-- =====================================================
-- TEST 6: Rename + change edit_permission simultaneously
-- =====================================================

UPDATE entities
SET table_name = 'eptest3', edit_permission = 'admin'
WHERE table_name = 'eptest2';

-- No old policies should remain
SELECT is_empty(
    $$SELECT policyname FROM pg_policies
      WHERE schemaname = 'public'
        AND policyname LIKE '%eptest2%'$$,
    'No policies should reference eptest2 after rename to eptest3'
);

-- New policies should reference 'admin' (not 'sales:manage')
SELECT ok(
    (SELECT with_check FROM pg_policies
     WHERE tablename = 'eptest3' AND schemaname = 'public'
       AND policyname = 'eptest3_insert_policy')
    LIKE '%admin%',
    'INSERT policy on eptest3 should reference admin after rename+permission change'
);

SELECT ok(
    NOT (
        (SELECT with_check FROM pg_policies
         WHERE tablename = 'eptest3' AND schemaname = 'public'
           AND policyname = 'eptest3_insert_policy')
        LIKE '%sales:manage%'
    ),
    'INSERT policy on eptest3 should NOT reference sales:manage after rename+permission change'
);

-- =====================================================
-- TEST 7: Rename + change view_permission simultaneously
-- =====================================================

UPDATE entities
SET table_name = 'eptest4', view_permission = 'public:read'
WHERE table_name = 'eptest3';

SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest4' AND schemaname = 'public'
       AND policyname = 'eptest4_select_policy')
    LIKE '%public:read%',
    'SELECT policy on eptest4 should reference public:read after rename+view_permission change'
);

-- =====================================================
-- TEST 8: Add select_rule and verify policy changes
-- =====================================================

UPDATE entities
SET select_rule = '{"==":[1,1]}'::jsonb
WHERE table_name = 'eptest4';

-- The select_rule function should be created
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should be created for eptest4'
);

-- =====================================================
-- TEST 9: Add validation_rules and verify trigger changes
-- =====================================================

UPDATE entities
SET validation_rules = '[{"code":"POSITIVE_ID","message":"ID must be positive","jsonlogic":{">":[{"var":"id"},0]}}]'::jsonb
WHERE table_name = 'eptest4';

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'compute_validate_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'compute_validate function should be created for eptest4'
);

-- =====================================================
-- TEST 10: Change view_permission when select_rule is set
-- The select_rule policy should be rebuilt with the new permission
-- =====================================================

UPDATE entities
SET view_permission = 'sales:read'
WHERE table_name = 'eptest4';

-- The select_rule function should still exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should still exist after view_permission change'
);

-- The select policy should still exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'eptest4' AND schemaname = 'public'
          AND policyname = 'eptest4_select_policy'
    ),
    'SELECT policy should still exist on eptest4 after view_permission change with select_rule'
);

-- =====================================================
-- TEST 11: Change select_rule to a different value
-- =====================================================

UPDATE entities
SET select_rule = '{">":[{"var":"id"},0]}'::jsonb
WHERE table_name = 'eptest4';

-- The select_rule function should still exist (rebuilt with new rule)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should still exist after changing select_rule to a different value'
);

-- The select policy should still exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'eptest4' AND schemaname = 'public'
          AND policyname = 'eptest4_select_policy'
    ),
    'SELECT policy should still exist after changing select_rule to a different value'
);

-- =====================================================
-- TEST 12: Remove select_rule (set to empty object)
-- Should drop the select_rule function and restore default permission-only policy
-- =====================================================

UPDATE entities
SET select_rule = '{}'::jsonb
WHERE table_name = 'eptest4';

-- The select_rule function should be dropped
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should be dropped after removing select_rule'
);

-- The select policy should still exist (restored to default permission-only)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'eptest4' AND schemaname = 'public'
          AND policyname = 'eptest4_select_policy'
    ),
    'SELECT policy should still exist after removing select_rule (restored to default)'
);

-- The restored policy should use the current view_permission (sales:read)
SELECT ok(
    (SELECT qual FROM pg_policies
     WHERE tablename = 'eptest4' AND schemaname = 'public'
       AND policyname = 'eptest4_select_policy')
    LIKE '%sales:read%',
    'Restored SELECT policy should reference current view_permission (sales:read) after select_rule removal'
);

-- =====================================================
-- TEST 13: Change validation_rules to a different value
-- =====================================================

UPDATE entities
SET validation_rules = '[{"code":"LABEL_REQUIRED","message":"Label must not be empty","jsonlogic":{"!=":[{"var":"item_name"},""]}}]'::jsonb
WHERE table_name = 'eptest4';

-- The compute_validate function should still exist (rebuilt with new rules)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'compute_validate_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'compute_validate function should still exist after changing validation_rules'
);

-- The trigger should still exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'eptest4'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'compute_validate_trigger'
    ),
    'compute_validate_trigger should still exist after changing validation_rules'
);

-- =====================================================
-- TEST 14: Remove validation_rules (set to empty array)
-- Should drop the compute_validate function and trigger
-- =====================================================

UPDATE entities
SET validation_rules = '[]'::jsonb
WHERE table_name = 'eptest4';

-- The compute_validate function should be dropped
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'compute_validate_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'compute_validate function should be dropped after removing validation_rules'
);

-- The trigger should be dropped
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'eptest4'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'compute_validate_trigger'
    ),
    'compute_validate_trigger should be dropped after removing validation_rules'
);

-- =====================================================
-- TEST 15: Re-add select_rule, then remove + add validation_rules simultaneously
-- =====================================================

UPDATE entities
SET select_rule = '{"==":[1,1]}'::jsonb
WHERE table_name = 'eptest4';

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should be re-created for eptest4'
);

-- Simultaneously remove select_rule and add validation_rules
UPDATE entities
SET select_rule = '{}'::jsonb,
    validation_rules = '[{"code":"CHK","message":"check","jsonlogic":{"==":[1,1]}}]'::jsonb
WHERE table_name = 'eptest4';

-- select_rule function should be gone
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'select_rule function should be dropped after simultaneous removal + validation_rules add'
);

-- validation trigger should exist
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'compute_validate_eptest4'
          AND pronamespace = 'public'::regnamespace
    ),
    'compute_validate function should be created after simultaneous select_rule removal + validation_rules add'
);

SELECT * FROM finish();
ROLLBACK;
