-- An entity's key is fixed when the entity is created: its key type
-- (id_type), the key column (id_column), the base of an is_a or has_a entity
-- (id_refentity) and the id field row. The key column, its default and
-- triggers, and the type of every reference to it are built from them, and no
-- path of the dictionary rebuilds a key, so a changed value would describe a
-- key the table does not have. The settings that may change are the prefix
-- of a typeid or typenumber entity and the digits of a typenumber entity:
-- they are read only when a new key is generated.
--
-- This file tries every change of those settings, for every key type, along
-- every path that writes the catalog, and pins the code that refuses it:
--   PART 1  id_type to every other key type, as administrator and as owner
--   PART 2  the same id_type written back, as a whole-record save sends it
--   PART 3  an entity that is not managed, with a table and without one
--   PART 4  ensure_entities with a file that names another key type
--   PART 5  the id field row
--   PART 6  type_prefix, type_digits, id_refentity and id_column
--
-- What a prefix change does to new and existing keys is pinned by PART 4 of
-- 0435_test_entity_id_types.sql and by 0438_test_entity_typenumber.sql, a key
-- column per family level by PART 3 of 0436_test_entity_family_changes.sql.
--
-- Fixture entities are named kc_*. Everything is rolled back.

BEGIN;

SELECT plan(53);

-- =====================================================
-- Helpers and fixtures
-- =====================================================

-- The SQLSTATE a statement raises, '00000' when it succeeds. The statement
-- always ends in an error, a sentinel one when it succeeded, so nothing it
-- did remains and the next attempt starts from the same catalog.
CREATE FUNCTION pg_temp.sqlstate_of(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_state TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'the statement succeeded' USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN OTHERS THEN
        v_state := SQLSTATE;
    END;
    RETURN CASE WHEN v_state = 'ZZ001' THEN '00000' ELSE v_state END;
END $fn$;

-- One entity per key type, and the prefix and base a row of that type needs.
-- computed is a core table: no managed entity may take that type (90234).
CREATE TEMP TABLE kc_types (ord INT, id_type TEXT, src TEXT, prefix TEXT, base TEXT);
INSERT INTO kc_types VALUES
    (1, 'auto_increment', 'kc_auto',          '',      NULL),
    (2, 'bigint',         'kc_big',           '',      NULL),
    (3, 'text',           'kc_text',          '',      NULL),
    (4, 'uuid',           'kc_uuid',          '',      NULL),
    (5, 'typeid',         'kc_tid',           'kcnew', NULL),
    (6, 'typenumber',     'kc_tnum',          'KCNEW', NULL),
    (7, 'is_a',           'kc_isa',           'kcnew', 'kc_root'),
    (8, 'has_a',          'kc_hasa',          '',      'kc_root'),
    (9, 'computed',       'role_permissions', '',      NULL);
GRANT SELECT ON kc_types TO semantius_user;

-- The outcome of changing the key type of p_from's entity to every other key
-- type, as 'type=code' in key type order. With p_full the update also sets
-- the prefix and base the new type needs, so the constraints that tie both to
-- the key type (type_prefix_matches_id_type, id_refentity_matches_id_type) hold
-- and cannot be what refuses it.
CREATE FUNCTION pg_temp.kc_changes(p_from TEXT, p_full BOOLEAN) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(t.id_type || '=' || pg_temp.sqlstate_of(
               CASE WHEN p_full
                    THEN format('UPDATE entities SET id_type = %L, type_prefix = %L, id_refentity = %L WHERE table_name = %L',
                                t.id_type, t.prefix, t.base, f.src)
                    ELSE format('UPDATE entities SET id_type = %L WHERE table_name = %L', t.id_type, f.src)
               END), ', ' ORDER BY t.ord)
      FROM kc_types f
      JOIN kc_types t ON t.id_type <> f.id_type
     WHERE f.id_type = p_from;
$fn$;

-- The outcome of p_sql against the entity of every key type, or of the types
-- in p_types, as 'type=code' in key type order. %1$L in p_sql is the entity.
CREATE FUNCTION pg_temp.kc_each(p_sql TEXT, p_types TEXT[] DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(t.id_type || '=' || pg_temp.sqlstate_of(format(p_sql, t.src)), ', ' ORDER BY t.ord)
      FROM kc_types t
     WHERE p_types IS NULL OR t.id_type = ANY (p_types);
$fn$;

-- The same code for every key type, in key type order.
CREATE FUNCTION pg_temp.kc_all(p_code TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(t.id_type || '=' || p_code, ', ' ORDER BY t.ord) FROM kc_types t;
$fn$;

-- The key type each fixture's row names and the type of the key column its
-- table or view has, which must still agree after every attempt.
CREATE FUNCTION pg_temp.kc_keys() RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(t.id_type || '=' || e.id_type || '/' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY t.ord)
      FROM kc_types t
      JOIN entities e ON e.table_name = t.src
      JOIN pg_attribute a ON a.attrelid = to_regclass(format('public.%I', t.src)) AND a.attname = e.id_column;
$fn$;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix)
VALUES ('kc_auto', 'Auto', 'Autos', 1, 'auto_increment', ''),
       ('kc_big',  'Big',  'Bigs',  1, 'bigint',         ''),
       ('kc_text', 'Text', 'Texts', 1, 'text',           ''),
       ('kc_uuid', 'Uuid', 'Uuids', 1, 'uuid',           ''),
       ('kc_tid',  'Tid',  'Tids',  1, 'typeid',         'kctid'),
       ('kc_tnum', 'Tnum', 'Tnums', 1, 'typenumber',     'KCTNUM'),
       ('kc_root', 'Root', 'Roots', 1, 'typeid',         'kcroot'),
       ('kc_root2', 'Root Two', 'Root Twos', 1, 'typeid', 'kcroottwo');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
VALUES ('kc_isa', 'Subtype', 'Subtypes', 1, 'is_a', 'kcisa', 'kc_root');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('kc_hasa', 'Extension', 'Extensions', 1, 'has_a', 'kc_root');

-- =====================================================
-- PART 1: id_type never changes
-- =====================================================
-- Rule 90233 on entities refuses any change of id_type. PostgreSQL fires
-- triggers in name order, so check_entity_family_trigger sees the row before
-- compute_validate_trigger runs the rules: a change that also gives the row a
-- base, or takes its base away, is refused there with 90241 (the base never
-- changes), and a change to is_a or has_a that names no base with 90242 (a
-- derived entity's label settings come from its base). Between is_a and has_a
-- the base stays, so the rule refuses it.

SELECT is(pg_temp.kc_changes(c.from_type, TRUE), c.expected,
          c.from_type || ': a change to any other key type, with the prefix and base it needs, is refused')
  FROM (VALUES
    (1, 'auto_increment', 'bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (2, 'bigint',         'auto_increment=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (3, 'text',           'auto_increment=90233, bigint=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (4, 'uuid',           'auto_increment=90233, bigint=90233, text=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (5, 'typeid',         'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (6, 'typenumber',     'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, is_a=90241, has_a=90241, computed=90233'),
    (7, 'is_a',           'auto_increment=90241, bigint=90241, text=90241, uuid=90241, typeid=90241, typenumber=90241, has_a=90233, computed=90241'),
    (8, 'has_a',          'auto_increment=90241, bigint=90241, text=90241, uuid=90241, typeid=90241, typenumber=90241, is_a=90233, computed=90241'),
    (9, 'computed',       'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241')
  ) AS c(ord, from_type, expected)
 ORDER BY c.ord;

SELECT is(pg_temp.kc_changes(c.from_type, FALSE), c.expected,
          c.from_type || ': a change of id_type alone, to any other key type, is refused')
  FROM (VALUES
    (1, 'auto_increment', 'bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90242, has_a=90242, computed=90233'),
    (2, 'bigint',         'auto_increment=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90242, has_a=90242, computed=90233'),
    (3, 'text',           'auto_increment=90233, bigint=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90242, has_a=90242, computed=90233'),
    (4, 'uuid',           'auto_increment=90233, bigint=90233, text=90233, typeid=90233, typenumber=90233, is_a=90242, has_a=90242, computed=90233'),
    (5, 'typeid',         'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typenumber=90233, is_a=90242, has_a=90242, computed=90233'),
    (6, 'typenumber',     'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, is_a=90242, has_a=90242, computed=90233'),
    (7, 'is_a',           'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, has_a=90233, computed=90233'),
    (8, 'has_a',          'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90233, computed=90233'),
    (9, 'computed',       'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90242, has_a=90242')
  ) AS c(ord, from_type, expected)
 ORDER BY c.ord;

-- The owner is not exempt: both guards are triggers, which run for every role.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is(pg_temp.kc_changes(c.from_type, TRUE), c.expected,
          c.from_type || ': as the owner, a change to any other key type is refused')
  FROM (VALUES
    (1, 'auto_increment', 'bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (2, 'bigint',         'auto_increment=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (3, 'text',           'auto_increment=90233, bigint=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (4, 'uuid',           'auto_increment=90233, bigint=90233, text=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (5, 'typeid',         'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typenumber=90233, is_a=90241, has_a=90241, computed=90233'),
    (6, 'typenumber',     'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, is_a=90241, has_a=90241, computed=90233'),
    (7, 'is_a',           'auto_increment=90241, bigint=90241, text=90241, uuid=90241, typeid=90241, typenumber=90241, has_a=90233, computed=90241'),
    (8, 'has_a',          'auto_increment=90241, bigint=90241, text=90241, uuid=90241, typeid=90241, typenumber=90241, is_a=90233, computed=90241'),
    (9, 'computed',       'auto_increment=90233, bigint=90233, text=90233, uuid=90233, typeid=90233, typenumber=90233, is_a=90241, has_a=90241')
  ) AS c(ord, from_type, expected)
 ORDER BY c.ord;

SELECT authenticate_as('user3');

-- =====================================================
-- PART 2: the same id_type written back
-- =====================================================
-- A form or a PATCH that saves the whole entity row sends id_type with it.
-- Rule 90233 fires only on a changed value, so such a save passes.

SELECT is(pg_temp.kc_each($$UPDATE entities SET id_type = id_type, description = 'saved' WHERE table_name = %1$L$$),
    pg_temp.kc_all('00000'),
    'writing the unchanged id_type back with another change passes for every key type');

UPDATE entities e SET id_type = t.id_type, description = 'kc saved'
  FROM kc_types t
 WHERE e.table_name = t.src;

SELECT is(
    (SELECT string_agg(t.id_type || '=' || e.id_type || '/' || e.description, ', ' ORDER BY t.ord)
       FROM kc_types t JOIN entities e ON e.table_name = t.src),
    'auto_increment=auto_increment/kc saved, bigint=bigint/kc saved, text=text/kc saved, uuid=uuid/kc saved, typeid=typeid/kc saved, typenumber=typenumber/kc saved, is_a=is_a/kc saved, has_a=has_a/kc saved, computed=computed/kc saved',
    '... and the rest of that save is applied');

-- =====================================================
-- PART 3: an entity that is not managed
-- =====================================================
-- The rule does not ask whether the entity is managed: a table switched off
-- still has the key its id_type built, and an entity registered without a
-- table is typed from id_type by every reference to it (field_data_type).

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type)
VALUES ('kc_off', 'Off', 'Offs', 1, 'auto_increment');
UPDATE entities SET managed = FALSE WHERE table_name = 'kc_off';

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed, id_type)
VALUES ('kc_ghost', 'Ghost', 'Ghosts', 1, FALSE, 'uuid');
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_type = 'uuid' WHERE table_name = 'kc_off'$$), '90233',
    'not managed, with a table: id_type cannot change');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_type = 'text' WHERE table_name = 'kc_ghost'$$), '90233',
    'not managed, without a table: id_type cannot change');

-- =====================================================
-- PART 4: ensure_entities
-- =====================================================
-- id_type is a create-only column of ensure_entities: a file applied to an
-- entity that exists does not write it, so a file naming another key type
-- applies without an error and the key stays as it is.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT lives_ok(
    format('SELECT public.ensure_entities(%L::jsonb)',
           jsonb_build_object('version', 1, 'entities', jsonb_build_array(jsonb_build_object('entity',
               jsonb_build_object('table_name', t.src, 'module_name', '_core', 'id_type', c.to_type)))))::text,
    'ensure_entities: a file that names ' || c.to_type || ' for the ' || t.id_type || ' entity applies')
  FROM kc_types t
  JOIN (VALUES ('auto_increment', 'uuid'), ('bigint', 'text'), ('text', 'uuid'), ('uuid', 'text'),
               ('typeid', 'uuid'), ('typenumber', 'typeid'), ('is_a', 'has_a'), ('has_a', 'is_a')) AS c(from_type, to_type)
    ON c.from_type = t.id_type
 ORDER BY t.ord;

SELECT is(pg_temp.kc_keys(),
    'auto_increment=auto_increment/bigint, bigint=bigint/bigint, text=text/text, uuid=uuid/uuid, typeid=typeid/common.typeid, typenumber=typenumber/common.typenumber, is_a=is_a/common.typeid, has_a=has_a/common.typeid, computed=computed/text',
    'ensure_entities: every entity keeps its key type and its key column');

SELECT authenticate_as('user3');

-- =====================================================
-- PART 5: the id field row
-- =====================================================
-- The id field row describes the key column. Its format, default and
-- deletion are locked by the core marker id it carries (dd_ctype_is_core),
-- which only the dictionary sets or clears; its key status by
-- update_dd_field; and one_pk_per_table_idx keeps the key a single column.

SELECT is(pg_temp.kc_each($$UPDATE fields SET format = CASE WHEN format = 'uuid' THEN 'int64' ELSE 'uuid' END
                             WHERE table_name = %1$L AND is_pk$$),
    pg_temp.kc_all('90219'),
    'id field: the format cannot change, for any key type');

SELECT is(pg_temp.kc_each($$UPDATE fields SET default_value = '1' WHERE table_name = %1$L AND is_pk$$),
    pg_temp.kc_all('90220'),
    'id field: the default cannot change, for any key type');

SELECT is(pg_temp.kc_each($$UPDATE fields SET is_pk = FALSE WHERE table_name = %1$L AND is_pk$$),
    pg_temp.kc_all('90222'),
    'id field: it cannot stop being the key, for any key type');

SELECT is(pg_temp.kc_each($$UPDATE fields SET ctype = '' WHERE table_name = %1$L AND is_pk$$),
    pg_temp.kc_all('90214'),
    'id field: its core marker cannot be cleared, for any key type');

SELECT is(pg_temp.kc_each($$DELETE FROM fields WHERE table_name = %1$L AND is_pk$$),
    pg_temp.kc_all('90217'),
    'id field: it cannot be deleted, for any key type');

SELECT is(pg_temp.kc_each($$INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order)
                             VALUES (%1$L, 'kc_key2', 'Second Key', 'uuid', TRUE, 90)$$),
    pg_temp.kc_all('23505'),
    'id field: no second key field can be added (one_pk_per_table_idx), for any key type');

-- =====================================================
-- PART 6: the prefix, the base and the key column
-- =====================================================
-- The prefix may change on a typeid or typenumber entity, and the digits on a
-- typenumber entity, where both are read when a new key is generated; each
-- within its own grammar (valid_type_prefix). An is_a entity's prefix names
-- the type of its records, whose keys carry it (90245), and it numbers with
-- its root's digits; every other key type has neither
-- (type_prefix_matches_id_type, valid_type_digits).

SELECT is(pg_temp.kc_each($$UPDATE entities SET type_prefix = 'kcpfx' WHERE table_name = %1$L$$),
    'auto_increment=23514, bigint=23514, text=23514, uuid=23514, typeid=00000, typenumber=23514, is_a=90245, has_a=23514, computed=23514',
    'type_prefix: a Typed Id prefix fits only a typeid entity, which may change it');

SELECT is(pg_temp.kc_each($$UPDATE entities SET type_prefix = 'KCPFX' WHERE table_name = %1$L$$),
    'auto_increment=23514, bigint=23514, text=23514, uuid=23514, typeid=23514, typenumber=00000, is_a=90245, has_a=23514, computed=23514',
    'type_prefix: a Typed Number prefix fits only a typenumber entity, which may change it');

SELECT is(pg_temp.kc_each($$UPDATE entities SET type_prefix = '' WHERE table_name = %1$L$$, ARRAY['typeid', 'typenumber', 'is_a']),
    'typeid=23514, typenumber=23514, is_a=90245',
    'type_prefix: the key types that carry one cannot drop it');

SELECT is(pg_temp.kc_each($$UPDATE entities SET type_digits = 4 WHERE table_name = %1$L$$),
    'auto_increment=23514, bigint=23514, text=23514, uuid=23514, typeid=23514, typenumber=00000, is_a=23514, has_a=23514, computed=23514',
    'type_digits: only a typenumber entity has digits, and may change them');

SELECT is(pg_temp.kc_each($$UPDATE entities SET id_refentity = 'kc_root2' WHERE table_name = %1$L$$),
    pg_temp.kc_all('90241'),
    'id_refentity: no entity gains or changes a base');

SELECT is(pg_temp.kc_each($$UPDATE entities SET id_refentity = NULL WHERE table_name = %1$L$$, ARRAY['is_a', 'has_a']),
    'is_a=90241, has_a=90241',
    'id_refentity: a derived entity cannot lose its base');

SELECT is(pg_temp.kc_each($$UPDATE entities SET id_column = 'kc_key' WHERE table_name = %1$L$$),
    pg_temp.kc_all('90253'),
    'id_column: the key column cannot be renamed, for any key type');

SELECT * FROM finish();
ROLLBACK;
