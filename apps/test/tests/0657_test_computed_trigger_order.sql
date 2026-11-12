-- Computed fields and validation rules against the other BEFORE triggers of a
-- table, whose firing order is listed in build_record_logic_trigger
-- (0210_computed_validation.sql); each part pins what one position buys.
--   PART 1  the whole order, on one table carrying every such trigger
--   PART 2  the typeid key: the rules see the generated id
--   PART 3  the order column: the rules see the assigned position
--   PART 4  the rollup guard before the rules, updated_at after them
--   PART 5  a RACI gate before and after the rules, in a family, on rename
--   PART 6  a rule that writes the record key
--   PART 7  the backfill of a rule that writes the key
--
-- Fixture entities use the 'ct' prefix; everything is rolled back.
BEGIN;

SELECT plan(32);

SELECT authenticate_as('user3');

-- The BEFORE row triggers of one event on a relation, in firing order.
-- tgtype bits: 1 ROW, 2 BEFORE, 4 INSERT, 8 DELETE, 16 UPDATE; names compare
-- byte by byte, hence COLLATE "C".
CREATE FUNCTION pg_temp.before_triggers(p_rel regclass, p_event int) RETURNS text
LANGUAGE sql AS $$
    SELECT string_agg(tgname::text, ', ' ORDER BY tgname::text COLLATE "C")
      FROM pg_trigger
     WHERE tgrelid = p_rel AND NOT tgisinternal AND (tgtype & (3 | p_event)) = (3 | p_event)
$$;

-- One process with a blocking consultation, for every gate of this file.
INSERT INTO processes (module_id, process_key, name) VALUES (1, 'ct_review', 'Review');
INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'consulted', r.id, 'block'
  FROM processes p, roles r
 WHERE p.process_key = 'ct_review' AND r.role_name = 'Administrator';

-- =====================================================
-- PART 1: the whole order
-- =====================================================
-- ctall: a typeid family root (an is_a subtype, a has_a extension) with an
-- order column, a rollup, a rule naming the key and a gated state column.

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, id_type, id_prefix, order_column)
VALUES ('ctall', 'ctall', 'All', 'Alls', 1, 'public:read', 'admin', 'typeid', 'ctall', 'sort_order'),
       ('ctall_line', 'ctall_line', 'All Line', 'All Lines', 1, 'public:read', 'admin', 'auto_increment', '', '');

INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value, field_order)
VALUES ('ctall', 'status', 'Status', 'enum', 'required', '["draft", "approved", "rejected"]'::jsonb, 'draft', 30);
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ctall_line', 'parent_id', 'Parent', 'parent', 10, 'ctall', 'cascade');
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ctall', 'line_count', 'Lines', 'int64', 40, '{"link_field": "ctall_line.parent_id", "function": "count"}');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctall', 'lines_plus', 'Lines Plus', 'int64', 50);

UPDATE entities
   SET computed_fields = '[{"name": "id", "jsonlogic": {"var": "id"}},
                           {"name": "lines_plus", "jsonlogic": {"+": [{"var": "line_count"}, 1]}}]'::jsonb
 WHERE table_name = 'ctall';

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('ctall_sub', 'All Sub', 'All Subs', 1, 'is_a', 'ctallsub', 'ctall');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('ctall_more', 'All More', 'All Mores', 1, 'has_a', 'ctall');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctall_sub', 'sub_note', 'Sub Note', 'text', 30);
UPDATE entities
   SET computed_fields = '[{"name": "sub_note", "jsonlogic": {"cat": ["S:", {"var": "status"}]}}]'::jsonb
 WHERE table_name = 'ctall_sub';

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'ctall', 'approval', 'approved', 'status', TRUE FROM processes WHERE process_key = 'ct_review';

SELECT is(pg_temp.before_triggers('public.ctall', 4),
    'a_auto_order_ctall, a_rollup_guard, a_typeid_assign, compute_validate_trigger, zz_key_check_insert',
    'order: BEFORE INSERT as listed in build_record_logic_trigger');

SELECT is(pg_temp.before_triggers('public.ctall', 16),
    'a_is_a_dispatch, a_raci_gate_on_ctall, a_rollup_guard, compute_validate_trigger, pk_immutable, '
    || 'raci_gate_on_ctall, update_ctall_updated_at, zz_key_check_update',
    'order: BEFORE UPDATE as listed in build_record_logic_trigger');

SELECT is(pg_temp.before_triggers('public.ctall', 8),
    'a_has_a_guard, a_is_a_dispatch, compute_validate_trigger',
    'order: BEFORE DELETE as listed in build_record_logic_trigger');

-- =====================================================
-- PART 2: the typeid key
-- =====================================================
-- The key has no column default; behind the rules, a label computed from the
-- id alone would be empty and refused by the required label (90258), and one
-- with a constant part would be saved without the id.

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, id_type, id_prefix, computed_fields)
VALUES
    ('ctid_label', 'ctid_label', 'Label', 'Labels', 1, 'public:read', 'admin', 'typeid', 'ctlab',
     '[{"name": "label", "jsonlogic": {"cat": [{"var": "id"}]}}]'),
    ('ctid_prefixed', 'ctid_prefixed', 'Prefixed', 'Prefixeds', 1, 'public:read', 'admin', 'typeid', 'ctpre',
     '[{"name": "label", "jsonlogic": {"cat": ["T-", {"var": "id"}]}}]'),
    ('ctid_root', 'ctid_root', 'Root', 'Roots', 1, 'public:read', 'admin', 'typeid', 'ctroot', '[]'),
    ('ctid_auto', 'ctid_auto', 'Auto', 'Autos', 1, 'public:read', 'admin', 'auto_increment', '',
     '[{"name": "label", "jsonlogic": {"cat": [{"var": "id"}]}}]'),
    ('ctid_uuid', 'ctid_uuid', 'Uuid', 'Uuids', 1, 'public:read', 'admin', 'uuid', '',
     '[{"name": "label", "jsonlogic": {"cat": [{"var": "id"}]}}]');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('ctid_sub', 'Sub', 'Subs', 1, 'is_a', 'ctsub', 'ctid_root');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctid_sub', 'ref_code', 'Ref Code', 'text', 30);
UPDATE entities
   SET computed_fields = '[{"name": "ref_code", "jsonlogic": {"cat": ["R-", {"var": "id"}]}}]'::jsonb
 WHERE table_name = 'ctid_sub';

SELECT lives_ok($$INSERT INTO ctid_label DEFAULT VALUES$$,
    'typeid: a required label computed from the generated id alone is accepted');

SELECT ok((SELECT label = id AND common.typeid_prefix(id) = 'ctlab' FROM ctid_label),
    'typeid: and the label is the generated id');

INSERT INTO ctid_prefixed DEFAULT VALUES;

SELECT ok((SELECT label = 'T-' || id FROM ctid_prefixed),
    'typeid: a label with a constant part carries the generated id');

-- The subtype's write routine mints the id, then runs the rules.
INSERT INTO ctid_sub (label) VALUES ('sub');

SELECT ok((SELECT ref_code = 'R-' || id AND common.typeid_prefix(id) = 'ctsub' FROM ctid_sub),
    'is_a: a computed field of a subtype sees the id minted with the subtype prefix');

-- The keys a column default fills, for comparison.
INSERT INTO ctid_auto DEFAULT VALUES;
INSERT INTO ctid_uuid DEFAULT VALUES;

SELECT ok((SELECT label = id::text FROM ctid_auto) AND (SELECT label = id::text FROM ctid_uuid),
    'auto_increment and uuid: a label computed from the id is the id the default filled');

-- =====================================================
-- PART 3: the order column
-- =====================================================
-- The column's default is 0, and a_auto_order_<table> replaces a 0 with the
-- next position.

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, order_column, computed_fields, validation_rules)
VALUES
    ('ctord', 'ctord', 'Ordered', 'Ordereds', 1, 'public:read', 'admin', 'sort_order',
     '[{"name": "order_note", "jsonlogic": {"cat": ["#", {"var": "sort_order"}]}}]',
     '[{"code": "99657", "message": "the record has no position", "jsonlogic": {">": [{"var": "sort_order"}, 0]}}]'),
    ('ctord_fixed', 'ctord_fixed', 'Pinned', 'Pinneds', 1, 'public:read', 'admin', 'sort_order',
     '[{"name": "sort_order", "jsonlogic": 5}]', '[]');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctord', 'order_note', 'Order Note', 'text', 30);

-- The validation rule would refuse a record without a position.
INSERT INTO ctord (label) VALUES ('first'), ('second');

SELECT is((SELECT string_agg(sort_order || '=' || order_note, ', ' ORDER BY sort_order) FROM ctord),
    '10=#10, 20=#20',
    'order column: computed fields and validation rules see the position assigned on insert');

INSERT INTO ctord_fixed (label) VALUES ('pinned');

SELECT is((SELECT sort_order FROM ctord_fixed), 5,
    'order column: a rule that writes the position still wins');

-- =====================================================
-- PART 4: the rollup guard before the rules, updated_at after them
-- =====================================================

INSERT INTO ctall (label) VALUES ('r1');
UPDATE ctall SET line_count = 999 WHERE label = 'r1';

SELECT is((SELECT line_count || '/' || lines_plus FROM ctall WHERE label = 'r1'), '0/1',
    'rollup: a computed field reads the aggregate the guard restored, not the value written');

-- update_ctall_updated_at skips a write that changes nothing outside the
-- rollup columns, and it runs after the rules, so a child write that moves a
-- computed field over the rollup still bumps it (0555_test_rollup.sql: without
-- one it does not). Every write here carries the same CURRENT_TIMESTAMP, so
-- the record is first given an old updated_at as the owner.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE ctall DISABLE TRIGGER update_ctall_updated_at;
UPDATE ctall SET updated_at = '2020-01-01 00:00:00+00' WHERE label = 'r1';
ALTER TABLE ctall ENABLE TRIGGER update_ctall_updated_at;
SELECT authenticate_as('user3');

INSERT INTO ctall_line (label, parent_id) SELECT 'l1', id FROM ctall WHERE label = 'r1';

SELECT ok((SELECT lines_plus = 2 AND updated_at = CURRENT_TIMESTAMP FROM ctall WHERE label = 'r1'),
    'rollup: a child write that moves a computed field over the rollup bumps updated_at');

-- A rule reads the previous updated_at on update, and the stored one as $now.
INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, computed_fields)
VALUES ('ctupd', 'ctupd', 'Touched', 'Toucheds', 1, 'public:read', 'admin',
    '[{"name": "seen_at", "jsonlogic": {"var": "updated_at"}},
      {"name": "now_at", "jsonlogic": {"var": "$now"}}]');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctupd', 'seen_at', 'Seen At', 'date-time', 30),
       ('ctupd', 'now_at', 'Now At', 'date-time', 40);

INSERT INTO ctupd (label, updated_at) VALUES ('touched', '2026-01-01 12:34:00+00');
UPDATE ctupd SET label = 'touched again';

SELECT ok((SELECT seen_at = '2026-01-01 12:34:00+00' AND now_at = updated_at AND updated_at = CURRENT_TIMESTAMP FROM ctupd),
    'updated_at: a rule reads the previous value on update and the stored one as $now');

-- =====================================================
-- PART 5: a state column held by a blocking consultation
-- =====================================================
-- Entering the gated state raises a consultation; while that is unacted, the
-- gate puts any change of the state column back (0850_test_raci.sql).

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, computed_fields, validation_rules)
VALUES ('ctgate', 'ctgate', 'Gated', 'Gateds', 1, 'public:read', 'admin',
    '[{"name": "status", "jsonlogic": {"if": [{"==": [{"var": "label"}, "force"]}, "closed", {"var": "status"}]}},
      {"name": "status_note", "jsonlogic": {"cat": ["S:", {"var": "status"}]}}]',
    '[{"code": "99658", "message": "a record is never rejected", "jsonlogic": {"!=": [{"var": "status"}, "rejected"]}}]');

INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value, field_order)
VALUES ('ctgate', 'status', 'Status', 'enum', 'required', '["draft", "approved", "rejected", "closed"]'::jsonb, 'draft', 30),
       ('ctgate', 'status_note', 'Status Note', 'text', 'default', '[]'::jsonb, '', 40);

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'ctgate', 'approval', 'approved', 'status', TRUE FROM processes WHERE process_key = 'ct_review';

INSERT INTO ctgate (label) VALUES ('gated');
UPDATE ctgate SET status = 'approved';

-- The rules judge the state that will be stored: the validation rule would
-- refuse 'rejected', which the gate holds back.
SELECT lives_ok($$UPDATE ctgate SET status = 'rejected', label = 'gated edited'$$,
    'RACI gate: a validation rule judges the held state, not the refused one');

SELECT is((SELECT status || ' ' || status_note || ' ' || label FROM ctgate),
    'approved S:approved gated edited',
    'RACI gate: and a computed field follows the held state');

UPDATE ctgate SET label = 'force';

SELECT is((SELECT status FROM ctgate), 'approved',
    'RACI gate: a state a rule writes is held as well');

-- A rename carries the gates, the pending consultation and the triggers along.
UPDATE entities SET table_name = 'ctgate_renamed' WHERE table_name = 'ctgate';
UPDATE ctgate_renamed SET status = 'closed', label = 'gated renamed';

SELECT is((SELECT status || ' ' || label FROM ctgate_renamed), 'approved gated renamed',
    'RACI gate: the gate still holds after the entity is renamed');

-- A subtype's rules run in its write routine, before the write reaches the
-- root table's gates: the routine holds the root's state first.
INSERT INTO ctall_sub (label) VALUES ('sub');
UPDATE ctall_sub SET status = 'approved';
UPDATE ctall_sub SET status = 'rejected';

SELECT is((SELECT status || ' ' || sub_note FROM ctall_sub), 'approved S:approved',
    'RACI gate: a subtype rule reading the root''s gated state sees the held state');

-- =====================================================
-- PART 6: a rule that writes the record key
-- =====================================================
-- A rule may compute the key of a new record, but the key has to pass the
-- checks a supplied one passes, and a stored record's key never changes.

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission, id_type, id_prefix, computed_fields)
VALUES
    ('ctkey_tid', 'ctkey_tid', 'Keyed', 'Keyeds', 1, 'public:read', 'admin', 'typeid', 'ctkey',
     '[{"name": "id", "jsonlogic": {"if": [{"==": [{"var": "label"}, "wrong"]},
                                           "other_01h455vb4pex5vsknk084sn02q",
                                           "ctkey_01h455vb4pex5vsknk084sn02q"]}}]'),
    ('ctkey_text', 'ctkey_text', 'Coded', 'Codeds', 1, 'public:read', 'admin', 'text', '',
     '[{"name": "id", "jsonlogic": {"cat": ["k-", {"var": "label"}]}}]');

SELECT ok(
    (SELECT count(*) = 2 FROM pg_trigger
      WHERE tgrelid = 'public.ctkey_tid'::regclass AND tgname IN ('zz_key_check_insert', 'zz_key_check_update'))
    AND NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgrelid IN ('public.ctid_label'::regclass, 'public.ctid_auto'::regclass)
                       AND tgname LIKE 'zz\_key\_check\_%'),
    'key rule: only a table with a rule naming its key gets the late key checks');

SELECT throws_ok($$INSERT INTO ctkey_tid (label) VALUES ('wrong')$$, '90237', NULL,
    'key rule: an id a rule writes must carry the entity prefix');

INSERT INTO ctkey_tid (label) VALUES ('right');

SELECT is((SELECT id::text FROM ctkey_tid), 'ctkey_01h455vb4pex5vsknk084sn02q',
    'key rule: an id a rule writes with the entity prefix is stored');

-- A new prefix reaches the late check with the same arguments as the early one.
UPDATE entities SET id_prefix = 'ctkeynew' WHERE table_name = 'ctkey_tid';

SELECT ok((SELECT count(DISTINCT tgargs) = 1 AND bool_and(position('ctkeynew' IN encode(tgargs, 'escape')) > 0)
             FROM pg_trigger
            WHERE tgrelid = 'public.ctkey_tid'::regclass AND tgname IN ('a_typeid_assign', 'zz_key_check_insert')),
    'key rule: a prefix change gives zz_key_check_insert the arguments of a_typeid_assign');

SELECT lives_ok($$INSERT INTO ctkey_text (label) VALUES ('a')$$,
    'key rule: a rule may compute a text key on insert');

SELECT throws_ok($$UPDATE ctkey_text SET label = 'b'$$, '90236', NULL,
    'key rule: but a change of what it is computed from cannot move it');

UPDATE entities SET computed_fields = '[]' WHERE table_name = 'ctkey_text';

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_trigger
                       WHERE tgrelid = 'public.ctkey_text'::regclass AND tgname LIKE 'zz\_key\_check\_%'),
    'key rule: removing the rule drops the late key checks');

-- A table whose key has no key trigger on purpose (0070_rbac_schema.sql) gets
-- none from a rule naming it: a permission is still renamed.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
UPDATE entities SET computed_fields = '[{"name": "permission_name", "jsonlogic": {"var": "permission_name"}}]'
 WHERE table_name = 'permissions';
INSERT INTO permissions (permission_name, description, module_id) VALUES ('ct:probe', '', 1);

SELECT lives_ok($$UPDATE permissions SET permission_name = 'ct:probed' WHERE permission_name = 'ct:probe'$$,
    'key rule: a rule naming a renamable key adds no key check');
SELECT authenticate_as('user3');

-- A subtype's and an extension's write routines check the key after the rules.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('ctkey_sub', 'Keyed Sub', 'Keyed Subs', 1, 'is_a', 'ctkeysub', 'ctid_root');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('ctkey_attach', 'Keyed Ext', 'Keyed Exts', 1, 'has_a', 'ctid_root');
UPDATE entities
   SET computed_fields = CASE table_name
           WHEN 'ctkey_sub' THEN
               '[{"name": "id", "jsonlogic": {"if": [{"==": [{"var": "label"}, "wrong"]},
                                                     "ctroot_01h455vb4pex5vsknk084sn02q", {"var": "id"}]}}]'::jsonb
           ELSE '[{"name": "id", "jsonlogic": {"cat": ["ctsub_01h455vb4pex5vsknk084sn02q"]}}]'::jsonb
       END
 WHERE table_name IN ('ctkey_sub', 'ctkey_attach');

SELECT throws_ok($$INSERT INTO ctkey_sub (label) VALUES ('wrong')$$, '90237', NULL,
    'key rule: an id a subtype rule writes must carry the subtype prefix');

INSERT INTO ctkey_sub (label) VALUES ('right');

SELECT throws_ok($$UPDATE ctkey_sub SET label = 'wrong'$$, '90236', NULL,
    'key rule: a subtype rule cannot change the key of a stored record');

SELECT throws_ok($$INSERT INTO ctkey_attach (label) VALUES ('e')$$, '90237', NULL,
    'key rule: an id an extension rule writes must carry the base prefix, not a subtype''s');

INSERT INTO ctid_root (id, label) VALUES ('ctroot_01h455vb4pex5vsknk084sn02r', 'base');

SELECT throws_ok($$INSERT INTO ctkey_attach (id, label) VALUES ('ctroot_01h455vb4pex5vsknk084sn02r', 'base')$$,
    '90236', NULL,
    'key rule: an extension rule cannot move the record it attaches to');

-- =====================================================
-- PART 7: the backfill of a rule that writes the key
-- =====================================================
-- Saving a rule applies it to the stored records. Each is found by its stored
-- key, so a rule that would move a key is refused like an update would be.

INSERT INTO entities (table_name, singular, singular_label, plural_label, module_id,
    view_permission, edit_permission)
VALUES ('ctbf', 'ctbf', 'Filled', 'Filleds', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ctbf', 'note', 'Note', 'text', 30);
INSERT INTO ctbf (label) VALUES ('one'), ('two');

SELECT throws_ok(
    $$UPDATE entities SET computed_fields = '[{"name": "id", "jsonlogic": {"+": [{"var": "id"}, 1000]}}]'
       WHERE table_name = 'ctbf'$$,
    '90908', NULL,
    'backfill: a rule that would move the key of a stored record is refused');

UPDATE entities
   SET computed_fields = '[{"name": "id", "jsonlogic": {"var": "id"}},
                           {"name": "note", "jsonlogic": {"cat": ["n", {"var": "id"}]}}]'
 WHERE table_name = 'ctbf';

SELECT ok((SELECT bool_and(note = 'n' || id) AND count(*) = 2 FROM ctbf),
    'backfill: a rule that keeps the key writes the other computed fields of every record');

SELECT * FROM finish();
ROLLBACK;
