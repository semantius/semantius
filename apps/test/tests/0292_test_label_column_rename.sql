-- Tests for renaming the label_column of an entity.
--
-- Verifies that:
--   1. Renaming a label field (is_core=TRUE, ctype='label') succeeds
--   2. entities.label_column is updated to the new field name
--   3. The physical column is renamed in the managed table
--   4. The fields metadata reflects the new name
--   5. Renaming core non-label fields (id, created_at, updated_at) is still blocked
BEGIN;

SELECT plan(8);

SELECT authenticate_as('user3');

-- =====================================================
-- SETUP: Create entity with a custom label_column
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'lblren1', 'item', 'Item', 'Items',
    'Label column rename test entity',
    1, 'public:read', 'nwind:manage', 'id', 'item_label'
);

-- =====================================================
-- TEST 1: Rename label column succeeds
-- =====================================================

SELECT lives_ok(
    $$UPDATE fields SET field_name = 'item_title'
      WHERE table_name = 'lblren1' AND field_name = 'item_label'$$,
    'Renaming label column item_label → item_title should succeed'
);

-- =====================================================
-- TEST 2: entities.label_column is updated
-- =====================================================

SELECT is(
    (SELECT label_column FROM entities WHERE table_name = 'lblren1'),
    'item_title',
    'entities.label_column should be updated to item_title'
);

-- =====================================================
-- TEST 3: Physical column exists under new name
-- =====================================================

SELECT has_column(
    'public', 'lblren1', 'item_title',
    'Column item_title should exist after label column rename'
);

-- =====================================================
-- TEST 4: Old column no longer exists
-- =====================================================

SELECT hasnt_column(
    'public', 'lblren1', 'item_label',
    'Column item_label should not exist after label column rename'
);

-- =====================================================
-- TEST 5: fields metadata reflects new name
-- =====================================================

SELECT is(
    (SELECT field_name FROM fields
     WHERE table_name = 'lblren1' AND ctype = 'label'),
    'item_title',
    'fields row for label should have field_name = item_title'
);

-- =====================================================
-- TEST 6: Renamed label field is still core
-- =====================================================

SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields
     WHERE table_name = 'lblren1' AND field_name = 'item_title'),
    TRUE,
    'Renamed label field should still be core (ctype = label)'
);

-- =====================================================
-- TEST 7: Renaming id column is still blocked
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET field_name = 'new_id'
      WHERE table_name = 'lblren1' AND field_name = 'id'$$,
    'P0001',
    'Cannot rename core system field "id"',
    'Renaming id column should still be rejected'
);

-- =====================================================
-- TEST 8: Renaming created_at column is still blocked
-- =====================================================

SELECT throws_ok(
    $$UPDATE fields SET field_name = 'new_created'
      WHERE table_name = 'lblren1' AND field_name = 'created_at'$$,
    'P0001',
    'Cannot rename core system field "created_at"',
    'Renaming created_at column should still be rejected'
);

SELECT * FROM finish();
ROLLBACK;
