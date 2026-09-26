-- Entity key types: entities.id_type and entities.id_prefix.
--
-- Every entity declares the type of its key (dd_id_column_ddl in
-- 0160_dd_functions.sql): auto_increment (a BIGINT identity, the default),
-- bigint and text (supplied by the caller), uuid (UUIDv7 default) and typeid
-- (a prefixed TypeID filled by the typeid_assign trigger). computed only labels
-- system tables. Pinned here:
--   PART 1  the helpers of 0045_typeid.sql: UUIDv7, base32, TypeID check
--   PART 2  the column, default and id field each id_type produces
--   PART 3  inserting: generated and supplied ids, the TypeID prefix
--   PART 4  changing the prefix, prefix format and uniqueness
--   PART 5  what cannot change: id_type (90233) and a record key (90236)
--   PART 6  refusals: computed (90234) and a takeover with the wrong key (90235)
--   PART 7  references to each key type (field_data_type) and get_schema
--   PART 8  get_record_by_id and set_record over every key type (90238)
--   PART 9  ensure_entities and the adoption path (90239)
--
-- Fixture entities use the 'idt_' prefix; everything is rolled back.

BEGIN;

SELECT plan(97);

-- =====================================================
-- PART 1: UUIDv7 and TypeID helpers
-- =====================================================

SELECT is(uuid_extract_version(common.uuid_v7()), 7::smallint,
    'uuid_v7: generates a version 7 UUID');

-- The body is chosen once, when 0045_typeid.sql runs: the native uuidv7() from
-- PostgreSQL 18 on, the PL/pgSQL fallback before.
SELECT is(
    (SELECT l.lanname::text FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
      WHERE p.oid = 'common.uuid_v7()'::regprocedure),
    CASE WHEN current_setting('server_version_num')::int >= 180000 THEN 'sql' ELSE 'plpgsql' END,
    'uuid_v7: native uuidv7() on PostgreSQL 18, the PL/pgSQL fallback before');

-- Non-decreasing, not strictly increasing: the PostgreSQL 17 fallback has
-- millisecond precision, so two values of the same millisecond tie on time.
-- The timestamp is read from the first 48 bits by hand because
-- uuid_extract_timestamp() only understands version 7 from PostgreSQL 18 on.
SELECT ok(
    (SELECT bool_and(ts >= prev_ts)
       FROM (SELECT ts, lag(ts) OVER (ORDER BY n) AS prev_ts
               FROM (SELECT n, ('x' || left(replace(common.uuid_v7()::text, '-', ''), 12))::bit(48)::bigint AS ts
                       FROM generate_series(1, 50) AS n) g) s
      WHERE prev_ts IS NOT NULL),
    'uuid_v7: timestamps of consecutive values never go backwards');

SELECT ok(
    abs(('x' || left(replace(common.uuid_v7()::text, '-', ''), 12))::bit(48)::bigint
        - (extract(epoch FROM clock_timestamp()) * 1000)::bigint) < 60000,
    'uuid_v7: the timestamp bits are the current Unix time in milliseconds');

SELECT is(
    common.base32_decode(common.base32_encode('01890a5d-ac96-774b-bcce-b302099a8057'::uuid)),
    '01890a5d-ac96-774b-bcce-b302099a8057'::uuid,
    'base32: decode(encode(uuid)) round-trips');

-- The TypeID spec's own example value.
SELECT is(common.base32_encode('01890a5d-ac96-774b-bcce-b302099a8057'::uuid),
    '01h455vb4pex5vsknk084sn02q',
    'base32: encodes the spec example to its published suffix');

SELECT ok(common.typeid_check_text('prefix_01h455vb4pex5vsknk084sn02q')
      AND common.typeid_check_text('01h455vb4pex5vsknk084sn02q')
      AND common.typeid_check_text('pre_fix_01h455vb4pex5vsknk084sn02q'),
    'typeid_check_text: accepts a prefixed, a bare and an underscored-prefix TypeID');

SELECT ok(NOT common.typeid_check_text('Prefix_01h455vb4pex5vsknk084sn02q')
      AND NOT common.typeid_check_text('prefix_81h455vb4pex5vsknk084sn02q')
      AND NOT common.typeid_check_text('prefix_01h455vb4pex5vsknk084sn02')
      AND NOT common.typeid_check_text('prefix_01h455vb4pex5vsknk084sn02u')
      AND NOT common.typeid_check_text('_01h455vb4pex5vsknk084sn02q'),
    'typeid_check_text: rejects an uppercase prefix, a first char above 7, a short suffix, a non-alphabet char and an empty prefix before the separator');

SELECT is(common.typeid_prefix('pre_fix_01h455vb4pex5vsknk084sn02q'), 'pre_fix',
    'typeid_prefix: everything before the last underscore');

SELECT is(common.typeid_prefix('01h455vb4pex5vsknk084sn02q'), '',
    'typeid_prefix: empty for a bare suffix');

-- =====================================================
-- PART 2: the key each id_type produces
-- =====================================================

SELECT authenticate_as('user3');  -- admin: may write entities and every fixture table

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES
    ('idt_auto', 'idt_auto', 'Auto', 'Autos', 1, 'public:read', 'admin', 'auto_increment', ''),
    ('idt_big',  'idt_big',  'Big',  'Bigs',  1, 'public:read', 'admin', 'bigint',         ''),
    ('idt_text', 'idt_text', 'Text', 'Texts', 1, 'public:read', 'admin', 'text',           ''),
    ('idt_uuid', 'idt_uuid', 'Uuid', 'Uuids', 1, 'public:read', 'admin', 'uuid',           ''),
    ('idt_tid',  'idt_tid',  'Tid',  'Tids',  1, 'public:read', 'admin', 'typeid',         'idtacct');

-- An entity that omits id_type gets the default.
INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id)
VALUES ('idt_plain', 'idt_plain', 'Plain', 'Plains', 1);

SELECT is((SELECT id_type FROM entities WHERE table_name = 'idt_plain'), 'auto_increment',
    'id_type defaults to auto_increment');

SELECT is(
    (SELECT string_agg(e.table_name || '=' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY e.table_name)
       FROM entities e
       JOIN pg_attribute a ON a.attrelid = to_regclass('public.' || e.table_name) AND a.attname = 'id'
      WHERE e.table_name LIKE 'idt\_%'),
    'idt_auto=bigint, idt_big=bigint, idt_plain=bigint, idt_text=text, idt_tid=common.typeid, idt_uuid=uuid',
    'each id_type produces its column type');

SELECT is((SELECT attidentity FROM pg_attribute WHERE attrelid = 'public.idt_auto'::regclass AND attname = 'id'),
    'd'::"char",
    'auto_increment: a GENERATED BY DEFAULT identity');

SELECT ok(pg_get_serial_sequence('public.idt_auto', 'id') = 'public.idt_auto_id_seq'
      AND has_sequence_privilege('semantius_user', 'public.idt_auto_id_seq', 'USAGE'),
    'auto_increment: the identity sequence has the <table>_<id>_seq name and is granted to the request role');

SELECT ok((SELECT attidentity = '' AND NOT atthasdef FROM pg_attribute
            WHERE attrelid = 'public.idt_big'::regclass AND attname = 'id'),
    'bigint: no identity and no default, the caller supplies the key');

SELECT is((SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
            JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
           WHERE d.adrelid = 'public.idt_uuid'::regclass AND a.attname = 'id'),
    'common.uuid_v7()',
    'uuid: the key defaults to common.uuid_v7()');

SELECT is((SELECT c.collname::text FROM pg_attribute a JOIN pg_collation c ON c.oid = a.attcollation
            WHERE a.attrelid = 'public.idt_tid'::regclass AND a.attname = 'id'),
    'C',
    'typeid: the key column takes the domain''s C collation');

SELECT is(
    (SELECT string_agg(table_name || '=' || format, ', ' ORDER BY table_name)
       FROM fields WHERE table_name LIKE 'idt\_%' AND field_name = 'id'),
    'idt_auto=int64, idt_big=int64, idt_plain=int64, idt_text=text, idt_tid=string, idt_uuid=uuid',
    'each id_type gives the id field its format (typeid keeps string: TypeID is no field format)');

SELECT is(
    (SELECT string_agg(table_name || '=' || input_type, ', ' ORDER BY table_name)
       FROM fields WHERE table_name LIKE 'idt\_%' AND field_name = 'id'),
    'idt_auto=readonly, idt_big=required, idt_plain=readonly, idt_text=required, idt_tid=readonly, idt_uuid=readonly',
    'a caller-supplied key (bigint, text) is required; a generated key is readonly');

SELECT is((SELECT input_type_rule FROM fields WHERE table_name = 'idt_text' AND field_name = 'id'),
    '{"if": [{"var": "id"}, "readonly", "required"]}'::jsonb,
    'text: the id field is required while empty and readonly once set');

SELECT is((SELECT input_type_rule FROM fields WHERE table_name = 'idt_auto' AND field_name = 'id'),
    '{}'::jsonb,
    'auto_increment: the id field carries no input_type_rule');

-- The rule names the entity's real key column, not a fixed "id".
INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_column, id_type)
VALUES ('idt_code', 'idt_code', 'Code', 'Codes', 1, 'code', 'text');

SELECT is((SELECT input_type_rule FROM fields WHERE table_name = 'idt_code' AND field_name = 'code'),
    '{"if": [{"var": "code"}, "readonly", "required"]}'::jsonb,
    'the input_type_rule reads the entity''s own id_column');

SELECT ok(
    (SELECT count(*) = 7 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE c.relname LIKE 'idt\_%' AND t.tgname = 'pk_immutable'),
    'every key type gets the pk_immutable trigger');

SELECT ok(
    (SELECT array_agg(c.relname::text ORDER BY c.relname) = ARRAY['idt_tid']
       FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE c.relname LIKE 'idt\_%' AND t.tgname = 'typeid_assign'),
    'only the typeid entity gets the typeid_assign trigger');

-- =====================================================
-- PART 3: inserting
-- =====================================================

INSERT INTO idt_auto (label) VALUES ('a1'), ('a2');
INSERT INTO idt_big (id, label) VALUES (5000000000, 'b1'), (5, 'b5');
INSERT INTO idt_text (id, label) VALUES ('abc', 't1');
INSERT INTO idt_uuid (label) VALUES ('u1');
INSERT INTO idt_tid (label) VALUES ('g1');

SELECT ok((SELECT count(*) = 2 AND min(id) >= 1 FROM idt_auto),
    'auto_increment: ids are generated');

SELECT is((SELECT id FROM idt_big WHERE label = 'b1'), 5000000000::bigint,
    'bigint: a key beyond the int4 range is stored');

SELECT throws_ok($$ INSERT INTO idt_big (label) VALUES ('no key') $$, '23502', NULL,
    'bigint: a row without a key is refused');

SELECT throws_ok($$ INSERT INTO idt_text (label) VALUES ('no key') $$, '23502', NULL,
    'text: a row without a key is refused');

SELECT is((SELECT uuid_extract_version(id) FROM idt_uuid WHERE label = 'u1'), 7::smallint,
    'uuid: the generated key is a UUIDv7');

SELECT lives_ok($$ INSERT INTO idt_uuid (id, label) VALUES ('7a1a1a1a-0000-4000-8000-000000000001', 'u-own') $$,
    'uuid: a caller may supply its own key');

SELECT ok((SELECT id LIKE 'idtacct\_%' AND common.typeid_check_text(id) AND length(id) = 34
             FROM idt_tid WHERE label = 'g1'),
    'typeid: a generated key carries the prefix and is a valid TypeID');

SELECT lives_ok($$ INSERT INTO idt_tid (id, label) VALUES ('idtacct_01h455vb4pex5vsknk084sn02q', 'g-own') $$,
    'typeid: a caller may supply a key with the current prefix');

SELECT throws_ok($$ INSERT INTO idt_tid (id, label) VALUES ('other_01h455vb4pex5vsknk084sn02r', 'g-foreign') $$,
    '90237', NULL,
    'typeid: a supplied key with a foreign prefix is refused');

SELECT throws_ok($$ INSERT INTO idt_tid (id, label) VALUES ('idtacct_not-a-typeid', 'g-bad') $$,
    '23514', NULL,
    'typeid: a malformed key fails the common.typeid domain');

-- =====================================================
-- PART 4: the prefix
-- =====================================================

UPDATE entities SET id_prefix = 'idtcust' WHERE table_name = 'idt_tid';
INSERT INTO idt_tid (label) VALUES ('g2');

SELECT ok((SELECT id LIKE 'idtcust\_%' FROM idt_tid WHERE label = 'g2'),
    'prefix change: new keys carry the new prefix');

SELECT ok((SELECT bool_and(id LIKE 'idtacct\_%') FROM idt_tid WHERE label IN ('g1', 'g-own')),
    'prefix change: existing keys keep the old prefix');

SELECT throws_ok($$ INSERT INTO idt_tid (id, label) VALUES ('idtacct_01h455vb4pex5vsknk084sn02s', 'g-old') $$,
    '90237', NULL,
    'prefix change: a key with the former prefix can no longer be inserted');

SELECT lives_ok($$ INSERT INTO idt_tid (id, label) VALUES ('idtcust_01h455vb4pex5vsknk084sn02t', 'g-new') $$,
    'prefix change: a supplied key with the new prefix is accepted');

SELECT throws_ok($$ UPDATE entities SET id_prefix = 'Bad-Prefix' WHERE table_name = 'idt_tid' $$,
    '23514', NULL,
    'the prefix must follow the TypeID prefix grammar');

SELECT throws_ok($$ UPDATE entities SET id_prefix = 'idtbad_' WHERE table_name = 'idt_tid' $$,
    '23514', NULL,
    'the prefix must end with a letter');

SELECT throws_ok($$ UPDATE entities SET id_prefix = 'x' WHERE table_name = 'idt_text' $$,
    '23514', NULL,
    'only a typeid entity has a prefix');

SELECT throws_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_type, id_prefix)
                    VALUES ('idt_tid2', 'idt_tid2', 'Tid2', 'Tid2s', 1, 'typeid', '') $$,
    '23514', NULL,
    'a typeid entity needs a prefix');

SELECT throws_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_type, id_prefix)
                    VALUES ('idt_tid2', 'idt_tid2', 'Tid2', 'Tid2s', 1, 'typeid', 'idtcust') $$,
    '23505', NULL,
    'a prefix in use by another entity is refused');

SELECT lives_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_type, id_prefix)
                   VALUES ('idt_tid2', 'idt_tid2', 'Tid2', 'Tid2s', 1, 'typeid', 'idtacct') $$,
    'a released prefix may be taken by another entity');

-- =====================================================
-- PART 5: what never changes
-- =====================================================

SELECT throws_ok($$ UPDATE entities SET id_type = 'uuid' WHERE table_name = 'idt_auto' $$,
    '90233', NULL,
    'id_type cannot change once the entity exists');

SELECT is((SELECT input_type_rule FROM fields WHERE table_name = 'entities' AND field_name = 'id_type'),
    '{"if": [{"var": "created_at"}, "readonly", "required"]}'::jsonb,
    'the id_type field is readonly in the UI once the entity exists');

SELECT throws_ok($$ UPDATE idt_auto SET id = id + 1000 WHERE label = 'a1' $$,
    '90236', NULL,
    'a generated record key cannot be changed');

SELECT throws_ok($$ UPDATE idt_text SET id = 'xyz' WHERE id = 'abc' $$,
    '90236', NULL,
    'a supplied record key cannot be changed either');

SELECT lives_ok($$ UPDATE idt_auto SET id = id, label = 'a1b' WHERE label = 'a1' $$,
    'writing the unchanged key back (a whole-record PATCH) passes');

SELECT is((SELECT count(*)::int FROM idt_auto WHERE label = 'a1b'), 1,
    'the rest of that update was applied');

SELECT lives_ok($$ UPDATE idt_tid SET label = 'g1b' WHERE label = 'g1' $$,
    'updating other columns of a typeid row works');

-- The core tables whose keys are auto_increment are locked the same way.
RESET ROLE;
SELECT throws_ok($$ UPDATE users SET id = 999001 WHERE id = 1001 $$,
    '90236', NULL,
    'users.id cannot be changed');
SELECT ok(
    (SELECT count(*) = 4 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE c.relname IN ('users', 'modules', 'roles', '_apikeys') AND t.tgname = 'pk_immutable'),
    'users, modules, roles and _apikeys carry pk_immutable');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                 WHERE c.relname IN ('entities', 'permissions', 'user_roles', 'role_permissions',
                                     'user_permissions', 'permission_hierarchy', 'fields')
                   AND t.tgname = 'pk_immutable'),
    'renamable natural keys and generated junction keys carry no pk_immutable');
SELECT is(
    (SELECT string_agg(table_name || '=' || id_type, ', ' ORDER BY table_name) FROM entities
      WHERE table_name IN ('entities', 'fields', 'users', 'modules', 'roles', 'permissions',
                           'user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy',
                           'audit_record_logs', 'audit_ddl_logs')),
    'audit_ddl_logs=auto_increment, audit_record_logs=auto_increment, entities=text, fields=computed, modules=auto_increment, permission_hierarchy=computed, permissions=text, role_permissions=computed, roles=auto_increment, user_permissions=computed, user_roles=computed, users=auto_increment',
    'the core entities are classified by their real keys');
SELECT authenticate_as('user3');

-- =====================================================
-- PART 6: refusals
-- =====================================================

SELECT throws_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_type)
                    VALUES ('idt_comp', 'idt_comp', 'Comp', 'Comps', 1, 'computed') $$,
    '90234', NULL,
    'computed is refused for a managed entity');

SELECT throws_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, id_type)
                    VALUES ('idt_nope', 'idt_nope', 'Nope', 'Nopes', 1, 'serial') $$,
    '23514', NULL,
    'an unknown id_type is refused');

-- Hand-made tables, adopted two ways. Created as the owner: the request role
-- has no CREATE in public.
RESET ROLE;
CREATE TABLE public.idt_hand_int4 (id serial PRIMARY KEY, label text NOT NULL DEFAULT '');
CREATE TABLE public.idt_hand_nokey (label text NOT NULL DEFAULT '');
CREATE TABLE public.idt_hand_text (id text PRIMARY KEY, label text NOT NULL DEFAULT '');
-- Adoption is SECURITY DEFINER as the dictionary's owner, and the trigger
-- stack of the managed flip needs to own the table before it gets to the key
-- check, as 0960_test_public_grants.sql explains. Where owner hardening did
-- not run, the installing role owns both and nothing is needed.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.idt_hand_int4 OWNER TO semantius_owner;
        ALTER TABLE public.idt_hand_nokey OWNER TO semantius_owner;
        ALTER TABLE public.idt_hand_text OWNER TO semantius_owner;
    END IF;
END $$;
SELECT authenticate_as('user3');

SELECT throws_ok($$ INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id)
                    VALUES ('idt_hand_int4', 'idt_hand_int4', 'Int4', 'Int4s', 1) $$,
    '90235', NULL,
    'registering an auto_increment entity onto an int4 serial table is refused');

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed)
VALUES ('idt_hand_nokey', 'idt_hand_nokey', 'NoKey', 'NoKeys', 1, false),
       ('idt_hand_text', 'idt_hand_text', 'HText', 'HTexts', 1, false);

SELECT throws_ok($$ UPDATE entities SET managed = true WHERE table_name = 'idt_hand_nokey' $$,
    '90235', NULL,
    'adopting a table with no key column is refused');

SELECT throws_ok($$ UPDATE entities SET managed = true WHERE table_name = 'idt_hand_text' $$,
    '90235', NULL,
    'adopting a text-keyed table as auto_increment is refused');

-- =====================================================
-- PART 7: references and get_schema
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id)
VALUES ('idt_ref', 'idt_ref', 'Ref', 'Refs', 1);

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES
    ('idt_ref', 'r_auto', 'Auto', 'reference', 'idt_auto', 'restrict', 30),
    ('idt_ref', 'r_big',  'Big',  'reference', 'idt_big',  'restrict', 40),
    ('idt_ref', 'r_text', 'Text', 'reference', 'idt_text', 'restrict', 50),
    ('idt_ref', 'r_uuid', 'Uuid', 'reference', 'idt_uuid', 'restrict', 60),
    ('idt_ref', 'r_tid',  'Tid',  'reference', 'idt_tid',  'restrict', 70),
    ('idt_ref', 'p_tid',  'Tid parent', 'parent', 'idt_tid', 'cascade', 80);

SELECT is(
    (SELECT string_agg(a.attname || '=' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
       FROM pg_attribute a
      WHERE a.attrelid = 'public.idt_ref'::regclass AND a.attname ~ '^(r|p)_'),
    'r_auto=bigint, r_big=bigint, r_text=text, r_uuid=uuid, r_tid=common.typeid, p_tid=common.typeid',
    'a reference takes the type of the key it points at, the common.typeid domain included');

SELECT is((SELECT c.collname::text FROM pg_attribute a JOIN pg_collation c ON c.oid = a.attcollation
            WHERE a.attrelid = 'public.idt_ref'::regclass AND a.attname = 'r_tid'),
    'C',
    'a reference to a typeid key has the key''s collation, so the join does not mix collations');

INSERT INTO idt_ref (label, r_tid, p_tid)
SELECT 'ref1', id, id FROM idt_tid WHERE label = 'g1b';

SELECT is((SELECT count(*)::int FROM idt_ref r JOIN idt_tid t ON t.id = r.r_tid), 1,
    'a typeid reference joins its target');

SELECT throws_ok($$ INSERT INTO idt_ref (label, p_tid) VALUES ('ref2', 'not-a-typeid') $$,
    '23514', NULL,
    'a reference column checks the TypeID format through the domain');

-- A registered entity without a table is typed from its id_type.
RESET ROLE;
INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed, id_type, id_prefix)
VALUES ('idt_ghost_uuid', 'idt_ghost_uuid', 'GU', 'GUs', 1, false, 'uuid', ''),
       ('idt_ghost_tid',  'idt_ghost_tid',  'GT', 'GTs', 1, false, 'typeid', 'idtghost'),
       ('idt_ghost_text', 'idt_ghost_text', 'GX', 'GXs', 1, false, 'text', '');

SELECT is(
    field_data_type('reference', NULL, 'idt_ghost_uuid') || ' ' ||
    field_data_type('parent', NULL, 'idt_ghost_tid') || ' ' ||
    field_data_type('reference', NULL, 'idt_ghost_text') || ' ' ||
    field_data_type('reference', NULL, 'idt_no_such_entity'),
    'UUID COMMON.TYPEID TEXT BIGINT',
    'without a table the reference is typed from id_type, and an unknown entity falls back to BIGINT');
SELECT authenticate_as('user3');

SELECT is(
    (SELECT string_agg(k || '=' || coalesce((public.get_schema(k)::jsonb) #>> '{properties,id,format}', '?'), ', ' ORDER BY k)
       FROM unnest(ARRAY['idt_auto', 'idt_big', 'idt_text', 'idt_uuid', 'idt_tid']) AS k),
    'idt_auto=int64, idt_big=int64, idt_text=text, idt_tid=string, idt_uuid=uuid',
    'get_schema: the id format follows the key type');

SELECT is((public.get_schema('idt_tid')::jsonb) #>> '{properties,id,pattern}',
    '^([a-z]([a-z_]{0,61}[a-z])?_)?[0-7][0123456789abcdefghjkmnpqrstvwxyz]{25}$',
    'get_schema: a typeid key carries the generic TypeID pattern');

SELECT is((public.get_schema('idt_tid')::jsonb) #>> '{properties,id,type}', 'string',
    'get_schema: a typeid key is a JSON string');

SELECT ok(
    (public.get_schema('idt_ref')::jsonb) #>> '{properties,r_tid,pattern}' IS NOT NULL
    AND (public.get_schema('idt_ref')::jsonb) #>> '{properties,p_tid,pattern}' IS NOT NULL
    AND (public.get_schema('idt_ref')::jsonb) #>> '{properties,r_uuid,pattern}' IS NULL
    AND (public.get_schema('idt_ref')::jsonb) #>> '{properties,r_auto,pattern}' IS NULL,
    'get_schema: references to a typeid key carry the pattern, other references do not');

SELECT ok(
    (public.get_schema('idt_text')::jsonb) -> 'required' ? 'id'
    AND (public.get_schema('idt_big')::jsonb) -> 'required' ? 'id'
    AND NOT (public.get_schema('idt_auto')::jsonb) -> 'required' ? 'id'
    AND NOT (public.get_schema('idt_tid')::jsonb) -> 'required' ? 'id',
    'get_schema: the key is required when the caller supplies it and only then');

SELECT ok(
    NOT (public.get_schema('idt_text')::jsonb) #> '{properties,id}' ? 'default'
    AND NOT (public.get_schema('idt_tid')::jsonb) #> '{properties,id}' ? 'default',
    'get_schema: a string key gets no automatic empty default');

-- =====================================================
-- PART 8: get_record_by_id and set_record
-- =====================================================

SELECT is(get_record_by_id('idt_text', 'abc') ->> 'label', 't1',
    'get_record_by_id: a text key');

SELECT is(get_record_by_id('idt_big', '5000000000') ->> 'label', 'b1',
    'get_record_by_id: a bigint key beyond the int4 range, as text');

SELECT is(get_record_by_id('idt_uuid', '7a1a1a1a-0000-4000-8000-000000000001') ->> 'label', 'u-own',
    'get_record_by_id: a uuid key');

SELECT is(get_record_by_id('idt_tid', (SELECT id FROM idt_tid WHERE label = 'g2')) ->> 'label', 'g2',
    'get_record_by_id: a typeid key');

SELECT is(get_record_by_id('idt_big', 5) ->> 'label', 'b5',
    'get_record_by_id: an integer argument resolves to the BIGINT overload');

SELECT is(get_record_by_id('idt_auto', (SELECT id FROM idt_auto WHERE label = 'a2')) ->> 'label', 'a2',
    'get_record_by_id: a bigint argument resolves to the BIGINT overload');

SELECT ok(to_regprocedure('public.get_record_by_id(text, integer)') IS NULL
      AND has_function_privilege('semantius_user', 'public.get_record_by_id(text, text)', 'EXECUTE')
      AND has_function_privilege('semantius_user', 'public.get_record_by_id(text, bigint)', 'EXECUTE')
      AND NOT has_function_privilege('public', 'public.get_record_by_id(text, text)', 'EXECUTE')
      AND NOT has_function_privilege('public', 'public.get_record_by_id(text, bigint)', 'EXECUTE'),
    'get_record_by_id: the (TEXT, TEXT) and (TEXT, BIGINT) versions replace (TEXT, INTEGER), granted to the request role only');

SELECT is(get_record_by_id('idt_text', 'nope'), NULL,
    'get_record_by_id: a record that does not exist is still NULL');

SELECT throws_ok($$ SELECT get_record_by_id('idt_big', 'abc') $$, '90238', NULL,
    'get_record_by_id: a key that is not a number is refused');

SELECT throws_ok($$ SELECT get_record_by_id('idt_big', '99999999999999999999') $$, '90238', NULL,
    'get_record_by_id: a key out of the bigint range is refused');

SELECT throws_ok($$ SELECT get_record_by_id('idt_uuid', 'not-a-uuid') $$, '90238', NULL,
    'get_record_by_id: a malformed uuid is refused');

SELECT throws_ok($$ SELECT get_record_by_id('idt_tid', 'idtcust_zzz') $$, '90238', NULL,
    'get_record_by_id: a malformed TypeID is refused');

-- A caller who may not see the entity gets the "no such thing" NULL instead:
-- the refusal must not reveal that the entity exists or what its key is.
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'idt_big';
SELECT authenticate_as('user1');
SELECT is(get_record_by_id('idt_big', 'abc'), NULL,
    'get_record_by_id: a caller without view permission gets NULL for a malformed key');
SELECT authenticate_as('user3');

SELECT is(
    evaluate_json_logic('{"set_record": ["r", "idt_text", {"var": "k"}, {"var": "r.label"}]}'::jsonb,
                        '{"k": "abc"}'::jsonb),
    '"t1"'::jsonb,
    'set_record: loads a record by a text key');

SELECT is(
    evaluate_json_logic('{"set_record": ["r", "idt_big", {"*": [{"var": "k"}, 1.0]}, {"var": "r.label"}]}'::jsonb,
                        '{"k": 5}'::jsonb),
    '"b5"'::jsonb,
    'set_record: a whole number computed as 5.0 is used as 5');

SELECT throws_ok(
    $$ SELECT evaluate_json_logic('{"set_record": ["r", "idt_big", "x1", {"var": "r.label"}]}'::jsonb, '{}'::jsonb) $$,
    '90238', NULL,
    'set_record: a malformed key raises get_record_by_id''s refusal');

-- =====================================================
-- PART 9: ensure_entities and adoption
-- =====================================================

RESET ROLE;

SELECT lives_ok($$
    SELECT public.ensure_entities('{
        "version": 1,
        "entities": [{"entity": {
            "table_name": "idt_ens", "module_name": "_core", "singular": "idt_ens",
            "singular_label": "Ens", "plural_label": "Enses",
            "id_type": "typeid", "id_prefix": "idtens",
            "fields": [{"field_name": "note", "title": "Note", "format": "text", "field_order": 30}]
        }}]
    }'::jsonb)
$$, 'ensure_entities: accepts id_type and id_prefix');

SELECT ok(
    (SELECT id_type = 'typeid' AND id_prefix = 'idtens' FROM entities WHERE table_name = 'idt_ens')
    AND (SELECT format_type(atttypid, atttypmod) = 'common.typeid' FROM pg_attribute
          WHERE attrelid = 'public.idt_ens'::regclass AND attname = 'id'),
    'ensure_entities: the entity gets a typeid key');

-- id_type is create-only: a later file that names another type changes nothing
-- (rule 90233 would refuse it), while a changed prefix is applied.
SELECT public.ensure_entities('{
    "version": 1,
    "entities": [{"entity": {
        "table_name": "idt_ens", "module_name": "_core", "id_type": "typeid", "id_prefix": "idtens_two",
        "fields": [{"field_name": "note", "title": "Note", "format": "text", "field_order": 30}]
    }}]
}'::jsonb);
INSERT INTO idt_ens (note) VALUES ('after');

SELECT ok((SELECT id LIKE 'idtens\_two\_%' FROM idt_ens WHERE note = 'after'),
    'ensure_entities: a changed id_prefix is applied to the table''s trigger');

-- Adoption of a table whose key matches, with an id field row the author
-- wrote while the entity was unmanaged. Switching managed on rewrites no
-- metadata: a row that describes another key type blocks the switch (90239)
-- until the author corrects it.
CREATE TABLE public.idt_hand_big (id bigserial PRIMARY KEY, label text NOT NULL DEFAULT '');
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.idt_hand_big OWNER TO semantius_owner;
        ALTER SEQUENCE public.idt_hand_big_id_seq OWNER TO semantius_owner;
    END IF;
END $$;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed)
VALUES ('idt_hand_big', 'idt_hand_big', 'HBig', 'HBigs', 1, false);
INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order)
VALUES ('idt_hand_big', 'id', 'Id', 'int32', TRUE, 10);

SELECT throws_ok($$ UPDATE entities SET managed = true WHERE table_name = 'idt_hand_big' $$,
    '90239', NULL,
    'adoption: an id field row whose format differs from the key type blocks the switch');

SELECT ok(
    (SELECT NOT managed FROM entities WHERE table_name = 'idt_hand_big')
    AND (SELECT format || '/' || input_type FROM fields WHERE table_name = 'idt_hand_big' AND field_name = 'id') = 'int32/default'
    AND NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.idt_hand_big'::regclass)
    AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.idt_hand_big'::regclass AND tgname = 'pk_immutable'),
    'adoption: the refused switch changed nothing, neither metadata nor table');

UPDATE fields SET format = 'int64' WHERE table_name = 'idt_hand_big' AND field_name = 'id';

SELECT lives_ok($$ UPDATE entities SET managed = true WHERE table_name = 'idt_hand_big' $$,
    'adoption: with the id field corrected, the bigserial table is adopted as auto_increment');

SELECT is((SELECT format || '/' || input_type FROM fields WHERE table_name = 'idt_hand_big' AND field_name = 'id'),
    'int64/default',
    'adoption: the id field row is left as its author wrote it');

SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.idt_hand_big'::regclass AND tgname = 'pk_immutable'),
    'adoption: the adopted table gets pk_immutable');

-- Switching managed off and on again changes no metadata.
UPDATE entities SET managed = false WHERE table_name = 'idt_hand_big';
UPDATE entities SET managed = true WHERE table_name = 'idt_hand_big';

SELECT is(
    (SELECT string_agg(field_name || '=' || format || '/' || input_type || '/' || input_type_rule::text, ', ' ORDER BY field_name)
       FROM fields WHERE table_name = 'idt_hand_big'),
    'created_at=date-time/disabled/{}, id=int64/default/{}, label=text/required/{}, updated_at=date-time/disabled/{}',
    'switching managed off and on again leaves the field rows as they were');

-- The managed-flip path builds the key from id_type too.
INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id, managed, id_type)
VALUES ('idt_late', 'idt_late', 'Late', 'Lates', 1, false, 'uuid');
UPDATE entities SET managed = true WHERE table_name = 'idt_late';

SELECT is((SELECT format_type(atttypid, atttypmod) || '/' || (SELECT format FROM fields WHERE table_name = 'idt_late' AND field_name = 'id')
             FROM pg_attribute WHERE attrelid = 'public.idt_late'::regclass AND attname = 'id'),
    'uuid/uuid',
    'enabling a managed entity creates the key its id_type describes');

SELECT * FROM finish();
ROLLBACK;
