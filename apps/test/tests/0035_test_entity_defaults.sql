-- Test entity insert defaults: singular, singular_label, and the name field title.
--
-- See 0230_entity_insert_defaults.sql:
--   * snake_to_label() converts snake_case -> Title Case
--   * a BEFORE INSERT trigger derives singular (de-pluralized table_name) and
--     singular_label (snake_to_label of label_column) when left blank
--   * create_dd_table() then seeds the name field title from singular_label
-- Caller-supplied values are always preserved verbatim.
--
-- Fixture tables use the 'tdef_' prefix so they never collide with real or
-- seeded entities.

BEGIN;

SELECT plan(22);

SELECT authenticate_as('user3');  -- admin: may insert into entities

-- =====================================================
-- snake_to_label() unit tests
-- =====================================================

SELECT is(snake_to_label('tenant_name'),    'Tenant Name',    'snake_to_label: tenant_name -> Tenant Name');
SELECT is(snake_to_label('city'),           'City',           'snake_to_label: city -> City');
SELECT is(snake_to_label('address_line_1'), 'Address Line 1', 'snake_to_label: address_line_1 -> Address Line 1');
SELECT is(snake_to_label('label'),          'Label',          'snake_to_label: label -> Label');

-- =====================================================
-- TEST 1: insert of just table_name fills singular, singular_label,
--         and the name field title
-- =====================================================
-- label_column defaults to 'label', so singular_label derives to 'Label'.

INSERT INTO entities (table_name) VALUES ('tdef_items');

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_items'), 'tdef_item',  'bare insert: singular de-pluralized from table_name');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_items'), 'Label',      'bare insert: singular_label derived from default label_column');
SELECT is((SELECT plural         FROM entities WHERE table_name = 'tdef_items'), 'tdef_items', 'bare insert: plural auto-set to table_name');
SELECT is(
    (SELECT title FROM fields WHERE table_name = 'tdef_items' AND field_name = 'label'),
    'Label',
    'bare insert: name field title seeded from derived singular_label'
);

-- De-pluralize '...ies' branch.
INSERT INTO entities (table_name) VALUES ('tdef_entries');
SELECT is((SELECT singular FROM entities WHERE table_name = 'tdef_entries'), 'tdef_entry', 'bare insert: ...ies de-pluralized to ...y');

-- =====================================================
-- TEST (point 4): label_column provided, singular_label omitted
--                 -> singular_label derived from the provided label_column
-- =====================================================

INSERT INTO entities (table_name, label_column) VALUES ('tdef_tenants', 'tenant_name');

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_tenants'), 'tdef_tenant', 'derived: singular de-pluralized from table_name');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_tenants'), 'Tenant Name', 'derived: singular_label from provided label_column tenant_name');
SELECT is(
    (SELECT title FROM fields WHERE table_name = 'tdef_tenants' AND field_name = 'tenant_name'),
    'Tenant Name',
    'derived: name field "tenant_name" gets title "Tenant Name"'
);

-- =====================================================
-- TEST 2: insert provides table_name, singular, singular_label, label_column
--         -> caller values preserved verbatim; fields defined correctly
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, label_column)
VALUES ('tdef_records', 'record', 'Record', 'record_no');

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_records'), 'record',       'full insert: provided singular preserved');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_records'), 'Record',       'full insert: provided singular_label preserved (not overwritten)');
SELECT is((SELECT plural         FROM entities WHERE table_name = 'tdef_records'), 'tdef_records', 'full insert: plural auto-set to table_name');
SELECT is((SELECT label_column   FROM entities WHERE table_name = 'tdef_records'), 'record_no',    'full insert: provided label_column preserved');

SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'record_no'),  'Record',     'full insert: name field title = provided singular_label');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'id'),         'Id',         'full insert: id field title');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'created_at'), 'Created At', 'full insert: created_at field title');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'updated_at'), 'Updated At', 'full insert: updated_at field title');

-- =====================================================
-- Dictionary metadata for the entities entity's own fields
-- =====================================================
-- singular is auto-derived, so it must not be a required input; module is
-- mandatory, so module_id must be a required input.

SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'entities' AND field_name = 'singular'),
    'default',
    'entities.singular is not a required input (auto-derived)'
);
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'entities' AND field_name = 'module_id'),
    'required',
    'entities.module_id is a required input'
);

SELECT * FROM finish();
ROLLBACK;
