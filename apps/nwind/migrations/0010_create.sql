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

-- 1. categories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'categories',
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

-- 2. customers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customers',
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

-- 3. employees
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees',
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

-- 4. suppliers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'suppliers',
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

-- 5. products
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products',
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

-- 6. regions
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'regions',
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

-- 7. shippers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'shippers',
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

-- 8. orders
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'orders',
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

-- 9. territories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'territories',
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

-- 10. employee_territories (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employee_territories',
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

-- 11. order_details (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'order_details',
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

-- =====================================================
-- FIELDS
-- =====================================================

-- -----------------------------------------------------
-- categories fields
-- -----------------------------------------------------
-- (category_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('categories', 'description', 'Description', 'text', FALSE, 20, 'default', 'w', 'Description of the product category', '', TRUE, '');

-- -----------------------------------------------------
-- customers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('customers', 'customer_id',    'Customer ID',    'text', FALSE, 10, 'required', 'default', 'Unique short code identifying the customer', '', TRUE,  TRUE,  ''),
    ('customers', 'contact_name',   'Contact Name',   'text', FALSE, 30, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'contact_title',  'Contact Title',  'text', FALSE, 40, 'default',  'default', 'Job title of the primary contact',          '', FALSE, FALSE, ''),
    ('customers', 'address',        'Street Address', 'text', FALSE, 50, 'default',  'w',       '',                                          '', FALSE, FALSE, ''),
    ('customers', 'city',           'City',           'text', FALSE, 60, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'region',         'Region',         'text', FALSE, 70, 'default',  'default', 'State or province',                         '', FALSE, FALSE, ''),
    ('customers', 'postal_code',    'Postal Code',    'text', FALSE, 80, 'default',  'default', 'Postal or ZIP code',                        '', FALSE, FALSE, ''),
    ('customers', 'country',        'Country',        'text', FALSE, 90, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'phone',          'Phone',          'text', FALSE, 100, 'default', 'default', 'Primary phone number',                      '', FALSE, FALSE, ''),
    ('customers', 'fax',            'Fax',            'text', FALSE, 110, 'default', 'default', '',                                          '', FALSE, FALSE, '');

-- -----------------------------------------------------
-- employees fields
-- -----------------------------------------------------
-- (last_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('employees', 'first_name',         'First Name',         'text', FALSE, 20,  'required', 'default', '',                                        '', TRUE,  ''),
    ('employees', 'title',              'Title',              'text', FALSE, 30,  'default',  'default', 'Job title',                               '', FALSE, ''),
    ('employees', 'title_of_courtesy',  'Title of Courtesy',  'text', FALSE, 40,  'default',  'default', 'Courtesy title (Mr., Ms., Dr., etc.)',    '', FALSE, ''),
    ('employees', 'address',            'Street Address',     'text', FALSE, 60,  'default',  'w',       '',                                        '', FALSE, ''),
    ('employees', 'city',               'City',               'text', FALSE, 70,  'default',  'default', '',                                        '', TRUE,  ''),
    ('employees', 'region',             'Region',             'text', FALSE, 80,  'default',  'default', 'State or province',                       '', FALSE, ''),
    ('employees', 'postal_code',        'Postal Code',        'text', FALSE, 90,  'default',  'default', 'Postal or ZIP code',                      '', FALSE, ''),
    ('employees', 'country',            'Country',            'text', FALSE, 100, 'default',  'default', '',                                        '', TRUE,  ''),
    ('employees', 'home_phone',         'Home Phone',         'text', FALSE, 110, 'default',  'default', '',                                        '', FALSE, ''),
    ('employees', 'extension',          'Extension',          'text', FALSE, 120, 'default',  'default', 'Phone extension',                         '', FALSE, ''),
    ('employees', 'notes',              'Notes',              'text', FALSE, 130, 'default',  'w',       '',                                        '', FALSE, ''),
    ('employees', 'photo_path',         'Photo Path',         'text', FALSE, 140, 'default',  'default', '',                                        '', FALSE, '');

-- birth_date: nullable (no sensible default)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('employees', 'birth_date', 'Birth Date', 'date', TRUE, 50, 'default', 'default', '', FALSE, '');

-- hire_date: not nullable with default
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('employees', 'hire_date', 'Hire Date', 'date', FALSE, 55, 'default', 'default', '', 'CURRENT_DATE', FALSE, '');

-- reports_to: self-reference, nullable
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('employees', 'reports_to', 'Reports To', 'reference', TRUE, 150, 'default', 'default', 'Manager this employee reports to', 'employees', 'restrict', FALSE);

-- -----------------------------------------------------
-- suppliers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('suppliers', 'contact_name',  'Contact Name',  'text', FALSE, 20,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'contact_title', 'Contact Title', 'text', FALSE, 30,  'default',  'default', 'Job title of the primary contact', '', FALSE, ''),
    ('suppliers', 'address',       'Street Address','text', FALSE, 40,  'default',  'w',       '',                               '', FALSE, ''),
    ('suppliers', 'city',          'City',          'text', FALSE, 50,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'region',        'Region',        'text', FALSE, 60,  'default',  'default', 'State or province',              '', FALSE, ''),
    ('suppliers', 'postal_code',   'Postal Code',   'text', FALSE, 70,  'default',  'default', 'Postal or ZIP code',             '', FALSE, ''),
    ('suppliers', 'country',       'Country',       'text', FALSE, 80,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'phone',         'Phone',         'text', FALSE, 90,  'default',  'default', 'Primary phone number',           '', FALSE, ''),
    ('suppliers', 'fax',           'Fax',           'text', FALSE, 100, 'default',  'default', '',                               '', FALSE, ''),
    ('suppliers', 'homepage',      'Homepage',      'text', FALSE, 110, 'default',  'default', 'Supplier website URL',           '', FALSE, '');

-- -----------------------------------------------------
-- products fields
-- -----------------------------------------------------
-- (product_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype, cube_type)
VALUES
    ('products', 'quantity_per_unit', 'Quantity Per Unit',  'text',    FALSE, 40, 'default',  'default', 'Quantity and unit of measure per package',    '',      FALSE, '', 'auto'),
    ('products', 'unit_price',        'Unit Price',         'float',   FALSE, 50, 'default',  'default', '',                                            '0.0',   FALSE, '', 'auto'),
    ('products', 'units_in_stock',    'Units In Stock',     'int32',   FALSE, 60, 'default',  'default', 'Current stock quantity',                      '0',     FALSE, '', 'measure'),
    ('products', 'units_on_order',    'Units On Order',     'int32',   FALSE, 70, 'default',  'default', 'Quantity currently on order from supplier',   '0',     FALSE, '', 'measure'),
    ('products', 'reorder_level',     'Reorder Level',      'int32',   FALSE, 80, 'default',  'default', 'Minimum stock level before reordering',       '0',     FALSE, '', 'measure'),
    ('products', 'discontinued',      'Discontinued',       'boolean', FALSE, 90, 'default',  'default', 'Whether the product is discontinued',         'FALSE', FALSE, '', 'auto');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('products', 'supplier_id', 'Supplier', 'reference', FALSE, 20, 'default', 'default', 'Supplier providing this product', 'suppliers', 'restrict', FALSE),
    ('products', 'category_id', 'Category', 'reference', FALSE, 30, 'default', 'default', 'Category this product belongs to', 'categories', 'restrict', FALSE);

-- -----------------------------------------------------
-- regions fields
-- -----------------------------------------------------
-- (region_description is auto-created as the label_column; no additional fields needed)

-- -----------------------------------------------------
-- shippers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('shippers', 'phone', 'Phone', 'text', FALSE, 20, 'default', 'default', '', '', FALSE, '');

-- -----------------------------------------------------
-- orders fields
-- -----------------------------------------------------
-- (ship_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('orders', 'ship_address',    'Ship Address',     'text',  FALSE, 50,  'default', 'w',       '',                                         '', FALSE, ''),
    ('orders', 'ship_city',       'Ship City',        'text',  FALSE, 60,  'default', 'default', '',                                         '', TRUE,  ''),
    ('orders', 'ship_region',     'Ship Region',      'text',  FALSE, 70,  'default', 'default', 'State or province for shipment',           '', FALSE, ''),
    ('orders', 'ship_postal_code','Ship Postal Code', 'text',  FALSE, 80,  'default', 'default', '',                                         '', FALSE, ''),
    ('orders', 'ship_country',    'Ship Country',     'text',  FALSE, 90,  'default', 'default', '',                                         '', TRUE,  ''),
    ('orders', 'freight',         'Freight',          'float', FALSE, 100, 'default', 'default', 'Freight cost for the order',               '0.0', FALSE, '');

-- order_date and required_date: not nullable with defaults
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('orders', 'order_date',    'Order Date',    'date', FALSE, 110, 'default', 'default', '',    'CURRENT_DATE', FALSE, ''),
    ('orders', 'required_date', 'Required Date', 'date', FALSE, 120, 'default', 'default', '', 'CURRENT_DATE', FALSE, '');

-- shipped_date: nullable (order may not yet be shipped)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('orders', 'shipped_date', 'Shipped Date', 'date', TRUE, 130, 'default', 'default', '', FALSE, '');

-- FK references on orders (not parent — orders is not a junction/child table)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('orders', 'customer_id',  'Customer',  'reference', FALSE, 10, 'default', 'default', 'Customer who placed the order', 'customers',  'restrict', FALSE),
    ('orders', 'employee_id',  'Employee',  'reference', FALSE, 20, 'default', 'default', 'Employee who handled the order', 'employees',  'restrict', FALSE),
    ('orders', 'ship_via',     'Shipped Via', 'reference', FALSE, 30, 'default', 'default', 'Shipper used for this order',   'shippers',   'restrict', FALSE);

-- -----------------------------------------------------
-- territories fields
-- -----------------------------------------------------
-- (territory_description is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('territories', 'territory_id', 'Territory ID', 'text', FALSE, 10, 'required', 'default', 'Unique code identifying the territory', '', TRUE, TRUE, '');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('territories', 'region_id', 'Region', 'reference', FALSE, 30, 'default', 'default', 'Region this territory belongs to', 'regions', 'restrict', FALSE);

-- -----------------------------------------------------
-- employee_territories fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('employee_territories', 'employee_id',  'Employee',  'parent', FALSE, 10, 'required', 'default', 'Reference to the employee',  'employees',  'restrict', FALSE),
    ('employee_territories', 'territory_id', 'Territory', 'parent', FALSE, 20, 'required', 'default', 'Reference to the territory', 'territories', 'restrict', FALSE);

-- -----------------------------------------------------
-- order_details fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('order_details', 'order_id',   'Order',   'parent', FALSE, 10, 'required', 'default', 'Reference to the order',   'orders',   'restrict', FALSE),
    ('order_details', 'product_id', 'Product', 'parent', FALSE, 20, 'required', 'default', 'Reference to the product', 'products', 'restrict', FALSE);

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype, cube_type)
VALUES
    ('order_details', 'unit_price', 'Unit Price', 'float', FALSE, 30, 'default', 'default', 'Actual price per unit charged on this order', '0.0', FALSE, '', 'auto'),
    ('order_details', 'quantity',   'Quantity',   'int32', FALSE, 40, 'default', 'default', 'Number of units ordered',                     '0',   FALSE, '', 'measure'),
    ('order_details', 'discount',   'Discount',   'float', FALSE, 50, 'default', 'default', 'Discount rate applied to this line item',     '0.0', FALSE, '', 'auto');



-- =====================================================
-- ROLE PERMISSIONS
-- =====================================================

-- Grant nwind:view and nwind:manage to role 2
INSERT INTO role_permissions (role_id, permission_id)
SELECT 2, p.id
FROM permissions p
WHERE p.permission_name IN ('nwind:view', 'nwind:manage')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = 2 AND rp.permission_id = p.id
  );

-- Grant nwind:view and nwind:manage to role 10001 (Sales User) if it exists
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permissions p
WHERE r.id = 10001
  AND r.role_name = 'Sales User'
  AND p.permission_name IN ('nwind:view', 'nwind:manage')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );
