-- Deleting an entity that fields of other entities reference is refused (90260):
-- DROP TABLE ... CASCADE would take their foreign keys and leave the columns, the
-- values and the field rows pointing at nothing. reference_delete_mode plays no
-- part, because it governs deleting records, not the entity.
--
-- A field written while the delete runs needs two sessions, which pgTAP does not
-- have: pgdocker/pg-reference-delete-race.sh covers that.
BEGIN;

SELECT plan(40);

-- The hint of the error a statement raises, or NULL when it succeeds.
CREATE FUNCTION pg_temp.hint_of(p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $fn$
DECLARE
    v_hint TEXT;
BEGIN
    EXECUTE p_sql;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    RETURN v_hint::jsonb;
END $fn$;

CREATE FUNCTION pg_temp.entity_in(p_table TEXT, p_module TEXT) RETURNS VOID LANGUAGE sql AS $fn$
    INSERT INTO entities (table_name, singular_label, plural_label, module_id)
    SELECT p_table, p_table, p_table, id FROM modules WHERE module_name = p_module;
$fn$;

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: refused, whatever the format and delete mode
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id)
SELECT t, t, t, 1
  FROM unnest(ARRAY['rd_regions', 'rd_other', 'rd_customers', 'rd_notes', 'rd_tasks']) AS t;

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_customers', 'region', 'Region', 'reference', 'rd_regions', 'restrict'),
    ('rd_notes',     'region', 'Region', 'parent',    'rd_regions', 'cascade'),
    ('rd_tasks',     'region', 'Region', 'reference', 'rd_regions', 'clear');

INSERT INTO rd_regions (label) VALUES ('EMEA');
INSERT INTO rd_customers (label, region) SELECT 'Acme', id FROM rd_regions;
INSERT INTO rd_notes (label, region) SELECT 'Note', id FROM rd_regions;
INSERT INTO rd_tasks (label, region) SELECT 'Task', id FROM rd_regions;

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'rd_regions'$$,
    '90260', NULL,
    'an entity that other entities reference cannot be deleted');

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_regions'$$),
    jsonb_build_object(
        'table', 'rd_regions',
        'fields', 'rd_customers.region, rd_notes.region, rd_tasks.region',
        'hint', 'Delete those fields or point them at another entity first.'),
    'the refusal names the entity and every field, whatever its format and delete mode');

SELECT ok(
    EXISTS (SELECT 1 FROM entities WHERE table_name = 'rd_regions')
    AND to_regclass('public.rd_regions') IS NOT NULL
    AND (SELECT count(*) FROM pg_constraint
          WHERE conname IN ('rd_customers_region_fkey', 'rd_notes_region_fkey', 'rd_tasks_region_fkey')) = 3
    AND (SELECT count(*) FROM rd_customers) = 1,
    'a refused delete leaves the entity, its table, the foreign keys and the records in place');

-- =====================================================
-- GROUP 2: a rename keeps the protection
-- =====================================================

UPDATE entities SET table_name = 'rd_areas' WHERE table_name = 'rd_regions';

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_areas'$$) ->> 'fields',
    'rd_customers.region, rd_notes.region, rd_tasks.region',
    'a renamed entity is still protected, because reference_table follows the rename');

-- =====================================================
-- GROUP 3: the ways out the hint names
-- =====================================================

DELETE FROM fields WHERE table_name = 'rd_tasks' AND field_name = 'region';

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_areas'$$) ->> 'fields',
    'rd_customers.region, rd_notes.region',
    'a deleted field no longer counts');

DELETE FROM rd_notes;
UPDATE fields SET reference_table = 'rd_other' WHERE table_name = 'rd_notes' AND field_name = 'region';

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_areas'$$) ->> 'fields',
    'rd_customers.region',
    'a field pointed at another entity no longer counts');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'rd_customers'$$,
    'the entity holding a reference can be deleted');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'rd_areas'$$,
    'and with no reference left the entity it pointed at can be too');

SELECT ok(
    to_regclass('public.rd_areas') IS NULL
    AND NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'rd_areas'),
    'the delete dropped the entity and its table');

-- =====================================================
-- GROUP 4: a self-reference goes with the entity
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id)
SELECT t, t, t, 1
  FROM unnest(ARRAY['rd_emps', 'rd_staff', 'rd_depts']) AS t;

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_emps',  'manager', 'Manager', 'reference', 'rd_emps',  'clear'),
    ('rd_staff', 'manager', 'Manager', 'reference', 'rd_staff', 'clear'),
    ('rd_depts', 'head',    'Head',    'reference', 'rd_staff', 'restrict');

INSERT INTO rd_emps (label) VALUES ('boss');
INSERT INTO rd_emps (label, manager) SELECT 'worker', id FROM rd_emps;

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'rd_emps'$$,
    'an entity that only references itself can be deleted');

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_staff'$$) ->> 'fields',
    'rd_depts.head',
    'a self-reference is not listed next to a reference from another entity');

-- =====================================================
-- GROUP 5: unmanaged entities, whose metadata would dangle the same way
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed) VALUES
    ('rd_unm_target', 'Target', 'Targets', 1, FALSE),
    ('rd_unm_ref',    'Ref',    'Refs',    1, FALSE);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_unm_ref', 'target', 'Target', 'reference', 'rd_unm_target', 'restrict'),
    ('rd_unm_ref', 'other',  'Other',  'reference', 'rd_other',      'restrict');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'rd_unm_target'$$,
    '90260', NULL,
    'an unmanaged entity is protected too');

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_other'$$) ->> 'fields',
    'rd_notes.region, rd_unm_ref.other',
    'a field of an unmanaged entity counts, as does one that was pointed here');

-- =====================================================
-- GROUP 6: module deletes
-- =====================================================

INSERT INTO modules (module_name)
VALUES ('rd_same_1'), ('rd_same_2'), ('rd_a'), ('rd_b'), ('rd_c'), ('rd_d');

-- Both entities in the module, created in both orders, because the cascade deletes
-- them in one statement in no guaranteed order.
SELECT pg_temp.entity_in('rd_s1_target', 'rd_same_1');
SELECT pg_temp.entity_in('rd_s1_ref',    'rd_same_1');
SELECT pg_temp.entity_in('rd_s2_ref',    'rd_same_2');
SELECT pg_temp.entity_in('rd_s2_target', 'rd_same_2');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_s1_ref', 'target', 'Target', 'reference', 'rd_s1_target', 'restrict'),
    ('rd_s2_ref', 'target', 'Target', 'reference', 'rd_s2_target', 'restrict');

INSERT INTO rd_s1_target (label) VALUES ('t');
INSERT INTO rd_s1_ref (label, target) SELECT 'r', id FROM rd_s1_target;
INSERT INTO rd_s2_target (label) VALUES ('t');
INSERT INTO rd_s2_ref (label, target) SELECT 'r', id FROM rd_s2_target;

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_same_1'$$,
    'a module delete takes a reference between its own entities along');
SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_same_2'$$,
    'whichever of the two entities was created first');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM entities
                 WHERE table_name IN ('rd_s1_target', 'rd_s1_ref', 'rd_s2_target', 'rd_s2_ref'))
    AND NOT EXISTS (SELECT 1 FROM fields
                     WHERE table_name IN ('rd_s1_target', 'rd_s1_ref', 'rd_s2_target', 'rd_s2_ref'))
    AND to_regclass('public.rd_s1_target') IS NULL AND to_regclass('public.rd_s1_ref') IS NULL
    AND to_regclass('public.rd_s2_target') IS NULL AND to_regclass('public.rd_s2_ref') IS NULL,
    'the module deletes left no entity, field or table');

-- A reference from another module.
SELECT pg_temp.entity_in('rd_a_target', 'rd_a');
SELECT pg_temp.entity_in('rd_b_ref',    'rd_b');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
VALUES ('rd_b_ref', 'target', 'Target', 'reference', 'rd_a_target', 'restrict');

SELECT throws_ok($$DELETE FROM modules WHERE module_name = 'rd_a'$$,
    '90260', NULL,
    'a module whose entity is referenced from another module cannot be deleted');
SELECT ok(
    EXISTS (SELECT 1 FROM modules WHERE module_name = 'rd_a')
    AND EXISTS (SELECT 1 FROM entities WHERE table_name = 'rd_a_target')
    AND to_regclass('public.rd_a_target') IS NOT NULL,
    'the refused module delete changed nothing');
SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_b'$$,
    'the module holding the reference can be deleted');
SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_a'$$,
    'then the module it pointed at');

-- Two modules referencing each other: one field has to go first.
SELECT pg_temp.entity_in('rd_c_x', 'rd_c');
SELECT pg_temp.entity_in('rd_d_y', 'rd_d');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_c_x', 'y', 'Y', 'reference', 'rd_d_y', 'restrict'),
    ('rd_d_y', 'x', 'X', 'reference', 'rd_c_x', 'restrict');

SELECT throws_ok($$DELETE FROM modules WHERE module_name = 'rd_c'$$,
    '90260', NULL,
    'modules referencing each other: the first cannot be deleted');
SELECT throws_ok($$DELETE FROM modules WHERE module_name = 'rd_d'$$,
    '90260', NULL,
    'modules referencing each other: nor can the second');

DELETE FROM fields WHERE table_name = 'rd_d_y' AND field_name = 'x';

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_c'$$,
    'with that field gone, the module it pointed at can be deleted');
SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'rd_d'$$,
    'and then the other one');

-- =====================================================
-- GROUP 7: how it sits with the family refusals
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('rd_fam_root', 'Root', 'Roots', 1, 'typeid', 'rdroot');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('rd_fam_sub', 'Sub', 'Subs', 1, 'is_a', 'rdsub', 'rd_fam_root');
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('rd_fam_out', 'Out', 'Outs', 1);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_fam_sub',  'owner', 'Owner', 'reference', 'rd_fam_root', 'restrict'),
    ('rd_fam_root', 'fav',   'Fav',   'reference', 'rd_fam_sub',  'clear'),
    ('rd_fam_out',  'sub',   'Sub',   'reference', 'rd_fam_sub',  'restrict');

INSERT INTO rd_fam_sub (label) VALUES ('s1');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'rd_fam_root'$$,
    '90248', NULL,
    'a base with a dependent is refused as such, even when the dependent also references it');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'rd_fam_sub'$$,
    '90260', NULL,
    'a reference is reported before the records: deleting the records would not help');

SELECT is(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'rd_fam_sub'$$) ->> 'fields',
    'rd_fam_out.sub, rd_fam_root.fav',
    'an is_a entity is protected, also from a field of its own base');

DELETE FROM fields WHERE (table_name, field_name) IN (('rd_fam_root', 'fav'), ('rd_fam_out', 'sub'));

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'rd_fam_sub'$$,
    '90247', NULL,
    'with the references gone the records are what is left in the way');

DELETE FROM rd_fam_sub;

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'rd_fam_sub'$$,
    'an empty, unreferenced subtype can be deleted while it references its base');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'rd_fam_root'$$,
    'and its reference to the base went with it');

-- =====================================================
-- GROUP 8: writing a reference
-- =====================================================

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
      VALUES ('rd_depts', 'nowhere', 'Nowhere', 'reference', 'rd_no_such', 'restrict')$$,
    '90212', NULL,
    'a new field cannot point at an entity that does not exist');

SELECT throws_ok(
    $$UPDATE fields SET reference_table = 'rd_no_such' WHERE table_name = 'rd_depts' AND field_name = 'head'$$,
    '90212', NULL,
    'a field cannot be pointed at an entity that does not exist');

SELECT lives_ok(
    $$UPDATE fields SET title = 'Dept Head' WHERE table_name = 'rd_depts' AND field_name = 'head'$$,
    'editing a reference field without changing its target works');

-- =====================================================
-- GROUP 9: a field already pointing at nothing
-- =====================================================

-- A database can hold such a field from before the refusal existed, so the delete
-- is reproduced by hand: the row goes and the table is dropped, taking the foreign
-- keys and leaving the rest.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
SELECT t, t, t, 1
  FROM unnest(ARRAY['rd_gone', 'rd_left']) AS t;

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode) VALUES
    ('rd_left', 'gone',  'Gone',  'reference', 'rd_gone', 'restrict'),
    ('rd_left', 'gone2', 'Gone2', 'reference', 'rd_gone', 'restrict');

INSERT INTO rd_gone (label) VALUES ('g');
INSERT INTO rd_left (label, gone, gone2) SELECT 'l', id, id FROM rd_gone;

RESET ROLE;
ALTER TABLE entities DISABLE TRIGGER delete_table_trigger;
DELETE FROM entities WHERE table_name = 'rd_gone';
DROP TABLE rd_gone CASCADE;
ALTER TABLE entities ENABLE TRIGGER delete_table_trigger;
SELECT authenticate_as('user3');

SELECT lives_ok(
    $$UPDATE fields SET title = 'Still Gone' WHERE table_name = 'rd_left' AND field_name = 'gone'$$,
    'a field pointing at nothing can be edited');

SELECT lives_ok($$UPDATE entities SET table_name = 'rd_left2' WHERE table_name = 'rd_left'$$,
    'and the entity holding it can be renamed');

SELECT throws_ok(
    $$UPDATE fields SET reference_delete_mode = 'clear' WHERE table_name = 'rd_left2' AND field_name = 'gone'$$,
    '90212', NULL,
    'a change that has to rebuild its foreign key is refused');

SELECT throws_ok(
    $$UPDATE fields SET reference_table = 'rd_no_such' WHERE table_name = 'rd_left2' AND field_name = 'gone'$$,
    '90212', NULL,
    'it cannot be pointed at another entity that does not exist');

UPDATE rd_left2 SET gone = NULL;

SELECT lives_ok(
    $$UPDATE fields SET reference_table = 'rd_depts' WHERE table_name = 'rd_left2' AND field_name = 'gone'$$,
    'it can be pointed at an entity that exists');

SELECT is(
    (SELECT count(*)::integer FROM pg_constraint
      WHERE conrelid = 'public.rd_left2'::regclass AND conname = 'rd_left2_gone_fkey'),
    1,
    'which gives it a foreign key again');

SELECT lives_ok($$DELETE FROM fields WHERE table_name = 'rd_left2' AND field_name = 'gone2'$$,
    'and it can be deleted');

SELECT * FROM finish();
ROLLBACK;
