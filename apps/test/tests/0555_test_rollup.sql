-- Rollup fields (0440_rollup.sql): a field whose value the database computes
-- over the records of a child entity.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. Types, the ctype marker and the generated objects
--   2. Values: every function, the filter subset, moves, deletes, bulk writes
--   3. Backfill, the guard, and the parent's updated_at and audit
--   4. Row security, parent rules, queues and hidden child rows
--   5. Refusals
--   6. Renames
--   7. Lifecycle: nested rollups, a tree, truncate, deletes, a module delete,
--      and ensure_entities ordering
--   8. A definition removed while the field stays
--   9. One statement: rollups over fields created earlier in it
--  10. rollup_rebuild_all: regenerating what a builder change leaves behind
--  11. The filter compiler's refusals and the branches no rollup reaches
--  12. Definition refusals, and the functions called with no rollup to act on
--  13. A restricted child, and the managed flag of an entity with rollups
--  14. The compiled filter and the interpreter, operator by operator
--  15. Values a filter meets when a child is written
BEGIN;

SELECT plan(366);

SELECT authenticate_as('user3');

-- =====================================================
-- PART 1: Types, the ctype marker and the generated objects
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('ru_parent', 'ru_parent', 'RU Parent', 'RU Parents', 'rollup parent',
        1, 'public:read', 'admin', 'id', 'label', TRUE),
       ('ru_child', 'ru_child', 'RU Child', 'RU Children', 'rollup child',
        1, 'public:read', 'nwind:manage', 'id', 'label', FALSE);

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_child', 'parent_id', 'Parent', 'parent', 10, 'ru_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, "precision")
VALUES ('ru_child', 'amount', 'Amount', 'number', 20, 3);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ru_child', 'qty', 'Qty', 'int32', 30),
       ('ru_child', 'flag', 'Flag', 'boolean', 50),
       ('ru_child', 'note', 'Note', 'text', 60),
       ('ru_child', 'ship_date', 'Ship date', 'date', 70),
       ('ru_child', 'shipped_at', 'Shipped at', 'date-time', 80),
       ('ru_child', 'payload', 'Payload', 'json', 90);
INSERT INTO fields (table_name, field_name, title, format, field_order, enum_values)
VALUES ('ru_child', 'status', 'Status', 'enum', 40, '["open", "closed"]');

-- Seven rollups in one statement: the column of a later row does not exist yet
-- when an earlier row's trigger rebuilds, and the builders must leave it out.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup) VALUES
    ('ru_parent', 'total',      'Total',      'number', 10, '{"link_field": "ru_child.parent_id", "function": "sum",   "value_field": "amount"}'),
    ('ru_parent', 'line_count', 'Lines',      'int64',  20, '{"link_field": "ru_child.parent_id", "function": "count"}'),
    ('ru_parent', 'max_qty',    'Max qty',    'int32',  30, '{"link_field": "ru_child.parent_id", "function": "max",   "value_field": "qty"}'),
    ('ru_parent', 'avg_amount', 'Avg amount', 'number', 40, '{"link_field": "ru_child.parent_id", "function": "avg",   "value_field": "amount"}'),
    ('ru_parent', 'last_ship',  'Last ship',  'date',   50, '{"link_field": "ru_child.parent_id", "function": "max",   "value_field": "ship_date"}'),
    ('ru_parent', 'first_note', 'First note', 'text',   60, '{"link_field": "ru_child.parent_id", "function": "min",   "value_field": "note"}'),
    ('ru_parent', 'open_total', 'Open total', 'number', 70, '{"link_field": "ru_child.parent_id", "function": "sum",   "value_field": "amount",
                                                              "filter": {"==": [{"var": "status"}, "open"]}}');

SELECT is(
    (SELECT jsonb_object_agg(attname, jsonb_build_array(format_type(atttypid, atttypmod), attnotnull))
       FROM pg_attribute
      WHERE attrelid = 'public.ru_parent'::regclass
        AND attname IN ('total', 'line_count', 'max_qty', 'avg_amount', 'last_ship', 'first_note')),
    '{"total": ["numeric(18,3)", true], "line_count": ["bigint", true], "max_qty": ["integer", true],
      "avg_amount": ["numeric(18,3)", true], "last_ship": ["date", false], "first_note": ["text", true]}'::jsonb,
    'a rollup column has its format''s type: numeric with the value field''s decimals, bigint for count, a nullable date for max over a date');

SELECT is(
    (SELECT "precision" FROM fields WHERE table_name = 'ru_parent' AND field_name = 'total'),
    3::smallint,
    'precision is copied from the value field');

SELECT is(
    (SELECT string_agg(field_name, ',' ORDER BY field_order) FROM fields WHERE table_name = 'ru_parent' AND ctype = 'rollup'),
    'total,line_count,max_qty,avg_amount,last_ship,first_note,open_total',
    'every rollup field carries ctype = rollup although none was sent');

-- ctype is the signal a client reads; input_type stays the author's.
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'ru_parent' AND field_name = 'total'),
    'default',
    'input_type default is kept: a client renders a rollup disabled from its ctype');
UPDATE fields SET input_type = 'readonly' WHERE table_name = 'ru_parent' AND field_name = 'total';
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'ru_parent' AND field_name = 'total'),
    'readonly',
    'and so is readonly');

SELECT is(
    (SELECT jsonb_build_array(p ->> 'ctype', p ->> 'is_core', p ->> 'format', p -> 'rollup' ->> 'function', p ->> 'precision')
       FROM (SELECT public.get_schema('ru_parent')::jsonb -> 'properties' -> 'total' AS p) s),
    '["rollup", "false", "number", "sum", "3"]'::jsonb,
    'get_schema shows ctype rollup, is_core false, the ordinary format, the definition and the copied precision');

SELECT throws_ok(
    $$UPDATE fields SET ctype = 'rollup' WHERE table_name = 'ru_child' AND field_name = 'note'$$,
    '90214', NULL,
    'the marker cannot be set by hand (fields_ctype_lock)');

SELECT throws_ok(
    $$UPDATE fields SET ctype = '' WHERE table_name = 'ru_parent' AND field_name = 'total'$$,
    '90214', NULL,
    'the marker cannot be cleared by hand');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_ru_child_parent_id' AND p.prosecdef),
    'the maintenance function common.rollup_ru_child_parent_id exists and is SECURITY DEFINER');

SELECT is(
    (SELECT array_agg(tgname::text ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.ru_child'::regclass AND tgname LIKE 'rollup\_ru\_child\_parent\_id\_%'),
    ARRAY['rollup_ru_child_parent_id_del', 'rollup_ru_child_parent_id_ins', 'rollup_ru_child_parent_id_trc', 'rollup_ru_child_parent_id_upd'],
    'four statement-level triggers on the child: insert, update, delete, truncate');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_guard_ru_parent' AND p.prosecdef)
    AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.ru_parent'::regclass AND tgname = 'a_rollup_guard'),
    'the guard common.rollup_guard_ru_parent and its a_rollup_guard trigger exist on the parent');

SELECT ok(
    pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgrelid = 'public.ru_parent'::regclass AND tgname = 'update_ru_parent_updated_at'))
        LIKE '%update_updated_at_column(''avg_amount'', ''first_note'', ''last_ship'', ''line_count'', ''max_qty'', ''open_total'', ''total'')',
    'the parent''s updated_at trigger ignores the rollup columns');

SELECT ok(
    pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgrelid = 'public.ru_parent'::regclass AND tgname = 'audit_i_u_d'))
        LIKE '%insert_update_delete_trigger(''avg_amount'', ''first_note'', ''last_ship'', ''line_count'', ''max_qty'', ''open_total'', ''total'')',
    'the parent''s audit UPDATE trigger ignores the rollup columns');

-- =====================================================
-- PART 2: Values
-- =====================================================
INSERT INTO ru_parent (label) VALUES ('P1'), ('P2');

INSERT INTO ru_child (label, parent_id, amount, qty, status, note, ship_date, flag)
VALUES ('c1', (SELECT id FROM ru_parent WHERE label = 'P1'), 10.500, 2, 'open',   'beta',  '2026-01-10', TRUE),
       ('c2', (SELECT id FROM ru_parent WHERE label = 'P1'),  4.250, 7, 'closed', 'alpha', '2026-02-20', FALSE),
       ('c3', (SELECT id FROM ru_parent WHERE label = 'P2'),  1.000, 1, 'open',   'gamma', NULL,         FALSE);

CREATE FUNCTION pg_temp.ru(p_label TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_array(total, line_count, max_qty, avg_amount, last_ship, first_note, open_total)
      FROM ru_parent WHERE label = p_label
$$;

SELECT is(pg_temp.ru('P1'), '[14.750, 2, 7, 7.375, "2026-02-20", "alpha", 10.500]'::jsonb,
    'sum, count, max, avg, max over a date, min over text and a filtered sum after a 3-row insert');
SELECT is(pg_temp.ru('P2'), '[1.000, 1, 1, 1.000, null, "gamma", 1.000]'::jsonb,
    'a parent whose only line has no ship date: the date rollup is NULL');

UPDATE ru_child SET amount = 20.000 WHERE label = 'c1';
SELECT is(pg_temp.ru('P1') -> 0, '24.250'::jsonb, 'a child update moves the total');

UPDATE ru_child SET parent_id = (SELECT id FROM ru_parent WHERE label = 'P1') WHERE label = 'c3';
SELECT is(pg_temp.ru('P1') -> 1, '3'::jsonb, 'a child moved to another parent counts there');
SELECT is(pg_temp.ru('P2'), '[0.000, 0, 0, 0.000, null, "", 0.000]'::jsonb,
    'and no longer counts here: the empty aggregates are 0, NULL for the date and the empty string for text');

DELETE FROM ru_child WHERE label = 'c2';
SELECT is(pg_temp.ru('P1'), '[21.000, 2, 2, 10.500, "2026-01-10", "beta", 21.000]'::jsonb,
    'a child delete recomputes every rollup of its parent');

INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
SELECT 'bulk' || i, (SELECT id FROM ru_parent WHERE label = 'P2'), 1.5, i, 'closed', 'n' || i FROM generate_series(1, 100) i;
SELECT is(pg_temp.ru('P2'), '[150.000, 100, 100, 1.500, null, "n1", 0.000]'::jsonb,
    'a 100-row insert in one statement recomputes the parent once and right');

UPDATE ru_child SET status = 'open' WHERE label = 'bulk7';
SELECT is(pg_temp.ru('P2') -> 6, '1.500'::jsonb, 'the filter follows the child: a status change moves the filtered sum');

-- The filter subset: and, in, != against a NULL column, a three-operand <, !
-- over ==, a bare boolean column.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'picky', 'Picky', 'int64', 80,
        '{"link_field": "ru_child.parent_id", "function": "count",
          "filter": {"and": [{"var": "flag"},
                              {"in": [{"var": "status"}, ["open", "closed"]]},
                              {"!=": [{"var": "ship_date"}, null]},
                              {"<": [1, {"var": "qty"}, 100]},
                              {"!": {"==": [{"var": "note"}, "zzz"]}}]}}');
SELECT is((SELECT picky FROM ru_parent WHERE label = 'P1'), 1::bigint,
    'and, in, != null, a three-operand < and ! compile and count the one child that satisfies them all');

UPDATE ru_child SET ship_date = NULL WHERE label = 'c1';
SELECT is((SELECT picky FROM ru_parent WHERE label = 'P1'), 0::bigint,
    '!= null is null-safe: a child whose date became NULL drops out');

-- Date operators as filter values, through a real rollup first.
SELECT authenticate_as('user3');

INSERT INTO ru_parent (label) VALUES ('PD');
INSERT INTO ru_child (label, parent_id, amount, qty, status, note, ship_date)
SELECT v.l, (SELECT id FROM ru_parent WHERE label = 'PD'), 1, 1, 'open', v.l, v.d::date
  FROM (VALUES ('d1', '2026-12-31'), ('d2', '2026-01-31')) AS v(l, d);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'q4_lines', 'Q4 lines', 'int64', 85,
        '{"link_field": "ru_child.parent_id", "function": "count",
          "filter": {"==": [{"date_part": [{"var": "ship_date"}, "quarter"]}, 4]}}');
SELECT is((SELECT q4_lines FROM ru_parent WHERE label = 'PD'), 1::bigint,
    'date operators: a filter on date_part counts the matching children when the rollup is added');
UPDATE ru_child SET ship_date = '2026-10-01' WHERE label = 'd2';
SELECT is((SELECT q4_lines FROM ru_parent WHERE label = 'PD'), 2::bigint,
    'date operators: and follows a child write');

INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'odd_lines', 'Odd lines', 'int64', 86,
        '{"link_field": "ru_child.parent_id", "function": "count",
          "filter": {"==": [{"date_format": [{"var": "ship_date"}, "YYYY"]}, "$$; DROP TABLE ru_parent; --"]}}');
UPDATE ru_child SET note = 'still writable' WHERE label = 'd1';
SELECT is((SELECT odd_lines FROM ru_parent WHERE label = 'PD'), 0::bigint,
    'a hostile literal in a saved date filter is only a literal: the generated trigger still runs');

DELETE FROM fields WHERE table_name = 'ru_parent' AND field_name = 'odd_lines';
DELETE FROM fields WHERE table_name = 'ru_parent' AND field_name = 'q4_lines';
DELETE FROM ru_child WHERE label IN ('d1', 'd2');
DELETE FROM ru_parent WHERE label = 'PD';

-- The compiled filter and the interpreter over the same rows. Each answer is the
-- pair of counts, so an agreement on nothing cannot pass.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TABLE public.ru_date_rows (
    id   SERIAL PRIMARY KEY,
    d    DATE,
    ts   TIMESTAMPTZ,
    n    INTEGER NOT NULL DEFAULT 0,
    g    INTERVAL NOT NULL DEFAULT 'PT0S',
    note TEXT NOT NULL DEFAULT ''
);
INSERT INTO public.ru_date_rows (d, ts, n, g) VALUES
    ('2026-01-31', '2026-01-31T23:30:00Z',  1, 'P1D'),
    ('2026-02-28', '2026-02-28T00:00:00Z',  2, 'PT1H'),
    ('2026-12-31', '2026-12-31T12:00:00Z', -1, 'P1M'),
    (NULL,         NULL,                    0, 'PT0S');

CREATE FUNCTION pg_temp.ru_compiled(p_rule JSONB, p_rel TEXT DEFAULT 'ru_date_rows') RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    EXECUTE format('SELECT count(*)::int FROM public.%I c WHERE %s', p_rel, rollup_filter_sql(p_rule, p_rel, 'c')) INTO v_count;
    RETURN v_count;
END;
$$;

-- {compiled, interpreted}. A side that raises answers -1, so its comparison fails
-- by itself and the statements after it still run.
CREATE FUNCTION pg_temp.ru_both(p_rule JSONB, p_rel TEXT DEFAULT 'ru_date_rows') RETURNS INTEGER[] LANGUAGE plpgsql AS $$
DECLARE
    v_compiled    INTEGER;
    v_interpreted INTEGER;
BEGIN
    BEGIN
        v_compiled := pg_temp.ru_compiled(p_rule, p_rel);
    EXCEPTION WHEN OTHERS THEN
        v_compiled := -1;
    END;
    BEGIN
        EXECUTE format('SELECT count(*)::int FROM public.%I r WHERE jl_truthy(evaluate_json_logic($1, to_jsonb(r)))', p_rel)
           INTO v_interpreted USING p_rule;
    EXCEPTION WHEN OTHERS THEN
        v_interpreted := -1;
    END;
    RETURN ARRAY[v_compiled, v_interpreted];
END;
$$;

SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"var": "d"}, "quarter"]}, 4]}'), ARRAY[1, 1], 'equivalence: date_part');
SELECT is(pg_temp.ru_both('{"in": [{"date_part": [{"var": "d"}, "month"]}, [1, 2]]}'), ARRAY[2, 2], 'equivalence: date_part in a list');
SELECT is(pg_temp.ru_both('{"==": [{"date_add": [{"var": "d"}, 1, "month"]}, "2026-02-28"]}'), ARRAY[1, 1], 'equivalence: date_add clamps a month end');
SELECT is(pg_temp.ru_both('{"==": [{"date_add": [{"var": "d"}, {"var": "n"}, "day"]}, "2026-02-01"]}'), ARRAY[1, 1], 'equivalence: date_add with an amount column');
SELECT is(pg_temp.ru_both('{">": [{"date_diff": ["2026-12-31", {"var": "d"}, "day"]}, 300]}'), ARRAY[2, 2], 'equivalence: date_diff from a literal');
SELECT is(pg_temp.ru_both('{"==": [{"date_trunc": [{"var": "d"}, "quarter"]}, "2026-01-01"]}'), ARRAY[2, 2], 'equivalence: date_trunc');
SELECT is(pg_temp.ru_both('{"==": [{"to_date": [{"var": "ts"}]}, "2026-02-28"]}'), ARRAY[1, 1], 'equivalence: to_date');
SELECT is(pg_temp.ru_both('{"==": [{"date_format": [{"var": "d"}, "Mon YYYY"]}, "Dec 2026"]}'), ARRAY[1, 1], 'equivalence: date_format');
SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"var": "ts"}, "hour"]}, 23]}'), ARRAY[1, 1], 'equivalence: a part of a date-time');
SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"date_add": [{"var": "d"}, 1, "month"]}, "month"]}, 3]}'), ARRAY[1, 1], 'equivalence: nested date operators');
SELECT is(pg_temp.ru_both('{"==": [{"date_add": [{"var": "ts"}, {"var": "g"}]}, "2026-02-01T23:30:00+00:00"]}'), ARRAY[1, 1], 'equivalence: date_add with a duration column');
SELECT is(pg_temp.ru_both('{"==": [{"date_add": [{"var": "d"}, "P1M"]}, "2026-02-28"]}'), ARRAY[1, 1], 'equivalence: date_add with a literal duration');
SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"var": "d"}, "year"]}, null]}'), ARRAY[1, 1], 'equivalence: a null date gives null');

SET LOCAL timezone = 'Pacific/Kiritimati';
SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"var": "ts"}, "hour"]}, 23]}'), ARRAY[1, 1], 'equivalence at UTC+14: a part of a date-time is UTC');
SELECT is(pg_temp.ru_both('{"==": [{"to_date": [{"var": "ts"}]}, "2026-02-28"]}'), ARRAY[1, 1], 'equivalence at UTC+14: to_date is UTC');
SELECT is(pg_temp.ru_compiled('{"==": [{"var": "ts"}, "2026-02-28T00:00:00"]}'), 1,
    'a date-time literal with no offset is UTC, not the session''s zone');
SELECT is(pg_temp.ru_compiled('{"==": [{"var": "ts"}, "2026-02-28"]}'), 1,
    'a date-only literal against a date-time column is midnight UTC');

SET LOCAL timezone = 'Pacific/Pago_Pago';
SELECT is(pg_temp.ru_both('{"==": [{"date_part": [{"var": "ts"}, "hour"]}, 23]}'), ARRAY[1, 1], 'equivalence at UTC-11: a part of a date-time is UTC');
SELECT is(pg_temp.ru_both('{"==": [{"to_date": [{"var": "ts"}]}, "2026-02-28"]}'), ARRAY[1, 1], 'equivalence at UTC-11: to_date is UTC');
SELECT is(pg_temp.ru_compiled('{"==": [{"var": "ts"}, "2026-02-28T00:00:00"]}'), 1,
    'at UTC-11 a date-time literal with no offset is still UTC');
SELECT is(pg_temp.ru_compiled('{"==": [{"var": "ts"}, "2026-02-28"]}'), 1,
    'at UTC-11 a date-only literal against a date-time column is still midnight UTC');
SET LOCAL timezone = 'UTC';

SET LOCAL intervalstyle = 'postgres';
SELECT is(pg_temp.ru_compiled('{"==": [{"date_add": [{"var": "ts"}, {"var": "g"}]}, "2026-02-01T23:30:00+00:00"]}'), 1,
    'a duration column works whatever the session''s interval style');
SET LOCAL intervalstyle = 'iso_8601';

SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_trunc": [{"var": "d"}, "fortnight"]}, "2026-01-01"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: an unknown unit is refused when saved');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"var": "d"}, "hour"]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a sub-day part on a date column is refused when saved');
SELECT is(catch_error_hint($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"var": "d"}, "hour"]}, 1]}', 'ru_date_rows', 'c')$$) ->> 'problem',
    'date_part cannot take the arguments [{"var": "d"}, "hour"]', 'date operators: the hint names the operator and its arguments');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"var": "d"}, {"var": "note"}]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a unit that is not a literal is refused');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_diff": [{"var": "$today"}, {"var": "d"}, "day"]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: $today stays refused, or the rollup would go stale');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"var": "note"}, "year"]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a text column is not a date, or a bad value would fail a child write');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_format": [{"var": "d"}, "TMMon"]}, "x"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a pattern outside the token list is refused');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_add": [{"var": "d"}, {"-": [0, {"var": "n"}]}, "day"]}, "2026-01-01"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: arithmetic stays out, even as an argument');
SELECT throws_ok($$SELECT rollup_filter_sql('{"date_part": [{"var": "d"}, "year"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a date operator alone is not a condition');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"var": "d"}]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: the wrong number of arguments is refused');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_add": [{"var": "d"}, {"var": "g"}]}, "2026-01-01"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'date operators: a duration column on a date column is refused, as it could fail on a later child write');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"var": "g"}, "P1D"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'a duration column still cannot be compared');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"var": "d"}, "today"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'a date column refuses a literal that would change meaning with the day');

-- The interpreter answers null for a blank date or amount before it looks at the
-- other arguments, so a blank must not be able to carry unchecked ones past the save.
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": ["", "anything"]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'a blank date is refused, with an unknown part after it');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_add": [{"var": "d"}, "", "anything"]}, "2026-01-01"]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'a blank amount is refused, with an unknown unit after it');
SELECT throws_ok($$SELECT rollup_filter_sql('{"==": [{"date_part": [{"date_trunc": ["", "x"]}, "year"]}, 1]}', 'ru_date_rows', 'c')$$,
    '90265', NULL, 'a blank date inside a nested date operator is refused');

-- Hostile text in every argument position. The test is that each value is refused
-- with 90265: an answer other than a refusal lists the value, and any other error
-- fails the test by itself.
CREATE FUNCTION pg_temp.ru_hostile() RETURNS TEXT[] LANGUAGE sql AS $f$
    SELECT ARRAY[
        'x''; DROP TABLE public.ru_date_rows; --',
        '$$; DROP TABLE public.ru_date_rows; $$',
        '%s %L %I',
        'back\slash''',
        '"); DROP TABLE public.ru_date_rows; --'
    ]
$f$;

CREATE FUNCTION pg_temp.ru_not_refused(p_template TEXT) RETURNS TEXT[] LANGUAGE plpgsql AS $f$
DECLARE
    v_value TEXT;
    v_out   TEXT[] := ARRAY[]::TEXT[];
BEGIN
    FOREACH v_value IN ARRAY pg_temp.ru_hostile() LOOP
        BEGIN
            PERFORM rollup_filter_sql(replace(p_template, '"@"', to_jsonb(v_value)::text)::jsonb, 'ru_date_rows', 'c');
            v_out := v_out || v_value;
        EXCEPTION WHEN SQLSTATE '90265' THEN
            NULL;
        END;
    END LOOP;
    RETURN v_out;
END;
$f$;

SELECT is(pg_temp.ru_not_refused('{"==": [{"date_part": ["@", "year"]}, 1]}'), ARRAY[]::TEXT[], 'hostile text as a date literal is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_trunc": [{"var": "d"}, "@"]}, "2026-01-01"]}'), ARRAY[]::TEXT[], 'hostile text as a unit is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_part": [{"var": "d"}, "@"]}, 1]}'), ARRAY[]::TEXT[], 'hostile text as a part is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_format": [{"var": "d"}, "@"]}, "x"]}'), ARRAY[]::TEXT[], 'hostile text as a pattern is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_add": [{"var": "d"}, "@", "day"]}, "2026-01-01"]}'), ARRAY[]::TEXT[], 'hostile text as an amount is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_add": [{"var": "ts"}, "@"]}, "2026-01-01"]}'), ARRAY[]::TEXT[], 'hostile text as a duration is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"date_part": [{"var": "@"}, "year"]}, 1]}'), ARRAY[]::TEXT[], 'hostile text as a column name is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"var": "d"}, "@"]}'), ARRAY[]::TEXT[], 'hostile text compared with a date column is refused');
SELECT is(pg_temp.ru_not_refused('{"==": [{"var": "ts"}, "@"]}'), ARRAY[]::TEXT[], 'hostile text compared with a date-time column is refused');

-- Compared with the text date_format produces, any text is a valid literal, so
-- this one is compiled and has to be inert.
SELECT is((SELECT sum(pg_temp.ru_compiled(('{"==": [{"date_format": [{"var": "d"}, "YYYY"]}, ' || to_jsonb(v)::text || ']}')::jsonb))::int
             FROM unnest(pg_temp.ru_hostile()) AS v), 0,
    'hostile text compared with a formatted date runs as a literal and matches nothing');
SELECT is((SELECT count(*)::int FROM public.ru_date_rows), 4, 'and the table and its rows are still there');

SELECT authenticate_as('user3');

-- =====================================================
-- PART 3: Backfill, the guard, and the parent's updated_at and audit
-- =====================================================
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'qty_sum', 'Qty sum', 'int32', 90,
        '{"link_field": "ru_child.parent_id", "function": "sum", "value_field": "qty"}');
SELECT is((SELECT qty_sum FROM ru_parent WHERE label = 'P2'), 5050,
    'a rollup added after the data exists is right at once (backfill)');

UPDATE fields SET rollup = jsonb_set(rollup, '{function}', '"max"') WHERE table_name = 'ru_parent' AND field_name = 'qty_sum';
SELECT is((SELECT qty_sum FROM ru_parent WHERE label = 'P2'), 100,
    'a changed function recomputes the column');

UPDATE fields SET rollup = jsonb_set(rollup, '{filter}', '{"<": [{"var": "qty"}, 50]}')
 WHERE table_name = 'ru_parent' AND field_name = 'qty_sum';
SELECT is((SELECT qty_sum FROM ru_parent WHERE label = 'P2'), 49,
    'a changed filter recomputes the column');

CREATE TEMP TABLE ru_ctid ON COMMIT DROP AS SELECT label, ctid AS before FROM ru_parent;
UPDATE fields SET rollup = rollup || '{"include_hidden_rows": false}' WHERE table_name = 'ru_parent' AND field_name = 'qty_sum';
SELECT is(
    (SELECT count(*)::int FROM ru_parent p JOIN ru_ctid c ON c.label = p.label WHERE p.ctid <> c.before),
    0,
    'a definition change that moves no value writes no parent row');

UPDATE ru_parent SET total = 999 WHERE label = 'P1';
SELECT is(pg_temp.ru('P1') -> 0, '21.000'::jsonb, 'a hand-written rollup value is replaced by the computed one (guard)');

INSERT INTO ru_parent (label, total, last_ship) VALUES ('P3', 5, '2026-01-01');
SELECT is(pg_temp.ru('P3'), '[0.000, 0, 0, 0.000, null, "", 0.000]'::jsonb,
    'a new parent starts with the empty aggregates whatever the insert said');

-- updated_at and audit. Every write of this transaction carries the same
-- CURRENT_TIMESTAMP, so the parent is first given an old updated_at as the
-- owner, with its trigger off for that one statement.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE ru_parent DISABLE TRIGGER update_ru_parent_updated_at;
UPDATE ru_parent SET updated_at = '2020-01-01 00:00:00+00' WHERE label = 'P1';
ALTER TABLE ru_parent ENABLE TRIGGER update_ru_parent_updated_at;
SELECT authenticate_as('user3');

CREATE TEMP TABLE ru_audit ON COMMIT DROP AS
    SELECT count(*) AS n FROM audit_record_logs WHERE table_name = 'ru_parent';

INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
VALUES ('c4', (SELECT id FROM ru_parent WHERE label = 'P1'), 3.000, 3, 'open', 'delta');

SELECT is((SELECT updated_at FROM ru_parent WHERE label = 'P1'), '2020-01-01 00:00:00+00'::timestamptz,
    'a child write that moves a total leaves the parent''s updated_at alone');
SELECT is((SELECT count(*) FROM audit_record_logs WHERE table_name = 'ru_parent'), (SELECT n FROM ru_audit),
    'and writes no audit row for the parent');

UPDATE ru_parent SET label = 'P1 renamed' WHERE label = 'P1';
SELECT is((SELECT updated_at FROM ru_parent WHERE label = 'P1 renamed'), CURRENT_TIMESTAMP,
    'a real change of the parent still bumps updated_at');
SELECT is((SELECT count(*) FROM audit_record_logs WHERE table_name = 'ru_parent'), (SELECT n FROM ru_audit) + 1,
    'and is audited');
SELECT is(
    (SELECT record ->> 'total' FROM audit_record_logs WHERE table_name = 'ru_parent' ORDER BY id DESC LIMIT 1),
    '24.000',
    'the audit row carries the rollup column; only the gate ignores it');
UPDATE ru_parent SET label = 'P1' WHERE label = 'P1 renamed';

-- =====================================================
-- PART 4: Row security, parent rules, queues and hidden child rows
-- =====================================================
SELECT authenticate_as('user2');
INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
VALUES ('c5', (SELECT id FROM ru_parent WHERE label = 'P1'), 1.000, 1, 'open', 'epsilon');
UPDATE ru_parent SET label = 'nope' WHERE label = 'P1';
SELECT is((SELECT count(*)::int FROM ru_parent WHERE label = 'nope'), 0,
    'user2 cannot write the parent: row security lets the update reach no row');
SELECT is(pg_temp.ru('P1') -> 0, '25.000'::jsonb,
    'but a child write by user2 still updates it: the maintenance runs as the owner');

SELECT authenticate_as('user3');
UPDATE entities
   SET validation_rules = '[{"code": "99001", "message": "total exceeds the limit", "jsonlogic": {"<=": [{"var": "total"}, 100]}}]'::jsonb
 WHERE table_name = 'ru_parent';
SELECT throws_ok(
    $$INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
      VALUES ('too much', (SELECT id FROM ru_parent WHERE label = 'P1'), 1000, 1, 'open', 'x')$$,
    '99001', NULL,
    'the parent''s validation rules run on the maintenance UPDATE: a rule over the total refuses the child write');
UPDATE entities SET validation_rules = '[]'::jsonb WHERE table_name = 'ru_parent';

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO queues (queue_name) VALUES ('ru_q');
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'ru parent update', 'ru_parent', 'update' FROM queues WHERE queue_name = 'ru_q';
INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
VALUES ('c6', (SELECT id FROM ru_parent WHERE label = 'P1'), 1.000, 1, 'open', 'zeta');
SELECT is((SELECT count(*)::int FROM pgmq.read('ru_q', 0, 100) WHERE message ->> 'table' = 'ru_parent'), 1,
    'a child write that moves a total enqueues one UPDATE message for the parent');
UPDATE ru_child SET payload = '{"k": 1}' WHERE label = 'c6';
SELECT is((SELECT count(*)::int FROM pgmq.read('ru_q', 0, 100) WHERE message ->> 'table' = 'ru_parent'), 1,
    'a child write that moves no aggregate does not touch the parent');
SELECT authenticate_as('user3');

-- Hidden rows: a child only administrators may read.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, select_rule)
VALUES ('ru_secret', 'ru_secret', 'RU Secret', 'RU Secrets', 'restricted child',
        1, 'public:read', 'admin', 'id', 'label', '{"has_permission": "admin"}');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_secret', 'parent_id', 'Parent', 'parent', 10, 'ru_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('ru_secret', 'amount', 'Amount', 'number', 20);
INSERT INTO ru_secret (label, parent_id, amount) VALUES ('s1', (SELECT id FROM ru_parent WHERE label = 'P1'), 7.00);

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
      VALUES ('ru_parent', 'secret_total', 'Secret total', 'number', 100,
              '{"link_field": "ru_secret.parent_id", "function": "sum", "value_field": "amount"}')$$,
    '90269', NULL,
    'a rollup over a child with a select_rule needs include_hidden_rows');

INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'secret_total', 'Secret total', 'number', 100,
        '{"link_field": "ru_secret.parent_id", "function": "sum", "value_field": "amount", "include_hidden_rows": true}');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM ru_secret), 0, 'user2 sees no secret row');
SELECT is((SELECT secret_total FROM ru_parent WHERE label = 'P1'), 7.00,
    'yet sees their sum on the parent: what include_hidden_rows accepts');
SELECT authenticate_as('user3');

SELECT throws_ok(
    $$UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'ru_child'$$,
    '90269', NULL,
    'making an existing child more restricted than its parent is refused while unflagged rollups aggregate over it');

-- =====================================================
-- PART 5: Refusals
-- =====================================================
CREATE FUNCTION pg_temp.ru_def(p_def TEXT, p_format TEXT DEFAULT 'number') RETURNS TEXT LANGUAGE sql AS $$
    SELECT format($q$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
                     VALUES ('ru_parent', 'probe', 'Probe', %L, 999, %L)$q$, p_format, p_def)
$$;

-- One derivation per field, in both directions.
SELECT throws_ok(
    $$UPDATE entities SET computed_fields = '[{"name": "total", "jsonlogic": {"var": "total"}}]' WHERE table_name = 'ru_parent'$$,
    '90907', NULL, '90907: a computed rule cannot name a rollup field');
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('ru_parent', 'calc', 'Calc', 'int64', 150);
UPDATE entities SET computed_fields = '[{"name": "calc", "jsonlogic": {"var": "line_count"}}]' WHERE table_name = 'ru_parent';
SELECT throws_ok(
    $$UPDATE fields SET rollup = '{"link_field": "ru_child.parent_id", "function": "count"}' WHERE table_name = 'ru_parent' AND field_name = 'calc'$$,
    '90261', NULL, '90261: a computed field cannot become a rollup');
UPDATE entities SET computed_fields = '[]'::jsonb WHERE table_name = 'ru_parent';

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "bogus": 1}', 'int64'),
    '90261', NULL, '90261: an unknown key');
SELECT is(catch_error_hint(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "bogus": 1}', 'int64')) ->> 'problem',
    'unknown key bogus', 'the hint names the key');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, rollup)
      VALUES ('ru_parent', 'probe', 'Probe', 'int64', 999, 'required', '{"link_field": "ru_child.parent_id", "function": "count"}')$$,
    '90261', NULL, '90261: a required rollup');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, searchable, rollup)
      VALUES ('ru_parent', 'probe', 'Probe', 'text', 999, TRUE, '{"link_field": "ru_child.parent_id", "function": "min", "value_field": "note"}')$$,
    '90261', NULL, '90261: a searchable rollup');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, unique_value, rollup)
      VALUES ('ru_parent', 'probe', 'Probe', 'int64', 999, TRUE, '{"link_field": "ru_child.parent_id", "function": "count"}')$$,
    '90261', NULL, '90261: a unique rollup');
SELECT throws_ok(
    $$UPDATE fields SET rollup = '{"link_field": "ru_child.parent_id", "function": "min", "value_field": "note"}'
       WHERE table_name = 'ru_parent' AND field_name = 'label'$$,
    '90261', NULL, '90261: a definition on the label column');

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.nope", "function": "count"}', 'int64'),
    '90262', NULL, '90262: a link field that does not exist');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.amount", "function": "count"}', 'int64'),
    '90262', NULL, '90262: a link field that is not a reference');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_secret.parent_id", "function": "count"}', 'int64'),
    '90269', NULL, 'a link to a restricted child is 90269, not 90262');
SELECT is(catch_error_hint(pg_temp.ru_def('{"link_field": "ru_child.nope", "function": "count"}', 'int64')) ->> 'link_field',
    'ru_child.nope', 'the hint names the link field');

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "median", "value_field": "amount"}'),
    '90263', NULL, '90263: an unknown function');

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "sum"}'),
    '90264', NULL, '90264: sum without a value field');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "sum", "value_field": "flag"}'),
    '90264', NULL, '90264: sum over a boolean');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "value_field": "amount"}', 'int64'),
    '90264', NULL, '90264: count with a value field');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "max", "value_field": "parent_id"}', 'int64'),
    '90264', NULL, '90264: max over a key');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "max", "value_field": "payload"}', 'json'),
    '90264', NULL, '90264: max over JSON');

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count"}', 'text'),
    '90268', NULL, '90268: count into a text field');
SELECT is(catch_error_hint(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count"}', 'text')) ->> 'expected_format',
    'int64', 'the hint names the expected format');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "max", "value_field": "shipped_at"}', 'date'),
    '90268', NULL, '90268: max over a date-time into a date field');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "avg", "value_field": "qty"}', 'int32'),
    '90268', NULL, '90268: avg into an integer field');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "min", "value_field": "amount"}', 'int64'),
    '90268', NULL, '90268: min over a number into an integer field');
SELECT lives_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "min", "value_field": "note"}', 'email'),
    'min over text into an email field passes: both are TEXT columns');
DELETE FROM fields WHERE table_name = 'ru_parent' AND field_name = 'probe';

SELECT throws_ok(
    $$UPDATE fields SET format = 'text' WHERE table_name = 'ru_parent' AND field_name = 'total'$$,
    '90223', NULL,
    'changing a rollup to another column type is the usual drop-and-recreate rule, not the core-field lock');

SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"if": [true, 1, 0]}}', 'int64'),
    '90265', NULL, '90265: an operator outside the subset');
SELECT is(catch_error_hint(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"if": [true, 1, 0]}}', 'int64')) ->> 'problem',
    'operator if is not supported in a rollup filter', 'the hint names the operator');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"has_permission": "admin"}}', 'int64'),
    '90265', NULL, '90265: a custom operator');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "qty"}, {"var": "$user_id"}]}}', 'int64'),
    '90265', NULL, '90265: a request variable');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "payload.k"}, 1]}}', 'int64'),
    '90265', NULL, '90265: a path');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "nope"}, 1]}}', 'int64'),
    '90265', NULL, '90265: a column that does not exist');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "payload"}, 1]}}', 'int64'),
    '90265', NULL, '90265: a JSON column');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "qty"}, "abc"]}}', 'int64'),
    '90265', NULL, '90265: a literal the column cannot be cast from (caught by the EXPLAIN probe)');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "qty"}, 1], "and": []}}', 'int64'),
    '90265', NULL, '90265: an operator object with two keys');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"in": [{"var": "status"}, []]}}', 'int64'),
    '90265', NULL, '90265: an empty in list');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"<": [{"var": "qty"}, null]}}', 'int64'),
    '90265', NULL, '90265: null in an ordering comparison');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"var": "note"}}', 'int64'),
    '90265', NULL, '90265: a bare column that is not boolean');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"date_part": [{"var": "ship_date"}, "hour"]}, 1]}}', 'int64'),
    '90265', NULL, '90265: a date operator the field cannot use, refused when the field is saved');
SELECT is(
    (SELECT (h ->> 'table') || '.' || (h ->> 'field_name') || ': ' || (h ->> 'problem')
       FROM catch_error_hint(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"date_part": [{"var": "ship_date"}, "hour"]}, 1]}}', 'int64')) AS h),
    'ru_parent.probe: date_part cannot take the arguments [{"var": "ship_date"}, "hour"]',
    'and the error names the table, the field and what was refused');

-- A TypeID key as a filter column: the literal is checked at compile time.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES ('ru_root', 'Root', 'Roots', 1, 'public:read', 'admin', 'typeid', 'ruroot');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_child', 'root_ref', 'Root', 'reference', 100, 'ru_root', 'clear');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "root_ref"}, "not-a-typeid"]}}', 'int64'),
    '90265', NULL, '90265: a malformed TypeID literal against a TypeID column');
SELECT lives_ok(pg_temp.ru_def('{"link_field": "ru_child.parent_id", "function": "count", "filter": {"==": [{"var": "root_ref"}, "ruroot_01h455vb4pex5vsknk084sn02q"]}}', 'int64'),
    'a well-formed TypeID literal compiles');
DELETE FROM fields WHERE table_name = 'ru_parent' AND field_name = 'probe';

-- An is_a child.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix, id_refentity)
VALUES ('ru_isa', 'Isa', 'Isas', 1, 'public:read', 'admin', 'is_a', 'ruisa', 'ru_root');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_isa', 'parent_ref', 'Parent', 'reference', 30, 'ru_parent', 'clear');
SELECT throws_ok(pg_temp.ru_def('{"link_field": "ru_isa.parent_ref", "function": "count"}', 'int64'),
    '90249', NULL, '90249: a rollup over an is_a child');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
      VALUES ('ru_parent', 'probe', 'Probe', 'number', 999, '"sum"')$$,
    '23514', NULL, 'rollup_is_object: the definition must be an object');

-- Dependencies.
SELECT throws_ok(
    $$DELETE FROM fields WHERE table_name = 'ru_child' AND field_name = 'parent_id'$$,
    '90266', NULL, '90266: the link field of a rollup cannot be deleted');
SELECT is(catch_error_hint($$DELETE FROM fields WHERE table_name = 'ru_child' AND field_name = 'qty'$$) ->> 'rollups',
    'ru_parent.max_qty, ru_parent.qty_sum', 'the hint lists the rollups that depend on a value field');
SELECT throws_ok(
    $$DELETE FROM entities WHERE table_name = 'ru_child'$$,
    '90266', NULL, '90266: the child entity cannot be deleted while rollups aggregate over it');
SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'ru_child' AND relkind = 'r'),
    'and its table is still there: the refusal came before any DDL');

-- A cycle: a tree whose rollup sums itself.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('ru_node', 'ru_node', 'RU Node', 'RU Nodes', 'tree', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_node', 'parent_ref', 'Parent', 'reference', 10, 'ru_node', 'clear');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
      VALUES ('ru_node', 'subtree', 'Subtree', 'int64', 20,
              '{"link_field": "ru_node.parent_ref", "function": "sum", "value_field": "subtree"}')$$,
    '90267', NULL, '90267: a rollup that sums itself');

-- Injection attempts are literals.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_parent', 'hostile', 'Hostile', 'int64', 110,
        '{"link_field": "ru_child.parent_id", "function": "count",
          "filter": {"or": [{"==": [{"var": "note"}, "''; DROP TABLE ru_parent; --"]},
                             {"in": [{"var": "note"}, ["50% off", "say \"hi\"", "$rb_x$ LANGUAGE plpgsql;"]]}]}}');
SELECT ok(EXISTS (SELECT 1 FROM pg_class WHERE relname = 'ru_parent' AND relkind = 'r'),
    'a filter literal that reads like SQL is a literal: the parent table survives');
INSERT INTO ru_child (label, parent_id, amount, qty, status, note)
VALUES ('c7', (SELECT id FROM ru_parent WHERE label = 'P1'), 0, 0, 'open', '50% off');
SELECT is((SELECT hostile FROM ru_parent WHERE label = 'P1'), 1::bigint,
    'and matches as text, percent sign and quotes included');

-- =====================================================
-- PART 6: Renames
-- =====================================================
UPDATE entities SET table_name = 'ru_lines' WHERE table_name = 'ru_child';
SELECT is(
    (SELECT string_agg(rollup ->> 'link_field', ',' ORDER BY field_order) FROM fields
      WHERE table_name = 'ru_parent' AND ctype = 'rollup' AND field_name IN ('total', 'secret_total')),
    'ru_lines.parent_id,ru_secret.parent_id',
    'a child table rename rewrites link_field in the rollups that name it');
SELECT is_empty(
    $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'common' AND p.proname LIKE '%ru\_child%'
      UNION ALL
      SELECT t.tgname::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
       WHERE c.relnamespace = 'public'::regnamespace AND t.tgname LIKE '%ru\_child%'$$,
    'no generated object keeps the old child name');
INSERT INTO ru_lines (label, parent_id, amount, qty, status, note)
VALUES ('c8', (SELECT id FROM ru_parent WHERE label = 'P1'), 10.000, 0, 'open', 'eta');
SELECT is(pg_temp.ru('P1') -> 0, '36.000'::jsonb, 'the rollup follows the renamed child');

UPDATE entities SET table_name = 'ru_orders' WHERE table_name = 'ru_parent';
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_guard_ru_orders')
    AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_guard_ru_parent'),
    'a parent table rename regenerates the guard under the new name');
UPDATE ru_lines SET amount = 11.000 WHERE label = 'c8';
SELECT is((SELECT total FROM ru_orders WHERE label = 'P1'), 37.000, 'the rollup follows the renamed parent');

UPDATE fields SET field_name = 'order_id' WHERE table_name = 'ru_lines' AND field_name = 'parent_id';
SELECT is((SELECT rollup ->> 'link_field' FROM fields WHERE table_name = 'ru_orders' AND field_name = 'total'),
    'ru_lines.order_id', 'a link field rename rewrites link_field');
SELECT ok(
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.ru_lines'::regclass AND tgname = 'rollup_ru_lines_order_id_ins'),
    'and the maintenance triggers carry the new link name');

UPDATE fields SET field_name = 'amt' WHERE table_name = 'ru_lines' AND field_name = 'amount';
SELECT is((SELECT rollup ->> 'value_field' FROM fields WHERE table_name = 'ru_orders' AND field_name = 'total'),
    'amt', 'a value field rename rewrites value_field');

UPDATE fields SET field_name = 'state' WHERE table_name = 'ru_lines' AND field_name = 'status';
SELECT is((SELECT rollup -> 'filter' FROM fields WHERE table_name = 'ru_orders' AND field_name = 'open_total'),
    '{"==": [{"var": "state"}, "open"]}'::jsonb, 'a filtered column rename rewrites the filter');

INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_orders', 'q4_lines', 'Q4 lines', 'int64', 900,
        '{"link_field": "ru_lines.order_id", "function": "count",
          "filter": {"==": [{"date_part": [{"var": "ship_date"}, "quarter"]}, 4]}}');
UPDATE fields SET field_name = 'sent_on' WHERE table_name = 'ru_lines' AND field_name = 'ship_date';
SELECT is((SELECT rollup -> 'filter' FROM fields WHERE table_name = 'ru_orders' AND field_name = 'q4_lines'),
    '{"==": [{"date_part": [{"var": "sent_on"}, "quarter"]}, 4]}'::jsonb,
    'a rename reaches a column named inside a date operator');
UPDATE ru_lines SET sent_on = '2026-11-01' WHERE label = 'c8';
SELECT is((SELECT q4_lines FROM ru_orders WHERE label = 'P1'), 1::bigint,
    'and the rebuilt filter reads the renamed column');
UPDATE ru_lines SET sent_on = NULL WHERE label = 'c8';
DELETE FROM fields WHERE table_name = 'ru_orders' AND field_name = 'q4_lines';
UPDATE fields SET field_name = 'ship_date' WHERE table_name = 'ru_lines' AND field_name = 'sent_on';

UPDATE fields SET field_name = 'grand_total' WHERE table_name = 'ru_orders' AND field_name = 'total';
UPDATE ru_lines SET amt = 12.000 WHERE label = 'c8';
SELECT is((SELECT grand_total FROM ru_orders WHERE label = 'P1'), 38.000,
    'a renamed rollup field (allowed although ctype is set) keeps working');

SELECT is_empty(
    $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'common'
         AND (p.proname LIKE '%ru\_parent%' OR p.proname LIKE '%ru\_child%' OR p.proname LIKE 'rollup\_ru\_lines\_parent\_id%')
      UNION ALL
      SELECT t.tgname::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
       WHERE c.relnamespace = 'public'::regnamespace
         AND (t.tgname LIKE '%ru\_parent%' OR t.tgname LIKE '%ru\_child%' OR t.tgname LIKE 'rollup\_ru\_lines\_parent\_id%')$$,
    'no generated object keeps an old name after the renames (ru_secret still links through its own parent_id)');

-- =====================================================
-- PART 7: Lifecycle
-- =====================================================
-- Nested: a grandparent sums the parents' totals.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('ru_grand', 'ru_grand', 'RU Grand', 'RU Grands', 'grandparent', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('ru_orders', 'grand_id', 'Grand', 'reference', 200, 'ru_grand', 'clear');
INSERT INTO ru_grand (label) VALUES ('G1');
UPDATE ru_orders SET grand_id = (SELECT id FROM ru_grand WHERE label = 'G1') WHERE label IN ('P1', 'P2');
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_grand', 'sum_totals', 'Sum of totals', 'number', 10,
        '{"link_field": "ru_orders.grand_id", "function": "sum", "value_field": "grand_total"}');
SELECT is((SELECT sum_totals FROM ru_grand WHERE label = 'G1'), 188.000,
    'a rollup over a rollup is backfilled from the parents'' totals');
UPDATE ru_lines SET amt = 13.000 WHERE label = 'c8';
SELECT is((SELECT sum_totals FROM ru_grand WHERE label = 'G1'), 189.000,
    'and a line write propagates two levels up');

-- A tree: each node counts its children.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('ru_node', 'child_count', 'Children', 'int64', 20, '{"link_field": "ru_node.parent_ref", "function": "count"}');
INSERT INTO ru_node (label) VALUES ('root');
INSERT INTO ru_node (label, parent_ref) VALUES ('kid', (SELECT id FROM ru_node WHERE label = 'root'));
INSERT INTO ru_node (label, parent_ref) VALUES ('grandkid', (SELECT id FROM ru_node WHERE label = 'kid'));
SELECT is((SELECT jsonb_object_agg(label, child_count) FROM ru_node), '{"root": 1, "kid": 1, "grandkid": 0}'::jsonb,
    'a self-referencing rollup counts a node''s children');

-- Truncate.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
TRUNCATE ru_lines;
SELECT is((SELECT jsonb_build_array(grand_total, line_count, last_ship, first_note) FROM ru_orders WHERE label = 'P1'),
    '[0.000, 0, null, ""]'::jsonb, 'TRUNCATE of the child resets every parent to the empty aggregates');
SELECT authenticate_as('user3');

-- A rollup another rollup aggregates over is a dependency like any value field.
SELECT throws_ok(
    $$DELETE FROM fields WHERE table_name = 'ru_orders' AND field_name = 'grand_total'$$,
    '90266', NULL, '90266: a rollup that another entity''s rollup sums cannot be deleted first');
DELETE FROM fields WHERE table_name = 'ru_grand' AND field_name = 'sum_totals';

-- Deleting the last rollup drops the generated objects and restores the plain triggers.
DELETE FROM fields WHERE table_name = 'ru_orders' AND ctype = 'rollup';
SELECT is_empty(
    $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'common' AND p.proname IN ('rollup_ru_lines_order_id', 'rollup_guard_ru_orders', 'rollup_ru_secret_parent_id')$$,
    'the maintenance functions and the guard are gone with the last rollup');
SELECT is((SELECT count(*)::int FROM pg_trigger WHERE tgrelid = 'public.ru_lines'::regclass AND tgname LIKE 'rollup\_%'), 0,
    'and so are the triggers on the child');
SELECT ok(
    pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgrelid = 'public.ru_orders'::regclass AND tgname = 'update_ru_orders_updated_at'))
        LIKE '%update_updated_at_column()',
    'the parent''s updated_at trigger is argument-less again');
SELECT ok(
    pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgrelid = 'public.ru_orders'::regclass AND tgname = 'audit_i_u_d'))
        LIKE '%insert_update_delete_trigger()',
    'and so is its audit UPDATE trigger');
SELECT lives_ok($$DELETE FROM fields WHERE table_name = 'ru_lines' AND field_name = 'order_id'$$,
    'the former link field is deletable once nothing depends on it');

-- A module delete takes parent and child together, whatever the cascade order.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('RU Mod', 'ru_mod', 'rollup module delete probe', 'public:read');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
SELECT t, t, t, t, 'module delete probe', (SELECT id FROM modules WHERE module_slug = 'ru_mod'),
       'public:read', 'admin', 'id', 'label'
  FROM unnest(ARRAY['rm_parent', 'rm_child']) AS t;
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rm_child', 'parent_id', 'Parent', 'parent', 10, 'rm_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rm_parent', 'kids', 'Kids', 'int64', 10, '{"link_field": "rm_child.parent_id", "function": "count"}'),
       ('rm_parent', 'kids2', 'Kids too', 'int64', 20, '{"link_field": "rm_child.parent_id", "function": "count"}');
SELECT lives_ok($$DELETE FROM modules WHERE module_slug = 'ru_mod'$$,
    'a module delete takes a parent with rollups and its child together');
SELECT is_empty(
    $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'common' AND p.proname LIKE 'rollup%rm\_%'$$,
    'and leaves no generated function behind');

-- ensure_entities applies a rollup after every other field, so a document may
-- name a child that comes later in the file.
SELECT lives_ok($$SELECT public.ensure_entities('{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ee_rollup_parent", "module_name": "_core", "singular_label": "EE Parent", "plural_label": "EE Parents",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "fields": [
                        {"field_name": "kids", "title": "Kids", "format": "int64", "field_order": 10,
                         "rollup": {"link_field": "ee_rollup_child.parent_id", "function": "count"}},
                        {"field_name": "memo", "title": "Memo", "format": "text", "field_order": 20}
                    ]}},
        {"entity": {"table_name": "ee_rollup_child", "module_name": "_core", "singular_label": "EE Child", "plural_label": "EE Children",
                    "view_permission": "public:read", "edit_permission": "admin", "id_column": "id", "label_column": "label",
                    "fields": [
                        {"field_name": "parent_id", "title": "Parent", "format": "parent", "field_order": 10,
                         "reference_table": "ee_rollup_parent", "reference_delete_mode": "restrict"}
                    ]}}
    ]}'::jsonb)$$,
    'ensure_entities: a rollup listed before the entity it aggregates over is applied after it');
SELECT is((SELECT ctype FROM fields WHERE table_name = 'ee_rollup_parent' AND field_name = 'kids'), 'rollup',
    'and became a rollup');
SELECT is(
    (SELECT (public.ensure_entities('{
        "version": 1,
        "entities": [
            {"entity": {"table_name": "ee_rollup_parent",
                        "fields": [{"field_name": "kids", "format": "int64", "ctype": "rollup",
                                    "rollup": {"link_field": "ee_rollup_child.parent_id", "function": "count"}}]}}
        ]}'::jsonb) -> 'fields' -> 'updated')),
    '[]'::jsonb,
    'applying an export that carries ctype rollup again changes nothing');

-- =====================================================
-- PART 8: A definition removed while the field stays
-- =====================================================
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rr_parent', 'rr_parent', 'RR Parent', 'RR Parents', 'rollup removal parent', 1, 'public:read', 'admin', 'id', 'label'),
       ('rr_child', 'rr_child', 'RR Child', 'RR Children', 'rollup removal child', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rr_child', 'parent_id', 'Parent', 'parent', 10, 'rr_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('rr_child', 'qty', 'Qty', 'int32', 20);
INSERT INTO rr_parent (label) VALUES ('P');
INSERT INTO rr_child (label, parent_id, qty) SELECT 'c', id, 3 FROM rr_parent;
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rr_parent', 'agg', 'Agg', 'int32', 10, '{"link_field": "rr_child.parent_id", "function": "sum", "value_field": "qty"}');

UPDATE fields SET rollup = '{}' WHERE table_name = 'rr_parent' AND field_name = 'agg';
SELECT is((SELECT agg FROM rr_parent), 3, 'a definition removed: the record keeps the last aggregate');
SELECT is((SELECT ctype FROM fields WHERE table_name = 'rr_parent' AND field_name = 'agg'), '', 'and the field loses ctype rollup');
SELECT ok(
    to_regprocedure('common.rollup_guard_rr_parent()') IS NULL AND to_regprocedure('common.rollup_rr_child_parent_id()') IS NULL,
    'and the guard and the maintenance function are gone');
SELECT ok(
    pg_get_triggerdef((SELECT oid FROM pg_trigger WHERE tgrelid = 'public.rr_parent'::regclass AND tgname = 'update_rr_parent_updated_at'))
        LIKE '%update_updated_at_column()',
    'and the updated_at trigger is argument-less again');
UPDATE rr_child SET qty = 9;
SELECT is((SELECT agg FROM rr_parent), 3, 'a child write no longer moves the value');
UPDATE rr_parent SET agg = 99;
SELECT is((SELECT agg FROM rr_parent), 99, 'and it is ordinary data a write can change');

-- =====================================================
-- PART 9: One statement: rollups over fields created earlier in it
-- =====================================================
-- A client sends a child's fields and the rollups over them in one INSERT.
-- Every row's BEFORE triggers run before any row's column exists, so a new
-- field's filter is compiled in its row's AFTER trigger, when the columns of
-- the earlier rows exist and those of the later rows do not.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rs_parent', 'rs_parent', 'RS Parent', 'RS Parents', 'one-statement parent', 1, 'public:read', 'admin', 'id', 'label'),
       ('rs_child', 'rs_child', 'RS Child', 'RS Children', 'one-statement child', 1, 'public:read', 'admin', 'id', 'label'),
       ('rs_node', 'rs_node', 'RS Node', 'RS Nodes', 'one-statement tree', 1, 'public:read', 'admin', 'id', 'label');

SELECT lives_ok($$
    INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode, enum_values, rollup) VALUES
        ('rs_child',  'parent_id',    'Parent',       'parent',  10, 'rs_parent', 'restrict', DEFAULT, DEFAULT),
        ('rs_child',  'stage',        'Stage',        'enum',    20, DEFAULT, DEFAULT, '["open", "hired"]', DEFAULT),
        ('rs_child',  'amount',       'Amount',       'number',  30, DEFAULT, DEFAULT, DEFAULT, DEFAULT),
        ('rs_child',  'urgent',       'Urgent',       'boolean', 40, DEFAULT, DEFAULT, DEFAULT, DEFAULT),
        ('rs_parent', 'hired_count',  'Hired',        'int64',   10, DEFAULT, DEFAULT, DEFAULT,
         '{"link_field": "rs_child.parent_id", "function": "count", "filter": {"==": [{"var": "stage"}, "hired"]}}'),
        ('rs_parent', 'urgent_total', 'Urgent total', 'number',  20, DEFAULT, DEFAULT, DEFAULT,
         '{"link_field": "rs_child.parent_id", "function": "sum", "value_field": "amount", "filter": {"var": "urgent"}}')
$$, 'one statement: the link field, the value field and the filtered columns of the child, then the rollups over them');

INSERT INTO rs_parent (label) VALUES ('P');
INSERT INTO rs_child (label, parent_id, stage, amount, urgent)
SELECT v.label, p.id, v.stage, v.amount, v.urgent
  FROM rs_parent p,
       (VALUES ('c1', 'hired', 10, TRUE), ('c2', 'hired', 20, FALSE), ('c3', 'open', 40, TRUE)) AS v(label, stage, amount, urgent);
SELECT is((SELECT ARRAY[hired_count::numeric, urgent_total] FROM rs_parent), ARRAY[2, 50]::numeric[],
    'and both apply their filters: 2 of 3 children hired, the urgent amounts 10 and 40 of 70');

-- One INSERT of a child field probe_col of the given format and a count whose
-- filter is p_filter, the rollup's row first when asked.
CREATE FUNCTION pg_temp.rs_call(p_format TEXT, p_filter TEXT, p_rollup_first BOOLEAN DEFAULT FALSE) RETURNS TEXT LANGUAGE sql AS $$
    SELECT format($q$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup) VALUES %s, %s$q$,
                  CASE WHEN p_rollup_first THEN r ELSE c END,
                  CASE WHEN p_rollup_first THEN c ELSE r END)
      FROM (SELECT format($r$('rs_child', 'probe_col', 'Probe column', %L, 900, '{}')$r$, p_format) AS c,
                   format($r$('rs_parent', 'probe', 'Probe', 'int64', 900, %L)$r$,
                          jsonb_build_object('link_field', 'rs_child.parent_id', 'function', 'count',
                                             'filter', p_filter::jsonb)) AS r) s
$$;

SELECT throws_ok(pg_temp.rs_call('boolean', '{"var": "probe_col"}', TRUE),
    '90265', NULL, 'one statement: a filter naming a field whose row comes later is refused');
SELECT is(catch_error_hint(pg_temp.rs_call('boolean', '{"var": "probe_col"}', TRUE)) ->> 'problem',
    'column probe_col does not exist on rs_child',
    'as a column that does not exist, the rule a later link or value field follows');
SELECT throws_ok(pg_temp.rs_call('json', '{"==": [{"var": "probe_col"}, 1]}'),
    '90265', NULL, 'one statement: a new column of a type the filter cannot compare is refused');
SELECT throws_ok(pg_temp.rs_call('int32', '{"==": [{"var": "probe_col"}, "abc"]}'),
    '90265', NULL, 'one statement: a literal the new column cannot be cast from is refused by the probe, not by the backfill');
SELECT throws_ok(
    $$UPDATE fields SET rollup = jsonb_set(rollup, '{filter}', '{"==": [{"var": "amount"}, "abc"]}')
       WHERE table_name = 'rs_parent' AND field_name = 'hired_count'$$,
    '90265', NULL, 'a filter changed to a literal its column cannot be cast from is refused by the probe');

-- A tree: the link, the filtered column and the rollup are all fields of the
-- one entity, so its own column and the filtered one are both new.
SELECT lives_ok($$
    INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode, rollup) VALUES
        ('rs_node', 'parent_ref',  'Parent',          'reference', 10, 'rs_node', 'clear', DEFAULT),
        ('rs_node', 'active',      'Active',          'boolean',   20, DEFAULT,   DEFAULT, DEFAULT),
        ('rs_node', 'active_kids', 'Active children', 'int64',     30, DEFAULT,   DEFAULT,
         '{"link_field": "rs_node.parent_ref", "function": "count", "filter": {"var": "active"}}')
$$, 'one statement: a tree''s link, a filtered column and the rollup over its own records');
INSERT INTO rs_node (label, active) VALUES ('root', TRUE);
INSERT INTO rs_node (label, parent_ref, active)
SELECT v.label, r.id, v.active
  FROM rs_node r, (VALUES ('on', TRUE), ('off', FALSE)) AS v(label, active)
 WHERE r.label = 'root';
SELECT is((SELECT jsonb_object_agg(label, active_kids) FROM rs_node), '{"root": 1, "on": 0, "off": 0}'::jsonb,
    'and the root counts its one active child');

-- The two trigger orders on fields that the compile depends on. A rename that
-- breaks one fails the tests above as well; these name the cause.
SELECT is(
    (SELECT tgname::text FROM pg_trigger
      WHERE tgrelid = 'public.fields'::regclass AND NOT tgisinternal AND (tgtype & 7) = 7
      ORDER BY tgname::text COLLATE "C" DESC LIMIT 1),
    'zz_validate_rollup_field',
    'zz_validate_rollup_field is the last BEFORE INSERT row trigger on fields, after the ctype lock and the computed marker');
SELECT ok(
    (SELECT array_position(a, 'add_field_trigger') < array_position(a, 'zz_rollup_field_change')
       FROM (SELECT array_agg(tgname::text ORDER BY tgname::text COLLATE "C") AS a
               FROM pg_trigger
              WHERE tgrelid = 'public.fields'::regclass AND NOT tgisinternal
                AND (tgtype & 7) = 5 AND (tgtype & 64) = 0) s),
    'add_field_trigger fires before zz_rollup_field_change, so a new rollup''s own column exists when its filter is compiled');

-- =====================================================
-- PART 10: rollup_rebuild_all
-- =====================================================
-- A change to a builder replaces the builder, not what it generated, so the
-- release that ships it calls rollup_rebuild_all() to regenerate every
-- maintenance function with its triggers, and every guard, from the fields
-- rows. Only the owner may call it.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('rb_parent', 'rb_parent', 'RB Parent', 'RB Parents', 'rebuild parent',        1, 'public:read', 'admin', 'id', 'label', TRUE),
       ('rb_line',   'rb_line',   'RB Line',   'RB Lines',   'rebuild child',         1, 'public:read', 'admin', 'id', 'label', FALSE),
       ('rb_memo',   'rb_memo',   'RB Memo',   'RB Memos',   'rebuild second child',  1, 'public:read', 'admin', 'id', 'label', FALSE);
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rb_line', 'parent_id', 'Parent', 'parent', 10, 'rb_parent', 'restrict'),
       ('rb_memo', 'parent_id', 'Parent', 'parent', 10, 'rb_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, "precision")
VALUES ('rb_line', 'amount', 'Amount', 'number', 20, 2);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup) VALUES
    ('rb_parent', 'total',      'Total', 'number', 10, '{"link_field": "rb_line.parent_id", "function": "sum", "value_field": "amount"}'),
    ('rb_parent', 'line_count', 'Lines', 'int64',  20, '{"link_field": "rb_line.parent_id", "function": "count"}'),
    ('rb_parent', 'memo_count', 'Memos', 'int64',  30, '{"link_field": "rb_memo.parent_id", "function": "count"}');

CREATE FUNCTION pg_temp.rb() RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_array(total, line_count, memo_count) FROM rb_parent WHERE label = 'P'
$$;

INSERT INTO rb_parent (label) VALUES ('P');
INSERT INTO rb_line (label, parent_id, amount) SELECT 'l1', id, 10.00 FROM rb_parent;
INSERT INTO rb_memo (label, parent_id) SELECT 'm1', id FROM rb_parent;
SELECT is(pg_temp.rb(), '[10.00, 1, 1]'::jsonb,
    'two links to one parent: a write under each moves the totals');

-- The owner removes one maintenance function with its triggers and one guard,
-- and replaces the body of a second function with one the builder never wrote.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
DROP FUNCTION common.rollup_rb_line_parent_id() CASCADE;
DROP FUNCTION common.rollup_guard_rb_parent() CASCADE;
CREATE OR REPLACE FUNCTION common.rollup_rb_memo_parent_id()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
    RETURN NULL;
END;
$f$;
SELECT ok(
    to_regprocedure('common.rollup_rb_line_parent_id()') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rb_line'::regclass AND tgname LIKE 'rollup\_rb\_line\_%'),
    'the maintenance function is gone, and its four triggers with it');
SELECT ok(
    to_regprocedure('common.rollup_guard_rb_parent()') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rb_parent'::regclass AND tgname = 'a_rollup_guard'),
    'the guard is gone, and a_rollup_guard with it');

SELECT authenticate_as('user3');
INSERT INTO rb_line (label, parent_id, amount) SELECT 'l2', id, 5.00 FROM rb_parent;
INSERT INTO rb_memo (label, parent_id) SELECT 'm2', id FROM rb_parent;
SELECT is(pg_temp.rb(), '[10.00, 1, 1]'::jsonb,
    'with the function missing and the other one stale, a child write moves no total');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT lives_ok($$SELECT rollup_rebuild_all()$$, 'rollup_rebuild_all runs as the owner');
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_rb_line_parent_id' AND p.prosecdef),
    'the maintenance function is back, SECURITY DEFINER');
SELECT is(
    (SELECT array_agg(tgname::text ORDER BY tgname) FROM pg_trigger
      WHERE tgrelid = 'public.rb_line'::regclass AND tgname LIKE 'rollup\_rb\_line\_%'),
    ARRAY['rollup_rb_line_parent_id_del', 'rollup_rb_line_parent_id_ins', 'rollup_rb_line_parent_id_trc', 'rollup_rb_line_parent_id_upd'],
    'with its four statement-level triggers');
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_guard_rb_parent' AND p.prosecdef)
    AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rb_parent'::regclass AND tgname = 'a_rollup_guard'),
    'the guard is back, with a_rollup_guard on the parent');

SELECT authenticate_as('user3');
INSERT INTO rb_line (label, parent_id, amount) SELECT 'l3', id, 1.00 FROM rb_parent;
INSERT INTO rb_memo (label, parent_id) SELECT 'm3', id FROM rb_parent;
SELECT is(pg_temp.rb(), '[16.00, 3, 3]'::jsonb,
    'a child write moves the totals again, over every child: the missing function is recreated and the stale body replaced');
UPDATE rb_parent SET total = 999 WHERE label = 'P';
SELECT is(pg_temp.rb() -> 0, '16.00'::jsonb,
    'and a hand-written total is replaced by the computed one: the guard is back');
SELECT throws_ok($$SELECT rollup_rebuild_all()$$, '42501', 'permission denied for function rollup_rebuild_all',
    'an administrator through the API cannot call it');

-- =====================================================
-- PART 11: The filter compiler's refusals and the branches no rollup reaches
-- =====================================================
-- Every compile error of a filter shares one code and one message template, and
-- the hint's problem is what tells one refusal from another, so a refusal is
-- compared whole: SQLSTATE, message and problem.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TABLE public.rf_rows (
    id  SERIAL PRIMARY KEY,
    t   TEXT,
    n   INTEGER,
    b   BOOLEAN,
    d   DATE,
    ts  TIMESTAMPTZ,
    tid common.typeid,
    iv  INTERVAL,
    j   JSONB,
    raw BYTEA
);
INSERT INTO public.rf_rows (t, n, b) VALUES ('a', 1, TRUE), ('b', 2, FALSE), (NULL, NULL, NULL);

CREATE FUNCTION pg_temp.rx_err(p_sql TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_object('code', e ->> 'code', 'message', e ->> 'message', 'hint', (e ->> 'hint')::jsonb)
      FROM (SELECT catch_error(p_sql) AS e) s
$$;

CREATE FUNCTION pg_temp.rx_filter(p_filter TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT pg_temp.rx_err(format('SELECT rollup_filter_sql(%L::jsonb, ''rf_rows'', ''c'')', p_filter))
$$;

CREATE FUNCTION pg_temp.rx_problem(p_problem TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_object('code', '90265',
                              'message', 'Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}',
                              'hint', jsonb_build_object('problem', p_problem))
$$;

CREATE FUNCTION pg_temp.rx_count(p_filter TEXT) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    EXECUTE format('SELECT count(*)::int FROM public.rf_rows c WHERE %s', rollup_filter_sql(p_filter::jsonb, 'rf_rows', 'c')) INTO v_count;
    RETURN v_count;
END;
$$;

-- The number of operands an operator takes.
SELECT is(pg_temp.rx_filter('{"and": []}'), pg_temp.rx_problem('and needs at least one condition'),
    'and with no condition is refused');
SELECT is(pg_temp.rx_filter('{"or": []}'), pg_temp.rx_problem('or needs at least one condition'),
    'and so is or');
SELECT is(pg_temp.rx_filter('{"!": [{"var": "b"}, {"var": "b"}]}'), pg_temp.rx_problem('! takes exactly one condition'),
    '! with two conditions is refused');
SELECT is(pg_temp.rx_filter('{"!!": []}'), pg_temp.rx_problem('!! takes exactly one condition'),
    'and !! with none');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "t"}]}'), pg_temp.rx_problem('== takes exactly two operands'),
    '== with one operand is refused');
SELECT is(pg_temp.rx_filter('{"==": [1, 2, 3]}'), pg_temp.rx_problem('== takes exactly two operands'),
    'and with three');
SELECT is(pg_temp.rx_filter('{">": [1, {"var": "n"}, 3]}'), pg_temp.rx_problem('> takes two operands (three for < and <=)'),
    '> with three operands is refused: only < and <= read as a range');
SELECT is(pg_temp.rx_filter('{">=": [1, {"var": "n"}, 3]}'), pg_temp.rx_problem('>= takes two operands (three for < and <=)'),
    'and so is >=');
SELECT is(pg_temp.rx_filter('{"<": [{"var": "n"}]}'), pg_temp.rx_problem('< takes two operands (three for < and <=)'),
    'and < with one operand');
SELECT is(pg_temp.rx_filter('{"in": [{"var": "t"}, "abc"]}'), pg_temp.rx_problem('in takes a value and a list of literals'),
    'in against a string and not a list is refused');
SELECT is(pg_temp.rx_filter('{"in": [{"var": "t"}]}'), pg_temp.rx_problem('in takes a value and a list of literals'),
    'and in with no list');
SELECT is(pg_temp.rx_filter('{"in": [{"var": "t"}, ["a", null]]}'), pg_temp.rx_problem('the list of in holds literals only'),
    'null in the list of in is refused');
SELECT is(pg_temp.rx_filter('{"in": [{"var": "t"}, ["a", {"var": "t"}]]}'), pg_temp.rx_problem('the list of in holds literals only'),
    'and so is a column');
SELECT is(pg_temp.rx_filter('"x"'), pg_temp.rx_problem('a condition must be a comparison, and, or, !, a boolean column or a boolean'),
    'a string is not a condition');
SELECT is(pg_temp.rx_filter('{"and": [5]}'), pg_temp.rx_problem('a condition must be a comparison, and, or, !, a boolean column or a boolean'),
    'nor is a number, inside an and');

-- What an operand may be.
SELECT is(pg_temp.rx_filter('{"==": [{"var": "t", "n": 1}, "a"]}'), pg_temp.rx_problem('an operator object has exactly one key'),
    'an operand with two keys is refused');
SELECT is(pg_temp.rx_filter('{"==": [{}, 1]}'), pg_temp.rx_problem('an operator object has exactly one key'),
    'and an operand with none');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "t"}, ["a"]]}'), pg_temp.rx_problem('an operand must be a column (var), a literal or null'),
    'an array is not an operand');
SELECT is(pg_temp.rx_filter('{"==": [{"var": ["a", 1]}, 1]}'), pg_temp.rx_problem('var takes a plain column name, without a path or a default'),
    'var with a default is refused as an operand');
SELECT is(pg_temp.rx_filter('{"var": ["a", 1]}'), pg_temp.rx_problem('var takes a plain column name, without a path or a default'),
    'and as a condition');

-- A literal against the wrong kind of column.
SELECT is(pg_temp.rx_filter('{"==": [{"var": "b"}, "yes"]}'), pg_temp.rx_problem('string yes compared with a boolean column'),
    'a string against a boolean column is refused');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "b"}, 1]}'), pg_temp.rx_problem('number 1 compared with a column of type boolean'),
    'a number against a boolean column is refused');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "tid"}, 5]}'), pg_temp.rx_problem('number 5 compared with a column of type common.typeid'),
    'and against a TypeID column');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "n"}, true]}'), pg_temp.rx_problem('boolean true compared with a column of type integer'),
    'a boolean against an integer column is refused');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "t"}, false]}'), pg_temp.rx_problem('boolean false compared with a column of type text'),
    'and against a text column');
SELECT is(pg_temp.rx_err($$SELECT rollup_filter_literal('[1]'::jsonb, 'text', 'other')$$),
    pg_temp.rx_problem('a literal must be a string, a number, a boolean or null'),
    'a literal that is an array is refused; the operand check keeps one from reaching the literal compiler');

-- A column the filter cannot compare.
SELECT is(pg_temp.rx_filter('{"==": [{"var": "j"}, 1]}'), pg_temp.rx_problem('column j has type jsonb, which a rollup filter cannot compare'),
    'a JSON column is outside the allowed types');
SELECT is(pg_temp.rx_filter('{"==": [{"var": "raw"}, "x"]}'), pg_temp.rx_problem('column raw has type bytea, which a rollup filter cannot compare'),
    'and so is a binary one');

-- The arguments of a date operator.
SELECT is(pg_temp.rx_filter('{"==": [{"date_part": [5, "year"]}, 1]}'),
    pg_temp.rx_problem('a date operator takes a date column, a date literal or another date operator'),
    'a number is not a date');
SELECT is(pg_temp.rx_filter('{"==": [{"date_add": [{"var": "ts"}, {"var": "n"}]}, "2026-01-01"]}'),
    pg_temp.rx_problem('{"var": "n"} is not a duration'),
    'date_add with two arguments takes a duration column, not an integer');
SELECT is(pg_temp.rx_filter('{"==": [{"date_add": [{"var": "d"}, {"var": "t"}, "day"]}, "2026-01-01"]}'),
    pg_temp.rx_problem('{"var": "t"} is not a whole number'),
    'and with three it takes an integer column, not text');

-- Conditions that compile: a boolean is a condition, {} is always true, and a
-- boolean literal meets a boolean column or another literal.
SELECT is(rollup_filter_sql('true', 'rf_rows', 'c'), 'TRUE', 'a boolean true is a condition');
SELECT is(rollup_filter_sql('false', 'rf_rows', 'c'), 'FALSE', 'and false');
SELECT is(rollup_filter_sql('{"and": [true, false]}', 'rf_rows', 'c'), '(TRUE AND FALSE)', 'inside an and');
SELECT is(rollup_filter_sql('{"or": [{}, {"var": "b"}]}', 'rf_rows', 'c'), '(TRUE OR c.b)', 'an empty object inside a condition is true');
SELECT is(rollup_filter_sql('{"==": [{"var": "b"}, true]}', 'rf_rows', 'c'), '(c.b IS NOT DISTINCT FROM TRUE)',
    'a boolean literal against a boolean column is TRUE');
SELECT is(rollup_filter_sql('{"!=": [{"var": "b"}, false]}', 'rf_rows', 'c'), '(c.b IS DISTINCT FROM FALSE)',
    'and false is FALSE');
SELECT is(rollup_filter_sql('{"==": [true, false]}', 'rf_rows', 'c'), '(TRUE IS NOT DISTINCT FROM FALSE)',
    'two boolean literals keep their own type');
SELECT is(pg_temp.rx_count('{"==": [{"var": "b"}, true]}'), 1, 'a boolean column equal to true matches its one true row');
SELECT is(pg_temp.rx_count('{"==": [{"var": "b"}, false]}'), 1, 'equal to false matches the false row and not the NULL one');
SELECT is(pg_temp.rx_count('{"==": [true, true]}'), 3, 'a constant condition matches every row');
SELECT is(pg_temp.rx_count('{"or": [{}, {"var": "b"}]}'), 3, 'as does an or with an empty object');

-- =====================================================
-- PART 12: Definition refusals, and the functions called with no rollup to act on
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rd_parent', 'rd_parent', 'RD Parent', 'RD Parents', 'definition parent', 1, 'public:read', 'admin', 'id', 'label'),
       ('rd_child',  'rd_child',  'RD Child',  'RD Children', 'definition child',  1, 'public:read', 'admin', 'id', 'label');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES ('rd_root', 'Root', 'Roots', 1, 'public:read', 'admin', 'typeid', 'rdroot');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, id_prefix, id_refentity)
VALUES ('rd_isa', 'Isa', 'Isas', 1, 'public:read', 'admin', 'is_a', 'rdisa', 'rd_root');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rd_child', 'parent_id', 'Parent', 'parent',    10, 'rd_parent', 'restrict'),
       ('rd_child', 'isa_ref',   'Isa',    'reference', 20, 'rd_isa',    'clear');
INSERT INTO fields (table_name, field_name, title, format, field_order, "precision")
VALUES ('rd_child', 'amount', 'Amount', 'number', 30, 2);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rd_child', 'note', 'Note', 'text', 40),
       ('rd_child', 'flag', 'Flag', 'boolean', 50);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rd_parent', 'total', 'Total', 'number', 10, '{"link_field": "rd_child.parent_id", "function": "sum", "value_field": "amount"}');
INSERT INTO rd_parent (label) VALUES ('P');
INSERT INTO rd_child (label, parent_id, amount, note, flag)
SELECT v.label, p.id, v.amount, v.note, v.flag
  FROM rd_parent p, (VALUES ('c1', 10.00, 'x', TRUE), ('c2', 5.00, 'y', FALSE)) AS v(label, amount, note, flag);

-- One INSERT of a probe field on p_table with the given definition.
CREATE FUNCTION pg_temp.rd_def(p_def TEXT, p_format TEXT DEFAULT 'int64', p_table TEXT DEFAULT 'rd_parent') RETURNS TEXT LANGUAGE sql AS $$
    SELECT format($q$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
                     VALUES (%L, 'probe', 'Probe', %L, 999, %L)$q$, p_table, p_format, p_def)
$$;

-- What an invalid definition looks like: 90261, its template, where and why.
CREATE FUNCTION pg_temp.rd_invalid(p_problem TEXT, p_table TEXT DEFAULT 'rd_parent', p_field TEXT DEFAULT 'probe') RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_object('code', '90261',
                              'message', 'Rollup ${field_name} on ${table} has an invalid definition: ${problem}',
                              'hint', jsonb_build_object('table', p_table, 'field_name', p_field, 'problem', p_problem))
$$;

SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"function": "count"}')),
    pg_temp.rd_invalid('link_field must be a string <entity>.<field>'),
    'a definition with no link_field is refused');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id"}')),
    pg_temp.rd_invalid('function must be a string'),
    'and one with no function');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "sum", "value_field": 5}', 'number')),
    pg_temp.rd_invalid('value_field must be a string'),
    'a value_field that is not a string is refused');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "count", "filter": "open"}')),
    pg_temp.rd_invalid('filter must be a JsonLogic object or a boolean'),
    'a filter that is a string is refused');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "count", "filter": [true]}')),
    pg_temp.rd_invalid('filter must be a JsonLogic object or a boolean'),
    'and one that is an array');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "count", "include_hidden_rows": "yes"}')),
    pg_temp.rd_invalid('include_hidden_rows must be a boolean'),
    'include_hidden_rows must be a boolean');
SELECT is(pg_temp.rx_err($$UPDATE fields SET rollup = '{"link_field": "rd_child.parent_id", "function": "count"}'
                           WHERE table_name = 'rd_parent' AND field_name = 'id'$$),
    pg_temp.rd_invalid('the key of an entity cannot be a rollup', 'rd_parent', 'id'),
    'the key of an entity cannot be a rollup');
SELECT is(pg_temp.rx_err($$INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode, rollup)
                           VALUES ('rd_parent', 'probe', 'Probe', 'reference', 999, 'rd_child', 'clear',
                                   '{"link_field": "rd_child.parent_id", "function": "count"}')$$),
    pg_temp.rd_invalid('a reference or parent field cannot be a rollup'),
    'a reference field cannot be a rollup');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.isa_ref", "function": "count"}', 'int64', 'rd_isa')),
    '{"code": "90249", "message": "${feature} is not available for ${id_type} entity ${table}",
      "hint": {"feature": "rollup", "id_type": "is_a", "table": "rd_isa"}}'::jsonb,
    'a rollup on an is_a parent is refused');

-- Two columns meet in a comparison only when PostgreSQL has an operator for
-- their types; the probe that plans the filter when the field is saved refuses
-- the pair that has none, with PostgreSQL's own words.
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "count", "filter": {"==": [{"var": "note"}, {"var": "amount"}]}}')),
    '{"code": "90265", "message": "Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}",
      "hint": {"table": "rd_parent", "field_name": "probe", "problem": "operator does not exist: text = numeric"}}'::jsonb,
    'a text column against a numeric one is refused');
SELECT is(pg_temp.rx_err(pg_temp.rd_def('{"link_field": "rd_child.parent_id", "function": "count", "filter": {"==": [{"var": "flag"}, {"var": "amount"}]}}')),
    '{"code": "90265", "message": "Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}",
      "hint": {"table": "rd_parent", "field_name": "probe", "problem": "operator does not exist: boolean = numeric"}}'::jsonb,
    'and a boolean column against a numeric one');

-- A boolean is a filter: true keeps every child, false none.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rd_parent', 'all_lines', 'All lines', 'int64', 20, '{"link_field": "rd_child.parent_id", "function": "count", "filter": true}'),
       ('rd_parent', 'no_lines',  'No lines',  'int64', 30, '{"link_field": "rd_child.parent_id", "function": "count", "filter": false}');
SELECT is((SELECT jsonb_build_array(all_lines, no_lines) FROM rd_parent), '[2, 0]'::jsonb,
    'a filter of true counts every child and one of false none');

-- A change that touches nothing the rollup depends on is not validated again.
UPDATE fields SET title = 'Grand total' WHERE table_name = 'rd_parent' AND field_name = 'total';
SELECT is(
    (SELECT jsonb_build_array(title, ctype, rollup ->> 'function', "precision") FROM fields WHERE table_name = 'rd_parent' AND field_name = 'total'),
    '["Grand total", "rollup", "sum", 2]'::jsonb,
    'a new title leaves the rollup, its marker and its precision as they were');

-- Called directly, as the owner, with a field that is not a rollup or with no
-- field at all, these do nothing and raise nothing.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT rollup_definition(f) FROM fields f WHERE table_name = 'rd_parent' AND field_name = 'label'), NULL::jsonb,
    'a field without a definition resolves to NULL');

CREATE TEMP TABLE rd_generated ON COMMIT DROP AS
    SELECT count(*) AS n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'common' AND p.proname LIKE 'rollup%';
SELECT lives_ok($$SELECT rollup_sync_field(f, TRUE) FROM fields f WHERE table_name = 'rd_parent' AND field_name = 'label'$$,
    'syncing a field without a definition does nothing');
SELECT is(
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'common' AND p.proname LIKE 'rollup%'),
    (SELECT n FROM rd_generated),
    'and generates nothing');
SELECT lives_ok($$SELECT rollup_backfill('rd_parent', 'no_such_field')$$, 'backfilling a field that does not exist does nothing');
SELECT lives_ok($$SELECT rollup_backfill('rd_parent', 'label')$$,
    'and backfilling a field that is not a rollup stops before it builds an expression from no definition');

-- A managed entity whose table is not there: the guard has nothing to attach to.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rd_ghost', 'rd_ghost', 'RD Ghost', 'RD Ghosts', 'managed entity whose table is gone', 1, 'public:read', 'admin', 'id', 'label');
DROP TABLE public.rd_ghost CASCADE;
SELECT ok((SELECT managed FROM entities WHERE table_name = 'rd_ghost') AND to_regclass('public.rd_ghost') IS NULL,
    'the entity is managed and its table is gone');
SELECT lives_ok($$SELECT rollup_build_guard('rd_ghost')$$,
    'building the guard of a managed entity whose table is missing stops before it creates a trigger on the table');

-- =====================================================
-- PART 13: A restricted child, and the managed flag of an entity with rollups
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rg_parent', 'rg_parent', 'RG Parent', 'RG Parents', 'flag parent', 1, 'public:read', 'admin', 'id', 'label'),
       ('rg_child',  'rg_child',  'RG Child',  'RG Children', 'flag child', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rg_child', 'parent_id', 'Parent', 'parent', 10, 'rg_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, "precision")
VALUES ('rg_child', 'amount', 'Amount', 'number', 20, 2);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rg_parent', 'total', 'Total', 'number', 10, '{"link_field": "rg_child.parent_id", "function": "sum", "value_field": "amount"}');
INSERT INTO rg_parent (label) VALUES ('P');
INSERT INTO rg_child (label, parent_id, amount) SELECT 'c1', id, 10.00 FROM rg_parent;
INSERT INTO rg_child (label, parent_id, amount) SELECT 'c2', id, 5.00 FROM rg_parent;

-- A child that becomes more restricted than its parent turns an existing rollup
-- into a leak, so the change is validated against every rollup that involves the
-- entity and refused until the rollup opts in. The parent's own permission is
-- compared the same way: a different one on the two sides counts as narrower.
SELECT is(pg_temp.rx_err($$UPDATE entities SET select_rule = '{"has_permission": "admin"}' WHERE table_name = 'rg_child'$$),
    '{"code": "90269",
      "message": "Rollup ${field_name} on ${table} aggregates rows of ${link_table} that readers of ${table} may not see; set include_hidden_rows to accept that",
      "hint": {"table": "rg_parent", "field_name": "total", "link_table": "rg_child"}}'::jsonb,
    'a select_rule on the child of a rollup is refused while the rollup does not accept hidden rows');
SELECT is((SELECT select_rule FROM entities WHERE table_name = 'rg_child'), '{}'::jsonb,
    'and the child keeps no rule');
SELECT is(pg_temp.rx_err($$UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'rg_parent'$$),
    '{"code": "90269",
      "message": "Rollup ${field_name} on ${table} aggregates rows of ${link_table} that readers of ${table} may not see; set include_hidden_rows to accept that",
      "hint": {"table": "rg_parent", "field_name": "total", "link_table": "rg_child"}}'::jsonb,
    'a different view permission on the parent is refused the same way');

UPDATE fields SET rollup = rollup || '{"include_hidden_rows": true}' WHERE table_name = 'rg_parent' AND field_name = 'total';
SELECT lives_ok($$UPDATE entities SET select_rule = '{"has_permission": "admin"}' WHERE table_name = 'rg_child'$$,
    'once the rollup accepts hidden rows the rule is accepted');
SELECT authenticate_as('user2');
SELECT is(
    (SELECT jsonb_build_array((SELECT count(*) FROM rg_child), (SELECT total FROM rg_parent))),
    '[0, 15.00]'::jsonb,
    'and a reader the rule hides the children from still sees the total over all of them');

-- The managed flag: unmanaging an entity drops what was generated for its
-- rollups, and managing it builds everything again and recomputes the values.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
UPDATE entities SET managed = FALSE WHERE table_name = 'rg_parent';
SELECT is_empty(
    $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'common' AND p.proname IN ('rollup_rg_child_parent_id', 'rollup_guard_rg_parent')$$,
    'unmanaging the parent drops the maintenance function and the guard');

-- A rollup added to an unmanaged parent is kept as metadata: it has no column to
-- fill and nothing to build.
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('rg_parent', 'line_count', 'Lines', 'int64', 20, '{"link_field": "rg_child.parent_id", "function": "count", "include_hidden_rows": true}');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.rg_parent'::regclass AND attname = 'line_count' AND NOT attisdropped)
    AND to_regprocedure('common.rollup_rg_child_parent_id()') IS NULL,
    'a rollup added to the unmanaged parent builds no column and no function');

INSERT INTO rg_child (label, parent_id, amount) SELECT 'c3', id, 1.00 FROM rg_parent;
SELECT is((SELECT total FROM rg_parent), 15.00, 'and a child written meanwhile moves no total');

UPDATE entities SET managed = TRUE WHERE table_name = 'rg_parent';
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'common' AND p.proname = 'rollup_rg_child_parent_id' AND p.prosecdef)
    AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.rg_parent'::regclass AND tgname = 'a_rollup_guard'),
    'managing the parent again builds the maintenance function and the guard');
SELECT is((SELECT jsonb_build_array(total, line_count) FROM rg_parent), '[16.00, 3]'::jsonb,
    'and recomputes both rollups, the one added meanwhile included');

-- =====================================================
-- PART 14: The compiled filter and the interpreter, operator by operator
-- =====================================================
-- A filter is compiled to SQL and never interpreted, but whoever writes one knows
-- JsonLogic from validation rules and select rules, which the interpreter
-- evaluates. So every operator of the subset runs both ways over the same rows,
-- through rollup_filter_sql and through evaluate_json_logic. Each answer is the
-- pair {compiled, interpreted} against the count the rows give, so two sides that
-- agree on a wrong number do not pass.
--
-- The rows hold one column of each type a filter usually compares, and one row
-- that is NULL in all of them. The text values serve the cases further down: two
-- that read as the number 10, the empty string, and a capital and an accented
-- initial, which a linguistic collation and code-point order place differently.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
-- The interpreter sees a date-time as the text to_jsonb renders, and that
-- follows the session's zone.
SET LOCAL timezone = 'UTC';

CREATE TABLE public.ru_op_rows (
    id SERIAL PRIMARY KEY,
    t  TEXT,
    n  INTEGER,
    x  NUMERIC(10,2),
    b  BOOLEAN,
    d  DATE,
    ts TIMESTAMPTZ,
    u  UUID
);
INSERT INTO public.ru_op_rows (t, n, x, b, d, ts, u) VALUES
    ('apple',        1,  1.50, TRUE,  '2026-01-10', '2026-01-10T08:00:00Z', '00000000-0000-0000-0000-000000000001'),
    ('Banana',       5,  5.00, FALSE, '2026-02-20', '2026-02-20T12:00:00Z', '00000000-0000-0000-0000-000000000002'),
    ('cherry',      10, 10.25, TRUE,  '2026-03-30', '2026-03-30T23:59:59Z', '00000000-0000-0000-0000-000000000003'),
    ('10',          -3, -0.50, FALSE, '2025-12-31', '2025-12-31T00:00:00Z', '00000000-0000-0000-0000-000000000004'),
    ('10.0',         0,  0.00, TRUE,  '2026-01-10', '2026-01-10T08:00:00Z', '00000000-0000-0000-0000-000000000005'),
    ('',             5,  5.00, FALSE, '2026-02-20', '2026-02-20T12:00:00Z', '00000000-0000-0000-0000-000000000006'),
    (U&'\00E9lan',   7,  7.75, TRUE,  '2026-06-15', '2026-06-15T10:00:00Z', '00000000-0000-0000-0000-00000000000a'),
    (NULL,        NULL,  NULL, NULL,  NULL,         NULL,                   NULL);

CREATE FUNCTION pg_temp.ru_ops(p_rule JSONB) RETURNS INTEGER[] LANGUAGE sql AS $$
    SELECT pg_temp.ru_both(p_rule, 'ru_op_rows')
$$;

-- == and ===. Both are IS NOT DISTINCT FROM, so null equals null and nothing else.
SELECT is(pg_temp.ru_ops('{"==": [{"var": "t"}, "apple"]}'), ARRAY[1, 1], 'both ways: == on a text column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "t"}, ""]}'), ARRAY[1, 1], 'both ways: the empty string equals itself and not the NULL row');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "n"}, 5]}'), ARRAY[2, 2], 'both ways: == on an integer column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "x"}, 5]}'), ARRAY[2, 2], 'both ways: == on a numeric column, whatever its scale');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "n"}, "5"]}'), ARRAY[2, 2], 'both ways: a string that is a number equals an integer column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "b"}, true]}'), ARRAY[4, 4], 'both ways: == on a boolean column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "d"}, "2026-01-10"]}'), ARRAY[2, 2], 'both ways: == on a date column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "ts"}, "2026-02-20T12:00:00+00:00"]}'), ARRAY[2, 2], 'both ways: == on a date-time column');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "u"}, "00000000-0000-0000-0000-000000000003"]}'), ARRAY[1, 1], 'both ways: == on a UUID column');
SELECT is(pg_temp.ru_ops('{"and": [{"==": [{"var": "t"}, null]}, {"==": [{"var": "n"}, null]}, {"==": [{"var": "x"}, null]},
                                   {"==": [{"var": "b"}, null]}, {"==": [{"var": "d"}, null]}, {"==": [{"var": "ts"}, null]},
                                   {"==": [{"var": "u"}, null]}]}'), ARRAY[1, 1],
    'both ways: == null finds the NULL of a column of every type');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "n"}, {"var": "x"}]}'), ARRAY[4, 4], 'both ways: == between two columns, two NULLs being equal');
SELECT is(pg_temp.ru_ops('{"===": [{"var": "t"}, "Banana"]}'), ARRAY[1, 1], 'both ways: === on a text column');
SELECT is(pg_temp.ru_ops('{"===": [{"var": "n"}, 5]}'), ARRAY[2, 2], 'both ways: === on an integer column');
SELECT is(pg_temp.ru_ops('{"===": [{"var": "x"}, 10.25]}'), ARRAY[1, 1], 'both ways: === on a numeric column');
SELECT is(pg_temp.ru_ops('{"===": [{"var": "b"}, false]}'), ARRAY[3, 3], 'both ways: === false leaves the NULL row out');
SELECT is(pg_temp.ru_ops('{"===": [{"var": "u"}, null]}'), ARRAY[1, 1], 'both ways: === null');

-- != and !==. IS DISTINCT FROM, so the NULL row differs from every value.
SELECT is(pg_temp.ru_ops('{"!=": [{"var": "t"}, "apple"]}'), ARRAY[7, 7], 'both ways: != on a text column keeps the NULL row');
SELECT is(pg_temp.ru_ops('{"!=": [{"var": "n"}, 5]}'), ARRAY[6, 6], 'both ways: != on an integer column');
SELECT is(pg_temp.ru_ops('{"!=": [{"var": "d"}, null]}'), ARRAY[7, 7], 'both ways: != null on a date column');
SELECT is(pg_temp.ru_ops('{"!=": [{"var": "b"}, true]}'), ARRAY[4, 4], 'both ways: != true is the false rows and the NULL row');
SELECT is(pg_temp.ru_ops('{"!==": [{"var": "x"}, 5]}'), ARRAY[6, 6], 'both ways: !== on a numeric column');
SELECT is(pg_temp.ru_ops('{"!==": [{"var": "t"}, null]}'), ARRAY[7, 7], 'both ways: !== null');
SELECT is(pg_temp.ru_ops('{"!==": [{"var": "u"}, "00000000-0000-0000-0000-000000000003"]}'), ARRAY[7, 7], 'both ways: !== on a UUID column');

-- Ordering. These are the comparisons the NULL row fails on either side: the
-- compiled one because NULL orders with nothing, the interpreted one because it
-- reads null as 0 and 0 does not satisfy them.
SELECT is(pg_temp.ru_ops('{">": [{"var": "n"}, 5]}'), ARRAY[2, 2], 'both ways: > on an integer column');
SELECT is(pg_temp.ru_ops('{">=": [{"var": "n"}, 5]}'), ARRAY[4, 4], 'both ways: >= on an integer column');
SELECT is(pg_temp.ru_ops('{">=": [{"var": "x"}, 5.00]}'), ARRAY[4, 4], 'both ways: >= on a numeric column');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "n"}, 0]}'), ARRAY[1, 1], 'both ways: < on an integer column');
SELECT is(pg_temp.ru_ops('{"<=": [{"var": "x"}, -0.5]}'), ARRAY[1, 1], 'both ways: <= on a numeric column');
SELECT is(pg_temp.ru_ops('{">": [{"var": "d"}, "2026-02-20"]}'), ARRAY[2, 2], 'both ways: > on a date column');
SELECT is(pg_temp.ru_ops('{">=": [{"var": "ts"}, "2026-02-20T12:00:00+00:00"]}'), ARRAY[4, 4], 'both ways: >= on a date-time column');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "u"}, "00000000-0000-0000-0000-000000000003"]}'), ARRAY[2, 2], 'both ways: < on a UUID column');
SELECT is(pg_temp.ru_ops('{">": [{"var": "t"}, "c"]}'), ARRAY[2, 2], 'both ways: > on a text column, where every collation agrees');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "n"}, {"var": "x"}]}'), ARRAY[4, 4], 'both ways: < between an integer and a numeric column');
SELECT is(pg_temp.ru_ops('{"<": [5, {"var": "n"}]}'), ARRAY[2, 2], 'both ways: the literal may come first');
SELECT is(pg_temp.ru_ops('{"<": [0, {"var": "n"}, 10]}'), ARRAY[4, 4], 'both ways: a three-operand < is an open range');
SELECT is(pg_temp.ru_ops('{"<=": [1.5, {"var": "x"}, 7.75]}'), ARRAY[4, 4], 'both ways: a three-operand <= includes both ends');
SELECT is(pg_temp.ru_ops('{"<=": ["2026-01-10", {"var": "d"}, "2026-02-20"]}'), ARRAY[4, 4], 'both ways: a three-operand <= over dates');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "n"}, {"var": "x"}, 8]}'), ARRAY[3, 3], 'both ways: a three-operand < with two columns');

-- in. The list is cast like any literal; a NULL column is in no list.
SELECT is(pg_temp.ru_ops('{"in": [{"var": "t"}, ["apple", "cherry", "nope"]]}'), ARRAY[2, 2], 'both ways: in with strings');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "n"}, [1, 5, 99]]}'), ARRAY[3, 3], 'both ways: in with numbers on an integer column');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "x"}, [1.5, 10.25]]}'), ARRAY[2, 2], 'both ways: in with numbers on a numeric column');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "d"}, ["2026-01-10", "2026-06-15"]]}'), ARRAY[3, 3], 'both ways: in with dates');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "u"}, ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-00000000000a"]]}'),
    ARRAY[2, 2], 'both ways: in with UUIDs');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "b"}, [true]]}'), ARRAY[4, 4], 'both ways: in with a boolean');

-- and, or, !, !!, a bare boolean column, a boolean, and the empty object.
SELECT is(pg_temp.ru_ops('{"and": [{"var": "b"}, {">": [{"var": "n"}, 0]}]}'), ARRAY[3, 3], 'both ways: and');
SELECT is(pg_temp.ru_ops('{"or": [{"==": [{"var": "t"}, "apple"]}, {"<": [{"var": "n"}, 0]}]}'), ARRAY[2, 2], 'both ways: or');
SELECT is(pg_temp.ru_ops('{"and": [{"or": [{"var": "b"}, {"==": [{"var": "n"}, 5]}]}, {"!=": [{"var": "t"}, ""]}]}'), ARRAY[5, 5],
    'both ways: an or inside an and');
SELECT is(pg_temp.ru_ops('{"!": {"==": [{"var": "t"}, "apple"]}}'), ARRAY[7, 7], 'both ways: ! over ==, which is never NULL');
SELECT is(pg_temp.ru_ops('{"!": [{"!=": [{"var": "n"}, 5]}]}'), ARRAY[2, 2], 'both ways: ! over !=, its argument in a list');
SELECT is(pg_temp.ru_ops('{"!!": {"var": "b"}}'), ARRAY[4, 4], 'both ways: !! over a boolean column');
SELECT is(pg_temp.ru_ops('{"!!": [{"==": [{"var": "n"}, 5]}]}'), ARRAY[2, 2], 'both ways: !! over a comparison');
SELECT is(pg_temp.ru_ops('{"var": "b"}'), ARRAY[4, 4], 'both ways: a bare boolean column');
SELECT is(pg_temp.ru_ops('true'), ARRAY[8, 8], 'both ways: true keeps every row');
SELECT is(pg_temp.ru_ops('false'), ARRAY[0, 0], 'both ways: false keeps none');
SELECT is(pg_temp.ru_ops('{}'), ARRAY[8, 8], 'both ways: the empty object keeps every row');
SELECT is(pg_temp.ru_ops('{"and": [true, {"var": "b"}]}'), ARRAY[4, 4], 'both ways: a boolean inside an and');
SELECT is(pg_temp.ru_ops('{"or": [false, {}]}'), ARRAY[8, 8], 'both ways: the empty object inside an or');
SELECT is(pg_temp.ru_ops('{"==": [1, 1]}'), ARRAY[8, 8], 'both ways: two literals that are equal');
SELECT is(pg_temp.ru_ops('{"<": [2, 1]}'), ARRAY[0, 0], 'both ways: two literals out of order');

-- Where the two are meant to differ, each side is held to its own count.
--
-- An ordering comparison is SQL's: a NULL column yields NULL and the row is left
-- out. The interpreter reads null as 0 and keeps the row whenever 0 satisfies
-- the comparison, so its count is one higher.
SELECT is(pg_temp.ru_ops('{"<": [{"var": "n"}, 5]}'), ARRAY[3, 4], 'a NULL integer is not below 5 when compiled and is when interpreted');
SELECT is(pg_temp.ru_ops('{"<=": [{"var": "x"}, 5]}'), ARRAY[5, 6], 'the same for <= on a numeric column');
SELECT is(pg_temp.ru_ops('{">=": [{"var": "n"}, 0]}'), ARRAY[6, 7], 'and for >= 0, which null read as 0 satisfies');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "d"}, "2026-02-01"]}'), ARRAY[3, 4], 'a NULL date is before no date when compiled and before every date when interpreted');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "ts"}, "2026-02-01T00:00:00+00:00"]}'), ARRAY[3, 4], 'the same for a NULL date-time');
SELECT is(pg_temp.ru_ops('{"<": [-5, {"var": "n"}, 5]}'), ARRAY[3, 4], 'and for a range that includes 0');

-- A literal is cast to the type of the column it meets, where the interpreter
-- coerces the pair to numbers. Against a text column a number is therefore
-- text: 10 equals only the value written '10', 0 does not equal the empty
-- string, and ordering is text ordering, in which every word is above '5'.
SELECT is(pg_temp.ru_ops('{"==": [{"var": "t"}, 10]}'), ARRAY[1, 2],
    'a text column equal to 10: compiled, the one value written 10; interpreted, every value that reads as 10');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "t"}, 0]}'), ARRAY[0, 1],
    'a text column equal to 0: compiled, nothing; interpreted, the empty string');
SELECT is(pg_temp.ru_ops('{">": [{"var": "t"}, 5]}'), ARRAY[4, 2],
    'a text column above 5: compiled, the four words; interpreted, the two values that read as 10');
-- Interpreted, a value that is no number is below nothing, which leaves the
-- empty string and the NULL row, both read as 0.
SELECT is(pg_temp.ru_ops('{"<": [{"var": "t"}, 5]}'), ARRAY[3, 2],
    'a text column below 5: compiled, the three values that sort before the digit 5; interpreted, the empty string and the NULL row');

-- Against a numeric column a string is a number, in a list as anywhere; the
-- interpreter looks for the value itself in the list and finds a number equal
-- to no string. The same holds with the types swapped.
SELECT is(pg_temp.ru_ops('{"in": [{"var": "n"}, ["1", "5"]]}'), ARRAY[3, 0],
    'in with a list of strings on an integer column: compiled, the strings are numbers; interpreted, nothing matches');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "x"}, ["1.5"]]}'), ARRAY[1, 0], 'the same on a numeric column');
SELECT is(pg_temp.ru_ops('{"in": [{"var": "t"}, [10]]}'), ARRAY[1, 0],
    'in with a list of numbers on a text column: compiled, the number is text; interpreted, nothing matches');

-- Differences that are written down nowhere. Each records what happens today.
--
-- ! over a comparison that is NULL. SQL's NOT keeps NULL, so the row with a NULL
-- column is in neither the comparison nor its negation. The interpreter always
-- answers true or false, so the row is in exactly one of the two. The sides
-- agree only where the interpreter's 0 puts the row into the comparison itself.
SELECT is(pg_temp.ru_ops('{"!": {">": [{"var": "n"}, 5]}}'), ARRAY[5, 6],
    'today: ! over > leaves the NULL row out when compiled and keeps it when interpreted');
SELECT is(pg_temp.ru_ops('{"!": {"<": [{"var": "n"}, 5]}}'), ARRAY[4, 4],
    'today: ! over < leaves the NULL row out on both sides, as the interpreter counts it below 5');
SELECT is(pg_temp.ru_ops('{"!": {"var": "b"}}'), ARRAY[3, 4],
    'today: ! over a NULL boolean column leaves the row out when compiled and keeps it when interpreted');
SELECT is(pg_temp.ru_ops('{"!": {"in": [{"var": "n"}, [1, 5]]}}'), ARRAY[4, 5],
    'today: ! over in leaves the NULL row out when compiled and keeps it when interpreted');

-- Text ordering. The compiled comparison uses the column's collation, the
-- interpreter code points. A linguistic collation places Banana after a and an
-- accented e before f; code points place both in the opposite order. A database
-- whose default collation is C therefore shows no difference, so each expected
-- pair follows what this database answers for the value in question.
SELECT is(pg_temp.ru_ops('{"<": [{"var": "t"}, "a"]}'),
    CASE WHEN 'Banana' < 'a' THEN ARRAY[4, 4] ELSE ARRAY[3, 4] END,
    'today: a capital initial sorts by the column''s collation when compiled and by code point when interpreted');
SELECT is(pg_temp.ru_ops('{"<": [{"var": "t"}, "f"]}'),
    CASE WHEN U&'\00E9lan' < 'f' THEN ARRAY[7, 6] ELSE ARRAY[6, 6] END,
    'today: an accented initial sorts by the column''s collation when compiled and by code point when interpreted');

-- === is compiled as ==, cast included, where the interpreter's === compares
-- the types first.
SELECT is(pg_temp.ru_ops('{"===": [{"var": "n"}, "5"]}'), ARRAY[2, 0],
    'today: === between an integer column and a string matches when compiled and never when interpreted');
-- The cast rounds a number to the column's scale before it compares.
SELECT is(pg_temp.ru_ops('{"==": [{"var": "x"}, 1.501]}'), ARRAY[1, 0],
    'today: a number with more decimals than the column equals the rounded value when compiled');
-- The compiled side reads a date-time or UUID literal as a value, the interpreter
-- as text, so another spelling of the same value matches on one side only.
SELECT is(pg_temp.ru_ops('{"==": [{"var": "ts"}, "2026-02-20T12:00:00Z"]}'), ARRAY[2, 0],
    'today: a date-time written with Z equals the column when compiled and not when interpreted');
SELECT is(pg_temp.ru_ops('{"==": [{"var": "u"}, "00000000-0000-0000-0000-00000000000A"]}'), ARRAY[1, 0],
    'today: a UUID written in capitals equals the column when compiled and not when interpreted');

-- =====================================================
-- PART 15: Values a filter meets when a child is written
-- =====================================================
-- A filter runs inside the maintenance trigger of every child write, so a value
-- it cannot handle fails the write of a record that has nothing wrong with it.
-- Whatever can be known when the definition is saved is refused then. What is
-- left is the value of a column, and a child holding any value its column takes
-- stays writable: the row is outside the filter, not an error.
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rt_parent', 'rt_parent', 'RT Parent', 'RT Parents', 'run time parent', 1, 'public:read', 'admin', 'id', 'label'),
       ('rt_dated',  'rt_dated',  'RT Dated',  'RT Dated',   'child with a date', 1, 'public:read', 'admin', 'id', 'label'),
       ('rt_sized',  'rt_sized',  'RT Sized',  'RT Sized',   'child with a date and an amount', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rt_dated', 'parent_id', 'Parent', 'parent', 10, 'rt_parent', 'restrict'),
       ('rt_sized', 'parent_id', 'Parent', 'parent', 10, 'rt_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rt_dated', 'ship_date', 'Ship date', 'date',  20),
       ('rt_sized', 'ship_date', 'Ship date', 'date',  20),
       ('rt_sized', 'days',      'Days',      'int64', 30);
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup) VALUES
    ('rt_parent', 'dated_all',  'Dated',      'int64', 10, '{"link_field": "rt_dated.parent_id", "function": "count"}'),
    ('rt_parent', 'dated_2026', 'Dated 2026', 'int64', 20, '{"link_field": "rt_dated.parent_id", "function": "count",
        "filter": {"==": [{"date_part": [{"var": "ship_date"}, "year"]}, 2026]}}'),
    ('rt_parent', 'sized_all',  'Sized',      'int64', 30, '{"link_field": "rt_sized.parent_id", "function": "count"}'),
    ('rt_parent', 'sized_soon', 'Sized soon', 'int64', 40, '{"link_field": "rt_sized.parent_id", "function": "count",
        "filter": {"<": [{"date_add": [{"var": "ship_date"}, {"var": "days"}, "day"]}, "2027-01-01"]}}');

-- A literal the column cannot be cast from is known at save time: a string that
-- is no number, in a list as anywhere, and a number with a fraction against an
-- integer column, which the interpreter would simply compare.
SELECT is(pg_temp.rx_err($$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
                           VALUES ('rt_parent', 'probe_list', 'Probe', 'int64', 100,
                                   '{"link_field": "rt_sized.parent_id", "function": "count", "filter": {"in": [{"var": "days"}, ["a", "b"]]}}')$$),
    '{"code": "90265", "message": "Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}",
      "hint": {"table": "rt_parent", "field_name": "probe_list", "problem": "invalid input syntax for type bigint: \"a\""}}'::jsonb,
    'in with a list of strings that are no numbers on an integer column is refused when the definition is saved');
SELECT is(pg_temp.rx_err($$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
                           VALUES ('rt_parent', 'probe_fraction', 'Probe', 'int64', 110,
                                   '{"link_field": "rt_sized.parent_id", "function": "count", "filter": {"<": [{"var": "days"}, 2.5]}}')$$),
    '{"code": "90265", "message": "Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}",
      "hint": {"table": "rt_parent", "field_name": "probe_fraction", "problem": "invalid input syntax for type bigint: \"2.5\""}}'::jsonb,
    'today: a number with a fraction against an integer column is refused when the definition is saved');

-- One parent per case, each with a child inside its filter and one outside, so a
-- write that fails in one case leaves the counts of the others alone.
INSERT INTO rt_parent (label) VALUES ('endless'), ('far'), ('wide'), ('long');
INSERT INTO rt_dated (label, parent_id, ship_date)
SELECT v.label, p.id, v.ship_date::date
  FROM rt_parent p, (VALUES ('this year', '2026-05-01'), ('last year', '2025-05-01')) AS v(label, ship_date);
INSERT INTO rt_sized (label, parent_id, ship_date, days)
SELECT v.label, p.id, v.ship_date::date, 10
  FROM rt_parent p, (VALUES ('in time', '2026-05-01'), ('late', '2026-12-30')) AS v(label, ship_date);

CREATE FUNCTION pg_temp.rt(p_label TEXT) RETURNS JSONB LANGUAGE sql AS $$
    SELECT jsonb_build_array(dated_all, dated_2026, sized_all, sized_soon) FROM rt_parent WHERE label = p_label
$$;

SELECT is((SELECT jsonb_object_agg(label, pg_temp.rt(label)) FROM rt_parent),
    '{"endless": [2, 1, 2, 1], "far": [2, 1, 2, 1], "wide": [2, 1, 2, 1], "long": [2, 1, 2, 1]}'::jsonb,
    'every parent starts with two children of each kind, one of them inside the filter');

-- A date column takes infinity and years beyond 9999, and a date operator can
-- read neither, so the filter has no answer for such a child. The write is
-- refused: counting the child in or out would both be a guess. What the writer
-- gets is one error of the dictionary that names the rollup, not whichever
-- error the date function or a cast underneath happened to raise.
SELECT is(
    COALESCE(catch_error($$INSERT INTO rt_dated (label, parent_id, ship_date) SELECT 'never', id, 'infinity' FROM rt_parent WHERE label = 'endless'$$) ->> 'code', 'no error'),
    '90272',
    'a child whose date is infinity is refused under a filter on a part of that date, with a rollup error');
SELECT is(pg_temp.rt('endless'), '[2, 1, 2, 1]'::jsonb,
    'and the refused child is counted nowhere');
SELECT is(
    COALESCE(catch_error($$INSERT INTO rt_dated (label, parent_id, ship_date) SELECT 'far off', id, '10000-01-01' FROM rt_parent WHERE label = 'far'$$) ->> 'code', 'no error'),
    '90272',
    'a child dated after the year 9999 is refused under the same filter, with the same kind of error');
SELECT is(pg_temp.rt('far'), '[2, 1, 2, 1]'::jsonb,
    'and the refused child is counted nowhere');

-- An int64 column takes more than an integer holds, and an amount that is an
-- integer can still carry the date past the last one a timestamp holds. The
-- sum has no date in either case, and the write is refused the same way.
SELECT is(
    COALESCE(catch_error($$INSERT INTO rt_sized (label, parent_id, ship_date, days) SELECT 'wide', id, '2026-05-01', 3000000000 FROM rt_parent WHERE label = 'wide'$$) ->> 'code', 'no error'),
    '90272',
    'a child whose amount is beyond the integer range is refused under a filter that adds it to a date, with a rollup error');
SELECT is(pg_temp.rt('wide'), '[2, 1, 2, 1]'::jsonb,
    'and the refused child is counted nowhere');
SELECT is(
    COALESCE(catch_error($$INSERT INTO rt_sized (label, parent_id, ship_date, days) SELECT 'long', id, '2026-05-01', 2000000000 FROM rt_parent WHERE label = 'long'$$) ->> 'code', 'no error'),
    '90272',
    'a child whose amount carries the date past the last timestamp is refused under the same filter, with the same kind of error');
SELECT is(pg_temp.rt('long'), '[2, 1, 2, 1]'::jsonb,
    'and the refused child is counted nowhere');

SELECT * FROM finish();
ROLLBACK;
