-- Required fields: a field with input_type 'required' refuses a missing value at the
-- table, so every writer is covered, not only forms. What "missing" means depends on
-- the format: NULL for the nullable formats, '' or whitespace for text, empty JSON, and
-- a rating of 0. Numbers and booleans have no missing value.
--
-- Writes run as user3, through the request role, because a required check calls its
-- raising function as the writer. Fixtures that need the owner use RESET ROLE.
BEGIN;

SELECT plan(117);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id)
SELECT t, t, t, 1
  FROM unnest(ARRAY['rq_target', 'rq_ref_int', 'rq_ref_text', 'rq_date', 'rq_dt', 'rq_text', 'rq_email',
                    'rq_json', 'rq_object', 'rq_array', 'rq_logic', 'rq_rating', 'rq_binary', 'rq_enum',
                    'rq_num', 'rq_bool', 'rq_uuid', 'rq_default', 'rq_computed']) AS t;

INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value) VALUES
    ('rq_ref_int',  'v', 'V', 'reference', 'required', 'rq_target',   'restrict', ''),
    ('rq_ref_text', 'v', 'V', 'reference', 'required', 'permissions', 'restrict', ''),
    ('rq_date',     'v', 'V', 'date',      'required', '', '', ''),
    ('rq_dt',       'v', 'V', 'date-time', 'required', '', '', ''),
    ('rq_text',     'v', 'V', 'text',      'required', '', '', ''),
    ('rq_email',    'v', 'V', 'email',     'required', '', '', ''),
    ('rq_json',     'v', 'V', 'json',      'required', '', '', ''),
    ('rq_object',   'v', 'V', 'object',    'required', '', '', ''),
    ('rq_array',    'v', 'V', 'array',     'required', '', '', ''),
    ('rq_logic',    'v', 'V', 'jsonlogic', 'required', '', '', ''),
    ('rq_rating',   'v', 'V', 'rating',    'required', '', '', ''),
    ('rq_binary',   'v', 'V', 'binary',    'required', '', '', ''),
    ('rq_num',      'v', 'V', 'int32',     'required', '', '', ''),
    ('rq_bool',     'v', 'V', 'boolean',   'required', '', '', ''),
    ('rq_uuid',     'v', 'V', 'uuid',      'required', '', '', ''),
    ('rq_default',  'v', 'V', 'text',      'required', '', '', 'hello'),
    ('rq_computed', 'v', 'V', 'text',      'required', '', '', '');

INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values) VALUES
    ('rq_enum', 'v', 'V', 'enum', 'required', '["a", "b"]'),
    ('rq_enum', 'w', 'W', 'enum', 'default',  '["a", "b"]');
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values, default_value) VALUES
    ('rq_default', 'e', 'E', 'enum', 'required', '["a", "b"]', 'b');

UPDATE entities SET computed_fields = '[{"name": "v", "jsonlogic": {"var": "label"}}]' WHERE table_name = 'rq_computed';

INSERT INTO rq_target (label) VALUES ('target');

-- =====================================================
-- GROUP 1: missing values are refused, format by format
-- =====================================================
SELECT throws_ok($$INSERT INTO rq_ref_int (label) VALUES ('x')$$, '90258', NULL, 'reference to an integer key: omitted');
SELECT throws_ok($$INSERT INTO rq_ref_int (label, v) VALUES ('x', NULL)$$, '90258', NULL, 'reference to an integer key: NULL');
SELECT throws_ok($$INSERT INTO rq_ref_text (label) VALUES ('x')$$, '90258', NULL, 'reference to a text key: omitted');
SELECT throws_ok($$INSERT INTO rq_ref_text (label, v) VALUES ('x', NULL)$$, '90258', NULL, 'reference to a text key: NULL');
SELECT throws_ok($$INSERT INTO rq_date (label) VALUES ('x')$$, '90258', NULL, 'date: omitted');
SELECT throws_ok($$INSERT INTO rq_date (label, v) VALUES ('x', NULL)$$, '90258', NULL, 'date: NULL');
SELECT throws_ok($$INSERT INTO rq_dt (label) VALUES ('x')$$, '90258', NULL, 'date-time: omitted');
SELECT throws_ok($$INSERT INTO rq_dt (label, v) VALUES ('x', NULL)$$, '90258', NULL, 'date-time: NULL');

SELECT throws_ok($$INSERT INTO rq_text (label) VALUES ('x')$$, '90258', NULL, 'text: omitted');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('x', '')$$, '90258', NULL, 'text: empty');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('x', ' ')$$, '90258', NULL, 'text: a space');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('x', E'\t')$$, '90258', NULL, 'text: a tab');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('x', E'\n')$$, '90258', NULL, 'text: a newline');
SELECT throws_ok($$INSERT INTO rq_email (label) VALUES ('x')$$, '90258', NULL, 'any format stored as TEXT is covered: email omitted');

SELECT throws_ok($$INSERT INTO rq_json (label) VALUES ('x')$$, '90258', NULL, 'json: omitted');
SELECT throws_ok($$INSERT INTO rq_json (label, v) VALUES ('x', '{}')$$, '90258', NULL, 'json: {}');
SELECT throws_ok($$INSERT INTO rq_json (label, v) VALUES ('x', '[]')$$, '90258', NULL, 'json: []');
SELECT throws_ok($$INSERT INTO rq_json (label, v) VALUES ('x', 'null')$$, '90258', NULL, 'json: null');
SELECT throws_ok($$INSERT INTO rq_json (label, v) VALUES ('x', '""')$$, '90258', NULL, 'json: an empty string');
SELECT throws_ok($$INSERT INTO rq_object (label) VALUES ('x')$$, '90258', NULL, 'object: omitted');
SELECT throws_ok($$INSERT INTO rq_array (label) VALUES ('x')$$, '90258', NULL, 'array: omitted');
SELECT throws_ok($$INSERT INTO rq_logic (label) VALUES ('x')$$, '90258', NULL, 'jsonlogic: omitted');

SELECT throws_ok($$INSERT INTO rq_rating (label) VALUES ('x')$$, '90258', NULL, 'rating: omitted');
SELECT throws_ok($$INSERT INTO rq_rating (label, v) VALUES ('x', 0)$$, '90258', NULL, 'rating: 0 means not rated');
SELECT throws_ok($$INSERT INTO rq_binary (label, v) VALUES ('x', '')$$, '90258', NULL, 'binary: empty');
SELECT throws_ok($$INSERT INTO rq_enum (label) VALUES ('x')$$, '90258', NULL, 'enum: omitted');
SELECT throws_ok($$INSERT INTO rq_enum (label, v) VALUES ('x', '')$$, '90258', NULL, 'enum: empty');

-- =====================================================
-- GROUP 2: what is not ours stays as it is
-- =====================================================
SELECT throws_ok($$INSERT INTO rq_enum (label, v) VALUES ('x', 'zzz')$$, '23514', NULL, 'an enum value outside the list still returns 23514');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('x', NULL)$$, '23502', NULL, 'explicit NULL on a NOT NULL column is the column''s own error');
SELECT throws_ok($$INSERT INTO rq_binary (label) VALUES ('x')$$, '23502', NULL, 'a format with no column default: omitted is the column''s own error');
SELECT throws_ok($$INSERT INTO rq_uuid (label) VALUES ('x')$$, '23502', NULL, 'uuid: omitted is the column''s own error');

-- =====================================================
-- GROUP 3: real values are accepted
-- =====================================================
SELECT lives_ok($$INSERT INTO rq_ref_int (label, v) SELECT 'ok', id FROM rq_target$$, 'reference to an integer key: a value');
SELECT lives_ok($$INSERT INTO rq_ref_text (label, v) VALUES ('ok', 'public:read')$$, 'reference to a text key: a value');
SELECT lives_ok($$INSERT INTO rq_date (label, v) VALUES ('ok', '2026-01-01')$$, 'date: a value');
SELECT lives_ok($$INSERT INTO rq_dt (label, v) VALUES ('ok', '2026-01-01T00:00:00Z')$$, 'date-time: a value');
SELECT lives_ok($$INSERT INTO rq_text (label, v) VALUES ('ok', 'x')$$, 'text: a value');
SELECT lives_ok($$INSERT INTO rq_json (label, v) VALUES ('ok', '{"a": 1}')$$, 'json: a value');
SELECT lives_ok($$INSERT INTO rq_object (label, v) VALUES ('ok', '{"a": 1}')$$, 'object: a value');
SELECT lives_ok($$INSERT INTO rq_array (label, v) VALUES ('ok', '[1]')$$, 'array: a value');
SELECT lives_ok($$INSERT INTO rq_rating (label, v) VALUES ('ok', 3)$$, 'rating: a value');
SELECT lives_ok($$INSERT INTO rq_binary (label, v) VALUES ('ok', '\x01')$$, 'binary: a value');
SELECT lives_ok($$INSERT INTO rq_enum (label, v) VALUES ('ok', 'a')$$, 'enum: a value');
SELECT lives_ok($$INSERT INTO rq_enum (label, v, w) VALUES ('ok2', 'a', '')$$, 'an optional enum beside it still accepts empty');
SELECT lives_ok($$INSERT INTO rq_num (label) VALUES ('ok')$$, 'a required number: omitted takes 0, a real value');
SELECT lives_ok($$INSERT INTO rq_num (label, v) VALUES ('ok2', 0)$$, 'a required number: 0 is a real value');
SELECT lives_ok($$INSERT INTO rq_bool (label, v) VALUES ('ok', FALSE)$$, 'a required boolean: false is a real value');
SELECT lives_ok($$INSERT INTO rq_default (label) VALUES ('ok')$$, 'explicit defaults on text and enum satisfy the check when omitted');
SELECT lives_ok($$INSERT INTO rq_computed (label) VALUES ('ok')$$, 'a computed field fills a required column before the check runs');

-- =====================================================
-- GROUP 4: updates, statements and the error itself
-- =====================================================
SELECT throws_ok($$UPDATE rq_text SET v = '' WHERE label = 'ok'$$, '90258', NULL, 'an update to a missing value is refused');
SELECT throws_ok($$UPDATE rq_ref_int SET v = NULL WHERE label = 'ok'$$, '90258', NULL, 'an update of a reference to NULL is refused');
SELECT throws_ok($$INSERT INTO rq_text (label, v) VALUES ('a', 'x'), ('b', '')$$, '90258', NULL, 'one missing value fails a multi-row insert');
SELECT is((SELECT count(*)::int FROM rq_text WHERE label IN ('a', 'b')), 0, 'and no row of it is saved');
SELECT throws_ok(
    $$INSERT INTO rq_text (id, label) SELECT id, 'z' FROM rq_text WHERE label = 'ok'
      ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label$$,
    '90258', NULL, 'a partial upsert leaving a required field out is refused even when the row exists');

DO $$
DECLARE
    v_hint TEXT;
BEGIN
    INSERT INTO rq_text (label) VALUES ('x');
EXCEPTION WHEN SQLSTATE '90258' THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    PERFORM set_config('rq.hint', v_hint, true);
END $$;
SELECT is(current_setting('rq.hint')::jsonb, '{"table": "rq_text", "field_name": "v"}'::jsonb,
    '90258 names the table and the field in its hint');

-- =====================================================
-- GROUP 5: fields that get no check
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type)
VALUES ('rq_keyed', 'K', 'K', 1, 'text');
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_rule', 'R', 'R', 1), ('rq_child', 'C', 'C', 1);
INSERT INTO fields (table_name, field_name, title, format, input_type, input_type_rule)
VALUES ('rq_rule', 'v', 'V', 'text', 'required', '{"if": [{"var": "label"}, "required", "hidden"]}');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode)
VALUES ('rq_child', 'parent_id', 'Parent', 'parent', 'required', 'rq_target', 'cascade');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_keyed_id_assert'), 'a key gets no check: it is already constrained');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_rule_v_assert'), 'a field with a rule gets no check: the rule can turn required off');
SELECT lives_ok($$INSERT INTO rq_rule (label) VALUES ('x')$$, 'so a field with a rule accepts a missing value');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_child_parent_id_assert'), 'a parent gets no check');
SELECT throws_ok($$INSERT INTO rq_child (label) VALUES ('x')$$, '23503', NULL, 'an omitted parent still fails the foreign key');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_num_v_assert'), 'a number gets no check');

-- =====================================================
-- GROUP 6: changes to input_type
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_flip', 'F', 'F', 1);
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES ('rq_flip', 'v', 'V', 'text', 'default');
INSERT INTO rq_flip (label, v) VALUES ('blank', '');

SELECT throws_ok($$UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_flip' AND field_name = 'v'$$,
    '90259', NULL, 'changing to required is refused while rows have a missing value');
SELECT is((SELECT input_type FROM fields WHERE table_name = 'rq_flip' AND field_name = 'v'), 'default', 'and the field stays as it was');

UPDATE rq_flip SET v = 'x';
UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), 'changing to required adds the check once the rows are clean');
SELECT is((SELECT convalidated FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), FALSE, 'the check goes on NOT VALID, so nothing scans under the lock');
SELECT throws_ok($$INSERT INTO rq_flip (label) VALUES ('x')$$, '90258', NULL, 'and it enforces new writes at once');

CREATE TEMP TABLE rq_oid ON COMMIT DROP AS SELECT oid AS o FROM pg_constraint WHERE conname = 'rq_flip_v_assert';
UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT is((SELECT oid FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), (SELECT o FROM rq_oid), 're-saving the same mode leaves the check alone');
UPDATE fields SET default_value = 'd' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT is((SELECT oid FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), (SELECT o FROM rq_oid), 'changing the default leaves the check alone');
UPDATE fields SET format = 'email' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT is((SELECT oid FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), (SELECT o FROM rq_oid), 'a format with the same condition leaves the check alone');
UPDATE fields SET format = 'text', default_value = '' WHERE table_name = 'rq_flip' AND field_name = 'v';

UPDATE fields SET input_type = 'hidden' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), 'changing away from required drops the check');
SELECT lives_ok($$INSERT INTO rq_flip (label, v) VALUES ('empty', '')$$, 'and the field accepts a missing value again');
DELETE FROM rq_flip WHERE label = 'empty';

UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_flip' AND field_name = 'v';
UPDATE fields SET input_type_rule = '{"if": [{"var": "label"}, "required", "hidden"]}' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), 'adding a rule drops the check');
INSERT INTO rq_flip (label, v) VALUES ('empty', '');
SELECT throws_ok($$UPDATE fields SET input_type_rule = '{}' WHERE table_name = 'rq_flip' AND field_name = 'v'$$,
    '90259', NULL, 'removing the rule is refused while rows have a missing value');
DELETE FROM rq_flip WHERE label = 'empty';
UPDATE fields SET input_type_rule = '{}' WHERE table_name = 'rq_flip' AND field_name = 'v';
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_flip_v_assert'), 'removing the rule adds the check once the rows are clean');

-- =====================================================
-- GROUP 7: adding a required field to a table with rows
-- =====================================================
SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES ('rq_flip', 'n1', 'N', 'text', 'required')$$,
    '90259', NULL, 'a required field with no default is refused on a table with rows');
SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, input_type, default_value) VALUES ('rq_flip', 'n2', 'N', 'text', 'required', '   ')$$,
    '90259', NULL, 'a default that is itself missing does not help');
SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, input_type, default_value) VALUES ('rq_flip', 'n3', 'N', 'text', 'required', 'filled')$$,
    'a required field with a real default is accepted, because every row takes it');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_flip_n3_assert'), 'and it gets its check');

-- =====================================================
-- GROUP 8: required with delete mode clear
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_clear', 'C', 'C', 1);
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode)
VALUES ('rq_clear', 'c1', 'C', 'reference', 'default', 'rq_target', 'clear'),
       ('rq_clear', 'c2', 'C', 'reference', 'required', 'rq_target', 'restrict');

SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode)
                   VALUES ('rq_clear', 'c3', 'C', 'reference', 'required', 'rq_target', 'clear')$$,
    '90257', NULL, 'a new required field with delete mode clear is refused');
SELECT throws_ok($$UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_clear' AND field_name = 'c1'$$,
    '90257', NULL, 'making a clearing reference required is refused');
SELECT throws_ok($$UPDATE fields SET reference_delete_mode = 'clear' WHERE table_name = 'rq_clear' AND field_name = 'c2'$$,
    '90257', NULL, 'setting clear on a required reference is refused');

-- =====================================================
-- GROUP 9: rows that were already missing a value, and renames
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_old', 'O', 'O', 1);
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES
    ('rq_old', 'v', 'V', 'text', 'required'),
    ('rq_old', 'other', 'Other', 'text', 'default');

RESET ROLE;
ALTER TABLE rq_old DROP CONSTRAINT rq_old_v_assert;
INSERT INTO rq_old (label, v, other) VALUES ('old', '', 'o');
SELECT dd_add_required_check(f, 'rq_old') FROM fields f WHERE f.table_name = 'rq_old' AND f.field_name = 'v';
SELECT authenticate_as('user3');

SELECT is((SELECT other FROM rq_old WHERE label = 'old'), 'o', 'a row with a missing value under the check stays readable');
SELECT throws_ok($$UPDATE rq_old SET other = 'p' WHERE label = 'old'$$, '90258', NULL, 'an update of its other columns is refused');

SELECT lives_ok($$UPDATE fields SET field_name = 'renamed' WHERE table_name = 'rq_old' AND field_name = 'v'$$,
    'renaming the field is not refused because of that row');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_old_renamed_assert') AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_old_v_assert'),
    'the check moves to the new name');
DO $$
DECLARE
    v_hint TEXT;
BEGIN
    INSERT INTO rq_old (label) VALUES ('x');
EXCEPTION WHEN SQLSTATE '90258' THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    PERFORM set_config('rq.hint', v_hint, true);
END $$;
SELECT is(current_setting('rq.hint')::jsonb ->> 'field_name', 'renamed', 'the error names the field''s new name');

SELECT lives_ok($$UPDATE rq_old SET renamed = 'filled' WHERE label = 'old'$$, 'an update that fills the value works');

UPDATE entities SET table_name = 'rq_old2', plural = 'rq_old2', singular = 'rq_old2' WHERE table_name = 'rq_old';
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_old2_renamed_assert'), 'renaming the entity renames the check');
DO $$
DECLARE
    v_hint TEXT;
BEGIN
    INSERT INTO rq_old2 (label) VALUES ('x');
EXCEPTION WHEN SQLSTATE '90258' THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    PERFORM set_config('rq.hint', v_hint, true);
END $$;
SELECT is(current_setting('rq.hint')::jsonb ->> 'table', 'rq_old2', 'the error names the entity''s new name');

-- =====================================================
-- GROUP 10: labels follow the same rule
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_label', 'L', 'L', 1);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, entity_type) VALUES ('rq_link', 'J', 'J', 1, 'junction');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode)
VALUES ('rq_link', 'left_id', 'Left', 'parent', 'required', 'rq_target', 'cascade'),
       ('rq_link', 'right_id', 'Right', 'parent', 'required', 'rq_target', 'cascade');

SELECT is((SELECT input_type FROM fields WHERE table_name = 'rq_label' AND field_name = 'label'), 'required', 'an auto-generated label is required');
SELECT throws_ok($$INSERT INTO rq_label DEFAULT VALUES$$, '90258', NULL, 'so a record with no label is refused');
SELECT throws_ok($$INSERT INTO rq_link (left_id, right_id) SELECT id, id FROM rq_target$$, '90258', NULL, 'on a junction too, because nothing about a label is special');
UPDATE fields SET input_type = 'default' WHERE table_name = 'rq_link' AND field_name = 'label';
SELECT lives_ok($$INSERT INTO rq_link (left_id, right_id) SELECT id, id FROM rq_target$$, 'a junction that does not require its label says so in its metadata');
SELECT is((SELECT public._label(l) FROM rq_link l), 'target › target', 'and its label still composes from the records it links');

-- =====================================================
-- GROUP 11: is_a and has_a
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix) VALUES ('rq_fam', 'F', 'F', 1, 'typeid', 'rqfam');
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES ('rq_fam', 'base_v', 'B', 'text', 'required');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity) VALUES ('rq_fam_sub', 'S', 'S', 1, 'is_a', 'rqsub', 'rq_fam');
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES ('rq_fam_sub', 'sub_v', 'S', 'text', 'required');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity) VALUES ('rq_fam_part', 'P', 'P', 1, 'has_a', 'rq_fam');
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES ('rq_fam_part', 'part_v', 'P', 'text', 'required');

SELECT throws_ok($$INSERT INTO rq_fam_sub (label, base_v) VALUES ('x', 'b')$$, '90258', NULL, 'is_a: a write through the view missing the entity''s own field is refused');
SELECT throws_ok($$INSERT INTO rq_fam_sub (label, sub_v) VALUES ('x', 's')$$, '90258', NULL, 'is_a: a write through the view missing a base''s field is refused');
SELECT lives_ok($$INSERT INTO rq_fam_sub (label, base_v, sub_v) VALUES ('x', 'b', 's')$$, 'is_a: a complete write is accepted');
DO $$
DECLARE
    v_hint TEXT;
BEGIN
    INSERT INTO rq_fam_sub (label, base_v) VALUES ('y', 'b');
EXCEPTION WHEN SQLSTATE '90258' THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    PERFORM set_config('rq.hint', v_hint, true);
END $$;
SELECT is(current_setting('rq.hint')::jsonb ->> 'table', 'rq_fam_sub', 'the error names the entity, not its _ext table');

SELECT lives_ok($$INSERT INTO rq_fam (label, base_v) VALUES ('root', 'b')$$, 'has_a: a record without the part is accepted, because the check lives with the part');
SELECT throws_ok($$INSERT INTO rq_fam_part (id) SELECT id FROM rq_fam WHERE label = 'root'$$, '90258', NULL, 'has_a: attaching the part without its required field is refused');
SELECT lives_ok($$INSERT INTO rq_fam_part (id, part_v) SELECT id, 'p' FROM rq_fam WHERE label = 'root'$$, 'has_a: attaching it with the field is accepted');

-- =====================================================
-- GROUP 12: adoption only adds what is missing
-- =====================================================
RESET ROLE;
CREATE TABLE public.rq_adopt (
    id BIGSERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    qty INTEGER CHECK (qty > 0),
    clean TEXT NOT NULL DEFAULT 'c',
    dirty TEXT NOT NULL DEFAULT '',
    st TEXT NOT NULL DEFAULT 'a',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.rq_adopt OWNER TO semantius_owner;
        ALTER SEQUENCE public.rq_adopt_id_seq OWNER TO semantius_owner;
    END IF;
END $$;
INSERT INTO public.rq_adopt (label, qty, clean, dirty, st) VALUES ('one', 1, 'c', '', 'unlisted');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed) VALUES ('rq_adopt', 'A', 'A', 1, FALSE);
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES
    ('rq_adopt', 'qty', 'Q', 'int32', 'default'),
    ('rq_adopt', 'clean', 'C', 'text', 'required'),
    ('rq_adopt', 'dirty', 'D', 'text', 'required');
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values) VALUES
    ('rq_adopt', 'st', 'S', 'enum', 'default', '["a", "b"]');

UPDATE entities SET managed = TRUE WHERE table_name = 'rq_adopt';

SELECT is(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'rq_adopt_qty_check')), 'CHECK ((qty > 0))',
    'adoption leaves the table''s own inline check untouched');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_adopt_clean_assert'), 'a required column with clean rows gets its check');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_adopt_dirty_assert'), 'a required column with missing values is left unenforced');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_adopt_st_check'), 'an enum column gets its check although a row holds another value');
SELECT is((SELECT st FROM rq_adopt), 'unlisted', 'and no row was changed');

-- =====================================================
-- GROUP 13: required checks of existing fields, one table at a time
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
SELECT t, t, t, 1 FROM unnest(ARRAY['rq_inst_a', 'rq_inst_b', 'rq_inst_c', 'rq_inst_d']) AS t;
INSERT INTO fields (table_name, field_name, title, format, input_type) VALUES
    ('rq_inst_a', 'v', 'V', 'text', 'required'),
    ('rq_inst_b', 'v', 'V', 'text', 'required');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode) VALUES
    ('rq_inst_c', 'v', 'V', 'reference', 'default', 'rq_target', 'clear');
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values) VALUES
    ('rq_inst_d', 'v', 'V', 'enum', 'required', '["a", "b"]');

-- What an earlier release left behind: no check, and an enum's first value as default.
ALTER TABLE rq_inst_a DROP CONSTRAINT rq_inst_a_v_assert;
ALTER TABLE rq_inst_b DROP CONSTRAINT rq_inst_b_v_assert;
ALTER TABLE rq_inst_d ALTER COLUMN v SET DEFAULT 'a';
INSERT INTO rq_inst_b (label, v) VALUES ('blank', '');
ALTER TABLE fields DISABLE TRIGGER validate_required_delete_mode_trigger;
UPDATE fields SET input_type = 'required' WHERE table_name = 'rq_inst_c' AND field_name = 'v';
ALTER TABLE fields ENABLE TRIGGER validate_required_delete_mode_trigger;
ALTER TABLE rq_inst_c DROP CONSTRAINT rq_inst_c_v_assert;

SELECT is((SELECT p_table FROM dd_install_missing_checks('rq_inst_')), 'rq_inst_a', 'one call handles the next table and names it');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_inst_a_v_assert'), 'a field with no check gets one');
SELECT is((SELECT p_skipped FROM dd_install_missing_checks('rq_inst_')), '[]'::jsonb, 'a second pass finds nothing to do');

SELECT is((SELECT p_skipped -> 0 ->> 'reason' FROM dd_install_missing_checks('rq_inst_a')), 'rows have no value for it',
    'a field whose rows have missing values is skipped and reported');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_inst_b_v_assert'), 'so its writers keep working');
UPDATE rq_inst_b SET v = 'x';
SELECT is((SELECT p_skipped FROM dd_install_missing_checks('rq_inst_a')), '[]'::jsonb, 'a later pass finds it clean');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_inst_b_v_assert'), 'and adds its check');

SELECT is((SELECT p_skipped -> 0 ->> 'reason' FROM dd_install_missing_checks('rq_inst_b')), 'its delete mode is clear',
    'a required field with delete mode clear is skipped, because the check would fail every parent delete');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rq_inst_c_v_assert'), 'and gets no check');
SELECT lives_ok($$UPDATE fields SET description = 'd' WHERE table_name = 'rq_inst_c' AND field_name = 'v'$$,
    'such a field stays editable');

SELECT dd_install_missing_checks('rq_inst_c');
SELECT is((SELECT column_default FROM information_schema.columns WHERE table_name = 'rq_inst_d' AND column_name = 'v'), '''''::text',
    'a required enum''s first value default is reset, so an omitted value is refused');

-- The default of an is_a view is a copy, so the family has to be rebuilt with it.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix) VALUES ('rq_inst_e', 'E', 'E', 1, 'typeid', 'rqinste');
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values) VALUES ('rq_inst_e', 's', 'S', 'enum', 'required', '["a", "b"]');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity) VALUES ('rq_inst_e_sub', 'S', 'S', 1, 'is_a', 'rqinsts', 'rq_inst_e');
ALTER TABLE rq_inst_e ALTER COLUMN s SET DEFAULT 'a';
ALTER VIEW rq_inst_e_sub ALTER COLUMN s SET DEFAULT 'a';
SELECT dd_install_missing_checks('rq_inst_d');
SELECT is((SELECT column_default FROM information_schema.columns WHERE table_name = 'rq_inst_e_sub' AND column_name = 's'), '''''::text',
    'the is_a view takes the reset default too');

SELECT * FROM finish();
ROLLBACK;
