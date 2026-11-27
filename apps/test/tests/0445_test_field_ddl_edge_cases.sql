-- The refusals and the less common paths of the field and entity DDL triggers:
-- what add_dd_field, update_dd_field and delete_dd_field do with a default
-- outside an enum's list, a reference to nothing, a constraint that is already
-- there, a column that is missing, a unique flag turned on, a field renamed or
-- deleted while it carries a unique index; what the managed flip
-- (enable_dd_table, apply_field_ddl) builds for a fresh entity and for a table
-- that already has rows; and the small guards around them.
--
-- Fixtures that need the table owner (a column or constraint made by hand, a
-- disabled trigger, a view of another author) use RESET ROLE. Each part
-- creates its own entities; the transaction is rolled back.
BEGIN;

SELECT plan(72);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES
    ('fd_target', 'Target', 'Targets', 1),
    ('fd_main',   'Main',   'Mains',   1);
INSERT INTO fd_main (label) VALUES ('first');

-- =====================================================
-- PART 1: adding a field
-- =====================================================
-- A default outside the enum's list is refused while the table has rows: every
-- existing row would take it and break the check the field is about to get.
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, enum_values, default_value)
      VALUES ('fd_main', 'status', 'Status', 'enum', '["open", "closed"]', 'zzz')$$,
    '23514', 'check constraint "fd_main_status_check" of relation "fd_main" is violated by some row',
    'an enum field whose default is outside its list is refused on a table with rows');
SELECT hasnt_column('public', 'fd_main', 'status', 'and the refused field leaves no column');
SELECT is((SELECT count(*)::int FROM fields WHERE table_name = 'fd_main' AND field_name = 'status'), 0,
    'and no fields row');
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, enum_values, default_value)
      VALUES ('fd_main', 'status', 'Status', 'enum', '["open", "closed"]', 'open')$$,
    'the same field with a default from its list is accepted');

-- A field name is unique within its table. The key of fields is the generated
-- id table_name.field_name, so fields_pkey refuses the second row before the
-- add trigger could try to add the column a second time;
-- fields_table_field_unique states the same rule on the pair. Only the code
-- is pinned: the rule holds whichever of the two enforces it.
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format)
      VALUES ('fd_main', 'status', 'Status again', 'text')$$,
    '23505', NULL,
    'a second field with the same name on the same table is refused');

-- Every entity has exactly one primary key field, and a unique index on fields
-- keeps it that way before the add trigger could ask.
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, is_pk)
      VALUES ('fd_main', 'second_key', 'Second key', 'int32', TRUE)$$,
    '23505', 'duplicate key value violates unique constraint "one_pk_per_table_idx"',
    'a second primary key field is refused by the one-key-per-table index');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
      VALUES ('fd_main', 'nowhere_id', 'Nowhere', 'reference', 'fd_nowhere', 'restrict')$$,
    '90212', 'Referenced table ${table} not found in entities',
    'a reference to an entity that does not exist is refused');
SELECT is(
    catch_error_hint($$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
                       VALUES ('fd_main', 'nowhere_id', 'Nowhere', 'reference', 'fd_nowhere', 'restrict')$$),
    '{"table": "fd_nowhere"}'::jsonb,
    'and the refusal names the missing table');

-- A foreign key that already carries the name the field would give it stays as
-- it is: the field is added, the index is built, the existing constraint is not
-- replaced.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE fd_main ADD COLUMN owner_ref INTEGER;
ALTER TABLE fd_main ADD CONSTRAINT fd_main_owner_ref_fkey
    FOREIGN KEY (owner_ref) REFERENCES fd_target (id) ON DELETE CASCADE;
SELECT authenticate_as('user3');

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
      VALUES ('fd_main', 'owner_ref', 'Owner', 'reference', 'fd_target', 'restrict')$$,
    'a reference field is added over a column whose foreign key already exists');
SELECT is(
    (SELECT confdeltype::text FROM pg_constraint WHERE conname = 'fd_main_owner_ref_fkey'),
    'c',
    'and the existing foreign key keeps its own delete action');
SELECT ok(
    EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_fd_main_owner_ref'),
    'and the index on the column is built');

-- The unique index of a text field leaves out the empty string; any other
-- format has no such value, so only NULL is left out.
INSERT INTO fields (table_name, field_name, title, format, unique_value) VALUES
    ('fd_main', 'sku',    'SKU',    'text',  TRUE),
    ('fd_main', 'serial', 'Serial', 'int32', TRUE);

SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_main_sku_unique'),
    'CREATE UNIQUE INDEX fd_main_sku_unique ON public.fd_main USING btree (sku) WHERE ((sku IS NOT NULL) AND (sku <> ''''::text))',
    'a unique text field is indexed without its empty strings');
SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_main_serial_unique'),
    'CREATE UNIQUE INDEX fd_main_serial_unique ON public.fd_main USING btree (serial) WHERE (serial IS NOT NULL)',
    'a unique number field is indexed without its NULLs only');

-- =====================================================
-- PART 2: updating and deleting a field
-- =====================================================
SELECT throws_ok(
    $$UPDATE fields SET is_pk = FALSE WHERE table_name = 'fd_main' AND field_name = 'id'$$,
    '90222', 'Cannot change primary key status of existing field',
    'the primary key status of a field cannot be changed');

-- A core field of an entity that is not managed has no BEFORE-trigger check on
-- its format, so the refusal comes from the update trigger itself. The rows are
-- made by the owner, because only a BYPASSRLS role may set a ctype.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed)
VALUES ('fd_unmanaged', 'Unmanaged', 'Unmanaged', 1, FALSE);
INSERT INTO fields (table_name, field_name, title, format, is_pk, ctype, input_type, field_order)
VALUES ('fd_unmanaged', 'id', 'Id', 'int32', TRUE, 'id', 'disabled', 10);
SELECT authenticate_as('user3');

SELECT throws_ok(
    $$UPDATE fields SET format = 'int64' WHERE table_name = 'fd_unmanaged' AND field_name = 'id'$$,
    '90219', 'Cannot change format of core system field ${field_name}',
    'the format of a core field of an unmanaged entity cannot be changed');
SELECT is(
    catch_error_hint($$UPDATE fields SET format = 'int64' WHERE table_name = 'fd_unmanaged' AND field_name = 'id'$$),
    '{"field_name": "id"}'::jsonb,
    'and the refusal names the field');

-- A field whose column is missing from a managed table gets it back on its next
-- update, built from the values the update carries.
INSERT INTO fields (table_name, field_name, title, format) VALUES ('fd_main', 'note', 'Note', 'text');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE fd_main DROP COLUMN note;
SELECT authenticate_as('user3');

SELECT hasnt_column('public', 'fd_main', 'note', 'the column of the field is gone');
UPDATE fields SET description = 'A free-text note' WHERE table_name = 'fd_main' AND field_name = 'note';
SELECT is(
    (SELECT data_type FROM information_schema.columns WHERE table_name = 'fd_main' AND column_name = 'note'),
    'text',
    'an update of the field builds the missing column');
SELECT is(
    col_description('public.fd_main'::regclass,
        (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.fd_main'::regclass AND attname = 'note')),
    E'Note (text)\n\nA free-text note',
    'and its comment comes from the updated values');

-- The BEFORE trigger refuses a format change that would change the column's
-- type; the update trigger repeats the refusal for a caller that got past it.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE fields DISABLE TRIGGER validate_field_rename_and_format_trigger;
SELECT authenticate_as('user3');

SELECT throws_ok(
    $$UPDATE fields SET format = 'int32' WHERE table_name = 'fd_main' AND field_name = 'note'$$,
    '90223',
    'Cannot change format of field ${field_name} from ${old_format} to ${new_format} because it would require changing the column type from ${old_type} to ${new_type}. Drop and recreate the field instead.',
    'the update trigger refuses a format change that alters the column type');
SELECT is(
    catch_error_hint($$UPDATE fields SET format = 'int32' WHERE table_name = 'fd_main' AND field_name = 'note'$$),
    '{"field_name": "note", "old_format": "text", "new_format": "int32", "old_type": "TEXT", "new_type": "INTEGER"}'::jsonb,
    'and names both formats and both types');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE fields ENABLE TRIGGER validate_field_rename_and_format_trigger;
SELECT authenticate_as('user3');

-- A reference to a text key becomes a plain text field: the column keeps its
-- type and loses its foreign key and the index built for it. While the entity
-- names the field as its label spine the change is refused, because a spine
-- that is no reference composes nothing; label_parent is cleared first.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type) VALUES ('fd_keyed', 'Keyed', 'Keyed', 1, 'text');
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fd_child', 'Child', 'Children', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
VALUES ('fd_child', 'keyed_id', 'Keyed', 'reference', 'fd_keyed', 'restrict');
UPDATE entities SET label_parent = 'keyed_id' WHERE table_name = 'fd_child';
INSERT INTO fd_keyed (id, label) VALUES ('k1', 'Parent One');
INSERT INTO fd_child (label, keyed_id) VALUES ('child', 'k1');

SELECT is((SELECT public._label(c) FROM fd_child c), 'Parent One › child',
    'a child is labeled with its parent through the label spine');

SELECT is(
    catch_error($$UPDATE fields SET format = 'text', reference_table = '', reference_delete_mode = ''
                   WHERE table_name = 'fd_child' AND field_name = 'keyed_id'$$) ->> 'code',
    '90277',
    'a reference that is the label spine of its entity cannot become text');

UPDATE entities SET label_parent = '' WHERE table_name = 'fd_child';
UPDATE fields SET format = 'text', reference_table = '', reference_delete_mode = ''
 WHERE table_name = 'fd_child' AND field_name = 'keyed_id';

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_child_keyed_id_fkey'),
    'a reference turned into text loses its foreign key');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_fd_child_keyed_id'),
    'and the index built for it');
SELECT is((SELECT keyed_id FROM fd_child), 'k1', 'and keeps its values');

-- And back: the text column turned into a reference again gets both its
-- foreign key and its index. A reference without the index would make every
-- delete of a fd_keyed row scan fd_child for referencing rows.
UPDATE fields SET format = 'reference', reference_table = 'fd_keyed', reference_delete_mode = 'restrict'
 WHERE table_name = 'fd_child' AND field_name = 'keyed_id';

SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_child_keyed_id_fkey'),
    'a text field turned into a reference gets its foreign key');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_fd_child_keyed_id'),
    'and the index on the column');

-- unique_value turned on for a field that already exists
INSERT INTO fields (table_name, field_name, title, format) VALUES
    ('fd_main', 'code2', 'Code', 'text'),
    ('fd_main', 'qty2',  'Qty',  'int32');
UPDATE fields SET unique_value = TRUE WHERE table_name = 'fd_main' AND field_name IN ('code2', 'qty2');

SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_main_code2_unique'),
    'CREATE UNIQUE INDEX fd_main_code2_unique ON public.fd_main USING btree (code2) WHERE ((code2 IS NOT NULL) AND (code2 <> ''''::text))',
    'a unique flag turned on for a text field indexes it without its empty strings');
SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_main_qty2_unique'),
    'CREATE UNIQUE INDEX fd_main_qty2_unique ON public.fd_main USING btree (qty2) WHERE (qty2 IS NOT NULL)',
    'and for a number field without its NULLs only');

-- A rename takes the unique index along.
UPDATE fields SET field_name = 'code3' WHERE table_name = 'fd_main' AND field_name = 'code2';

SELECT is(
    (SELECT string_agg(indexname, ', ' ORDER BY indexname) FROM pg_indexes
      WHERE tablename = 'fd_main' AND indexname IN ('fd_main_code2_unique', 'fd_main_code3_unique')),
    'fd_main_code3_unique',
    'renaming a unique field renames its index');

-- Deleting the field takes the index and the column with it.
DELETE FROM fields WHERE table_name = 'fd_main' AND field_name = 'code3';

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'fd_main_code3_unique'),
    'deleting a unique field drops its index');
SELECT hasnt_column('public', 'fd_main', 'code3', 'and its column');

-- =====================================================
-- PART 3: the managed flip
-- =====================================================
-- A fresh entity with its field rows written first and managed switched on:
-- every field gets its column, key, check and index in one pass.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed)
VALUES ('fd_flip', 'Flip', 'Flips', 1, FALSE);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, unique_value, enum_values) VALUES
    ('fd_flip', 'ref_r', 'Restrict', 'reference', 'fd_target', 'restrict', FALSE, NULL),
    ('fd_flip', 'par_c', 'Cascade',  'parent',    'fd_target', 'cascade',  FALSE, NULL),
    ('fd_flip', 'ref_u', 'Unique',   'reference', 'fd_target', 'restrict', TRUE,  NULL),
    ('fd_flip', 'us',    'Text',     'text',      '',          '',         TRUE,  NULL),
    ('fd_flip', 'ui',    'Number',   'int32',     '',          '',         TRUE,  NULL),
    ('fd_flip', 'en',    'Enum',     'enum',      '',          '',         FALSE, '["a", "b"]');
UPDATE entities SET managed = TRUE WHERE table_name = 'fd_flip';

SELECT is(
    (SELECT string_agg(conname || ':' || confdeltype::text, ', ' ORDER BY conname) FROM pg_constraint
      WHERE conrelid = 'fd_flip'::regclass AND contype = 'f'),
    'fd_flip_par_c_fkey:c, fd_flip_ref_r_fkey:r, fd_flip_ref_u_fkey:r',
    'the flip gives a reference its restrict action and a parent its cascade action');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_flip_en_check' AND contype = 'c'),
    'and an enum its check');
SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_flip_us_unique'),
    'CREATE UNIQUE INDEX fd_flip_us_unique ON public.fd_flip USING btree (us) WHERE ((us IS NOT NULL) AND (us <> ''''::text))',
    'and a unique text field its index without empty strings');
SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_flip_ui_unique'),
    'CREATE UNIQUE INDEX fd_flip_ui_unique ON public.fd_flip USING btree (ui) WHERE (ui IS NOT NULL)',
    'and a unique number field its index without NULLs');
SELECT is(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'fd_flip_ref_u_unique'),
    'CREATE UNIQUE INDEX fd_flip_ref_u_unique ON public.fd_flip USING btree (ref_u) WHERE (ref_u IS NOT NULL)',
    'and a unique reference to an integer key its index without NULLs');

-- A table that already exists and has rows is adopted without touching them.
-- A column the field rows add gets what it can: a required field with no
-- default stays unenforced because the rows hold no value for it, and a
-- foreign key whose name the table already uses for another column is left
-- alone. A blank label in the rows keeps the label unenforced too, although the
-- label has no field row yet.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
CREATE TABLE public.fd_adopt (
    id BIGSERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    other INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE public.fd_adopt_filled (
    id BIGSERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.fd_adopt OWNER TO semantius_owner;
        ALTER SEQUENCE public.fd_adopt_id_seq OWNER TO semantius_owner;
        ALTER TABLE public.fd_adopt_filled OWNER TO semantius_owner;
        ALTER SEQUENCE public.fd_adopt_filled_id_seq OWNER TO semantius_owner;
    END IF;
END $$;
ALTER TABLE fd_adopt ADD CONSTRAINT fd_adopt_fk_x_fkey
    FOREIGN KEY (other) REFERENCES fd_target (id) ON DELETE CASCADE;
INSERT INTO fd_adopt (label) VALUES ('');
INSERT INTO fd_adopt_filled (label) VALUES ('filled');
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, managed) VALUES
    ('fd_adopt',        'Adopt',        'Adopts',        1, FALSE),
    ('fd_adopt_filled', 'Adopt filled', 'Adopts filled', 1, FALSE);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, input_type, default_value) VALUES
    ('fd_adopt', 'fk_x',   'FK',          'reference', 'fd_target', 'restrict', 'default',  ''),
    ('fd_adopt', 'req',    'Required',    'text',      '',          '',         'required', ''),
    ('fd_adopt', 'req_ok', 'Required ok', 'text',      '',          '',         'required', 'filled');
UPDATE entities SET managed = TRUE WHERE table_name IN ('fd_adopt', 'fd_adopt_filled');

SELECT is(
    (SELECT conname || ':' || confdeltype::text || ':' || a.attname
       FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.conname = 'fd_adopt_fk_x_fkey'),
    'fd_adopt_fk_x_fkey:c:other',
    'a foreign key name the table already uses for another column is left on that column');
SELECT has_column('public', 'fd_adopt', 'fk_x', 'and the new column is added');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_fd_adopt_fk_x'),
    'and its index is built');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_adopt_req_assert'),
    'a required field no row has a value for stays unenforced');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_adopt_req_ok_assert'),
    'a required field with a real default is enforced');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_adopt_label_assert'),
    'a label that rows leave blank stays unenforced');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fd_adopt_filled_label_assert'),
    'a label every row fills is enforced');

-- =====================================================
-- PART 4: policies, search vector, enum values
-- =====================================================
SELECT throws_ok(
    $$SELECT create_entity_policies('fd_nothing')$$,
    '42501', 'permission denied for function create_entity_policies',
    'the policy builder is not callable by the request role');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT throws_ok(
    $$SELECT create_entity_policies('fd_nothing')$$,
    '90231', 'Table ${table} is not an entity',
    'creating policies for a name that is not an entity is refused');
SELECT is(
    catch_error_hint($$SELECT create_entity_policies('fd_nothing')$$),
    '{"table": "fd_nothing"}'::jsonb,
    'and the refusal names the table');
SELECT authenticate_as('user3');

-- The permission policies exist only on a managed entity's table, so a change of
-- edit_permission on an unmanaged one is just the metadata.
SELECT lives_ok($$UPDATE entities SET edit_permission = 'nwind:manage' WHERE table_name = 'fd_unmanaged'$$,
    'edit_permission of an unmanaged entity can be changed');
SELECT is((SELECT edit_permission FROM entities WHERE table_name = 'fd_unmanaged'), 'nwind:manage',
    'and the entity row carries the new value');
SELECT is((SELECT count(*)::int FROM pg_policies WHERE tablename = 'fd_unmanaged'), 0,
    'and no policy exists for it');

-- An entity with no searchable field keeps no search vector, and asking for one
-- to be rebuilt changes nothing.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fd_plain', 'Plain', 'Plains', 1);
SELECT has_column('public', 'fd_plain', 'search_vector', 'a new entity has a search vector for its label');
UPDATE fields SET searchable = FALSE WHERE table_name = 'fd_plain' AND field_name = 'label';
SELECT hasnt_column('public', 'fd_plain', 'search_vector', 'the vector goes when no field is searchable');

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT lives_ok($$SELECT update_search_vector_column('fd_plain')$$,
    'rebuilding the vector of an entity with no searchable field and no vector is accepted');
SELECT hasnt_column('public', 'fd_plain', 'search_vector', 'and it creates no vector');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'fd_plain_search_vector_idx'),
    'and no index');
SELECT authenticate_as('user3');

SELECT is(effective_enum_values('default', NULL::jsonb), NULL::jsonb,
    'the effective values of NULL are NULL');
SELECT is(effective_enum_values('default', '[]'::jsonb), '[]'::jsonb,
    'the effective values of an empty list are the empty list');
SELECT is(effective_enum_values('default', '{"a": 1}'::jsonb), '{"a": 1}'::jsonb,
    'the effective values of something that is not a list are returned as they are');
SELECT is(effective_enum_values('default', '["a", "b"]'::jsonb), '["a", "b", ""]'::jsonb,
    'an optional enum gets the empty value added');
SELECT is(effective_enum_values('required', '["a", "b"]'::jsonb), '["a", "b"]'::jsonb,
    'a required enum does not');

-- =====================================================
-- PART 5: families
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix)
VALUES ('fd_fam', 'Family', 'Families', 1, 'typeid', 'fdfam');
INSERT INTO fields (table_name, field_name, title, format, input_type, enum_values)
VALUES ('fd_fam', 'st', 'State', 'enum', 'required', '["a", "b"]');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('fd_part', 'Part', 'Parts', 1, 'has_a', 'fd_fam');
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fd_taken', 'Taken', 'Taken', 1);

-- A derived entity needs both of its names free.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
CREATE TABLE public.fd_gone_ext (x INTEGER);
SELECT authenticate_as('user3');

SELECT throws_ok(
    $$UPDATE entities SET table_name = 'fd_taken' WHERE table_name = 'fd_part'$$,
    '90250', 'Table name ${relation} is already in use',
    'a derived entity cannot be renamed to a name another table has');
SELECT is(
    catch_error_hint($$UPDATE entities SET table_name = 'fd_taken' WHERE table_name = 'fd_part'$$),
    '{"relation": "fd_taken"}'::jsonb,
    'and the refusal names that table');
SELECT is(
    catch_error_hint($$UPDATE entities SET table_name = 'fd_gone' WHERE table_name = 'fd_part'$$),
    '{"relation": "fd_gone_ext"}'::jsonb,
    'nor to a name whose extension table is taken, and the refusal names it');
SELECT is((SELECT count(*)::int FROM entities WHERE table_name = 'fd_part'), 1,
    'a refused rename leaves the entity under its name');

-- The required checks of existing fields are installed one table at a time,
-- after a given name. Past the last name there is nothing left.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT p_table FROM dd_install_missing_checks('~')), NULL,
    'past the last table the installer names none');
SELECT is((SELECT p_skipped FROM dd_install_missing_checks('~')), '[]'::jsonb,
    'and skips none');

-- A required enum without an explicit default whose column default is not ''
-- is reset to '', and the family has to be rebuilt with it. While a view of
-- another author is built on a family view, the rebuild is refused: the table
-- is skipped and reported, and its default stays as it was.
ALTER TABLE fd_fam ALTER COLUMN st SET DEFAULT 'a';
CREATE VIEW public.fd_report AS SELECT id FROM public.fd_part;

SELECT is((SELECT p_table FROM dd_install_missing_checks('fd_fal')), 'fd_fam',
    'the installer takes the next table after the given name');
SELECT is((SELECT p_skipped -> 0 ->> 'reason' FROM dd_install_missing_checks('fd_fal')),
    'This change drops ${views}, and with them ${dependents}, which the dictionary did not create',
    'a table whose family cannot be rebuilt is skipped and reported');
SELECT is(
    (SELECT column_default FROM information_schema.columns WHERE table_name = 'fd_fam' AND column_name = 'st'),
    '''a''::text',
    'and its column default is left as it was');
DROP VIEW public.fd_report;
SELECT is((SELECT p_skipped FROM dd_install_missing_checks('fd_fal')), '[]'::jsonb,
    'once the view is gone the table is handled');
SELECT is(
    (SELECT column_default FROM information_schema.columns WHERE table_name = 'fd_fam' AND column_name = 'st'),
    '''''::text',
    'and the default is reset');

SELECT * FROM finish();
ROLLBACK;
