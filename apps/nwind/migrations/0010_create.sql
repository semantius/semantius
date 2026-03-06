-- =====================================================
-- NORTHWIND ENTITY/FIELD DEFINITIONS
-- =====================================================
-- Converts the Northwind database from raw DDL to the
-- entity/field system. Tables are created automatically
-- by triggers when rows are inserted into entities.
-- =====================================================

-- Module
INSERT INTO modules (module_name, description, view_permission, home_page)
VALUES ('nwind', 'Northwind Sample Database', 'nwind:view', '/nwind');

-- Permissions
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('nwind:view',   'Permission to view Northwind data',   (SELECT id FROM modules WHERE module_name = 'nwind')),
    ('nwind:manage', 'Permission to manage Northwind data', (SELECT id FROM modules WHERE module_name = 'nwind'));

-- Permission hierarchy: nwind:manage implies nwind:view
INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id)
SELECT p.id, c.id
FROM permissions p, permissions c
WHERE p.permission_name = 'nwind:manage'
  AND c.permission_name = 'nwind:view';

-- =====================================================
-- ENTITIES
-- =====================================================

-- 1. nw_categories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_categories',
    'category',
    'Category',
    'Categories',
    'Product categories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'category_name'
);

-- 2. nw_customer_demographics
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_customer_demographics',
    'customer_demographic',
    'Customer Demographic',
    'Customer Demographics',
    'Customer demographic categories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'customer_type_id'
);

-- 3. nw_customers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_customers',
    'customer',
    'Customer',
    'Customers',
    'Customer information and contact details',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 4. nw_customer_customer_demo (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_customer_customer_demo',
    'customer_customer_demo',
    'Customer Demographic Assignment',
    'Customer Demographic Assignments',
    'Links customers to their demographic categories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'label'
);

-- 5. nw_employees
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_employees',
    'employee',
    'Employee',
    'Employees',
    'Employee records and contact information',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'last_name'
);

-- 6. nw_suppliers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_suppliers',
    'supplier',
    'Supplier',
    'Suppliers',
    'Supplier information and contact details',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 7. nw_products
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_products',
    'product',
    'Product',
    'Products',
    'Product catalog and inventory',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'product_name'
);

-- 8. nw_regions
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_regions',
    'region',
    'Region',
    'Regions',
    'Sales territories and geographic regions',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'region_description'
);

-- 9. nw_shippers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_shippers',
    'shipper',
    'Shipper',
    'Shippers',
    'Shipping companies and carriers',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 10. nw_orders
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_orders',
    'order',
    'Order',
    'Orders',
    'Customer orders and shipping details',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'ship_name'
);

-- 11. nw_territories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_territories',
    'territory',
    'Territory',
    'Territories',
    'Sales territories within regions',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'territory_description'
);

-- 12. nw_employee_territories (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_employee_territories',
    'employee_territory',
    'Employee Territory',
    'Employee Territories',
    'Links employees to their assigned territories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'label'
);

-- 13. nw_order_details (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_order_details',
    'order_detail',
    'Order Detail',
    'Order Details',
    'Individual line items within an order',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'label'
);

-- 14. nw_us_states
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'nw_us_states',
    'us_state',
    'US State',
    'US States',
    'United States state reference data',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'state_name'
);

-- =====================================================
-- FIELDS
-- =====================================================

-- -----------------------------------------------------
-- nw_categories fields
-- -----------------------------------------------------
-- (category_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_categories', 'description', 'Description', 'text', FALSE, 20, 'default', 'w', 'Description of the product category', '', TRUE, '');

-- -----------------------------------------------------
-- nw_customer_demographics fields
-- -----------------------------------------------------
-- (customer_type_id is auto-created as the label_column; unique_value handled separately if needed)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('nw_customer_demographics', 'customer_desc', 'Description', 'text', FALSE, 20, 'default', 'w', 'Description of the customer demographic', '', TRUE, FALSE, '');

-- -----------------------------------------------------
-- nw_customers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('nw_customers', 'customer_id',    'Customer ID',    'text', FALSE, 10, 'required', 'default', 'Unique short code identifying the customer', '', TRUE,  TRUE,  ''),
    ('nw_customers', 'contact_name',   'Contact Name',   'text', FALSE, 30, 'default',  'default', 'Name of the primary contact person',        '', TRUE,  FALSE, ''),
    ('nw_customers', 'contact_title',  'Contact Title',  'text', FALSE, 40, 'default',  'default', 'Title of the primary contact person',       '', FALSE, FALSE, ''),
    ('nw_customers', 'address',        'Address',        'text', FALSE, 50, 'default',  'w',       'Street address',                            '', FALSE, FALSE, ''),
    ('nw_customers', 'city',           'City',           'text', FALSE, 60, 'default',  'default', 'City',                                      '', TRUE,  FALSE, ''),
    ('nw_customers', 'region',         'Region',         'text', FALSE, 70, 'default',  'default', 'State or province',                         '', FALSE, FALSE, ''),
    ('nw_customers', 'postal_code',    'Postal Code',    'text', FALSE, 80, 'default',  'default', 'Postal or ZIP code',                        '', FALSE, FALSE, ''),
    ('nw_customers', 'country',        'Country',        'text', FALSE, 90, 'default',  'default', 'Country',                                   '', TRUE,  FALSE, ''),
    ('nw_customers', 'phone',          'Phone',          'text', FALSE, 100, 'default', 'default', 'Primary phone number',                      '', FALSE, FALSE, ''),
    ('nw_customers', 'fax',            'Fax',            'text', FALSE, 110, 'default', 'default', 'Fax number',                                '', FALSE, FALSE, '');

-- -----------------------------------------------------
-- nw_customer_customer_demo fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_customer_customer_demo', 'customer_id',      'Customer',           'parent', FALSE, 10, 'required', 'default', 'Reference to the customer',             'nw_customers',            'restrict', FALSE),
    ('nw_customer_customer_demo', 'customer_type_id', 'Customer Demographic', 'parent', FALSE, 20, 'required', 'default', 'Reference to the customer demographic', 'nw_customer_demographics', 'restrict', FALSE);

-- -----------------------------------------------------
-- nw_employees fields
-- -----------------------------------------------------
-- (last_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_employees', 'first_name',         'First Name',         'text', FALSE, 20,  'required', 'default', 'Employee first name',                     '', TRUE,  ''),
    ('nw_employees', 'title',              'Title',              'text', FALSE, 30,  'default',  'default', 'Job title',                               '', FALSE, ''),
    ('nw_employees', 'title_of_courtesy',  'Title of Courtesy',  'text', FALSE, 40,  'default',  'default', 'Courtesy title (Mr., Ms., Dr., etc.)',    '', FALSE, ''),
    ('nw_employees', 'address',            'Address',            'text', FALSE, 60,  'default',  'w',       'Street address',                          '', FALSE, ''),
    ('nw_employees', 'city',               'City',               'text', FALSE, 70,  'default',  'default', 'City',                                    '', TRUE,  ''),
    ('nw_employees', 'region',             'Region',             'text', FALSE, 80,  'default',  'default', 'State or province',                       '', FALSE, ''),
    ('nw_employees', 'postal_code',        'Postal Code',        'text', FALSE, 90,  'default',  'default', 'Postal or ZIP code',                      '', FALSE, ''),
    ('nw_employees', 'country',            'Country',            'text', FALSE, 100, 'default',  'default', 'Country',                                 '', TRUE,  ''),
    ('nw_employees', 'home_phone',         'Home Phone',         'text', FALSE, 110, 'default',  'default', 'Home telephone number',                   '', FALSE, ''),
    ('nw_employees', 'extension',          'Extension',          'text', FALSE, 120, 'default',  'default', 'Phone extension',                         '', FALSE, ''),
    ('nw_employees', 'notes',              'Notes',              'text', FALSE, 130, 'default',  'w',       'General notes about the employee',        '', FALSE, ''),
    ('nw_employees', 'photo_path',         'Photo Path',         'text', FALSE, 140, 'default',  'default', 'Path to employee photo file',             '', FALSE, '');

-- birth_date: nullable (no sensible default)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('nw_employees', 'birth_date', 'Birth Date', 'date', TRUE, 50, 'default', 'default', 'Employee date of birth', FALSE, '');

-- hire_date: not nullable with default
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_employees', 'hire_date', 'Hire Date', 'date', FALSE, 55, 'default', 'default', 'Date the employee was hired', 'CURRENT_DATE', FALSE, '');

-- reports_to: self-reference, nullable
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_employees', 'reports_to', 'Reports To', 'reference', TRUE, 150, 'default', 'default', 'Manager this employee reports to', 'nw_employees', 'restrict', FALSE);

-- -----------------------------------------------------
-- nw_suppliers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_suppliers', 'contact_name',  'Contact Name',  'text', FALSE, 20,  'default',  'default', 'Name of the primary contact',    '', TRUE,  ''),
    ('nw_suppliers', 'contact_title', 'Contact Title', 'text', FALSE, 30,  'default',  'default', 'Title of the primary contact',   '', FALSE, ''),
    ('nw_suppliers', 'address',       'Address',       'text', FALSE, 40,  'default',  'w',       'Street address',                 '', FALSE, ''),
    ('nw_suppliers', 'city',          'City',          'text', FALSE, 50,  'default',  'default', 'City',                           '', TRUE,  ''),
    ('nw_suppliers', 'region',        'Region',        'text', FALSE, 60,  'default',  'default', 'State or province',              '', FALSE, ''),
    ('nw_suppliers', 'postal_code',   'Postal Code',   'text', FALSE, 70,  'default',  'default', 'Postal or ZIP code',             '', FALSE, ''),
    ('nw_suppliers', 'country',       'Country',       'text', FALSE, 80,  'default',  'default', 'Country',                        '', TRUE,  ''),
    ('nw_suppliers', 'phone',         'Phone',         'text', FALSE, 90,  'default',  'default', 'Primary phone number',           '', FALSE, ''),
    ('nw_suppliers', 'fax',           'Fax',           'text', FALSE, 100, 'default',  'default', 'Fax number',                     '', FALSE, ''),
    ('nw_suppliers', 'homepage',      'Homepage',      'text', FALSE, 110, 'default',  'default', 'Supplier website URL',           '', FALSE, '');

-- -----------------------------------------------------
-- nw_products fields
-- -----------------------------------------------------
-- (product_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_products', 'quantity_per_unit', 'Quantity Per Unit',  'text',  FALSE, 40, 'default',  'default', 'Quantity and unit of measure per package',    '', FALSE, ''),
    ('nw_products', 'unit_price',        'Unit Price',         'float', FALSE, 50, 'default',  'default', 'Price per unit',                              '0.0', FALSE, ''),
    ('nw_products', 'units_in_stock',    'Units In Stock',     'int32', FALSE, 60, 'default',  'default', 'Current stock quantity',                      '0',   FALSE, ''),
    ('nw_products', 'units_on_order',    'Units On Order',     'int32', FALSE, 70, 'default',  'default', 'Quantity currently on order from supplier',   '0',   FALSE, ''),
    ('nw_products', 'reorder_level',     'Reorder Level',      'int32', FALSE, 80, 'default',  'default', 'Minimum stock level before reordering',       '0',   FALSE, ''),
    ('nw_products', 'discontinued',      'Discontinued',       'int32', FALSE, 90, 'default',  'default', 'Whether the product is discontinued (1=yes)', '0',   FALSE, '');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_products', 'supplier_id', 'Supplier', 'reference', FALSE, 20, 'default', 'default', 'Supplier providing this product', 'nw_suppliers', 'restrict', FALSE),
    ('nw_products', 'category_id', 'Category', 'reference', FALSE, 30, 'default', 'default', 'Category this product belongs to', 'nw_categories', 'restrict', FALSE);

-- -----------------------------------------------------
-- nw_regions fields
-- -----------------------------------------------------
-- (region_description is auto-created as the label_column; no additional fields needed)

-- -----------------------------------------------------
-- nw_shippers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_shippers', 'phone', 'Phone', 'text', FALSE, 20, 'default', 'default', 'Shipper phone number', '', FALSE, '');

-- -----------------------------------------------------
-- nw_orders fields
-- -----------------------------------------------------
-- (ship_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_orders', 'ship_address',    'Ship Address',     'text',  FALSE, 50,  'default', 'w',       'Street address for shipment',              '', FALSE, ''),
    ('nw_orders', 'ship_city',       'Ship City',        'text',  FALSE, 60,  'default', 'default', 'City for shipment',                        '', TRUE,  ''),
    ('nw_orders', 'ship_region',     'Ship Region',      'text',  FALSE, 70,  'default', 'default', 'State or province for shipment',           '', FALSE, ''),
    ('nw_orders', 'ship_postal_code','Ship Postal Code', 'text',  FALSE, 80,  'default', 'default', 'Postal code for shipment',                 '', FALSE, ''),
    ('nw_orders', 'ship_country',    'Ship Country',     'text',  FALSE, 90,  'default', 'default', 'Country for shipment',                     '', TRUE,  ''),
    ('nw_orders', 'freight',         'Freight',          'float', FALSE, 100, 'default', 'default', 'Freight cost for the order',               '0.0', FALSE, '');

-- order_date and required_date: not nullable with defaults
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_orders', 'order_date',    'Order Date',    'date', FALSE, 110, 'default', 'default', 'Date the order was placed',    'CURRENT_DATE', FALSE, ''),
    ('nw_orders', 'required_date', 'Required Date', 'date', FALSE, 120, 'default', 'default', 'Date the order is required by', 'CURRENT_DATE', FALSE, '');

-- shipped_date: nullable (order may not yet be shipped)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('nw_orders', 'shipped_date', 'Shipped Date', 'date', TRUE, 130, 'default', 'default', 'Date the order was shipped', FALSE, '');

-- FK references on nw_orders (not parent — orders is not a junction/child table)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_orders', 'customer_id',  'Customer',  'reference', FALSE, 10, 'default', 'default', 'Customer who placed the order', 'nw_customers',  'restrict', FALSE),
    ('nw_orders', 'employee_id',  'Employee',  'reference', FALSE, 20, 'default', 'default', 'Employee who handled the order', 'nw_employees',  'restrict', FALSE),
    ('nw_orders', 'ship_via',     'Shipped Via', 'reference', FALSE, 30, 'default', 'default', 'Shipper used for this order',   'nw_shippers',   'restrict', FALSE);

-- -----------------------------------------------------
-- nw_territories fields
-- -----------------------------------------------------
-- (territory_description is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('nw_territories', 'territory_id', 'Territory ID', 'text', FALSE, 10, 'required', 'default', 'Unique code identifying the territory', '', TRUE, TRUE, '');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_territories', 'region_id', 'Region', 'reference', FALSE, 30, 'default', 'default', 'Region this territory belongs to', 'nw_regions', 'restrict', FALSE);

-- -----------------------------------------------------
-- nw_employee_territories fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_employee_territories', 'employee_id',  'Employee',  'parent', FALSE, 10, 'required', 'default', 'Reference to the employee',  'nw_employees',  'restrict', FALSE),
    ('nw_employee_territories', 'territory_id', 'Territory', 'parent', FALSE, 20, 'required', 'default', 'Reference to the territory', 'nw_territories', 'restrict', FALSE);

-- -----------------------------------------------------
-- nw_order_details fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('nw_order_details', 'order_id',   'Order',   'parent', FALSE, 10, 'required', 'default', 'Reference to the order',   'nw_orders',   'restrict', FALSE),
    ('nw_order_details', 'product_id', 'Product', 'parent', FALSE, 20, 'required', 'default', 'Reference to the product', 'nw_products', 'restrict', FALSE);

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_order_details', 'unit_price', 'Unit Price', 'float', FALSE, 30, 'default', 'default', 'Actual price per unit charged on this order', '0.0', FALSE, ''),
    ('nw_order_details', 'quantity',   'Quantity',   'int32', FALSE, 40, 'default', 'default', 'Number of units ordered',                     '0',   FALSE, ''),
    ('nw_order_details', 'discount',   'Discount',   'float', FALSE, 50, 'default', 'default', 'Discount rate applied to this line item',     '0.0', FALSE, '');

-- -----------------------------------------------------
-- nw_us_states fields
-- -----------------------------------------------------
-- (state_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('nw_us_states', 'state_abbr',   'State Abbreviation', 'text', FALSE, 20, 'default', 'default', 'Two-letter state abbreviation',     '', TRUE,  ''),
    ('nw_us_states', 'state_region', 'State Region',       'text', FALSE, 30, 'default', 'default', 'Geographic region the state is in', '', FALSE, '');
