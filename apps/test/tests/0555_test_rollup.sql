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
BEGIN;

SELECT plan(179);

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

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'ru_parent' AND field_name = 'total'),
    'disabled',
    'input_type default is coerced to disabled: a form must not submit a computed value');
UPDATE fields SET input_type = 'readonly' WHERE table_name = 'ru_parent' AND field_name = 'total';
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'ru_parent' AND field_name = 'total'),
    'disabled',
    'and so is readonly, which an HTML form would still submit');

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

CREATE FUNCTION pg_temp.ru_compiled(p_rule JSONB) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    EXECUTE format('SELECT count(*)::int FROM public.ru_date_rows c WHERE %s', rollup_filter_sql(p_rule, 'ru_date_rows', 'c')) INTO v_count;
    RETURN v_count;
END;
$$;

CREATE FUNCTION pg_temp.ru_both(p_rule JSONB) RETURNS INTEGER[] LANGUAGE sql AS $$
    SELECT ARRAY[pg_temp.ru_compiled(p_rule),
                 (SELECT count(*)::int FROM public.ru_date_rows r WHERE jl_truthy(evaluate_json_logic(p_rule, to_jsonb(r))))];
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

SELECT * FROM finish();
ROLLBACK;
