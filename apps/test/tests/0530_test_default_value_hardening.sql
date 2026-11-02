-- =====================================================
-- fields.default_value hardening (0530)
-- =====================================================
-- Regression test for the default-value SQL injection (release review S1):
-- quote_default_value() used to return any value containing "(" or "::"
-- unquoted, and the DDL triggers interpolate its result into
-- ALTER TABLE ... DEFAULT as the table owner. It now returns caller text
-- only as a quoted literal (or one of a fixed allow-list of argument-less
-- expressions), and fields.default_value carries a CHECK that rejects
-- statement separators and comment markers outright.
--
-- Also covers the generated compute/validate trigger (S13): rule code,
-- computed-field names and messages containing quotes or percent signs are
-- emitted as proper literals.
BEGIN;

SELECT plan(49);

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
SELECT is((SELECT created FROM dv_probe WHERE label = 'r1'), CURRENT_DATE,
    'CURRENT_DATE is applied as an expression');
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

-- =====================================================
-- GROUP 4: generated compute/validate trigger quoting (S13)
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

SELECT * FROM finish();
ROLLBACK;
