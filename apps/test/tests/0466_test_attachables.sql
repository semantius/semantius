-- Attachable entities (0450_attachables.sql): what the dictionary keeps for
-- them, what it refuses, and what deletes, truncates and drops of a target do.
--   PART 1  the attached_to field, the link entity, get_schema
--   PART 2  what cannot be attachable, or a target, and the protected link entity
--   PART 3  changing the attach mode
--   PART 4  deleting, truncating, switching off and dropping a target
--   PART 5  renames of a target and of an attachable entity, ensure_entities
-- The attach step and the policies are 0625_test_attach_policies.sql.
--
-- Fixture entities use the 'atx' prefix; everything is rolled back.
BEGIN;

SELECT plan(58);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('atx_order', 'Order', 'Orders', 1, 'public:read', 'admin');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES ('atx_case', 'Case', 'Cases', 1, 'public:read', 'admin', 'typeid', 'atxcase');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('atx_bug', 'Bug', 'Bugs', 1, 'is_a', 'atxbug', 'atx_case');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      attach_mode, attach_permission, attach_on_target_delete)
VALUES ('atx_note', 'Note', 'Notes', 1, 'public:read', 'admin', 'single', 'view', 'cascade'),
       ('atx_doc', 'Doc', 'Docs', 1, 'public:read', 'admin', 'owned_shared', 'edit', 'restrict'),
       ('atx_todo', 'Todo', 'Todos', 1, 'public:read', 'admin', 'multiple', 'view', '');
INSERT INTO entity_attachables (target, attachable)
VALUES ('atx_order', 'atx_note'), ('atx_case', 'atx_note'), ('atx_order', 'atx_doc'),
       ('atx_order', 'atx_todo'), ('atx_case', 'atx_todo');

INSERT INTO atx_order (label) VALUES ('o1'), ('o2'), ('o3'), ('o4'), ('o5'), ('o6');
INSERT INTO atx_case (label) VALUES ('c1');
INSERT INTO atx_bug (label) VALUES ('b1');

CREATE FUNCTION pg_temp.oref(p_label text) RETURNS text LANGUAGE sql AS
$$ SELECT 'atx_order:' || id FROM atx_order WHERE label = p_label $$;

-- =====================================================
-- PART 1: what the dictionary keeps
-- =====================================================
SELECT is(
    (SELECT format || ' ' || ctype || ' ' || input_type FROM fields WHERE table_name = 'atx_note' AND field_name = 'attached_to'),
    'text attached_to required',
    'single: the dictionary gives the entity the required text field attached_to, ctype attached_to');

SELECT ok(pg_get_indexdef('public.idx_atx_note_attached_to'::regclass) LIKE '%(attached_to text_pattern_ops)%',
    'attached_to is indexed with text_pattern_ops, for lookups by the prefix of one table''s references');

SELECT is(
    (SELECT link_of FROM entities WHERE table_name = 'atx_doc_links'),
    'atx_doc',
    'owned_shared: the link entity <entity>_links is marked with link_of');

SELECT ok(EXISTS (SELECT 1 FROM fields WHERE table_name = 'atx_doc' AND field_name = 'attached_to' AND ctype = 'attached_to'),
    'owned_shared: the owner is held in attached_to');

SELECT is(
    (SELECT string_agg(field_name || ' ' || format || ' ' || reference_table || ' ' || reference_delete_mode || ' ' || ctype, ', ' ORDER BY field_order)
       FROM fields WHERE table_name = 'atx_doc_links' AND field_name IN ('atx_doc_id', 'attached_to')),
    'atx_doc_id parent atx_doc cascade , attached_to text   attached_to',
    'the link entity holds the attachable record (a parent, cascading) and a target');

SELECT ok(pg_get_indexdef('public.atx_doc_links_attached_to_unique'::regclass) LIKE 'CREATE UNIQUE INDEX%(attached_to text_pattern_ops, atx_doc_id)%'
          AND NOT EXISTS (SELECT 1 FROM pg_indexes i
                           WHERE i.schemaname = 'public' AND i.tablename = 'atx_doc_links'
                             AND i.indexname IN ('idx_atx_doc_links_attached_to', 'atx_doc_links_search_vector_idx')),
    'a record is linked to a target once, by the one index of attached_to; the empty label is not searched');

SELECT ok(EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_todo_links' AND link_of = 'atx_todo')
          AND NOT EXISTS (SELECT 1 FROM fields WHERE table_name = 'atx_todo' AND field_name = 'attached_to'),
    'multiple: the targets are in the link entity only');

SELECT is((SELECT id FROM entity_attachables WHERE target = 'atx_order' AND attachable = 'atx_note'), 'atx_order.atx_note',
    'entity_attachables is keyed like a junction table: target.attachable');

SELECT is(
    (SELECT ((get_schema('atx_note')::jsonb) -> 'attach_mode') || ((get_schema('atx_note')::jsonb) -> 'attach_targets')),
    '["single", "atx_case", "atx_order"]'::jsonb,
    'get_schema reports the attach mode and the targets of an attachable entity');

SELECT is((get_schema('atx_order')::jsonb) -> 'attachables', '["atx_doc", "atx_note", "atx_todo"]'::jsonb,
    'get_schema reports the attachable entities of a target entity');

SELECT is((get_schema('atx_bug')::jsonb) -> 'attachables', '["atx_note", "atx_todo"]'::jsonb,
    'an is_a subtype reports the attachable entities its base admits');

SELECT ok(NOT ((get_schema('atx_order')::jsonb) ? 'attach_mode'),
    'an entity that is not attachable reports no attach mode');

-- =====================================================
-- PART 2: what is refused
-- =====================================================
SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                            attach_mode, attach_permission, attach_on_target_delete)
      VALUES ('atx_sub', 'Sub', 'Subs', 1, 'is_a', 'atxsub', 'atx_case', 'single', 'view', 'cascade')$$,
    '91002', NULL, 'an is_a entity is attachable through its root only');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity, attach_mode, attach_permission)
      VALUES ('atx_more', 'More', 'Mores', 1, 'has_a', 'atx_case', 'multiple', 'view')$$,
    '91002', NULL, 'a has_a entity cannot be attachable');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode, attach_permission)
      VALUES ('atx_a_name_that_is_long', 'Long', 'Longs', 1, 'multiple', 'view')$$,
    '91004', NULL, 'an attachable entity''s name has at most 22 bytes, so its link field fits');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed, attach_mode, attach_permission)
      VALUES ('atx_loose', 'Loose', 'Looses', 1, FALSE, 'multiple', 'view')$$,
    '91001', NULL, 'an unmanaged entity cannot be attachable');

SELECT throws_ok(
    $$UPDATE entities SET attach_mode = 'multiple', attach_permission = 'view' WHERE table_name = 'user_permissions'$$,
    '91003', NULL, 'a system table with a computed key cannot be attachable');

SELECT throws_ok(
    $$UPDATE entities SET managed = FALSE WHERE table_name = 'atx_order'$$,
    '91006', NULL, 'a listed target stays managed');

INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('atx_own', 'Own', 'Owns', 1);
INSERT INTO fields (table_name, field_name, title, format) VALUES ('atx_own', 'attached_to', 'Attached to', 'int32');
SELECT throws_ok(
    $$UPDATE entities SET attach_mode = 'single', attach_permission = 'view', attach_on_target_delete = 'cascade'
       WHERE table_name = 'atx_own'$$,
    '91022', NULL, 'an entity with a field attached_to of its own cannot keep its target there');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode)
      VALUES ('atx_bare', 'Bare', 'Bares', 1, 'multiple')$$,
    '23514', 'new row for relation "entities" violates check constraint "attach_permission_set"',
    'an attachable entity names its attach permission');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode, attach_permission)
      VALUES ('atx_bare', 'Bare', 'Bares', 1, 'single', 'view')$$,
    '23514', 'new row for relation "entities" violates check constraint "attach_on_target_delete_set"',
    'a single entity names what a delete of its target does');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id)
      VALUES ('atx_some_links', 'Link', 'Links', 1)$$,
    '23514', 'new row for relation "entities" violates check constraint "links_name_is_link"',
    'a name ending in _links is kept for link entities');

SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('permissions', 'atx_note')$$,
    '91014', NULL, 'an entity whose key can be renamed cannot be a target');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed)
VALUES ('atx_ghost', 'Ghost', 'Ghosts', 1, FALSE);
SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_ghost', 'atx_note')$$,
    '91010', NULL, 'an unmanaged entity cannot be a target');

SELECT throws_ok(
    $$UPDATE entity_attachables SET target = 'atx_case' WHERE target = 'atx_order' AND attachable = 'atx_doc'$$,
    '91008', NULL, 'a row of entity_attachables is not changed in place');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('atx_extra', 'Extra', 'Extras', 1, 'has_a', 'atx_case');
SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_extra', 'atx_note')$$,
    '91011', NULL, 'a has_a entity cannot be a target: its base is');

SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_note', 'atx_note')$$,
    '91013', NULL, 'an attachable entity cannot be a target of itself');

SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_doc_links', 'atx_note')$$,
    '91012', NULL, 'a link entity cannot be a target');

SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_case', 'atx_order')$$,
    '91009', NULL, 'an entity without an attach mode cannot be switched on');

SELECT throws_ok(
    $$UPDATE entities SET description = 'mine now' WHERE table_name = 'atx_doc_links'$$,
    '91007', NULL, 'the link entity''s row is the dictionary''s');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format) VALUES ('atx_doc_links', 'extra', 'Extra', 'text')$$,
    '91007', NULL, 'and so are its fields');

-- =====================================================
-- PART 3: changing the attach mode
-- =====================================================
INSERT INTO atx_note (label, attached_to) VALUES ('n1', pg_temp.oref('o1'));
SELECT throws_ok(
    $$UPDATE entities SET attach_mode = 'multiple' WHERE table_name = 'atx_note'$$,
    '91005', NULL, 'the attach mode cannot change while the entity has records');

UPDATE entities SET attach_mode = 'single', attach_on_target_delete = 'cascade' WHERE table_name = 'atx_todo';
SELECT ok(EXISTS (SELECT 1 FROM fields WHERE table_name = 'atx_todo' AND field_name = 'attached_to')
          AND NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_todo_links'),
    'multiple to single: attached_to comes, the link entity goes');
UPDATE entities SET attach_mode = 'multiple' WHERE table_name = 'atx_todo';
SELECT ok(NOT EXISTS (SELECT 1 FROM fields WHERE table_name = 'atx_todo' AND field_name = 'attached_to')
          AND EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_todo_links'),
    'single to multiple: attached_to goes, the link entity comes back');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode, attach_permission)
VALUES ('atx_tmp', 'Tmp', 'Tmps', 1, 'multiple', 'view');
INSERT INTO entity_attachables (target, attachable) VALUES ('atx_order', 'atx_tmp');
UPDATE entities SET attach_mode = 'none' WHERE table_name = 'atx_tmp';
SELECT ok(NOT EXISTS (SELECT 1 FROM entity_attachables WHERE attachable = 'atx_tmp')
          AND NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_tmp_links'),
    'leaving attachable removes the link entity and the targets');

INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Atx One', 'atxone', 'attachables fixture', 'user:read'),
       ('Atx Two', 'atxtwo', 'attachables fixture', 'user:read');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode, attach_permission)
VALUES ('atx_mover', 'Mover', 'Movers', (SELECT id FROM modules WHERE module_slug = 'atxone'), 'multiple', 'view');
UPDATE entities SET module_id = (SELECT id FROM modules WHERE module_slug = 'atxtwo') WHERE table_name = 'atx_mover';
DELETE FROM modules WHERE module_slug = 'atxone';
SELECT ok(EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_mover_links'
                     AND module_id = (SELECT id FROM modules WHERE module_slug = 'atxtwo')),
    'the link entity moves with its attachable entity to another module, so the old module''s delete leaves it');

-- A module holding an attachable entity created before its target, with
-- records attached: whichever of the two the delete reaches first, the other
-- is not left half done.
INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Atx Mix', 'atxmix', 'attachables fixture', 'user:read');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, attach_mode, attach_permission, attach_on_target_delete)
VALUES ('atx_mix_note', 'Mix Note', 'Mix Notes', (SELECT id FROM modules WHERE module_slug = 'atxmix'), 'single', 'view', 'cascade');
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('atx_mix_target', 'Mix Target', 'Mix Targets', (SELECT id FROM modules WHERE module_slug = 'atxmix'));
INSERT INTO entity_attachables (target, attachable) VALUES ('atx_mix_target', 'atx_mix_note');
INSERT INTO atx_mix_target (label) VALUES ('mt');
INSERT INTO atx_mix_note (label, attached_to) SELECT 'mn', 'atx_mix_target:' || id FROM atx_mix_target;
SELECT lives_ok($$DELETE FROM modules WHERE module_slug = 'atxmix'$$,
    'a module holding an attachable entity and its target is deleted with records attached');

-- Following a target is refused when the target's records follow the
-- attachable entity's in turn: the policies would read each other without end.
INSERT INTO entity_attachables (target, attachable) VALUES ('atx_note', 'atx_doc');
SELECT throws_ok(
    $$INSERT INTO entity_attachables (target, attachable) VALUES ('atx_doc', 'atx_note')$$,
    '91024', NULL, 'an entity whose records follow the attachable entity''s cannot be its target');
INSERT INTO entity_attachables (target, attachable) VALUES ('atx_todo', 'atx_doc'), ('atx_doc', 'atx_todo');
SELECT throws_ok(
    $$UPDATE entities SET attach_mode = 'single', attach_on_target_delete = 'cascade' WHERE table_name = 'atx_todo'$$,
    '91024', NULL, 'nor can an entity become single while one of its targets follows it');
DELETE FROM entity_attachables
 WHERE (target, attachable) IN (('atx_note', 'atx_doc'), ('atx_todo', 'atx_doc'), ('atx_doc', 'atx_todo'));

-- =====================================================
-- PART 4: deleting, truncating, switching off, dropping
-- =====================================================
SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.atx_order'::regclass AND tgname = 'attached_del')
          AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.atx_order'::regclass AND tgname = 'attached_trc')
          AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.atx_case'::regclass AND tgname = 'attached_del')
          AND to_regprocedure('common.attached_atx_order(text[])') IS NOT NULL,
    'every target table carries attached_del and attached_trc and its delete step attached_<t>, an is_a target its root');

DELETE FROM atx_order WHERE label = 'o1';
SELECT ok(NOT EXISTS (SELECT 1 FROM atx_note WHERE label = 'n1'), 'cascade: deleting the target deletes the record attached to it');

INSERT INTO atx_doc (label, attached_to) VALUES ('d2', pg_temp.oref('o2')), ('d3', pg_temp.oref('o3'));
SELECT throws_ok(
    $$DELETE FROM atx_order WHERE label = 'o2'$$,
    '91016', NULL, 'restrict: a target cannot be deleted while a record is attached to it in attached_to');

INSERT INTO atx_doc_links (atx_doc_id, attached_to)
SELECT id, pg_temp.oref('o4') FROM atx_doc WHERE label = 'd3';
DELETE FROM atx_order WHERE label = 'o4';
SELECT ok(NOT EXISTS (SELECT 1 FROM atx_doc_links) AND EXISTS (SELECT 1 FROM atx_doc WHERE label = 'd3'),
    'deleting a further target removes the link and keeps the record');

INSERT INTO atx_todo (label) VALUES ('t1'), ('t2'), ('t3');
INSERT INTO atx_todo_links (atx_todo_id, attached_to)
SELECT t.id, pg_temp.oref('o5') FROM atx_todo t WHERE t.label IN ('t1', 't2')
UNION ALL
SELECT t.id, 'atx_case:' || (SELECT id FROM atx_case WHERE label = 'c1') FROM atx_todo t WHERE t.label = 't2';
DELETE FROM atx_order WHERE label = 'o5';
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM atx_todo), 't2, t3',
    'multiple: a record that loses its last target is deleted; one with a target left, and one created without any, stay');

-- An is_a family of an attachable entity: a subtype record is attached through
-- the root's attached_to and deleted through its subtype's view.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      id_type, id_prefix, attach_mode, attach_permission, attach_on_target_delete)
VALUES ('atx_memo', 'Memo', 'Memos', 1, 'public:read', 'admin', 'typeid', 'atxmemo', 'single', 'view', 'cascade');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('atx_voice_memo', 'Voice Memo', 'Voice Memos', 1, 'is_a', 'atxvmemo', 'atx_memo');
INSERT INTO entity_attachables (target, attachable) VALUES ('atx_order', 'atx_memo');
INSERT INTO atx_order (label) VALUES ('o7');
INSERT INTO atx_voice_memo (label, attached_to) VALUES ('vm', pg_temp.oref('o7'));
DELETE FROM atx_order WHERE label = 'o7';
SELECT ok(NOT EXISTS (SELECT 1 FROM atx_memo WHERE label = 'vm'),
    'is_a attachable: deleting the target deletes the subtype record, every part of it');

INSERT INTO atx_note (label, attached_to) VALUES ('nb', 'atx_case:' || (SELECT id FROM atx_bug WHERE label = 'b1'));
SELECT is((SELECT attached_to FROM atx_note WHERE label = 'nb'), 'atx_bug:' || (SELECT id FROM atx_bug WHERE label = 'b1'),
    'is_a: a reference through the base is stored under the subtype');
DELETE FROM atx_bug WHERE label = 'b1';
SELECT ok(NOT EXISTS (SELECT 1 FROM atx_note WHERE label = 'nb'),
    'is_a: deleting the subtype record reaches the delete step on the root');

SELECT throws_ok(
    $$DELETE FROM entity_attachables WHERE target = 'atx_order' AND attachable = 'atx_doc'$$,
    '91015', NULL, 'a target cannot be switched off while records are attached there');

SELECT throws_ok(
    $$DELETE FROM entities WHERE table_name = 'atx_order'$$,
    '91015', NULL, 'nor can the target entity be dropped');

DELETE FROM entity_attachables WHERE target = 'atx_case' AND attachable = 'atx_note';
SELECT ok(NOT EXISTS (SELECT 1 FROM entity_attachables WHERE target = 'atx_case' AND attachable = 'atx_note'),
    'a target with nothing attached is switched off');

RESET ROLE;
SELECT throws_ok(
    $$TRUNCATE atx_order$$,
    '91017', NULL, 'a TRUNCATE fires no delete step, so it is refused while records are attached');
SELECT authenticate_as('user3');

-- =====================================================
-- PART 5: renames, ensure_entities
-- =====================================================
INSERT INTO atx_doc_links (atx_doc_id, attached_to) SELECT id, pg_temp.oref('o3') FROM atx_doc WHERE label = 'd2';
UPDATE entities SET table_name = 'atx_orders' WHERE table_name = 'atx_order';
SELECT is((SELECT string_agg(split_part(x.attached_to, ':', 1), ', ')
             FROM (SELECT attached_to FROM atx_doc UNION ALL SELECT attached_to FROM atx_doc_links) x),
    'atx_orders, atx_orders, atx_orders',
    'a rename of the target rewrites the references to it, in attached_to and in the link entity');

INSERT INTO atx_note (label, attached_to) SELECT 'n6', 'atx_orders:' || id FROM atx_orders WHERE label = 'o6';
DELETE FROM atx_orders WHERE label = 'o6';
SELECT ok(NOT EXISTS (SELECT 1 FROM atx_note WHERE label = 'n6')
          AND to_regprocedure('common.attached_atx_orders(text[])') IS NOT NULL
          AND to_regprocedure('common.attached_atx_order(text[])') IS NULL,
    'after the rename the delete step works under the new name');

INSERT INTO atx_doc_links (atx_doc_id, attached_to)
SELECT d.id, 'atx_orders:' || (SELECT id FROM atx_orders WHERE label = 'o2') FROM atx_doc d WHERE d.label = 'd3';
SELECT throws_ok(
    $$UPDATE entities SET table_name = 'atx_doc_with_a_long_name' WHERE table_name = 'atx_doc'$$,
    '91004', NULL, 'a rename of an attachable entity to a name longer than 22 bytes is refused before its link entity is renamed');
UPDATE entities SET table_name = 'atx_file' WHERE table_name = 'atx_doc';
SELECT is(
    (SELECT count(*)::int FROM atx_file_links l JOIN atx_file f ON f.id = l.atx_file_id WHERE f.label = 'd3'),
    1,
    'a rename of the attachable entity renames its link entity and the link field, links kept');

-- ensure_entities is the migration runner's, run as the connecting role.
RESET ROLE;
SELECT is(
    (SELECT ensure_entities('{"version": 1, "entity_attachables": [{"target": "atx_case", "attachable": "atx_file"},
                                                                    {"target": "atx_orders", "attachable": "atx_file"}]}'::jsonb)
            -> 'entity_attachables' -> 'created'),
    '["atx_file on atx_case"]'::jsonb,
    'ensure_entities adds the targets a definition lists and has not');

SELECT ok(EXISTS (SELECT 1 FROM entity_attachables WHERE target = 'atx_orders' AND attachable = 'atx_note'),
    'and removes none it does not list');
SELECT authenticate_as('user3');

DELETE FROM entities WHERE table_name = 'atx_todo';
SELECT ok(NOT EXISTS (SELECT 1 FROM entities WHERE table_name = 'atx_todo_links'),
    'deleting an attachable entity deletes its link entity');

SELECT * FROM finish();
ROLLBACK;
