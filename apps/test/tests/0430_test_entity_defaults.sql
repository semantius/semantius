-- Test entity defaults and the label field's title.
--
-- See 0220_entity_insert_defaults.sql and the label title triggers in
-- 0160_dd_functions.sql:
--   * snake_to_label() converts snake_case -> Title Case
--   * dd_label_field_title() is the label field's default title: label_column
--     in words without a leading entity singular or plural, except for a
--     column ending in _number, _no, _id or _code
--   * on insert, singular (de-pluralized table_name), singular_label (from
--     singular) and label_column_label (dd_label_field_title) are filled when
--     left blank, and the label field is created with label_column_label
--   * label_column_label and the label field's title stay equal: a change of
--     either is copied to the other, and an unchanged value writes nothing
-- Caller-supplied values are always preserved verbatim, except plural, which
-- is always forced to table_name (a wrong caller value is ignored).
--
-- Fixture tables use the 'tdef_' prefix so they never collide with real or
-- seeded entities.

BEGIN;

SELECT plan(46);

SELECT authenticate_as('user3');  -- admin: may insert into entities

-- =====================================================
-- snake_to_label() unit tests
-- =====================================================

SELECT is(snake_to_label('tenant_name'),    'Tenant Name',    'snake_to_label: tenant_name -> Tenant Name');
SELECT is(snake_to_label('city'),           'City',           'snake_to_label: city -> City');
SELECT is(snake_to_label('address_line_1'), 'Address Line 1', 'snake_to_label: address_line_1 -> Address Line 1');
SELECT is(snake_to_label('label'),          'Label',          'snake_to_label: label -> Label');

-- =====================================================
-- dd_label_field_title() unit tests
-- =====================================================

SELECT is(dd_label_field_title('company_name', 'company', 'companies'),      'Name',         'title: the entity singular is dropped (company_name on companies)');
SELECT is(dd_label_field_title('category_name', 'category', 'categories'),   'Name',         'title: ...ies plural (category_name on categories)');
SELECT is(dd_label_field_title('region_description', 'region', 'regions'),   'Description',  'title: not only _name loses the entity (region_description)');
SELECT is(dd_label_field_title('address_line', 'addresse', 'addresses'),     'Line',         'title: a naively derived singular is covered by the plural (addresses)');
SELECT is(dd_label_field_title('company_name', 'customer', 'customers'),     'Company Name', 'title: a column without the entity keeps its words');
SELECT is(dd_label_field_title('last_name', 'employee', 'employees'),        'Last Name',    'title: last_name on employees');
SELECT is(dd_label_field_title('city', 'city', 'cities'),                    'City',         'title: a column that is just the entity name stays');
SELECT is(dd_label_field_title('name', 'x', 'xs'),                           'Name',         'title: name');
SELECT is(dd_label_field_title('label', 'x', 'xs'),                          'Label',        'title: label');
SELECT is(dd_label_field_title('offer_number', 'offer', 'offers'),           'Offer Number', 'title: a _number column keeps the entity');
SELECT is(dd_label_field_title('invoice_id', 'invoice', 'invoices'),         'Invoice Id',   'title: an _id column keeps the entity');
SELECT is(dd_label_field_title('ticket_no', 'ticket', 'tickets'),            'Ticket No',    'title: a _no column keeps the entity');
SELECT is(dd_label_field_title('product_code', 'product', 'products'),       'Product Code', 'title: a _code column keeps the entity');

-- =====================================================
-- TEST 1: insert of just table_name fills singular, singular_label,
--         and the label field title
-- =====================================================
-- label_column defaults to 'label', so the label field is titled 'Label'.

INSERT INTO entities (table_name, module_id) VALUES ('tdef_items', 1);

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_items'), 'tdef_item',  'bare insert: singular de-pluralized from table_name');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_items'), 'Tdef Item',  'bare insert: singular_label derived from singular');
SELECT is((SELECT plural         FROM entities WHERE table_name = 'tdef_items'), 'tdef_items', 'bare insert: plural auto-set to table_name');
SELECT is(
    (SELECT title FROM fields WHERE table_name = 'tdef_items' AND field_name = 'label')
    || ' | ' || (SELECT label_column_label FROM entities WHERE table_name = 'tdef_items'),
    'Label | Label',
    'bare insert: the label field and label_column_label are both titled Label'
);

-- De-pluralize '...ies' branch.
INSERT INTO entities (table_name, module_id) VALUES ('tdef_entries', 1);
SELECT is((SELECT singular FROM entities WHERE table_name = 'tdef_entries'), 'tdef_entry', 'bare insert: ...ies de-pluralized to ...y');

-- =====================================================
-- TEST 2: label_column provided, singular_label omitted
-- =====================================================

INSERT INTO entities (table_name, label_column, module_id) VALUES ('tdef_tenants', 'tenant_name', 1);

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_tenants'), 'tdef_tenant', 'derived: singular de-pluralized from table_name');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_tenants'), 'Tdef Tenant', 'derived: singular_label from singular, not from label_column');
SELECT is(
    (SELECT title FROM fields WHERE table_name = 'tdef_tenants' AND field_name = 'tenant_name'),
    'Tenant Name',
    'derived: tenant_name does not start with the entity name, so it keeps its words'
);

-- =====================================================
-- TEST 3: insert provides table_name, singular, singular_label, label_column
--         -> caller values preserved verbatim; fields defined correctly
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, label_column, module_id)
VALUES ('tdef_records', 'record', 'Record', 'record_title', 1);

SELECT is((SELECT singular       FROM entities WHERE table_name = 'tdef_records'), 'record',       'full insert: provided singular preserved');
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_records'), 'Record',       'full insert: provided singular_label preserved (not overwritten)');
SELECT is((SELECT plural         FROM entities WHERE table_name = 'tdef_records'), 'tdef_records', 'full insert: plural auto-set to table_name');
SELECT is((SELECT label_column   FROM entities WHERE table_name = 'tdef_records'), 'record_title', 'full insert: provided label_column preserved');

SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'record_title'), 'Title', 'full insert: the provided singular is dropped from the label title');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'id'),           'Id',         'full insert: id field title');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'created_at'),   'Created At', 'full insert: created_at field title');
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_records' AND field_name = 'updated_at'),   'Updated At', 'full insert: updated_at field title');

-- =====================================================
-- TEST 4: insert provides a WRONG plural -> ignored, plural forced to table_name
-- =====================================================

INSERT INTO entities (table_name, plural, module_id) VALUES ('tdef_widgets', 'wrongplural', 1);

SELECT is((SELECT plural FROM entities WHERE table_name = 'tdef_widgets'), 'tdef_widgets', 'wrong plural: caller-supplied plural is ignored, plural auto-set to table_name');

-- =====================================================
-- TEST 5: the label title given in the insert, and the defaults it replaces
-- =====================================================

INSERT INTO entities (table_name, singular, label_column, label_column_label, module_id)
VALUES ('tdef_offers', 'offer', 'offer_number', 'Offer #', 1);

SELECT is(
    (SELECT title FROM fields WHERE table_name = 'tdef_offers' AND field_name = 'offer_number')
    || ' | ' || (SELECT label_column_label FROM entities WHERE table_name = 'tdef_offers'),
    'Offer # | Offer #',
    'given label_column_label: the label field is created with it'
);
SELECT is((SELECT singular_label FROM entities WHERE table_name = 'tdef_offers'), 'Offer', 'an omitted singular_label comes from singular, not from offer_number');

INSERT INTO entities (table_name, singular, label_column, module_id)
VALUES ('tdef_quotes', 'quote', 'quote_number', 1);
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_quotes' AND field_name = 'quote_number'), 'Quote Number', 'default: a _number label column keeps the entity');

INSERT INTO entities (table_name, singular, label_column, module_id)
VALUES ('tdef_companies', 'company', 'company_name', 1);
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_companies' AND field_name = 'company_name'), 'Name', 'default: company_name on companies is Name');

-- =====================================================
-- TEST 6: label_column_label and the label field's title stay equal
-- =====================================================

UPDATE fields SET title = 'Offer No.' WHERE table_name = 'tdef_offers' AND field_name = 'offer_number';
SELECT is((SELECT label_column_label FROM entities WHERE table_name = 'tdef_offers'), 'Offer No.', 'a field title change is copied to label_column_label');

UPDATE entities SET label_column_label = 'Offer Ref' WHERE table_name = 'tdef_offers';
SELECT is((SELECT title FROM fields WHERE table_name = 'tdef_offers' AND field_name = 'offer_number'), 'Offer Ref', 'a label_column_label change is written to the field title');

-- entities is audited: an unchanged title must not reach its row.
CREATE TEMP TABLE tdef_audit_base AS
SELECT count(*) AS n FROM audit_record_logs WHERE table_name = 'entities';
UPDATE fields SET title = 'Offer Ref' WHERE table_name = 'tdef_offers' AND field_name = 'offer_number';
SELECT is(
    (SELECT count(*) FROM audit_record_logs WHERE table_name = 'entities') - (SELECT n FROM tdef_audit_base),
    0::bigint,
    'an unchanged field title does not update the entities row'
);

-- A rename keeps the title; the label column follows the field.
UPDATE fields SET field_name = 'offer_ref' WHERE table_name = 'tdef_offers' AND field_name = 'offer_number';
SELECT is(
    (SELECT label_column || ' | ' || label_column_label FROM entities WHERE table_name = 'tdef_offers'),
    'offer_ref | Offer Ref',
    'a label field rename keeps the title'
);

-- label_column pointed at another field takes that field's title.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('tdef_offers', 'offer_code', 'Code', 'text', 30);
UPDATE entities SET label_column = 'offer_code' WHERE table_name = 'tdef_offers';
SELECT is((SELECT label_column_label FROM entities WHERE table_name = 'tdef_offers'), 'Code', 'a repointed label_column takes the title of the field it names');

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

-- The core tables got their copy in the bootstrap.
SELECT is(
    (SELECT count(*)::INTEGER FROM entities e JOIN fields f
        ON f.table_name = e.table_name AND f.field_name = e.label_column
      WHERE e.label_column_label IS DISTINCT FROM f.title),
    0,
    'every entity''s label_column_label equals its label field''s title'
);

SELECT * FROM finish();
ROLLBACK;
