-- =====================================================
-- fields.default_value hardening (0530)
-- =====================================================
-- The DDL triggers interpolate the result of quote_default_value() into
-- ALTER TABLE ... DEFAULT as the table owner, so caller text it returned
-- unquoted would run there as SQL. It returns caller text only as a quoted
-- literal (or one of a fixed allow-list of argument-less expressions), and
-- fields.default_value carries a CHECK that rejects statement separators and
-- comment markers outright.
--
-- Also covers the generated compute/validate trigger: rule code,
-- computed-field names and messages containing quotes or percent signs are
-- emitted as proper literals; and the select rule, whose text and leading
-- permission names reach the generated function and policies the same way.
BEGIN;

SELECT plan(85);

-- =====================================================
-- GROUP 1: quote_default_value never returns caller text bare
-- =====================================================
SELECT is(quote_default_value('(0); CREATE ROLE pwned_probe SUPERUSER', 'INTEGER'),
    quote_literal('(0); CREATE ROLE pwned_probe SUPERUSER'),
    'quote_default_value: parentheses and a statement separator become a string literal');
SELECT is(quote_default_value('now()::text', 'TEXT'), quote_literal('now()::text'),
    'quote_default_value: cast syntax becomes a string literal');
SELECT is(quote_default_value('gen_random_uuid()::text || ''x''', 'UUID'), quote_literal('gen_random_uuid()::text || ''x'''),
    'quote_default_value: an expression that is not allow-listed becomes a string literal');
SELECT is(quote_default_value('now()', 'TIMESTAMPTZ'), 'NOW()',
    'quote_default_value: now() is allow-listed');
SELECT is(quote_default_value('CURRENT_DATE', 'DATE'), 'CURRENT_DATE',
    'quote_default_value: CURRENT_DATE is allow-listed');
SELECT is(quote_default_value('current_timestamp', 'TIMESTAMPTZ'), 'CURRENT_TIMESTAMP',
    'quote_default_value: the allow-list is case-insensitive');
SELECT is(quote_default_value('gen_random_uuid()', 'UUID'), 'GEN_RANDOM_UUID()',
    'quote_default_value: gen_random_uuid() is allow-listed');
SELECT is(quote_default_value('0.5', 'NUMERIC(18, 2)'), '0.5',
    'quote_default_value: a plain numeric literal for a numeric column stays bare');
SELECT is(quote_default_value('-3', 'INTEGER'), '-3',
    'quote_default_value: a negative integer stays bare');
SELECT is(quote_default_value('1e3', 'INTEGER'), quote_literal('1e3'),
    'quote_default_value: any other numeric spelling becomes a literal (still castable)');
SELECT is(quote_default_value('t', 'BOOLEAN'), 'TRUE',
    'quote_default_value: boolean t becomes TRUE');
SELECT is(quote_default_value('false', 'BOOLEAN'), 'FALSE',
    'quote_default_value: boolean false becomes FALSE');
SELECT is(quote_default_value('null', 'TEXT'), 'NULL',
    'quote_default_value: the NULL keyword stays bare');
SELECT is(quote_default_value('[]', 'JSONB'), quote_literal('[]'),
    'quote_default_value: a JSON default becomes a literal');
SELECT is(quote_default_value('a (b)', 'TEXT'), quote_literal('a (b)'),
    'quote_default_value: text with parentheses stays a literal');
SELECT is(quote_default_value('O''Brien', 'TEXT'), quote_literal('O''Brien'),
    'quote_default_value: embedded quotes are escaped');
SELECT is(quote_default_value('', 'TEXT'), '',
    'quote_default_value: an empty value is returned as-is');

-- A relative day or moment becomes a fixed expression that reads the day or the
-- clock in UTC. The words would otherwise be quoted, and PostgreSQL converts a
-- quoted 'today' once, when the default is set; the keywords would read the
-- session's time zone, which a client can change.
SELECT is(dd_date_token_default('today', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date)',
    'dd_date_token_default: today on a date column is the UTC day');
SELECT is(dd_date_token_default(' Tomorrow ', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date + 1)',
    'dd_date_token_default: tomorrow is the next UTC day, in any case and with spaces around it');
SELECT is(dd_date_token_default('yesterday', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date - 1)',
    'dd_date_token_default: yesterday is the UTC day before');
SELECT is(dd_date_token_default('$TODAY', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date)',
    'dd_date_token_default: $today, the name a rule reads, is the same as today');
SELECT is(dd_date_token_default('CURRENT_DATE', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date)',
    'dd_date_token_default: CURRENT_DATE on a date column is the UTC day, not the session''s');
SELECT is(dd_date_token_default('now()', 'DATE'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date)',
    'dd_date_token_default: a moment on a date column is its UTC day');
SELECT is(dd_date_token_default('clock_timestamp()', 'DATE'), '((clock_timestamp() AT TIME ZONE ''UTC'')::date)',
    'dd_date_token_default: clock_timestamp() keeps its own moment');
SELECT is(dd_date_token_default('LOCALTIME', 'DATE'), NULL,
    'dd_date_token_default: a clock time names no day');
SELECT is(dd_date_token_default('tomorrow', 'TIMESTAMPTZ'),
    '(((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date + 1)::timestamp AT TIME ZONE ''UTC'')',
    'dd_date_token_default: tomorrow on a date-time column is UTC midnight of the next day');
SELECT is(dd_date_token_default('CURRENT_DATE', 'TIMESTAMPTZ'),
    '(((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date)::timestamp AT TIME ZONE ''UTC'')',
    'dd_date_token_default: CURRENT_DATE on a date-time column is UTC midnight, not the session''s');
SELECT is(dd_date_token_default('$now', 'TIMESTAMPTZ'), 'CURRENT_TIMESTAMP',
    'dd_date_token_default: $now on a date-time column is the moment');
SELECT is(dd_date_token_default('CURRENT_TIMESTAMP', 'TIMESTAMPTZ'), NULL,
    'dd_date_token_default: a moment on a date-time column stays as written');
SELECT is(dd_date_token_default('LOCALTIME', 'TIME'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::time)',
    'dd_date_token_default: LOCALTIME on a time column is the UTC clock');
SELECT is(dd_date_token_default('now', 'TIME'), '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::time)',
    'dd_date_token_default: now on a time column is the UTC clock');
SELECT is(dd_date_token_default('today', 'TIME'), NULL,
    'dd_date_token_default: a day on a time column is no default');
SELECT is(dd_date_token_default('tomorrow 09:00', 'TIMESTAMPTZ'), NULL,
    'dd_date_token_default: a word with more text is no relative day');
SELECT is(dd_date_token_default('2026-01-01', 'DATE'), NULL,
    'dd_date_token_default: a fixed date stays a literal');
SELECT is(dd_date_token_default('today', 'TEXT'), NULL,
    'dd_date_token_default: a text column keeps the word');
SELECT is(dd_column_default('date', 'tomorrow', 'default', NULL, 'DATE', ''),
    '((CURRENT_TIMESTAMP AT TIME ZONE ''UTC'')::date + 1)',
    'dd_column_default: a relative day is the expression, not a quoted literal');

-- =====================================================
-- GROUP 2: the fields.default_value CHECK (second line of defense)
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('dv_probe', 'dv_probe', 'DV Probe', 'DV Probes', 'default value hardening probe', 1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
VALUES ('dv_probe', 'qty', 'Qty', 'int32', 10, 'default', 'default', '0');

SELECT throws_ok(
    $$UPDATE fields SET default_value = '(0); CREATE ROLE pwned_probe SUPERUSER' WHERE table_name = 'dv_probe' AND field_name = 'qty'$$,
    '23514', NULL, 'fields.default_value: a statement separator is rejected by the CHECK');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
      VALUES ('dv_probe', 'c1', 'C1', 'text', 20, 'default', 'default', 'a -- b')$$,
    '23514', NULL, 'fields.default_value: a SQL comment marker is rejected by the CHECK');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
      VALUES ('dv_probe', 'c2', 'C2', 'text', 21, 'default', 'default', 'a /* b */')$$,
    '23514', NULL, 'fields.default_value: a block comment marker is rejected by the CHECK');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value)
      VALUES ('dv_probe', 'c3', 'C3', 'text', 22, 'default', 'default', repeat('x', 201))$$,
    '23514', NULL, 'fields.default_value: more than 200 characters are rejected by the CHECK');
SELECT is((SELECT count(*)::int FROM pg_roles WHERE rolname = 'pwned_probe'), 0,
    'no role was created by the rejected defaults');

-- =====================================================
-- GROUP 3: legitimate defaults still work end to end
-- =====================================================
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value) VALUES
    ('dv_probe', 'note',        'Note',        'text',      30, 'default', 'default', 'a (b)'),
    ('dv_probe', 'created',     'Created',     'date',      40, 'default', 'default', 'CURRENT_DATE'),
    ('dv_probe', 'tags',        'Tags',        'json',      50, 'default', 'default', '[]'),
    ('dv_probe', 'price',       'Price',       'number',    60, 'default', 'default', '0.5'),
    ('dv_probe', 'flag',        'Flag',        'boolean',   70, 'default', 'default', 't'),
    ('dv_probe', 'happened_at', 'Happened at', 'date-time', 80, 'default', 'default', 'now()');

INSERT INTO dv_probe (label) VALUES ('r1');

SELECT is((SELECT note FROM dv_probe WHERE label = 'r1'), 'a (b)',
    'a text default with parentheses is applied as a value');
SELECT is((SELECT created FROM dv_probe WHERE label = 'r1'), (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date,
    'CURRENT_DATE is applied as an expression, the UTC day');
SELECT is((SELECT tags FROM dv_probe WHERE label = 'r1'), '[]'::jsonb,
    'a JSON default is applied');
SELECT is((SELECT price FROM dv_probe WHERE label = 'r1'), 0.5::numeric,
    'a numeric default is applied');
SELECT is((SELECT flag FROM dv_probe WHERE label = 'r1'), true,
    'a boolean default is applied');
SELECT ok((SELECT happened_at FROM dv_probe WHERE label = 'r1') BETWEEN now() - interval '1 minute' AND now() + interval '1 minute',
    'now() is applied as an expression');
SELECT is((SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
            JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
           WHERE d.adrelid = 'dv_probe'::regclass AND a.attname = 'note'),
    '''a (b)''::text', 'the column default is stored as a quoted literal');
SELECT isnt((SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
              JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
             WHERE d.adrelid = 'dv_probe'::regclass AND a.attname = 'created'),
    'CURRENT_DATE', 'CURRENT_DATE on a date field is stored as the UTC expression, not the session''s CURRENT_DATE');

-- =====================================================
-- GROUP 4: generated compute/validate trigger quoting
-- =====================================================
UPDATE entities
   SET validation_rules = $$[{"code":"99401","message":"50% off isn't allowed","jsonlogic":{"!=":[{"var":"note"},"bad"]}}]$$::jsonb,
       computed_fields  = $$[{"name":"it's computed","jsonlogic":{"var":"note"}}]$$::jsonb
 WHERE table_name = 'dv_probe';

SELECT lives_ok($$INSERT INTO dv_probe (label, note) VALUES ('r2', 'fine')$$,
    'rules whose name and message contain quotes and percent signs compile and pass');
SELECT throws_ok($$INSERT INTO dv_probe (label, note) VALUES ('r3', 'bad')$$,
    '99401', $$50% off isn't allowed$$,
    'a failing rule raises its message verbatim (percent sign and quote intact)');
SELECT throws_like($$INSERT INTO dv_probe (label, note) VALUES ('r4', 'bad')$$,
    '%50\% off isn''t allowed%',
    'the rule message survives as the exception text');

-- A dollar tag in rule text is text. The generated bodies are dollar-quoted,
-- and a fixed tag ($RULES$, $SEL$) inside a message or a rule would have ended
-- the body early and handed the rest of the text to EXECUTE as SQL run by the
-- owner; dd_dollar_quote derives the tag from the body instead.
UPDATE entities
   SET validation_rules = $$[{"code": "99402",
                              "message": "$RULES$ LANGUAGE plpgsql; DROP TABLE dv_probe; CREATE FUNCTION x() RETURNS void AS $RULES$ BEGIN END",
                              "jsonlogic": {"!=": [{"var": "note"}, "$TRIG$"]}}]$$::jsonb,
       computed_fields  = $$[{"name": "it's computed", "jsonlogic": {"cat": ["$RULES$", {"var": "note"}]}}]$$::jsonb,
       select_rule      = $$ {"!=": [{"var": "label"}, "$SEL$ LANGUAGE sql; DROP TABLE dv_probe; CREATE FUNCTION y() RETURNS void AS $SEL$ BEGIN END"]} $$::jsonb
 WHERE table_name = 'dv_probe';

SELECT has_table('public', 'dv_probe',
    'a dollar tag in a rule, a message and a select rule ends no generated body: the table they name survives');
SELECT ok((SELECT prosrc LIKE '%$RULES$ LANGUAGE plpgsql; DROP TABLE%' FROM pg_proc WHERE proname = 'record_rules_dv_probe'),
    'the tag sits inside the generated rule function as text');
SELECT ok((SELECT prosrc LIKE '%$SEL$ LANGUAGE sql; DROP TABLE%' FROM pg_proc WHERE proname = 'select_rule_dv_probe' AND pronargs = 2),
    'and inside the generated select rule function');
SELECT throws_ok($$INSERT INTO dv_probe (label, note) VALUES ('r6', '$TRIG$')$$,
    '99402', NULL,
    'a rule whose literal is a dollar tag compares it as text');
SELECT lives_ok($$INSERT INTO dv_probe (label, note) VALUES ('r7', 'fine')$$,
    'and passes other values');

-- The permission name of a leading has_permission term goes into the
-- policies themselves (build_select_rule_policy checks it once per statement),
-- as a literal: unquoted, this name would close the call and OR true into
-- every policy of the entity.
UPDATE entities
   SET select_rule = $$ {"or": [{"has_permission": "x')) OR true OR ((rbac.has_permission('y"}, {"!=": [{"var": "label"}, "hidden"]}]} $$::jsonb
 WHERE table_name = 'dv_probe';

SELECT is(
    (SELECT count(*)::int FROM pg_policies
      WHERE tablename = 'dv_probe' AND cmd IN ('SELECT', 'UPDATE', 'DELETE')
        AND strpos(qual, $q$rbac.has_permission('x'')) OR true OR ((rbac.has_permission(''y'::text)$q$) > 0),
    3,
    'a permission name in a leading has_permission term is one quoted literal in the SELECT, UPDATE and DELETE policies');

-- Back to the rules of the first part of this group for what follows.
UPDATE entities
   SET validation_rules = $$[{"code":"99401","message":"50% off isn't allowed","jsonlogic":{"!=":[{"var":"note"},"bad"]}}]$$::jsonb,
       computed_fields  = $$[{"name":"it's computed","jsonlogic":{"var":"note"}}]$$::jsonb,
       select_rule      = '{}'::jsonb
 WHERE table_name = 'dv_probe';

-- =====================================================
-- GROUP 5: changing and clearing a default
-- =====================================================
-- A blank default restores the zero value of a NOT NULL column instead of
-- dropping the default, and the label column is the one core field whose
-- default can be changed, so a default set on it by mistake can be cleared.
CREATE FUNCTION pg_temp.column_default(p_column TEXT) RETURNS TEXT AS $f$
    SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'dv_probe'::regclass AND a.attname = p_column
$f$ LANGUAGE sql;

SELECT lives_ok($$UPDATE fields SET default_value = 'Offer' WHERE table_name = 'dv_probe' AND field_name = 'label'$$,
    'the label column takes a default');
INSERT INTO dv_probe (note) VALUES ('r5');
SELECT is((SELECT label FROM dv_probe WHERE note = 'r5'), 'Offer',
    'the label default is applied');
SELECT lives_ok($$UPDATE fields SET default_value = '' WHERE table_name = 'dv_probe' AND field_name = 'label'$$,
    'the label default can be cleared with an empty string');
SELECT is(pg_temp.column_default('label'), '''''::text',
    'a cleared label default falls back to the empty string');
UPDATE fields SET default_value = 'Offer' WHERE table_name = 'dv_probe' AND field_name = 'label';
SELECT lives_ok($$UPDATE fields SET default_value = NULL WHERE table_name = 'dv_probe' AND field_name = 'label'$$,
    'the label default can be cleared with NULL');
SELECT is(pg_temp.column_default('label'), '''''::text',
    'clearing with NULL keeps a default on the NOT NULL column');
SELECT lives_ok($$UPDATE fields SET default_value = '' WHERE table_name = 'dv_probe' AND field_name = 'note'$$,
    'an ordinary text default can be cleared with an empty string');
SELECT is(pg_temp.column_default('note'), '''''::text',
    'a cleared text default falls back to the empty string');
SELECT lives_ok($$UPDATE fields SET default_value = '' WHERE table_name = 'dv_probe' AND field_name = 'created'$$,
    'a date default can be cleared');
SELECT is(pg_temp.column_default('created'), NULL,
    'a cleared default on a nullable format leaves no default');
SELECT throws_ok($$UPDATE fields SET default_value = 'x' WHERE table_name = 'dv_probe' AND field_name = 'id'$$,
    '90220', NULL, 'the id column default stays locked');
SELECT throws_ok($$UPDATE fields SET default_value = '2026-01-01' WHERE table_name = 'dv_probe' AND field_name = 'created_at'$$,
    '90220', NULL, 'an audit column default stays locked');

-- =====================================================
-- GROUP 6: relative days and moments, end to end
-- =====================================================
-- Quoted, 'today' would be converted once, when the default is set, and every
-- record would get the day the field was saved. Each of these columns holds an
-- expression that reads the UTC day or clock on every insert. The rows are
-- written at UTC+14 and at UTC-11: at any hour one of the two zones is on
-- another calendar day than UTC, so a default that read the session's zone
-- would differ there.
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, default_value) VALUES
    ('dv_probe', 'd_today',     'D today',     'date',      100, 'default', 'default', 'today'),
    ('dv_probe', 'd_tomorrow',  'D tomorrow',  'date',      110, 'default', 'default', 'Tomorrow'),
    ('dv_probe', 'd_yesterday', 'D yesterday', 'date',      120, 'default', 'default', 'yesterday'),
    ('dv_probe', 'd_dollar',    'D dollar',    'date',      130, 'default', 'default', '$today'),
    ('dv_probe', 'd_curdate',   'D curdate',   'date',      140, 'default', 'default', 'CURRENT_DATE'),
    ('dv_probe', 'ts_today',    'TS today',    'date-time', 150, 'default', 'default', 'today'),
    ('dv_probe', 'ts_curdate',  'TS curdate',  'date-time', 160, 'default', 'default', 'CURRENT_DATE'),
    ('dv_probe', 'ts_now',      'TS now',      'date-time', 170, 'default', 'default', '$now'),
    ('dv_probe', 't_now',       'T now',       'time',      180, 'default', 'default', 'now');

SELECT is(
    (SELECT string_agg(c, ', ' ORDER BY c)
       FROM unnest(ARRAY['d_today', 'd_tomorrow', 'd_yesterday', 'd_dollar', 'd_curdate',
                         'ts_today', 'ts_curdate', 'ts_now', 't_now']) AS c
      WHERE coalesce(pg_temp.column_default(c), '''') LIKE '''%'),
    NULL::text,
    'no relative default is stored as a literal');

SET LOCAL timezone = 'Pacific/Kiritimati';
INSERT INTO dv_probe (label) VALUES ('r8');
SET LOCAL timezone = 'Pacific/Pago_Pago';
INSERT INTO dv_probe (label) VALUES ('r9');
SET LOCAL timezone = 'UTC';

SELECT is(
    (SELECT count(*)::int FROM dv_probe
      WHERE label IN ('r8', 'r9')
        AND d_today     = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
        AND d_tomorrow  = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date + 1
        AND d_yesterday = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date - 1
        AND d_dollar    = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
        AND d_curdate   = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date),
    2,
    'the date defaults hold the UTC day, whatever the time zone of the session that writes');
SELECT is(
    (SELECT count(*)::int FROM dv_probe
      WHERE label IN ('r8', 'r9')
        AND ts_today   = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date::timestamp AT TIME ZONE 'UTC'
        AND ts_curdate = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date::timestamp AT TIME ZONE 'UTC'
        AND ts_now     = CURRENT_TIMESTAMP),
    2,
    'today and CURRENT_DATE on a date-time field are UTC midnight, $now is the moment');
SELECT is(
    (SELECT count(*)::int FROM dv_probe
      WHERE label IN ('r8', 'r9') AND t_now = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::time),
    2,
    'now on a time field is the UTC clock');

SELECT lives_ok($$UPDATE fields SET default_value = 'yesterday' WHERE table_name = 'dv_probe' AND field_name = 'd_today'$$,
    'a default can be changed to a relative day');
INSERT INTO dv_probe (label) VALUES ('r10');
SELECT is((SELECT d_today FROM dv_probe WHERE label = 'r10'), (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date - 1,
    'and the changed default is the expression');

-- Any other default naming one of the words would be quoted, and PostgreSQL
-- would store one fixed day or refuse it: refused when the field is saved.
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
      VALUES ('dv_probe', 'bad_ts', 'Bad', 'date-time', 200, 'tomorrow 09:00')$$,
    '90284', NULL, 'a word with a time of day is refused');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
      VALUES ('dv_probe', 'bad_d', 'Bad', 'date', 210, '$today + 1')$$,
    '90284', NULL, 'arithmetic on a word is refused');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
      VALUES ('dv_probe', 'bad_t', 'Bad', 'time', 220, 'today')$$,
    '90284', NULL, 'a day on a time field is refused');
SELECT throws_ok(
    $$UPDATE fields SET default_value = 'now + 1' WHERE table_name = 'dv_probe' AND field_name = 'ts_now'$$,
    '90284', NULL, 'and so is changing a default to such a value');
SELECT is(
    catch_error_hint($$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
                       VALUES ('dv_probe', 'bad_ts2', 'Bad', 'date-time', 230, 'tomorrow 09:00')$$) - 'hint',
    '{"table": "dv_probe", "field_name": "bad_ts2", "default_value": "tomorrow 09:00"}'::jsonb,
    '90284 names the table, the field and the default in its hint');
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
      VALUES ('dv_probe', 'ok_ts', 'Ok', 'date-time', 240, 'now()')$$,
    'now() on a date-time field is accepted');
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, default_value)
      VALUES ('dv_probe', 'ok_text', 'Ok', 'text', 250, 'today')$$,
    'today on a text field is accepted');
SELECT is(pg_temp.column_default('ok_text'), '''today''::text',
    'and stored as the word');

SELECT is((public.get_schema('dv_probe')::jsonb)->'properties'->'d_tomorrow'->>'default', 'Tomorrow',
    'get_schema returns a relative default as written');

SELECT * FROM finish();
ROLLBACK;
