-- Renaming an entity with a field that references the entity itself. The rename
-- reaches such a field twice: the foreign key on fields.table_name cascades first,
-- while reference_table still holds the old name, and rename_dd_reference_tables
-- rewrites reference_table afterwards. In between the field names an entity that no
-- longer exists, and that must not be refused.
BEGIN;

SELECT plan(21);

SELECT authenticate_as('user3');

-- The definition of a foreign key, by the table it is on and its name.
CREATE FUNCTION pg_temp.fk_of(p_table TEXT, p_name TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT pg_get_constraintdef(c.oid)
      FROM pg_constraint c
     WHERE c.conrelid = to_regclass(format('public.%I', p_table))
       AND c.conname = p_name;
$fn$;

-- =====================================================
-- GROUP 1: a plain entity with records, referenced from elsewhere too
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES
    ('rs_emps',  'Emp',  'Emps',  1),
    ('rs_depts', 'Dept', 'Depts', 1);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rs_emps',  'manager', 'Manager', 'reference', 'rs_emps', 'clear'),
    ('rs_depts', 'head',    'Head',    'reference', 'rs_emps', 'restrict');

INSERT INTO rs_emps (label) VALUES ('Boss');
INSERT INTO rs_emps (label, manager) SELECT 'Worker', id FROM rs_emps WHERE label = 'Boss';
INSERT INTO rs_depts (label, head) SELECT 'Sales', id FROM rs_emps WHERE label = 'Boss';

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_staff' WHERE table_name = 'rs_emps'$$,
    'an entity that references itself can be renamed');

SELECT is(
    (SELECT table_name || '.' || field_name || ' -> ' || reference_table
       FROM fields WHERE table_name = 'rs_staff' AND field_name = 'manager'),
    'rs_staff.manager -> rs_staff',
    'the self-referencing field follows the rename at both ends');

SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'rs_depts' AND field_name = 'head'),
    'rs_staff',
    'a field of another entity follows the rename too');

SELECT is(
    (SELECT count(*)::integer FROM fields WHERE table_name = 'rs_emps' OR reference_table = 'rs_emps'),
    0,
    'no field row keeps the old name');

SELECT is(
    pg_temp.fk_of('rs_staff', 'rs_staff_manager_fkey'),
    'FOREIGN KEY (manager) REFERENCES rs_staff(id) ON UPDATE CASCADE ON DELETE SET NULL',
    'the foreign key points at the new name and keeps its delete mode');

SELECT is(
    (SELECT w.manager = b.id FROM rs_staff w, rs_staff b WHERE w.label = 'Worker' AND b.label = 'Boss'),
    TRUE,
    'the records still point at each other');

SELECT is(
    (SELECT manager_label(w) FROM rs_staff w WHERE w.label = 'Worker'),
    'Boss',
    'the label companion reads the new name');

SELECT throws_ok($$INSERT INTO rs_staff (label, manager) VALUES ('Ghost', 987654)$$,
    '23503', NULL,
    'the foreign key is enforced after the rename');

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_people' WHERE table_name = 'rs_staff'$$,
    'a second rename works');

SELECT is(
    pg_temp.fk_of('rs_people', 'rs_people_manager_fkey'),
    'FOREIGN KEY (manager) REFERENCES rs_people(id) ON UPDATE CASCADE ON DELETE SET NULL',
    'and the foreign key follows it');

-- =====================================================
-- GROUP 2: parent format
-- =====================================================

-- No records: a parent field is NOT NULL, so a first row with no parent fails the
-- foreign key on the column's default.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('rs_tree', 'Tree', 'Trees', 1);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
VALUES ('rs_tree', 'up', 'Up', 'parent', 'rs_tree', 'cascade');

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_forest' WHERE table_name = 'rs_tree'$$,
    'a self-referencing parent field does not block a rename');

SELECT is(
    pg_temp.fk_of('rs_forest', 'rs_forest_up_fkey'),
    'FOREIGN KEY (up) REFERENCES rs_forest(id) ON UPDATE CASCADE ON DELETE CASCADE',
    'and its foreign key points at the new name and still cascades');

-- =====================================================
-- GROUP 3: unmanaged, which has metadata only
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed)
VALUES ('rs_unm', 'Unm', 'Unms', 1, FALSE);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
VALUES ('rs_unm', 'up', 'Up', 'reference', 'rs_unm', 'restrict');

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_unm2' WHERE table_name = 'rs_unm'$$,
    'an unmanaged entity that references itself can be renamed');

SELECT is(
    (SELECT table_name || '.' || field_name || ' -> ' || reference_table
       FROM fields WHERE table_name = 'rs_unm2' AND field_name = 'up'),
    'rs_unm2.up -> rs_unm2',
    'and its field follows at both ends');

-- =====================================================
-- GROUP 4: an is_a family, where a rename also rebuilds the views
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('rs_root', 'Root', 'Roots', 1, 'typeid', 'rsroot');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('rs_sub', 'Sub', 'Subs', 1, 'is_a', 'rssub', 'rs_root');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rs_root', 'root_up', 'Root Up', 'reference', 'rs_root', 'clear'),
    ('rs_sub',  'sub_up',  'Sub Up',  'reference', 'rs_sub',  'clear');

INSERT INTO rs_sub (label) VALUES ('s1');
INSERT INTO rs_sub (label, sub_up) SELECT 's2', id FROM rs_sub WHERE label = 's1';

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_sub2' WHERE table_name = 'rs_sub'$$,
    'a subtype that references itself can be renamed');

SELECT is(
    pg_temp.fk_of('rs_sub2_ext', 'rs_sub2_ext_sub_up_fkey'),
    'FOREIGN KEY (sub_up) REFERENCES rs_sub2_ext(id) ON UPDATE CASCADE ON DELETE SET NULL',
    'its foreign key points at the renamed part');

SELECT is(
    (SELECT count(*)::integer FROM rs_sub2 WHERE sub_up IS NOT NULL),
    1,
    'the records read through the renamed view');

SELECT lives_ok($$UPDATE entities SET table_name = 'rs_root2' WHERE table_name = 'rs_root'$$,
    'a root that references itself can be renamed');

SELECT is(
    pg_temp.fk_of('rs_root2', 'rs_root2_root_up_fkey'),
    'FOREIGN KEY (root_up) REFERENCES rs_root2(id) ON UPDATE CASCADE ON DELETE SET NULL',
    'its foreign key points at the new name');

SELECT is(
    (SELECT count(*)::integer FROM rs_sub2 WHERE root_up IS NULL),
    2,
    'the subtype view shows the field of the renamed root');

SELECT lives_ok($$INSERT INTO rs_sub2 (label, sub_up) SELECT 's3', id FROM rs_sub2 WHERE label = 's1'$$,
    'and the family writes under the new names');

SELECT * FROM finish();
ROLLBACK;
