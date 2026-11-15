-- Test number-format precision support
-- Validates that:
--   • fields.precision exists with a default of 2
--   • format='number' generates a NUMERIC(18, precision) column
--   • Custom precision overrides the default
--   • Northwind monetary/measure fields use 'number' (not 'float') with default precision 2
--   • A precision change on an existing field is recorded and leaves the column's scale as it is
--   • The precision range (0 to 18) is enforced on insert and update
BEGIN;

SELECT plan(21);

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

-- And no fields in nwind tables should still use 'float' format
SELECT is(
    (SELECT count(*)::INTEGER FROM fields f
       JOIN entities e ON e.table_name = f.table_name
      WHERE e.module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')
        AND f.format = 'float'),
    0,
    'nwind: no fields should still use the float format'
);

-- =====================================================
-- precision changed on an existing field
-- =====================================================
-- The scale is part of the column's type, and a number column holds values
-- written under it, so a precision change on a field whose column exists is
-- recorded in the dictionary and leaves the column as it is (the same holds for
-- the rollup of a number field, docs/rollup-fields.md). The column takes a
-- precision when it is created: with the field, or when an unmanaged entity
-- becomes managed.

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
    2,
    'a precision change should leave the scale of the existing column alone'
);

INSERT INTO precision_change (label, amount) VALUES ('after', 1.23456);

SELECT is(
    (SELECT string_agg(label || '=' || amount, ', ' ORDER BY label) FROM precision_change),
    'after=1.23, before=1.24',
    'values keep the scale of the column, those written before and after the change'
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
