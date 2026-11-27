-- Typed Number keys: entities.id_type typenumber, with type_prefix and
-- type_digits. A key a person can read and type, such as TASK-125: the
-- prefix, a hyphen, and a number from a counter of the entity padded to the
-- digits (0045_typeid.sql, dd_install_id_triggers, dd_id_sequence and
-- dd_id_sequence_sync in 0160_dd_functions.sql). Pinned here:
--   PART 1  the common.typenumber domain and the helpers of 0045_typeid.sql
--   PART 2  the key: column, id field, trigger, counter and its grant
--   PART 3  generated keys and their width
--   PART 4  supplied keys (90237, 90287), and a counter left behind them
--           (23505)
--   PART 5  changing the digits and the prefix: new numbers only
--   PART 6  is_a: a counter per subtype in the root's digits, the dispatch and
--           the view writes
--   PART 7  has_a on a typenumber base: minting and attaching
--   PART 8  what a family may be based on (90240) and the prefix kind (90288)
--   PART 9  ensure_entities, rename, drop, the managed flip, adoption, and a
--           counter name another table's sequence holds
--   PART 10 references
--
-- The key types that may not change, for typenumber among the others, are
-- pinned by 0437_test_entity_key_changes.sql, the trigger order by
-- 0657_test_computed_trigger_order.sql, fix_id_sequence by
-- 0730_test_fix_id_sequence.sql, the get_schema pattern by
-- 0700_test_get_schema.sql and record references by
-- 0465_test_record_references.sql. Each counter here is created inside
-- this transaction, so its numbers start at 1. Fixture entities are named
-- tn_*; everything is rolled back.

BEGIN;

SELECT plan(55);

-- =====================================================
-- PART 1: the domain and the helpers
-- =====================================================

SELECT ok(common.typenumber_check_text('TASK-1') AND common.typenumber_check_text('A-0')
          AND common.typenumber_check_text('INC2-000000000000000042')
          AND common.typenumber_check_text('ABCDEFGHIJ-1'),
    'typenumber_check_text: an uppercase prefix of up to 10, a hyphen and up to 18 digits');

SELECT ok(NOT common.typenumber_check_text('task-1') AND NOT common.typenumber_check_text('1TASK-1')
          AND NOT common.typenumber_check_text('TASK1') AND NOT common.typenumber_check_text('TASK-')
          AND NOT common.typenumber_check_text('ABCDEFGHIJK-1')
          AND NOT common.typenumber_check_text('TASK-1234567890123456789')
          AND NOT common.typenumber_check_text('TASK_1') AND NOT common.typenumber_check_text('TA-SK-1'),
    'typenumber_check_text: refuses a lowercase or long prefix, a missing number and more than 18 digits');

SELECT throws_ok($$SELECT 'task-1'::common.typenumber$$, '23514', NULL,
    'the common.typenumber domain refuses a malformed key (typenumber_format)');

SELECT is(common.type_prefix('TASK-125') || '/' || common.type_prefix('acct_01h455vb4pex5vsknk084sn02q')
          || '/' || common.type_prefix('01h455vb4pex5vsknk084sn02q') || '/',
    'TASK/acct//',
    'type_prefix: reads the prefix of a Typed Number and of a Typed Id, empty for a bare Typed Id');

SELECT is(common.typenumber_text('INC', 7, 42) || ' ' || common.typenumber_text('TASK', 0, 125)
          || ' ' || common.typenumber_text('INC', 2, 12345),
    'INC-0000042 TASK-125 INC-12345',
    'typenumber_text: pads to the digits and never cuts a longer number');

-- =====================================================
-- PART 2: the key
-- =====================================================

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, type_digits)
VALUES ('tn_ticket', 'Ticket', 'Tickets', 1, 'typenumber', 'TNT', 4);

SELECT is(
    (SELECT format_type(a.atttypid, a.atttypmod) || ' ' || f.format || '/' || f.input_type
       FROM pg_attribute a, fields f
      WHERE a.attrelid = 'public.tn_ticket'::regclass AND a.attname = 'id'
        AND f.table_name = 'tn_ticket' AND f.field_name = 'id'),
    'common.typenumber string/readonly',
    'the key column carries the common.typenumber domain, and its field is a readonly string');

SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.tn_ticket'::regclass AND tgname = 'a_typenumber_assign')
          AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.tn_ticket'::regclass AND tgname = 'a_typeid_assign'),
    'the table gets a_typenumber_assign, not a_typeid_assign');

SELECT is(pg_get_serial_sequence('public.tn_ticket', 'id'), 'public.tn_ticket_id_seq',
    'the counter is named like an identity sequence and owned by the key column');

SELECT ok(has_sequence_privilege('semantius_user', 'public.tn_ticket_id_seq', 'USAGE'),
    'the request role may take numbers from the counter');

-- =====================================================
-- PART 3: generated keys
-- =====================================================

INSERT INTO tn_ticket (label) VALUES ('t1'), ('t2');

SELECT is((SELECT string_agg(id, ', ' ORDER BY id) FROM tn_ticket), 'TNT-0001, TNT-0002',
    'a new record takes the next number, padded to the digits');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT setval('public.tn_ticket_id_seq', 12344);
SELECT authenticate_as('user3');

INSERT INTO tn_ticket (label) VALUES ('long');

SELECT is((SELECT id::text FROM tn_ticket WHERE label = 'long'), 'TNT-12345',
    'a number longer than the digits keeps all of them');

-- =====================================================
-- PART 4: supplied keys
-- =====================================================
-- Anyone may bring a key, as with an auto_increment key. It must carry the
-- current prefix and be written with the current digits, so a number has one
-- spelling at the current width. It does not move the counter.

SELECT lives_ok($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-0100', 'own')$$,
    'a key with the prefix and the digits may be supplied');

SELECT throws_ok($$INSERT INTO tn_ticket (id, label) VALUES ('XYZ-0101', 'other')$$, '90237', NULL,
    'a supplied key with another prefix is refused');

SELECT throws_ok($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-101', 'short')$$, '90287', NULL,
    'a supplied key with fewer digits than the entity''s is refused');

SELECT throws_ok($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-00101', 'zeros')$$, '90287', NULL,
    'a supplied key with more leading zeros is refused: TNT-0101 and TNT-00101 would be one number');

SELECT is(catch_error_hint($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-00101', 'zeros')$$) ->> 'expected',
    'TNT-0101',
    '90287 names the spelling the number has');

INSERT INTO tn_ticket (id, label) VALUES ('TNT-12346', 'ahead');

SELECT throws_ok($$INSERT INTO tn_ticket (label) VALUES ('collides')$$, '23505', NULL,
    'a supplied key leaves the counter behind: the next number collides with it');

-- =====================================================
-- PART 5: changing the digits and the prefix
-- =====================================================
-- Both apply to the numbers given from then on; the keys given keep their
-- spelling, and the counter numbers on.

UPDATE entities SET type_digits = 6 WHERE table_name = 'tn_ticket';
INSERT INTO tn_ticket (label) VALUES ('six');

SELECT is((SELECT id::text FROM tn_ticket WHERE label = 'six'), 'TNT-012347',
    'a digits change applies to new numbers');

SELECT ok(EXISTS (SELECT 1 FROM tn_ticket WHERE id = 'TNT-0001'),
    'a digits change leaves the keys given before as they are');

SELECT throws_ok($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-0102', 'old width')$$, '90287', NULL,
    'a supplied key in the former width is refused, as a re-import after the change would be');

UPDATE entities SET type_prefix = 'TNX' WHERE table_name = 'tn_ticket';
INSERT INTO tn_ticket (label) VALUES ('new prefix');

SELECT is((SELECT id::text FROM tn_ticket WHERE label = 'new prefix'), 'TNX-012348',
    'a prefix change: new keys carry the new prefix and number on');

SELECT throws_ok($$INSERT INTO tn_ticket (id, label) VALUES ('TNT-020100', 'old prefix')$$, '90237', NULL,
    'a prefix change: a key with the former prefix is refused');

SELECT throws_ok($$UPDATE entities SET type_prefix = 'tnx' WHERE table_name = 'tn_ticket'$$, '23514', NULL,
    'a typenumber prefix is uppercase (valid_type_prefix)');

-- =====================================================
-- PART 6: an is_a family under a typenumber root
-- =====================================================
-- tn_incident (TNI, 5 digits) > tn_major (TNMAJ), tn_minor (TNMIN). Each
-- subtype counts with a counter of its own on its _ext table, in the root's
-- digits.

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, type_digits)
VALUES ('tn_incident', 'Incident', 'Incidents', 1, 'typenumber', 'TNI', 5);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('tn_incident', 'severity', 'Severity', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
VALUES ('tn_major', 'Major', 'Majors', 1, 'is_a', 'TNMAJ', 'tn_incident'),
       ('tn_minor', 'Minor', 'Minors', 1, 'is_a', 'TNMIN', 'tn_incident');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('tn_major', 'bridge', 'Bridge', 'text', 30);

SELECT ok(pg_get_serial_sequence('public.tn_major_ext', 'id') = 'public.tn_major_ext_id_seq'
          AND pg_get_serial_sequence('public.tn_minor_ext', 'id') = 'public.tn_minor_ext_id_seq'
          AND has_sequence_privilege('semantius_user', 'public.tn_major_ext_id_seq', 'USAGE'),
    'is_a: each subtype has a counter of its own, owned by its _ext key and granted to the request role');

INSERT INTO tn_major (label, bridge) VALUES ('m1', 'b1'), ('m2', 'b2');
INSERT INTO tn_minor (label) VALUES ('n1');
INSERT INTO tn_incident (label) VALUES ('i1');

SELECT is((SELECT string_agg(id, ', ' ORDER BY id) FROM tn_incident),
    'TNI-00001, TNMAJ-00001, TNMAJ-00002, TNMIN-00001',
    'is_a: each subtype numbers with its own counter, in the root''s digits');

UPDATE tn_incident SET severity = 'high' WHERE id = 'TNMAJ-00001';
UPDATE tn_major SET bridge = 'b9' WHERE id = 'TNMAJ-00001';

SELECT is((SELECT severity || '/' || bridge FROM tn_major WHERE id = 'TNMAJ-00001'), 'high/b9',
    'is_a: a write through the root reaches the subtype, and the subtype''s view writes its record');

DELETE FROM tn_incident WHERE id = 'TNMAJ-00002';

SELECT ok(NOT EXISTS (SELECT 1 FROM tn_major_ext WHERE id = 'TNMAJ-00002')
          AND NOT EXISTS (SELECT 1 FROM tn_incident WHERE id = 'TNMAJ-00002'),
    'is_a: a delete through the root is dispatched by the prefix and removes every part');

SELECT lives_ok($$INSERT INTO tn_major (id, label) VALUES ('TNMAJ-00010', 'own')$$,
    'is_a: a subtype key with its prefix and the root''s digits may be supplied');

SELECT throws_ok($$INSERT INTO tn_major (id, label) VALUES ('TNMAJ-10', 'short')$$, '90287', NULL,
    'is_a: a supplied subtype key is held to the root''s digits');

SELECT throws_ok($$INSERT INTO tn_major (id, label) VALUES ('TNMIN-00011', 'wrong type')$$, '90237', NULL,
    'is_a: a supplied key with a sibling''s prefix is refused');

SELECT throws_ok($$INSERT INTO tn_incident (id, label) VALUES ('TNMAJ-00012', 'no parts')$$, '90237', NULL,
    'is_a: the root table refuses a subtype prefix from a direct insert');

SELECT throws_ok($$UPDATE entities SET type_digits = 2 WHERE table_name = 'tn_major'$$, '23514', NULL,
    'is_a: a subtype has no digits of its own (valid_type_digits)');

UPDATE entities SET type_digits = 3 WHERE table_name = 'tn_incident';
INSERT INTO tn_major (label) VALUES ('m3');

SELECT is((SELECT id::text FROM tn_major WHERE label = 'm3'), 'TNMAJ-003',
    'is_a: a digits change of the root reaches what the subtype mints');

-- =====================================================
-- PART 7: has_a on a typenumber base
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('tn_extra', 'Extra', 'Extras', 1, 'has_a', 'tn_ticket');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('tn_extra', 'note', 'Note', 'text', 30);

SELECT is((SELECT format_type(atttypid, atttypmod) FROM pg_attribute
            WHERE attrelid = 'public.tn_extra_ext'::regclass AND attname = 'id'),
    'common.typenumber',
    'has_a: the extension''s key has the base''s key type');

INSERT INTO tn_extra (label, note) VALUES ('fresh', 'n');

SELECT is((SELECT id::text FROM tn_extra WHERE note = 'n'), 'TNX-012349',
    'has_a: a record without a base record mints one from the base''s counter');

INSERT INTO tn_extra (id, note) SELECT id, 'attached' FROM tn_ticket WHERE label = 't1';

SELECT is((SELECT id::text || '/' || label FROM tn_extra WHERE note = 'attached'), 'TNT-0001/t1',
    'has_a: the id of a base record attaches to it, whatever prefix and width it was given');

SELECT throws_ok($$INSERT INTO tn_extra (id, label) VALUES ('ZZZ-1', 'x')$$, '90237', NULL,
    'has_a: a supplied id that names no base record must carry the base''s prefix');

UPDATE entities SET type_digits = 7 WHERE table_name = 'tn_ticket';
INSERT INTO tn_extra (label, note) VALUES ('fresh7', 'n7');

SELECT is((SELECT id::text FROM tn_extra WHERE note = 'n7'), 'TNX-0012350',
    'has_a: a digits change of the base is rebuilt into the extension''s write routine');

-- =====================================================
-- PART 8: bases and prefix kinds
-- =====================================================

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix)
VALUES ('tn_tid', 'Tid', 'Tids', 1, 'typeid', 'tntid'),
       ('tn_auto', 'Auto', 'Autos', 1, 'auto_increment', '');

SELECT throws_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
                   VALUES ('tn_bad', 'Bad', 'Bads', 1, 'is_a', 'tnbad', 'tn_incident')$$, '90288', NULL,
    'a Typed Id prefix is refused for a subtype of a typenumber root');

SELECT throws_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
                   VALUES ('tn_bad', 'Bad', 'Bads', 1, 'is_a', 'TNBAD', 'tn_tid')$$, '90288', NULL,
    'a Typed Number prefix is refused for a subtype of a typeid root');

SELECT throws_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
                   VALUES ('tn_bad', 'Bad', 'Bads', 1, 'has_a', 'tn_major')$$, '90240', NULL,
    'a has_a entity is based on a typeid or typenumber root, not on a subtype');

SELECT throws_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
                   VALUES ('tn_bad', 'Bad', 'Bads', 1, 'is_a', 'TNBAD', 'tn_auto')$$, '90240', NULL,
    'an is_a entity is not based on an auto_increment entity');

SELECT lives_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
                  VALUES ('tn_sub_sub', 'Sub Sub', 'Sub Subs', 1, 'is_a', 'TNSUB', 'tn_major')$$,
    'an is_a entity may be based on a subtype of a typenumber root');

-- =====================================================
-- PART 9: ensure_entities, rename, drop, the managed flip, adoption, and a
-- counter name another table's sequence holds
-- =====================================================

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT public.ensure_entities('{
    "version": 1,
    "entities": [{"entity": {
        "table_name": "tn_ens", "module_name": "_core", "singular": "tn_ens",
        "singular_label": "Ens", "plural_label": "Enses",
        "id_type": "typenumber", "type_prefix": "TNE",
        "fields": [{"field_name": "note", "title": "Note", "format": "text", "field_order": 30}]},
      "records": [{"id": "TNE-5", "label": "five"}, {"id": "TNE-7", "label": "seven"}]}]
}'::jsonb);

SELECT authenticate_as('user3');
INSERT INTO tn_ens (label) VALUES ('next');

SELECT is((SELECT id::text FROM tn_ens WHERE label = 'next'), 'TNE-8',
    'ensure_entities moves the counter past the records it wrote');

-- tn_ens belongs to no family, so no family refresh reinstalls its trigger on
-- a rename: the trigger finds the renamed counter by its ownership.
UPDATE entities SET table_name = 'tn_ens2' WHERE table_name = 'tn_ens';
INSERT INTO tn_ens2 (label) VALUES ('after rename');

SELECT is((SELECT pg_get_serial_sequence('public.tn_ens2', 'id') || ' ' || id::text
             FROM tn_ens2 WHERE label = 'after rename'),
    'public.tn_ens2_id_seq TNE-9',
    'rename of an entity outside a family: the counter follows the table, and a new record takes the next number');

-- tn_ticket is the base of tn_extra, so its family is rebuilt under the new
-- name.
UPDATE entities SET table_name = 'tn_ticket2' WHERE table_name = 'tn_ticket';
INSERT INTO tn_ticket2 (label) VALUES ('after rename');

SELECT ok(pg_get_serial_sequence('public.tn_ticket2', 'id') = 'public.tn_ticket2_id_seq'
          AND to_regclass('public.tn_ticket_id_seq') IS NULL,
    'rename of a family root: the counter is renamed with the table');

SELECT is((SELECT id::text FROM tn_ticket2 WHERE label = 'after rename'), 'TNX-0012351',
    'rename of a family root: a new record still takes the next number');

UPDATE entities SET table_name = 'tn_major2' WHERE table_name = 'tn_major';
INSERT INTO tn_major2 (label) VALUES ('m after rename');

SELECT ok(pg_get_serial_sequence('public.tn_major2_ext', 'id') = 'public.tn_major2_ext_id_seq'
          AND (SELECT id::text FROM tn_major2 WHERE label = 'm after rename') = 'TNMAJ-004',
    'rename: a subtype''s counter follows its _ext table, and the subtype numbers on');

DELETE FROM tn_minor;
DELETE FROM entities WHERE table_name = 'tn_minor';

SELECT ok(to_regclass('public.tn_minor_ext_id_seq') IS NULL,
    'drop: the counter goes with the table');

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed, id_type, type_prefix)
VALUES ('tn_late', 'tn_late', 'Late', 'Lates', 1, false, 'typenumber', 'TNL');

SELECT ok(to_regclass('public.tn_late_id_seq') IS NULL,
    'an entity without a table has no counter');

UPDATE entities SET managed = true WHERE table_name = 'tn_late';
INSERT INTO tn_late (label) VALUES ('first');

SELECT is((SELECT id::text FROM tn_late), 'TNL-1',
    'the managed flip creates the key, its trigger and its counter');

-- Adoption of a table that brings Typed Number keys: the counter starts above
-- them.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
CREATE TABLE public.tn_hand (id common.typenumber PRIMARY KEY, label text NOT NULL DEFAULT '');
INSERT INTO public.tn_hand (id, label) VALUES ('TNH-3', 'three'), ('TNH-9', 'nine');
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.tn_hand OWNER TO semantius_owner;
    END IF;
END $$;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed, id_type, type_prefix)
VALUES ('tn_hand', 'tn_hand', 'Hand', 'Hands', 1, false, 'typenumber', 'TNH');
UPDATE entities SET managed = true WHERE table_name = 'tn_hand';
INSERT INTO tn_hand (label) VALUES ('next');

SELECT is((SELECT id::text FROM tn_hand WHERE label = 'next'), 'TNH-10',
    'adoption: the counter starts above the keys the table brings');

SELECT throws_ok($$INSERT INTO tn_hand (id, label) VALUES ('TNH-03', 'zero')$$, '90287', NULL,
    'adoption: the adopted table checks supplied keys like a created one');

-- The counter is the sequence the key column owns. The identity of
-- tn_clash.x_id is named tn_clash_x_id_seq, which is also the name of the
-- counter of an entity tn_clash_x: it is not taken for that counter, and the
-- entity cannot be created while the name is taken.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
CREATE TABLE public.tn_clash (x_id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY);
SELECT authenticate_as('user3');

SELECT throws_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix)
                   VALUES ('tn_clash_x', 'Clash', 'Clashes', 1, 'typenumber', 'TNC')$$, '42P07', NULL,
    'a sequence of another table under the counter''s name is never taken for the counter');

-- =====================================================
-- PART 10: references
-- =====================================================

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('tn_tid', 'ticket_id', 'Ticket', 'reference', 'tn_ticket2', 'restrict', 30);

SELECT is((SELECT format_type(atttypid, atttypmod) FROM pg_attribute
            WHERE attrelid = 'public.tn_tid'::regclass AND attname = 'ticket_id'),
    'common.typenumber',
    'a reference to a typenumber entity has the key''s domain');

SELECT * FROM finish();
ROLLBACK;
