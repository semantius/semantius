-- Record references (0160_dd_functions.sql) and the rewrite of stored
-- references when an entity is renamed (0170_dd_rename.sql).
--   PART 1  building and splitting a reference, every key type
--   PART 2  the canonical spelling
--   PART 3  is_a and has_a records
--   PART 4  the rename rewrite: bookmarks follow the entity and keep their user
--
-- Fixture entities use the 'rrf' prefix; everything is rolled back.
BEGIN;

SELECT plan(22);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES ('rrf_auto', 'Auto', 'Autos', 1, 'public:read', 'admin', 'auto_increment', ''),
       ('rrf_big', 'Big', 'Bigs', 1, 'public:read', 'admin', 'bigint', ''),
       ('rrf_txt', 'Txt', 'Txts', 1, 'public:read', 'admin', 'text', ''),
       ('rrf_uid', 'Uid', 'Uids', 1, 'public:read', 'admin', 'uuid', ''),
       ('rrf_act', 'Activity', 'Activities', 1, 'public:read', 'admin', 'typeid', 'rrfact');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('rrf_mail', 'Mail', 'Mails', 1, 'is_a', 'rrfmail', 'rrf_act');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('rrf_more', 'More', 'Mores', 1, 'has_a', 'rrf_act');

INSERT INTO rrf_auto (label) VALUES ('auto');
INSERT INTO rrf_txt (id, label) VALUES ('A:1-2', 'colon and dash');
INSERT INTO rrf_uid (label) VALUES ('uid');
INSERT INTO rrf_act (label) VALUES ('plain activity');
INSERT INTO rrf_mail (label) VALUES ('mail');
INSERT INTO rrf_more (id) SELECT id FROM rrf_act WHERE label = 'plain activity';

-- =====================================================
-- PART 1: building and splitting
-- =====================================================
SELECT is(dd_record_ref('users', '42'), 'users:42',
    'auto_increment: the table name, a colon and the key');

SELECT is(dd_record_ref('rrf_txt', 'A:1-2'), 'rrf_txt:A:1-2',
    'text: a key with a colon and a dash is taken as it is');

SELECT is(
    (SELECT row(s.table_name, s.key)::text FROM dd_record_ref_split('rrf_txt:A:1-2') s),
    '(rrf_txt,A:1-2)',
    'split: the table name ends at the first colon, the key may hold more');

SELECT is(
    (SELECT row(s.table_name, s.key)::text FROM dd_record_ref_split('no colon') s),
    '(,)',
    'split: text without a colon is no reference');

SELECT ok('rrf_txt:A' LIKE dd_ref_like('rrf_txt') AND NOT ('rrfXtxt:A' LIKE dd_ref_like('rrf_txt')),
    'the LIKE pattern of a table matches its references and reads its underscores literally');

-- =====================================================
-- PART 2: the canonical spelling
-- =====================================================
SELECT is(dd_record_ref_canonical('rrf_big:042'), 'rrf_big:42',
    'bigint: the key is spelled as its type spells it');

SELECT is(dd_record_ref_canonical('rrf_auto:' || (SELECT id FROM rrf_auto)),
    'rrf_auto:' || (SELECT id FROM rrf_auto),
    'auto_increment: a canonical reference stays as it is');

SELECT is(dd_record_ref_canonical('rrf_uid:' || upper((SELECT id::text FROM rrf_uid))),
    'rrf_uid:' || (SELECT id::text FROM rrf_uid),
    'uuid: an upper-case key is spelled in lower case');

SELECT is(dd_record_ref_canonical('rrf_txt:A:1-2'), 'rrf_txt:A:1-2',
    'text: the key is kept, colon and dash included');

SELECT is(dd_record_ref_canonical('rrf_big:abc'), NULL,
    'a key that is no value of the key type gives no reference');

SELECT is(dd_record_ref_canonical('rrf_nowhere:1'), NULL,
    'a table that is no entity gives no reference');

SELECT is(dd_record_ref_canonical('rrf_act:not_a_typeid'), NULL,
    'typeid: a key that is no TypeID gives no reference');

-- =====================================================
-- PART 3: is_a and has_a
-- =====================================================
SELECT is(dd_record_ref('rrf_act', (SELECT id FROM rrf_mail)), 'rrf_mail:' || (SELECT id FROM rrf_mail),
    'is_a: a record reached through its root is named by its subtype, read from the key prefix');

SELECT is(dd_record_ref('rrf_mail', (SELECT id FROM rrf_mail)), 'rrf_mail:' || (SELECT id FROM rrf_mail),
    'is_a: the same reference through the subtype itself');

SELECT is(dd_record_ref_canonical('rrf_act:' || (SELECT id FROM rrf_mail)), 'rrf_mail:' || (SELECT id FROM rrf_mail),
    'is_a: a reference through the supertype is rewritten to the subtype');

SELECT is(dd_record_ref('rrf_act', (SELECT id FROM rrf_act WHERE label = 'plain activity')),
    'rrf_act:' || (SELECT id FROM rrf_act WHERE label = 'plain activity'),
    'typeid: a record of the root itself keeps the root''s name');

SELECT is(dd_record_ref_canonical('rrf_more:' || (SELECT id FROM rrf_more)),
    'rrf_act:' || (SELECT id FROM rrf_more),
    'has_a: an extension record is named by its base record');

-- =====================================================
-- PART 4: the rename rewrite
-- =====================================================
SELECT authenticate_as('user1');
INSERT INTO user_bookmarks (title, entity_name, entity_id) VALUES ('RRF pointer', 'rrf_txt', 'A:1-2');
INSERT INTO user_bookmarks (title, entity_name, entity_id) VALUES ('RRF bystander', 'rrf_txtx', '1');

SELECT authenticate_as('user3');
UPDATE entities SET table_name = 'rrf_text' WHERE table_name = 'rrf_txt';

SELECT authenticate_as('user1');
SELECT is(
    (SELECT entity_name || ':' || entity_id || ' ' || user_id FROM user_bookmarks WHERE title = 'RRF pointer'),
    'rrf_text:A:1-2 1001',
    'a rename rewrites the bookmarks of the entity, and they keep their user');

SELECT is(
    (SELECT entity_name FROM user_bookmarks WHERE title = 'RRF bystander'),
    'rrf_txtx',
    'a bookmark of an entity whose name only starts like it is left alone');

-- The rules run again on an edit of the owner's own: the user stays.
UPDATE user_bookmarks SET user_id = 1002, url = 'https://example.com/rrf' WHERE title = 'RRF pointer';
SELECT is(
    (SELECT url || ' ' || user_id FROM user_bookmarks WHERE title = 'RRF pointer'),
    'https://example.com/rrf 1001',
    'after the rewrite an edit runs the bookmark rules again');

-- A migration renames without claims, where the bookmark rules (90207) would
-- refuse an update: the rewrite runs past them.
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;
UPDATE entities SET table_name = 'rrf_texts' WHERE table_name = 'rrf_text';

SELECT is(
    (SELECT entity_name || ' ' || user_id FROM user_bookmarks WHERE title = 'RRF pointer'),
    'rrf_texts 1001',
    'a rename without claims rewrites the bookmarks past their rules');

SELECT is(
    (SELECT string_agg(DISTINCT tgenabled::text, '') FROM pg_trigger
      WHERE tgrelid = 'public.user_bookmarks'::regclass AND NOT tgisinternal),
    'O',
    'the triggers of the rewritten table are enabled again');

SELECT * FROM finish();
ROLLBACK;
