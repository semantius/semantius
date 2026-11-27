-- fields.reference_table is set when a field is created and never changes.
--
-- The values of a reference or parent column are keys of the entity the field
-- names. Pointed at another entity, the column would keep every value and each
-- record would reference whichever row of the new entity carries the same key:
-- auto_increment keys of two entities usually overlap, so the rebuilt foreign
-- key would accept it and every record would silently point at a different
-- record. update_dd_field refuses the change (90289), for every role and on
-- unmanaged entities too, and refuses converting a field into or out of a
-- reference, which sets or clears reference_table: out and back in would be
-- the same re-pointing in two writes. The rename of the referenced entity is
-- the one change that carries to the field, and the marker that lets it
-- through does not outlive the cascade. The form asks for reference_table only
-- while the field is being created (input_type_rule).
--
-- Fixtures: user3 = Administrator.

BEGIN;

SELECT plan(19);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('rtw_customers', 'Rtw Customer', 'Rtw Customers', 1, 'public:read', 'admin'),
       ('rtw_suppliers', 'Rtw Supplier', 'Rtw Suppliers', 1, 'public:read', 'admin'),
       ('rtw_orders',    'Rtw Order',    'Rtw Orders',    1, 'public:read', 'admin'),
       ('rtw_lines',     'Rtw Line',     'Rtw Lines',     1, 'public:read', 'admin');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, managed)
VALUES ('rtw_loose', 'Rtw Loose', 'Rtw Loose', 1, 'public:read', 'admin', FALSE);

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rtw_orders', 'customer_id', 'Customer', 'reference', 20, 'rtw_customers', 'restrict'),
       ('rtw_lines',  'order_id',    'Order',    'parent',    20, 'rtw_orders',    'cascade'),
       ('rtw_loose',  'customer_id', 'Customer', 'reference', 20, 'rtw_customers', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rtw_orders', 'legacy_no', 'Legacy No', 'int64', 30);

INSERT INTO rtw_customers (label) VALUES ('Alice');
INSERT INTO rtw_suppliers (label) VALUES ('Acme');
INSERT INTO rtw_orders (label, customer_id, legacy_no) SELECT 'Order 1', id, id FROM rtw_customers;

-- =====================================================
-- Re-pointing an existing field is refused
-- =====================================================
SELECT is(
    (SELECT jsonb_build_object('code', e ->> 'code', 'message', e ->> 'message', 'hint', e ->> 'hint')
       FROM catch_error($$UPDATE fields SET reference_table = 'rtw_suppliers'
                          WHERE table_name = 'rtw_orders' AND field_name = 'customer_id'$$) AS e),
    jsonb_build_object('code', '90289',
                       'message', 'reference_table of field ${field_name} on ${table} is set when the field is created and cannot be changed',
                       'hint', jsonb_build_object('table', 'rtw_orders', 'field_name', 'customer_id',
                                                  'hint', 'Create a new field that references the other entity instead.')::text),
    'a reference with records cannot be pointed at another entity');

SELECT is(
    (SELECT reference_table || ' ' || (SELECT confrelid::regclass::text FROM pg_constraint
                                        WHERE conname = 'rtw_orders_customer_id_fkey')
       FROM fields WHERE table_name = 'rtw_orders' AND field_name = 'customer_id'),
    'rtw_customers rtw_customers',
    'and both the field and its foreign key still name the original entity');

SELECT is(
    (SELECT c.label FROM rtw_orders o JOIN rtw_customers c ON c.id = o.customer_id),
    'Alice',
    'and the record still references the same record');

SELECT is(
    catch_error($$UPDATE fields SET reference_table = 'rtw_customers'
                   WHERE table_name = 'rtw_lines' AND field_name = 'order_id'$$) ->> 'code',
    '90289',
    'a parent field cannot be pointed at another entity, even on an entity without records');

SELECT is(
    catch_error($$UPDATE fields SET reference_table = 'rtw_suppliers'
                   WHERE table_name = 'rtw_loose' AND field_name = 'customer_id'$$) ->> 'code',
    '90289',
    'an unmanaged entity, which has no foreign key, is held to it too');

-- The migrations and ensure_entities write fields as the owner, past RLS.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is(
    catch_error($$UPDATE fields SET reference_table = 'rtw_suppliers'
                   WHERE table_name = 'rtw_orders' AND field_name = 'customer_id'$$) ->> 'code',
    '90289',
    'the owner cannot re-point a field either');

SELECT authenticate_as('user3');

-- =====================================================
-- Converting into or out of a reference is refused
-- =====================================================
-- int64 and a reference to an auto_increment entity are both BIGINT, so the
-- format-change guard (90223) lets both conversions through to this one.
SELECT is(
    catch_error($$UPDATE fields SET format = 'int64', reference_table = '', reference_delete_mode = ''
                   WHERE table_name = 'rtw_orders' AND field_name = 'customer_id'$$) ->> 'code',
    '90289',
    'a reference cannot become a plain field, which would clear reference_table');

SELECT is(
    catch_error($$UPDATE fields SET format = 'reference', reference_table = 'rtw_suppliers', reference_delete_mode = 'restrict'
                   WHERE table_name = 'rtw_orders' AND field_name = 'legacy_no'$$) ->> 'code',
    '90289',
    'a plain field cannot become a reference, which would make its values point at records');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rtw_orders_legacy_no_fkey'),
    'and the plain field gets no foreign key');

-- =====================================================
-- The rest of a reference field stays editable
-- =====================================================
SELECT lives_ok(
    $$UPDATE fields SET reference_delete_mode = 'clear', title = 'Buyer', description = 'Who placed the order'
       WHERE table_name = 'rtw_orders' AND field_name = 'customer_id'$$,
    'the delete mode, title and description of a reference can still change');

SELECT is(
    (SELECT confdeltype::text FROM pg_constraint WHERE conname = 'rtw_orders_customer_id_fkey'),
    'n',
    'and the foreign key is rebuilt with the new delete mode (SET NULL)');

-- =====================================================
-- A rename of the referenced entity carries to the field
-- =====================================================
UPDATE entities SET table_name = 'rtw_clients' WHERE table_name = 'rtw_customers';

SELECT is(
    (SELECT string_agg(table_name || '.' || field_name || '=' || reference_table, ', ' ORDER BY table_name)
       FROM fields WHERE field_name = 'customer_id' AND table_name IN ('rtw_orders', 'rtw_loose')),
    'rtw_loose.customer_id=rtw_clients, rtw_orders.customer_id=rtw_clients',
    'renaming the referenced entity re-points its fields, the unmanaged one included');

SELECT is(
    (SELECT confrelid::regclass::text FROM pg_constraint WHERE conname = 'rtw_orders_customer_id_fkey'),
    'rtw_clients',
    'and the foreign key follows the renamed table');

-- The marker that lets the cascade through is cleared after it: a new entity
-- under the old name, and a field pointing at it, cannot use the rename to be
-- re-pointed at the renamed entity later in the transaction.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('rtw_customers', 'Rtw Customer', 'Rtw Customers', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rtw_orders', 'second_customer_id', 'Second Customer', 'reference', 40, 'rtw_customers', 'restrict');

SELECT is(
    catch_error($$UPDATE fields SET reference_table = 'rtw_clients'
                   WHERE table_name = 'rtw_orders' AND field_name = 'second_customer_id'$$) ->> 'code',
    '90289',
    'after a rename, a field of the old name cannot be re-pointed at the renamed entity');

SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'rtw_orders' AND field_name = 'second_customer_id'),
    'rtw_customers',
    'and keeps the entity it was created with');

-- =====================================================
-- The form asks for reference_table only while the field is created
-- =====================================================
-- created_at is set by the database, so a field being created has none.
SELECT is(
    evaluate_json_logic(
        (SELECT input_type_rule FROM fields WHERE table_name = 'fields' AND field_name = 'reference_table'),
        '{"format": "reference"}'::jsonb),
    '"required"'::jsonb,
    'input_type_rule: required on a new reference field');

SELECT is(
    evaluate_json_logic(
        (SELECT input_type_rule FROM fields WHERE table_name = 'fields' AND field_name = 'reference_table'),
        (SELECT to_jsonb(f) FROM fields f WHERE table_name = 'rtw_orders' AND field_name = 'customer_id')),
    '"readonly"'::jsonb,
    'input_type_rule: readonly on an existing reference field');

SELECT is(
    evaluate_json_logic(
        (SELECT input_type_rule FROM fields WHERE table_name = 'fields' AND field_name = 'reference_table'),
        (SELECT to_jsonb(f) FROM fields f WHERE table_name = 'rtw_lines' AND field_name = 'order_id')),
    '"readonly"'::jsonb,
    'input_type_rule: readonly on an existing parent field');

SELECT is(
    evaluate_json_logic(
        (SELECT input_type_rule FROM fields WHERE table_name = 'fields' AND field_name = 'reference_table'),
        (SELECT to_jsonb(f) FROM fields f WHERE table_name = 'rtw_orders' AND field_name = 'legacy_no')),
    '"hidden"'::jsonb,
    'input_type_rule: hidden on a field that is no reference');

SELECT * FROM finish();
ROLLBACK;
