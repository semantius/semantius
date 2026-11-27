-- Test number-format precision support
-- Validates that:
--   • fields.precision exists with a default of 2
--   • format='number' generates a NUMERIC(18, precision) column
--   • Custom precision overrides the default
--   • Northwind monetary/measure fields use 'number' (not 'float') with default precision 2
--   • A precision change on an existing field alters the column, raised or lowered, also in an is_a family
--   • The precision range (0 to 18) is enforced on insert and update
BEGIN;

SELECT plan(30);

SELECT authenticate_as('user3');

-- =====================================================
-- precision column exists with default 2
-- =====================================================

SELECT has_column('fields', 'precision', 'fields table has a precision column');

SELECT col_default_is(
    'fields', 'precision', '2',
    'fields.precision should default to 2'
);

-- =====================================================
-- Default precision (2) yields NUMERIC(18, 2)
-- =====================================================

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    module_id, view_permission, edit_permission, id_column, label_column
)
VALUES (
    'precision_test', 'Precision Test', 'precision_test',
    'Precision Test', 'Precision Tests',
    1, 'public:read', 'admin', 'id', 'label'
);

INSERT INTO fields (table_name, field_name, title, format, default_value)
VALUES ('precision_test', 'amount', 'Amount', 'number', '0.0');

SELECT is(
    (SELECT data_type FROM information_schema.columns
       WHERE table_name = 'precision_test' AND column_name = 'amount'),
    'numeric',
    'number format with default precision should map to NUMERIC'
);

SELECT is(
    (SELECT numeric_precision FROM information_schema.columns
       WHERE table_name = 'precision_test' AND column_name = 'amount')::INTEGER,
    18,
    'number format should produce NUMERIC with precision 18'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
       WHERE table_name = 'precision_test' AND column_name = 'amount')::INTEGER,
    2,
    'number format with default precision should produce NUMERIC scale 2'
);

-- =====================================================
-- Custom precision (4) is honored
-- =====================================================

INSERT INTO fields (table_name, field_name, title, format, default_value, "precision")
VALUES ('precision_test', 'rate', 'Rate', 'number', '0.0', 4);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
       WHERE table_name = 'precision_test' AND column_name = 'rate')::INTEGER,
    4,
    'custom precision=4 should produce NUMERIC scale 4'
);

-- =====================================================
-- Northwind monetary/measure fields should use NUMERIC(18,2), not REAL
-- =====================================================

-- products.unit_price
SELECT is(
    (SELECT data_type FROM information_schema.columns
       WHERE table_name = 'products' AND column_name = 'unit_price'),
    'numeric',
    'nwind: products.unit_price should be NUMERIC (not REAL/float)'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
       WHERE table_name = 'products' AND column_name = 'unit_price')::INTEGER,
    2,
    'nwind: products.unit_price should have scale 2'
);

-- orders.freight
SELECT is(
    (SELECT data_type FROM information_schema.columns
       WHERE table_name = 'orders' AND column_name = 'freight'),
    'numeric',
    'nwind: orders.freight should be NUMERIC (not REAL/float)'
);

-- order_details.unit_price + discount
SELECT is(
    (SELECT data_type FROM information_schema.columns
       WHERE table_name = 'order_details' AND column_name = 'unit_price'),
    'numeric',
    'nwind: order_details.unit_price should be NUMERIC (not REAL/float)'
);

SELECT is(
    (SELECT data_type FROM information_schema.columns
       WHERE table_name = 'order_details' AND column_name = 'discount'),
    'numeric',
    'nwind: order_details.discount should be NUMERIC (not REAL/float)'
);

-- And no field in nwind tables should use the 'float' format
SELECT is(
    (SELECT count(*)::INTEGER FROM fields f
       JOIN entities e ON e.table_name = f.table_name
      WHERE e.module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')
        AND f.format = 'float'),
    0,
    'nwind: no field should use the float format'
);

-- =====================================================
-- precision changed on an existing field
-- =====================================================
-- The scale is part of the column's type, and the column follows the field: a
-- changed precision alters the column, raised or lowered. Lowering it rounds
-- the values the column holds, and whoever lowers it accepts that. A column
-- that does not exist yet takes its precision when it is created: with the
-- field, or when an unmanaged entity becomes managed.

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    module_id, view_permission, edit_permission, id_column, label_column
)
VALUES (
    'precision_change', 'Precision Change', 'precision_change',
    'Precision Change', 'Precision Changes',
    1, 'public:read', 'admin', 'id', 'label'
);

INSERT INTO fields (table_name, field_name, title, format, default_value, field_order)
VALUES ('precision_change', 'amount', 'Amount', 'number', '0.0', 30);

INSERT INTO precision_change (label, amount) VALUES ('before', 1.239);

SELECT lives_ok(
    $$UPDATE fields SET "precision" = 4
       WHERE table_name = 'precision_change' AND field_name = 'amount'$$,
    'precision of an existing number field can be changed'
);

SELECT is(
    (SELECT "precision" FROM fields WHERE table_name = 'precision_change' AND field_name = 'amount'),
    4::smallint,
    'the changed precision is stored on the field'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
      WHERE table_name = 'precision_change' AND column_name = 'amount')::INTEGER,
    4,
    'a raised precision should raise the scale of the existing column'
);

INSERT INTO precision_change (label, amount) VALUES ('after', 1.23456);

SELECT is(
    (SELECT string_agg(label || '=' || amount, ', ' ORDER BY label) FROM precision_change),
    'after=1.2346, before=1.2400',
    'a value written before the change keeps its value, and one written after it has the new scale'
);

-- The check on fields.precision covers the range of NUMERIC(18, scale).
SELECT throws_ok(
    $$UPDATE fields SET "precision" = 19
       WHERE table_name = 'precision_change' AND field_name = 'amount'$$,
    '23514',
    'new row for relation "fields" violates check constraint "valid_precision"',
    'a precision above 18 should be refused'
);

SELECT throws_ok(
    $$UPDATE fields SET "precision" = -1
       WHERE table_name = 'precision_change' AND field_name = 'amount'$$,
    '23514',
    'new row for relation "fields" violates check constraint "valid_precision"',
    'a negative precision should be refused'
);

SELECT is(
    (SELECT "precision" FROM fields WHERE table_name = 'precision_change' AND field_name = 'amount'),
    4::smallint,
    'a refused precision should leave the stored one as it was'
);

SELECT lives_ok(
    $$UPDATE fields SET "precision" = 1
       WHERE table_name = 'precision_change' AND field_name = 'amount'$$,
    'precision of an existing number field can be lowered'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
      WHERE table_name = 'precision_change' AND column_name = 'amount')::INTEGER,
    1,
    'a lowered precision should lower the scale of the existing column'
);

SELECT is(
    (SELECT string_agg(label || '=' || amount, ', ' ORDER BY label) FROM precision_change),
    'after=1.2, before=1.2',
    'and round the values the column holds'
);

-- In a family the column of an is_a entity sits in <entity>_ext and every
-- level is read through a view over the levels above it. PostgreSQL does not
-- alter a column a view uses, so the views are rebuilt around the change: a
-- changed precision reaches the base column under its children's views, and
-- the child's own column under its own.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_column,
                      view_permission, edit_permission)
VALUES ('pc_parties', 'Pc Party', 'Pc Parties', 1, 'typeid', 'pcp', 'id', 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('pc_parties', 'rate', 'Rate', 'number', 30);

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('pc_orgs', 'Pc Org', 'Pc Orgs', 1, 'is_a', 'pco', 'pc_parties', 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('pc_orgs', 'fee', 'Fee', 'number', 30);

INSERT INTO pc_orgs (label, rate, fee) VALUES ('O1', 1.239, 2.468);

SELECT lives_ok(
    $$UPDATE fields SET "precision" = 4
       WHERE table_name = 'pc_parties' AND field_name = 'rate'$$,
    'family: precision of a base field that a child''s view reads can be changed'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
      WHERE table_name = 'pc_parties' AND column_name = 'rate')::INTEGER,
    4,
    'family: the base column takes the new scale'
);

SELECT is(
    (SELECT rate::text FROM pc_orgs WHERE label = 'O1'),
    '1.2400',
    'family: and the child''s view reads it at that scale'
);

SELECT lives_ok(
    $$UPDATE fields SET "precision" = 1
       WHERE table_name = 'pc_orgs' AND field_name = 'fee'$$,
    'family: precision of an is_a entity''s own field can be changed'
);

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
      WHERE table_name = 'pc_orgs_ext' AND column_name = 'fee')::INTEGER,
    1,
    'family: the column in the entity''s own table takes the new scale'
);

SELECT is(
    (SELECT fee::text FROM pc_orgs WHERE label = 'O1'),
    '2.5',
    'family: and the entity''s view reads the rounded value'
);

INSERT INTO fields (table_name, field_name, title, format, "precision", field_order)
VALUES ('precision_change', 'whole', 'Whole', 'number', 0, 40),
       ('precision_change', 'exact', 'Exact', 'number', 18, 50);

SELECT is(
    (SELECT jsonb_object_agg(column_name, numeric_scale) FROM information_schema.columns
      WHERE table_name = 'precision_change' AND column_name IN ('whole', 'exact')),
    '{"whole": 0, "exact": 18}'::jsonb,
    'precision 0 and 18, the ends of the range, should produce those scales'
);

-- An unmanaged entity has no column yet; the table is built from the fields as
-- they are when it becomes managed.
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES (
    'precision_late', 'Precision Late', 'precision_late',
    'Precision Late', 'Precision Lates',
    1, 'public:read', 'admin', 'id', 'label', FALSE
);

INSERT INTO fields (table_name, field_name, title, format, "precision", field_order)
VALUES ('precision_late', 'amount', 'Amount', 'number', 2, 30);

UPDATE fields SET "precision" = 5
 WHERE table_name = 'precision_late' AND field_name = 'amount';

UPDATE entities SET managed = TRUE WHERE table_name = 'precision_late';

SELECT is(
    (SELECT numeric_scale FROM information_schema.columns
      WHERE table_name = 'precision_late' AND column_name = 'amount')::INTEGER,
    5,
    'a precision changed before the entity is managed should be the scale of the column built then'
);

SELECT * FROM finish();
ROLLBACK;
