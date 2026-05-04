-- Test number-format precision support
-- Validates that:
--   • fields.precision exists with a default of 2
--   • format='number' generates a NUMERIC(18, precision) column
--   • Custom precision overrides the default
--   • Northwind monetary/measure fields use 'number' (not 'float') with default precision 2
BEGIN;

SELECT plan(12);

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
    1001, 'public:read', 'admin', 'id', 'label'
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
-- Custom precision (4) is honoured
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
      WHERE e.module_id = (SELECT id FROM modules WHERE module_name = 'nwind')
        AND f.format = 'float'),
    0,
    'nwind: no fields should still use the float format'
);

SELECT * FROM finish();
ROLLBACK;
