-- Test unique_value boolean flag on fields
-- Verify that fields with unique_value=TRUE enforce a partial unique index
-- For string types: empty string is excluded from uniqueness enforcement
-- (explicit NULL is rejected on every TEXT column, so it is never inserted here)
--
-- Target: nwind territories.territory_id (TEXT, unique_value=TRUE). The field is
-- required, and a required field refuses an empty string, so this file makes it
-- optional first: what it tests is that uniqueness leaves empty strings alone.
--
-- The next part turns unique_value on for fields that already hold rows, for
-- each kind of value: text, integer, date, date-time and uuid. The last part
-- does the same for a reference, on creation and on an existing field.
BEGIN;

SELECT plan(37);

-- Authenticate as admin user (writes territories and fields)
SELECT authenticate_as('user3');

UPDATE fields SET input_type = 'default'
 WHERE table_name = 'territories' AND field_name = 'territory_id';

-- =====================================================
-- TEST: unique index exists for territories.territory_id
-- =====================================================

-- Test 1: Unique index was created for territories.territory_id (unique_value=TRUE)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'territories'
          AND indexname = 'territories_territory_id_unique'
    ),
    'Unique index territories_territory_id_unique should exist'
);

-- =====================================================
-- TEST: Two records without territory_id can be inserted (column defaults to '', excluded from uniqueness)
-- =====================================================

-- Test 2: Insert first territory omitting territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, region_id)
      VALUES ('No Code Territory 1', 1)$$,
    'Should allow inserting territory without territory_id (defaults to empty string, not enforced by unique index)'
);

-- Test 3: Insert second territory omitting territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, region_id)
      VALUES ('No Code Territory 2', 1)$$,
    'Should allow inserting second territory without territory_id (uniqueness not enforced for empty string)'
);

-- Test 4: Insert territory with explicit empty string territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('No Code Territory 3', '', 1)$$,
    'Should allow inserting territory with empty string territory_id (not enforced by unique index)'
);

-- Test 5: Insert second territory with explicit empty string territory_id should succeed
SELECT lives_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('No Code Territory 4', '', 1)$$,
    'Should allow inserting second territory with empty string territory_id (uniqueness not enforced for empty string)'
);

-- =====================================================
-- TEST: Duplicate non-empty territory_id is rejected
-- =====================================================

-- Test 6: Insert a territory with territory_id 01581 (Westboro, already exists) should fail
SELECT throws_ok(
    $$INSERT INTO territories (territory_description, territory_id, region_id)
      VALUES ('Duplicate Westboro', '01581', 1)$$,
    '23505',
    NULL,
    'Should reject duplicate territory_id 01581 (unique constraint violation)'
);

-- =====================================================
-- TEST: unique_value flag controls index creation via trigger
-- =====================================================

-- Test 7: Updating unique_value to FALSE on territories.territory_id drops the unique index
SELECT lives_ok(
    $$UPDATE fields SET unique_value = FALSE WHERE table_name = 'territories' AND field_name = 'territory_id'$$,
    'Should allow setting unique_value=FALSE on territories.territory_id'
);

-- Test 8: Unique index should no longer exist after setting unique_value=FALSE
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'territories'
          AND indexname = 'territories_territory_id_unique'
    ),
    'Unique index territories_territory_id_unique should be dropped after unique_value set to FALSE'
);

-- =====================================================
-- unique_value turned on for an existing field
-- =====================================================
-- The rows that are there decide: the index is built over them, so a duplicate
-- among the values that count (a string field leaves out '' and every field
-- NULL; a number counts 0) refuses the change and leaves the field as it was.
-- Without duplicates the index is built and holds from then on.
--
-- Fixture: `uq_probe`, with a field of each kind and rows, created in-tx as
-- user3. The uuid field defaults to gen_random_uuid(), so every row has a
-- value of its own.

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    module_id, view_permission, edit_permission, id_column, label_column
)
VALUES (
    'uq_probe', 'Unique Probe', 'uq_probe', 'Unique Probe', 'Unique Probes',
    1, 'public:read', 'admin', 'id', 'label'
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('uq_probe', 'code', 'Code', 'text', 30),
       ('uq_probe', 'tag',  'Tag',  'text', 40),
       ('uq_probe', 'n',    'N',    'int32', 50),
       ('uq_probe', 'm',    'M',    'int32', 60),
       ('uq_probe', 'z',    'Z',    'int32', 70),
       ('uq_probe', 'due',  'Due',  'date', 80),
       ('uq_probe', 'seen', 'Seen', 'date-time', 90);

INSERT INTO fields (table_name, field_name, title, format, default_value, field_order)
VALUES ('uq_probe', 'ext', 'Ext', 'uuid', 'gen_random_uuid()', 100);

-- code: distinct, apart from the blanks. tag: 'dup' twice. n: distinct.
-- m: 7 twice. z: left at its default 0. due and seen: distinct, apart from the
-- NULLs.
INSERT INTO uq_probe (label, code, tag, n, m, due, seen) VALUES
    ('r1', 'A', 'dup', 1, 7, '2026-01-01', '2026-01-01 10:00:00+00'),
    ('r2', 'B', 'dup', 2, 7, '2026-01-02', '2026-01-02 10:00:00+00'),
    ('r3', '',  '',    3, 8, NULL,         NULL),
    ('r4', '',  '',    4, 9, NULL,         NULL);

-- A text field whose values are distinct apart from the blanks.
SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'code'$$,
    'unique_value can be turned on for a text field whose values are distinct apart from blanks'
);

SELECT ok(
    (SELECT unique_value FROM fields WHERE table_name = 'uq_probe' AND field_name = 'code'),
    'the field keeps unique_value = TRUE'
);

SELECT is(
    (SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'uq_probe_code_unique'),
    'CREATE UNIQUE INDEX uq_probe_code_unique ON public.uq_probe USING btree (code) WHERE ((code IS NOT NULL) AND (code <> ''''::text))',
    'the index over a text field leaves out NULL and the empty string'
);

SELECT throws_ok(
    $$INSERT INTO uq_probe (label, code, n, m) VALUES ('r5', 'A', 10, 20)$$,
    '23505',
    'duplicate key value violates unique constraint "uq_probe_code_unique"',
    'a value that is already there is refused once the field is unique'
);

SELECT lives_ok(
    $$INSERT INTO uq_probe (label, code, n, m) VALUES ('r6', '', 11, 21), ('r7', '', 12, 22)$$,
    'blank values stay allowed in a unique text field, any number of them'
);

-- A text field with a duplicate.
SELECT is(
    catch_error($$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'tag'$$),
    jsonb_build_object(
        'code', '23505',
        'message', 'could not create unique index "uq_probe_tag_unique"',
        'details', 'Key (tag)=(dup) is duplicated.',
        'hint', ''),
    'unique_value cannot be turned on for a text field that holds a duplicate'
);

SELECT ok(
    NOT (SELECT unique_value FROM fields WHERE table_name = 'uq_probe' AND field_name = 'tag')
    AND to_regclass('public.uq_probe_tag_unique') IS NULL,
    'a refused change leaves the field not unique and builds no index'
);

UPDATE uq_probe SET tag = 'solo' WHERE label = 'r2';

SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'tag'$$,
    'unique_value can be turned on for the same field once the duplicate is gone'
);

-- A number field: distinct values, then a duplicate.
SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'n'$$,
    'unique_value can be turned on for an integer field whose values are distinct'
);

SELECT is(
    (SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'uq_probe_n_unique'),
    'CREATE UNIQUE INDEX uq_probe_n_unique ON public.uq_probe USING btree (n) WHERE (n IS NOT NULL)',
    'the index over an integer field leaves out only NULL'
);

SELECT is(
    catch_error($$INSERT INTO uq_probe (label, n, m) VALUES ('r8', 1, 23)$$) ->> 'code',
    '23505',
    'a value that is already there is refused once an integer field is unique'
);

SELECT is(
    catch_error($$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'm'$$),
    jsonb_build_object(
        'code', '23505',
        'message', 'could not create unique index "uq_probe_m_unique"',
        'details', 'Key (m)=(7) is duplicated.',
        'hint', ''),
    'unique_value cannot be turned on for an integer field that holds a duplicate'
);

SELECT is(
    catch_error($$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'z'$$) ->> 'details',
    'Key (z)=(0) is duplicated.',
    'zero is a value for an integer field: rows left at the default 0 are duplicates');

-- A date field: distinct dates and several NULLs.
SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'due'$$,
    'unique_value can be turned on for a date field whose values are distinct apart from NULLs'
);

SELECT ok(
    to_regclass('public.uq_probe_due_unique') IS NOT NULL,
    'the date field gets its unique index'
);

SELECT lives_ok(
    $$INSERT INTO uq_probe (label, due, n, m) VALUES ('r9', NULL, 13, 24), ('r10', NULL, 14, 25)$$,
    'NULL dates stay allowed in a unique date field, any number of them'
);

SELECT is(
    catch_error($$INSERT INTO uq_probe (label, due, n, m) VALUES ('r11', '2026-01-01', 15, 26)$$) ->> 'code',
    '23505',
    'a date that is already there is refused once the date field is unique'
);

SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'seen'$$,
    'unique_value can be turned on for a date-time field whose values are distinct apart from NULLs'
);

SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'ext'$$,
    'unique_value can be turned on for a uuid field whose values are distinct'
);

-- The same on creation: a date field that is unique from the start.
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, unique_value, field_order)
      VALUES ('uq_probe', 'due2', 'Due 2', 'date', TRUE, 110)$$,
    'a date field can be created with unique_value = TRUE'
);

-- =====================================================
-- A unique reference
-- =====================================================
-- A reference gets the same partial unique index as any other field, next to
-- the plain index every reference has. What the index leaves out follows the
-- type of the key the reference points at: NULL for an integer key, NULL and
-- the empty string for a text key. queue_table_events.table_name, a reference
-- to the text key of entities, is unique this way.
--
-- Fixture: `uq_ref_target`, two rows, created in-tx as user3.

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('uq_ref_target', 'Unique Target', 'Unique Targets', 1, 'public:read', 'admin');
INSERT INTO uq_ref_target (label) VALUES ('t1'), ('t2');

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, unique_value, field_order)
      VALUES ('uq_probe', 'owner', 'Owner', 'reference', 'uq_ref_target', 'restrict', TRUE, 120)$$,
    'a reference field can be created with unique_value = TRUE'
);

SELECT is(
    (SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'uq_probe_owner_unique'),
    'CREATE UNIQUE INDEX uq_probe_owner_unique ON public.uq_probe USING btree (owner) WHERE (owner IS NOT NULL)',
    'the index over a reference to an integer key leaves out only NULL'
);

SELECT ok(
    to_regclass('public.idx_uq_probe_owner') IS NOT NULL,
    'and the reference keeps its plain index next to the unique one'
);

UPDATE uq_probe SET owner = (SELECT id FROM uq_ref_target WHERE label = 't1') WHERE label = 'r1';

SELECT throws_ok(
    $$UPDATE uq_probe SET owner = (SELECT id FROM uq_ref_target WHERE label = 't1') WHERE label = 'r2'$$,
    '23505',
    'duplicate key value violates unique constraint "uq_probe_owner_unique"',
    'a second row pointing at the same record is refused'
);

SELECT lives_ok(
    $$INSERT INTO uq_probe (label, n, m) VALUES ('r12', 16, 27), ('r13', 17, 28)$$,
    'rows that point at nothing stay allowed in a unique reference, any number of them'
);

-- A text key: permissions is keyed by permission_name.
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, unique_value, field_order)
      VALUES ('uq_probe', 'perm', 'Permission', 'reference', 'permissions', 'restrict', TRUE, 130)$$,
    'a reference to a text-keyed entity can be created with unique_value = TRUE'
);

SELECT is(
    (SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'uq_probe_perm_unique'),
    'CREATE UNIQUE INDEX uq_probe_perm_unique ON public.uq_probe USING btree (perm) WHERE ((perm IS NOT NULL) AND (perm <> ''''::text))',
    'the index over a reference to a text key leaves out NULL and the empty string'
);

-- An existing reference: the rows decide, as for every other format.
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('uq_probe', 'buddy', 'Buddy', 'reference', 'uq_ref_target', 'restrict', 140);
UPDATE uq_probe SET buddy = (SELECT id FROM uq_ref_target WHERE label = 't2') WHERE label IN ('r1', 'r2');

SELECT is(
    catch_error($$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'buddy'$$) ->> 'message',
    'could not create unique index "uq_probe_buddy_unique"',
    'unique_value cannot be turned on for a reference that holds a duplicate'
);

UPDATE uq_probe SET buddy = NULL WHERE label = 'r2';

SELECT lives_ok(
    $$UPDATE fields SET unique_value = TRUE WHERE table_name = 'uq_probe' AND field_name = 'buddy'$$,
    'unique_value can be turned on for the same reference once the duplicate is gone'
);

SELECT * FROM finish();
ROLLBACK;
