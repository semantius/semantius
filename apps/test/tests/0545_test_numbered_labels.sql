-- Numbered labels: entities.label_format = 'number' and the label step
-- common.label_number_assign (0160_dd_functions.sql).
--   PART 1  the settings and their checks
--   PART 2  a numeric key: the label is the prefix and the formatted id
--   PART 3  a separate counter: insert, update, privileged supply
--   PART 4  switching an entity with records, and what is refused
--   PART 5  an is_a family: a counter per subtype with settings of its own
--   PART 6  the unique index, the rename and the drop of the counter
--
-- Fixture entities use the 'nlb' prefix; everything is rolled back.
BEGIN;

SELECT plan(40);

SELECT authenticate_as('user3');

-- =====================================================
-- PART 1: the settings
-- =====================================================
SELECT is(
    (SELECT string_agg(field_name || '=' || default_value, ', ' ORDER BY field_order)
       FROM fields
      WHERE table_name = 'entities'
        AND field_name IN ('label_format', 'label_number_prefix', 'label_number_digits', 'label_number_start')),
    'label_format=custom, label_number_prefix=, label_number_digits=0, label_number_start=1',
    'the four label settings are fields of entities, custom with no prefix and padding, counting from 1');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, label_number_prefix)
      VALUES ('nlb_bad', 'Bad', 'Bads', 1, 'IN C')$$,
    '23514', NULL,
    'a prefix with a character outside letters, digits, - and _ is refused');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, label_number_prefix)
      VALUES ('nlb_bad', 'Bad', 'Bads', 1, 'ABCDEFGHIJKLMNOPQRSTU')$$,
    '23514', NULL,
    'a prefix of more than 20 characters is refused');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, label_number_digits)
      VALUES ('nlb_bad', 'Bad', 'Bads', 1, 19)$$,
    '23514', NULL,
    'more than 18 digits are refused');

-- =====================================================
-- PART 2: a numeric key
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      label_format, label_number_prefix, label_number_digits)
VALUES ('nlb_order', 'Order', 'Orders', 1, 'public:read', 'admin', 'number', 'SO-', 6);

SELECT is((SELECT ctype FROM fields WHERE table_name = 'nlb_order' AND field_name = 'label'), 'number_label',
    'the label field of a numbered entity carries ctype number_label');

INSERT INTO nlb_order (label) VALUES ('typed');
SELECT is((SELECT label FROM nlb_order), 'SO-' || lpad((SELECT id FROM nlb_order)::text, 6, '0'),
    'numeric key: the label is the prefix and the id, padded to the digits');

UPDATE nlb_order SET label = 'changed';
SELECT is((SELECT label FROM nlb_order), 'SO-' || lpad((SELECT id FROM nlb_order)::text, 6, '0'),
    'an update keeps the label');

-- A seed brings a label of its own: a numeric key writes it from the id all the
-- same. A seed is a privileged direct session: the connecting role, no claims.
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;
INSERT INTO nlb_order (id, label) VALUES (1234567, 'SO-000001');
SELECT is((SELECT label FROM nlb_order WHERE id = 1234567), 'SO-1234567',
    'numeric key: a privileged session cannot supply a label either, and a long id is not cut');
SELECT authenticate_as('user3');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_class WHERE relname IN ('nlb_order_label_seq', 'nlb_order_label_number_unique')),
    'numeric key: no counter and no unique index');

SELECT is(
    (SELECT string_agg(tgname::text, ', ' ORDER BY tgname::text COLLATE "C") FROM pg_trigger
      WHERE tgrelid = 'public.nlb_order'::regclass AND NOT tgisinternal AND tgname LIKE 'b\_%'),
    'b_label_number',
    'the label step is the trigger b_label_number');

UPDATE entities SET label_format = 'custom' WHERE table_name = 'nlb_order';
SELECT is((SELECT ctype FROM fields WHERE table_name = 'nlb_order' AND field_name = 'label'), 'label',
    'back to custom, the label field is an ordinary label again');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.nlb_order'::regclass AND tgname = 'b_label_number'),
    'back to custom, the label step is gone');
INSERT INTO nlb_order (label) VALUES ('free text');
SELECT ok(EXISTS (SELECT 1 FROM nlb_order WHERE label = 'free text'), 'a custom label is written as given');

-- =====================================================
-- PART 3: a separate counter
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      id_type, label_format, label_number_prefix, label_number_digits, label_number_start)
VALUES ('nlb_incident', 'Incident', 'Incidents', 1, 'public:read', 'admin',
        'uuid', 'number', 'INC', 7, 10001);

INSERT INTO nlb_incident (label) VALUES ('first');
INSERT INTO nlb_incident (label) VALUES ('');
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM nlb_incident), 'INC0010001, INC0010002',
    'other keys: a counter of the entity numbers from its start, padded to the digits');

UPDATE nlb_incident SET label = 'INC9' WHERE label = 'INC0010001';
SELECT ok(EXISTS (SELECT 1 FROM nlb_incident WHERE label = 'INC0010001'), 'an update keeps a counted label');

SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incident_label_seq' AND relkind = 'S'),
    'the counter is the sequence <table>_label_seq');

-- A seed may supply labels; the counter moves past the highest one of its format.
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;
INSERT INTO nlb_incident (label) VALUES ('INC0050000'), ('imported by hand');
SELECT authenticate_as('user3');
SELECT is((SELECT count(*)::int FROM nlb_incident WHERE label IN ('INC0050000', 'imported by hand')), 2,
    'a privileged session supplies labels, of the format or not');
INSERT INTO nlb_incident (label) VALUES ('next');
SELECT ok(EXISTS (SELECT 1 FROM nlb_incident WHERE label = 'INC0050001'),
    'after a supplied label of the format the counter goes on past it');

RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;
SELECT throws_ok(
    $$INSERT INTO nlb_incident (label) VALUES ('INC0050001')$$,
    '23505', 'duplicate key value violates unique constraint "nlb_incident_label_number_unique"',
    'two records cannot hold one number: the labels of the format are unique');
SELECT authenticate_as('user3');

-- =====================================================
-- PART 4: switching, and what is refused
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type)
VALUES ('nlb_ticket', 'Ticket', 'Tickets', 1, 'public:read', 'admin', 'text');
INSERT INTO nlb_ticket (id, label) VALUES ('a', 'TK-7'), ('b', 'Old ticket');
UPDATE entities SET label_format = 'number', label_number_prefix = 'TK-' WHERE table_name = 'nlb_ticket';
INSERT INTO nlb_ticket (id, label) VALUES ('c', '');
SELECT is((SELECT string_agg(id || '=' || label, ', ' ORDER BY id) FROM nlb_ticket), 'a=TK-7, b=Old ticket, c=TK-8',
    'switching keeps the labels there are, and the counter starts above the highest one of the format');

-- A numeric key: a label of the format that is not its own row's number would
-- be the number of another row.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('nlb_case', 'Case', 'Cases', 1, 'public:read', 'admin');
INSERT INTO nlb_case (label) VALUES ('C-1'), ('C-999999');
SELECT throws_ok(
    $$UPDATE entities SET label_format = 'number', label_number_prefix = 'C-' WHERE table_name = 'nlb_case'$$,
    '90287', NULL,
    'numeric key: switching is refused while a label of the format is not its row''s own number');

UPDATE nlb_case SET label = 'Case 999999' WHERE label = 'C-999999';
SELECT lives_ok(
    $$UPDATE entities SET label_format = 'number', label_number_prefix = 'C-' WHERE table_name = 'nlb_case'$$,
    'numeric key: once every label of the format is its row''s own number, the switch passes');

SELECT throws_ok(
    $$UPDATE entities SET computed_fields = '[{"name": "label", "jsonlogic": {"cat": ["X", {"var": "id"}]}}]'::jsonb
       WHERE table_name = 'nlb_case'$$,
    '90288', NULL,
    'a computed rule that writes the label is refused while the format is number');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, computed_fields)
VALUES ('nlb_note', 'Note', 'Notes', 1, 'public:read', 'admin', '[{"name": "label", "jsonlogic": {"cat": ["N", {"var": "id"}]}}]');
SELECT throws_ok(
    $$UPDATE entities SET label_format = 'number' WHERE table_name = 'nlb_note'$$,
    '90288', NULL,
    'and the format cannot become number while such a rule is there');

-- ensure_entities writes the label settings together with the rules, so one
-- definition drops the rule that wrote the label and numbers it instead. It is
-- run by the installing role, inside a migration.
RESET ROLE;
SELECT lives_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "nlb_note",
        "computed_fields": [], "label_format": "number", "label_number_prefix": "NT-", "fields": []}}]}')$$,
    'ensure_entities: one definition switches a computed label to a numbered one');
SELECT authenticate_as('user3');
INSERT INTO nlb_note (label) VALUES ('');
SELECT is((SELECT label = 'NT-' || id FROM nlb_note), TRUE,
    'ensure_entities: after the switch the database numbers the label');

-- =====================================================
-- PART 5: an is_a family
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      id_type, id_prefix, label_format, label_number_prefix, label_number_digits)
VALUES ('nlb_work', 'Work', 'Works', 1, 'public:read', 'admin', 'typeid', 'nlbwork', 'number', 'WRK', 3);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      label_number_prefix, label_number_digits)
VALUES ('nlb_change', 'Change', 'Changes', 1, 'is_a', 'nlbchg', 'nlb_work', 'CHG', 4);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('nlb_chore', 'Chore', 'Chores', 1, 'is_a', 'nlbchore', 'nlb_work');

INSERT INTO nlb_work (label) VALUES ('w');
INSERT INTO nlb_change (label) VALUES ('c');
INSERT INTO nlb_change (label) VALUES ('c');
INSERT INTO nlb_chore (label) VALUES ('h');
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM nlb_work), 'CHG0001, CHG0002, WRK001, WRK002',
    'is_a: a subtype with a prefix of its own counts on its own; one without shares the root''s counter');

SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_change_label_seq')
          AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_chore_label_seq'),
    'is_a: the counter of a subtype is <subtype>_label_seq, and only a subtype with settings has one');

SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.nlb_work'::regclass AND tgname = 'b_label_number')
          AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'b_label_number'
                           AND tgrelid IN ('public.nlb_change_ext'::regclass, 'public.nlb_chore_ext'::regclass)),
    'is_a: the label step sits on the root table, which holds the label');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity, label_format)
      VALUES ('nlb_bad', 'Bad', 'Bads', 1, 'is_a', 'nlbbad', 'nlb_work', 'number')$$,
    '90289', NULL,
    'is_a: label_format is set on the root for the whole family');

-- The counters of a family share the unique index of the label: a prefix may
-- be neither another counter's nor another counter's followed by digits.
SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity, label_number_prefix)
      VALUES ('nlb_fix', 'Fix', 'Fixes', 1, 'is_a', 'nlbfix', 'nlb_work', 'CHG')$$,
    '90290', 'The label prefix ${prefix} of ${table} and ${other_prefix} of ${other} would number labels of the same shape',
    'is_a: a subtype''s prefix equal to another counter''s is refused');
SELECT throws_ok(
    $$UPDATE entities SET label_number_prefix = 'WRK2' WHERE table_name = 'nlb_chore'$$,
    '90290', NULL,
    'is_a: so is a prefix that is another counter''s followed by digits');

-- =====================================================
-- PART 6: the unique index, the rename and the drop
-- =====================================================
SELECT ok(
    (SELECT pg_get_expr(i.indpred, i.indrelid) FROM pg_index i
      WHERE i.indexrelid = 'public.nlb_work_label_number_unique'::regclass) LIKE '%(CHG|WRK)%',
    'the family''s unique index covers the labels of every prefix it numbers with');

UPDATE fields SET unique_value = TRUE WHERE table_name = 'nlb_incident' AND field_name = 'label';
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incident_label_number_unique'),
    'a label field with unique_value needs no index of the format');
UPDATE fields SET unique_value = FALSE WHERE table_name = 'nlb_incident' AND field_name = 'label';
SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incident_label_number_unique'),
    'without unique_value the index of the format is back');

UPDATE entities SET table_name = 'nlb_incidents' WHERE table_name = 'nlb_incident';
SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incidents_label_seq')
          AND EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incidents_label_number_unique')
          AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relname IN ('nlb_incident_label_seq', 'nlb_incident_label_number_unique')),
    'a rename renames the counter and the index');
INSERT INTO nlb_incidents (label) VALUES ('after rename');
SELECT ok(EXISTS (SELECT 1 FROM nlb_incidents WHERE label = 'INC0050002'),
    'after a rename the counter goes on');

UPDATE entities SET label_number_prefix = 'IN-', label_number_digits = 2 WHERE table_name = 'nlb_incidents';
INSERT INTO nlb_incidents (label) VALUES ('new prefix');
SELECT ok(EXISTS (SELECT 1 FROM nlb_incidents WHERE label = 'IN-50003')
          AND EXISTS (SELECT 1 FROM nlb_incidents WHERE label = 'INC0050002'),
    'a changed prefix and digit count apply to new numbers only');

DELETE FROM nlb_incidents;
DELETE FROM entities WHERE table_name = 'nlb_incidents';
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_incidents_label_seq'),
    'dropping the entity drops its counter');

DELETE FROM nlb_change;
DELETE FROM entities WHERE table_name = 'nlb_change';
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'nlb_change_label_seq'),
    'dropping a subtype drops its counter');

SELECT * FROM finish();
ROLLBACK;
