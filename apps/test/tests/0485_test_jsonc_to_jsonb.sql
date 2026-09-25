-- =====================================================
-- jsonc_to_jsonb (0290_ensure_entities.sql)
-- =====================================================
-- The parser every runner hands a .jsonc migration to. What it must get right
-- is what a naive comment stripper gets wrong: markers and commas inside
-- strings, escaped quotes and backslashes, a comment that ends the file, CRLF
-- line ends, a byte order mark, and a trailing comma with a comment between it
-- and the bracket. Invalid JSON must still fail.
BEGIN;

SELECT plan(10);

SELECT is(
    jsonc_to_jsonb('{"a": 1, "b": [true, null]}'),
    '{"a": 1, "b": [true, null]}'::jsonb,
    'plain JSON passes through unchanged');

SELECT is(
    jsonc_to_jsonb('{"url": "https://example.com/a//b", "c": "/* not a comment */", "d": "x // y"}'),
    '{"url": "https://example.com/a//b", "c": "/* not a comment */", "d": "x // y"}'::jsonb,
    'comment markers inside strings are kept');

SELECT is(
    jsonc_to_jsonb(E'{"q": "say \\"hi\\" // still a string", "b": "back\\\\"} // after'),
    jsonb_build_object('q', 'say "hi" // still a string', 'b', E'back\\'),
    'escaped quotes and backslashes do not end a string early');

SELECT is(
    jsonc_to_jsonb(E'// leading\n{"a": /* inline */ 1}\n// trailing comment, no newline at the end'),
    '{"a": 1}'::jsonb,
    'line and block comments are removed, including one that ends the text');

SELECT is(
    jsonc_to_jsonb(E'{\r\n  "a": 1, // x\r\n  "b": 2\r\n}\r\n'),
    '{"a": 1, "b": 2}'::jsonb,
    'CRLF line ends');

SELECT is(
    jsonc_to_jsonb(chr(65279) || '{"a": 1}'),
    '{"a": 1}'::jsonb,
    'a byte order mark is dropped');

SELECT is(
    jsonc_to_jsonb(E'{"a": [1, 2, ], "b": {"c": 3, /* x */ }, "d": [4, // y\n ], }'),
    '{"a": [1, 2], "b": {"c": 3}, "d": [4]}'::jsonb,
    'trailing commas are dropped, also with a comment before the bracket');

SELECT is(
    jsonc_to_jsonb('{"s": "a, ]", "t": "b,}"}'),
    '{"s": "a, ]", "t": "b,}"}'::jsonb,
    'a comma and a bracket inside a string are not a trailing comma');

SELECT throws_ok(
    $$SELECT jsonc_to_jsonb('{"a": }')$$,
    '22P02', NULL,
    'invalid JSON is refused by the jsonb cast');

SELECT throws_ok(
    $$SELECT jsonc_to_jsonb('{"a": "unterminated}')$$,
    '22P02', NULL,
    'an unterminated string is refused');

SELECT * FROM finish();
ROLLBACK;
