-- Deep rename test: rename an entity table_name and verify ALL metadata,
-- physical catalog objects, records, JsonLogic triggers, select_rule policies,
-- set_record references, and cross-table FK references survive correctly.
--
-- Scenario:
--   families    – standalone reference entity
--   parents     – references families, has computed_fields, validation_rules,
--                 select_rule (restrict views, compute fields, check permissions)
--   children    – has a parent reference to parents
--   nephews     – has a set_record JsonLogic to load a specific parent record
--
-- Flow:
--   1. Create all four entities with fields & JsonLogic
--   2. Insert one record per table, verify it exists
--   3. Rename "parents" → "eltern"
--   4. Verify all records, metadata, catalog objects, and JsonLogic survive
--   5. Insert a second record per table (proves triggers & policies still work)
BEGIN;

SELECT plan(43);

SELECT authenticate_as('user3');

-- =====================================================
-- STEP 1: Create entities
-- =====================================================

-- 1a. families (standalone, no JsonLogic)
INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'rn_families', 'family', 'Family', 'Families',
    'Rename test: families', 1001, 'public:read', 'sales:manage',
    'id', 'family_name'
);

-- 1b. parents — references families, has ALL JsonLogic
INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column,
    computed_fields, validation_rules,
    select_rule
) VALUES (
    'rn_parents', 'parent', 'Parent', 'Parents',
    'Rename test: parents', 1001, 'public:read', 'sales:manage',
    'id', 'parent_name',
    -- computed_fields: derive full_title from parent_name
    '[{"name":"full_title","jsonlogic":{"cat":[{"var":"parent_name"}," (parent)"]}}]'::jsonb,
    -- validation_rules: parent_name must not be empty
    '[{"code":"name_required","message":"parent_name is required","jsonlogic":{"!!":[{"var":"parent_name"}]}}]'::jsonb,
    -- select_rule: allow all (admin has permission)
    '{"has_permission":"sales:manage"}'::jsonb
);

-- 1c. children — parent reference to parents
INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'rn_children', 'child', 'Child', 'Children',
    'Rename test: children', 1001, 'public:read', 'sales:manage',
    'id', 'child_name'
);

-- 1d. nephews — has a set_record JsonLogic to load a parent record
INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column,
    computed_fields
) VALUES (
    'rn_nephews', 'nephew', 'Nephew', 'Nephews',
    'Rename test: nephews', 1001, 'public:read', 'sales:manage',
    'id', 'nephew_name',
    -- computed_fields: use set_record to load a parent and derive parent_title
    '[{"name":"parent_title","jsonlogic":{"set_record":["p","rn_parents",{"var":"parent_ref"},{"var":"p.full_title"}]}}]'::jsonb
);

-- =====================================================
-- STEP 1b: Create fields
-- =====================================================

-- families: family_name is auto-created as label column; no extra fields needed

-- parents: parent_name is auto-created as label column; add family_ref and full_title
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order, input_type, width, default_value)
VALUES ('rn_parents', 'family_ref', 'Family', 'reference', 'rn_families', 'restrict', 20, 'default', 'default', '');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
VALUES ('rn_parents', 'full_title', 'Full Title', 'text', 30, 'readonly', 'default', '');

-- children: child_name is auto-created as label column; add parent_ref
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order, input_type, width, default_value)
VALUES ('rn_children', 'parent_ref', 'Parent', 'parent', 'rn_parents', 'restrict', 20, 'default', 'default', '');

-- nephews: nephew_name is auto-created as label column; add parent_ref and parent_title
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order, input_type, width, default_value)
VALUES ('rn_nephews', 'parent_ref', 'Parent Ref', 'reference', 'rn_parents', 'restrict', 20, 'default', 'default', '');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
VALUES ('rn_nephews', 'parent_title', 'Parent Title', 'text', 30, 'readonly', 'default', '');

-- =====================================================
-- STEP 2: Insert one record per table, verify existence
-- =====================================================

DO $$
DECLARE
    v_family_id INTEGER;
    v_parent_id INTEGER;
    v_child_id INTEGER;
    v_nephew_id INTEGER;
BEGIN
    INSERT INTO rn_families (family_name) VALUES ('Smith') RETURNING id INTO v_family_id;
    INSERT INTO rn_parents (parent_name, family_ref) VALUES ('John', v_family_id) RETURNING id INTO v_parent_id;
    INSERT INTO rn_children (child_name, parent_ref) VALUES ('Alice', v_parent_id) RETURNING id INTO v_child_id;
    INSERT INTO rn_nephews (nephew_name, parent_ref) VALUES ('Bob', v_parent_id) RETURNING id INTO v_nephew_id;
END $$;

SELECT is(
    (SELECT family_name FROM rn_families LIMIT 1),
    'Smith',
    'families: Smith record exists'
);

SELECT is(
    (SELECT parent_name FROM rn_parents LIMIT 1),
    'John',
    'parents: John record exists'
);

-- Verify computed field worked
SELECT is(
    (SELECT full_title FROM rn_parents LIMIT 1),
    'John (parent)',
    'parents: computed full_title is correct'
);

SELECT is(
    (SELECT child_name FROM rn_children LIMIT 1),
    'Alice',
    'children: Alice record exists'
);

SELECT is(
    (SELECT nephew_name FROM rn_nephews LIMIT 1),
    'Bob',
    'nephews: Bob record exists'
);

-- Verify set_record computed parent_title
SELECT is(
    (SELECT parent_title FROM rn_nephews LIMIT 1),
    'John (parent)',
    'nephews: set_record computed parent_title is correct'
);

-- Verify validation rule works (reject empty parent_name)
SELECT throws_ok(
    $$INSERT INTO rn_parents (parent_name) VALUES ('')$$,
    '23514',
    NULL,
    'parents: validation rejects empty parent_name'
);

-- =====================================================
-- PRE-RENAME CHECKS: Verify JsonLogic functions and triggers exist
-- =====================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'compute_validate_rn_parents'
            AND pronamespace = 'public'::regnamespace),
    'pre-rename: compute_validate_rn_parents function exists'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'select_rule_rn_parents'
            AND pronamespace = 'public'::regnamespace),
    'pre-rename: select_rule_rn_parents function exists'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'compute_validate_rn_nephews'
            AND pronamespace = 'public'::regnamespace),
    'pre-rename: compute_validate_rn_nephews function exists'
);

-- =====================================================
-- STEP 3: RENAME parents → eltern
-- =====================================================

SELECT lives_ok(
    $$UPDATE entities SET table_name = 'rn_eltern' WHERE table_name = 'rn_parents'$$,
    'Rename rn_parents → rn_eltern should succeed'
);

-- =====================================================
-- STEP 4: Verify ALL aspects after rename
-- =====================================================

-- 4a. Physical table renamed
SELECT hasnt_table('public', 'rn_parents', 'rn_parents table should not exist after rename');
SELECT has_table('public', 'rn_eltern', 'rn_eltern table should exist after rename');

-- 4b. Records still exist with original data
SELECT is(
    (SELECT parent_name FROM rn_eltern LIMIT 1),
    'John',
    'eltern: John record still exists after rename'
);

SELECT is(
    (SELECT full_title FROM rn_eltern LIMIT 1),
    'John (parent)',
    'eltern: computed full_title still correct after rename'
);

SELECT is(
    (SELECT family_name FROM rn_families LIMIT 1),
    'Smith',
    'families: Smith record still exists after rename'
);

SELECT is(
    (SELECT child_name FROM rn_children LIMIT 1),
    'Alice',
    'children: Alice record still exists after rename'
);

SELECT is(
    (SELECT nephew_name FROM rn_nephews LIMIT 1),
    'Bob',
    'nephews: Bob record still exists after rename'
);

-- 4c. entities metadata updated
SELECT is(
    (SELECT count(*)::integer FROM entities WHERE table_name = 'rn_parents'),
    0,
    'No entities row for rn_parents after rename'
);

SELECT is(
    (SELECT count(*)::integer FROM entities WHERE table_name = 'rn_eltern'),
    1,
    'entities row exists for rn_eltern after rename'
);

-- 4d. fields metadata cascaded: table_name column updated
SELECT is(
    (SELECT count(*)::integer FROM fields WHERE table_name = 'rn_parents'),
    0,
    'No fields rows for rn_parents after rename'
);

-- Exact count: id, parent_name, family_ref, full_title, created_at, updated_at = 6
SELECT is(
    (SELECT count(*)::integer FROM fields WHERE table_name = 'rn_eltern'),
    6,
    'Exactly 6 fields rows should reference rn_eltern after rename'
);

-- 4d2. fields.id (generated PK = table_name.field_name) must also update
SELECT is(
    (SELECT count(*)::integer FROM fields WHERE id LIKE 'rn_parents.%'),
    0,
    'No fields.id should start with rn_parents. after rename'
);

SELECT is(
    (SELECT count(*)::integer FROM fields WHERE id LIKE 'rn_eltern.%'),
    6,
    'Exactly 6 fields.id should start with rn_eltern. after rename'
);

-- 4e. Cross-table reference_table updated (children.parent_ref → rn_eltern)
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'rn_children' AND field_name = 'parent_ref'),
    'rn_eltern',
    'children: parent_ref reference_table updated to rn_eltern'
);

-- nephews.parent_ref reference_table also updated
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'rn_nephews' AND field_name = 'parent_ref'),
    'rn_eltern',
    'nephews: parent_ref reference_table updated to rn_eltern'
);

-- No fields anywhere still reference rn_parents
SELECT is(
    (SELECT count(*)::integer FROM fields WHERE reference_table = 'rn_parents'),
    0,
    'No fields row should retain reference_table = rn_parents'
);

-- 4f. Physical FK on children still points at rn_eltern
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class src ON c.conrelid = src.oid
        JOIN pg_class tgt ON c.confrelid = tgt.oid
        WHERE src.relname = 'rn_children'
          AND src.relnamespace = 'public'::regnamespace
          AND c.conname = 'rn_children_parent_ref_fkey'
          AND tgt.relname = 'rn_eltern'
    ),
    'FK rn_children_parent_ref_fkey physically references rn_eltern'
);

-- 4g. No trace of rn_parents in the public schema catalog
SELECT is_empty(
    $$
    SELECT 'pg_class: ' || relname AS artifact
    FROM   pg_class
    WHERE  relnamespace = 'public'::regnamespace
      AND  relname LIKE '%rn\_parents%' ESCAPE '\'
    UNION ALL
    SELECT 'pg_trigger: ' || t.tgname
    FROM   pg_trigger t
    JOIN   pg_class c ON t.tgrelid = c.oid
    WHERE  c.relnamespace = 'public'::regnamespace
      AND  t.tgname LIKE '%rn\_parents%' ESCAPE '\'
    UNION ALL
    SELECT 'pg_policy: ' || p.polname
    FROM   pg_policy p
    JOIN   pg_class c ON p.polrelid = c.oid
    WHERE  c.relnamespace = 'public'::regnamespace
      AND  p.polname LIKE '%rn\_parents%' ESCAPE '\'
    UNION ALL
    SELECT 'pg_constraint: ' || c.conname
    FROM   pg_constraint c
    JOIN   pg_class t ON c.conrelid = t.oid
    WHERE  t.relnamespace = 'public'::regnamespace
      AND  c.conname LIKE '%rn\_parents%' ESCAPE '\'
    UNION ALL
    SELECT 'pg_proc: ' || p.proname
    FROM   pg_proc p
    WHERE  p.pronamespace = 'public'::regnamespace
      AND  p.proname LIKE '%rn\_parents%' ESCAPE '\'
    UNION ALL
    SELECT 'pg_indexes: ' || indexname
    FROM   pg_indexes
    WHERE  schemaname = 'public'
      AND  indexname LIKE '%rn\_parents%' ESCAPE '\'
    $$,
    'No trace of rn_parents should remain in the public schema catalog'
);

-- 4h. compute_validate function renamed
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'compute_validate_rn_parents'
                AND pronamespace = 'public'::regnamespace),
    'post-rename: compute_validate_rn_parents function should NOT exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'compute_validate_rn_eltern'
            AND pronamespace = 'public'::regnamespace),
    'post-rename: compute_validate_rn_eltern function should exist'
);

-- 4i. select_rule function renamed
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'select_rule_rn_parents'
                AND pronamespace = 'public'::regnamespace),
    'post-rename: select_rule_rn_parents function should NOT exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'select_rule_rn_eltern'
            AND pronamespace = 'public'::regnamespace),
    'post-rename: select_rule_rn_eltern function should exist'
);

-- 4j. nephews compute_validate function rebuilt (set_record ref updated)
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'compute_validate_rn_nephews'
            AND pronamespace = 'public'::regnamespace),
    'post-rename: compute_validate_rn_nephews function still exists'
);

-- 4k. set_record reference in nephews.computed_fields updated
SELECT ok(
    (SELECT computed_fields::text FROM entities WHERE table_name = 'rn_nephews') LIKE '%rn_eltern%',
    'nephews: computed_fields set_record reference updated to rn_eltern'
);

SELECT ok(
    NOT ((SELECT computed_fields::text FROM entities WHERE table_name = 'rn_nephews') LIKE '%rn_parents%'),
    'nephews: computed_fields should NOT contain rn_parents'
);

-- =====================================================
-- STEP 5: Insert a second record per table
-- =====================================================

INSERT INTO rn_families (family_name) VALUES ('Jones');

SELECT is(
    (SELECT count(*)::integer FROM rn_families WHERE family_name = 'Jones'),
    1,
    'families: second record Jones inserted'
);

-- Insert into rn_eltern (the renamed table)
DO $$
DECLARE
    v_family_id INTEGER;
    v_parent_id INTEGER;
BEGIN
    SELECT id INTO v_family_id FROM rn_families WHERE family_name = 'Jones';
    INSERT INTO rn_eltern (parent_name, family_ref) VALUES ('Jane', v_family_id) RETURNING id INTO v_parent_id;
    INSERT INTO rn_children (child_name, parent_ref) VALUES ('Charlie', v_parent_id);
    INSERT INTO rn_nephews (nephew_name, parent_ref) VALUES ('Dave', v_parent_id);
END $$;

SELECT is(
    (SELECT parent_name FROM rn_eltern WHERE parent_name = 'Jane'),
    'Jane',
    'eltern: second record Jane inserted'
);

-- Verify computed field still works on new records
SELECT is(
    (SELECT full_title FROM rn_eltern WHERE parent_name = 'Jane'),
    'Jane (parent)',
    'eltern: computed full_title works on new record'
);

-- Verify validation still works after rename
SELECT throws_ok(
    $$INSERT INTO rn_eltern (parent_name) VALUES ('')$$,
    '23514',
    NULL,
    'eltern: validation still rejects empty parent_name after rename'
);

SELECT is(
    (SELECT child_name FROM rn_children WHERE child_name = 'Charlie'),
    'Charlie',
    'children: second record Charlie inserted'
);

SELECT is(
    (SELECT nephew_name FROM rn_nephews WHERE nephew_name = 'Dave'),
    'Dave',
    'nephews: second record Dave inserted'
);

-- Verify set_record still works after rename (references rn_eltern now)
SELECT is(
    (SELECT parent_title FROM rn_nephews WHERE nephew_name = 'Dave'),
    'Jane (parent)',
    'nephews: set_record computed parent_title works after rename with new record'
);

SELECT * FROM finish();
ROLLBACK;
