-- =====================================================
-- NORTHWIND TEST SEED
-- =====================================================
-- Deploys the Northwind entity definitions and a minimal
-- subset of data for use in the nwind test suite.
-- Mirrors apps/nwind/migrations/ for the test environment.
-- =====================================================

-- =====================================================
-- MODULE AND PERMISSIONS
-- =====================================================

INSERT INTO modules (module_name, description, view_permission, home_page)
VALUES ('nwind', 'Northwind Sample Database', 'nwind:view', '/nwind');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('nwind:view',   'Permission to view Northwind data',   (SELECT id FROM modules WHERE module_name = 'nwind')),
    ('nwind:manage', 'Permission to manage Northwind data', (SELECT id FROM modules WHERE module_name = 'nwind'));

INSERT INTO permission_hierarchy (parent_permission_id, child_permission_id)
SELECT p.id, c.id
FROM permissions p, permissions c
WHERE p.permission_name = 'nwind:manage'
  AND c.permission_name = 'nwind:view';

-- =====================================================
-- ENTITIES (in dependency order)
-- =====================================================

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'categories', 'category', 'Category', 'Categories',
    'Product categories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'category_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'suppliers', 'supplier', 'Supplier', 'Suppliers',
    'Product suppliers',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'company_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customer_demographics', 'customer_demographic', 'Customer Demographic', 'Customer Demographics',
    'Customer demographic types',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'customer_desc'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customers', 'customer', 'Customer', 'Customers',
    'Northwind customers',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'company_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'regions', 'region', 'Region', 'Regions',
    'Geographic sales regions',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'region_description'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'shippers', 'shipper', 'Shipper', 'Shippers',
    'Shipping companies',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'company_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees', 'employee', 'Employee', 'Employees',
    'Northwind employees',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'last_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products', 'product', 'Product', 'Products',
    'Northwind products',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'product_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'territories', 'territory', 'Territory', 'Territories',
    'Sales territories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'territory_description'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'orders', 'order', 'Order', 'Orders',
    'Customer orders',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'ship_name'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customer_customer_demo', 'customer_customer_demo', 'Customer Demographic Assignment', 'Customer Demographic Assignments',
    'Links customers to their demographics',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'label'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employee_territories', 'employee_territory', 'Employee Territory', 'Employee Territories',
    'Links employees to their sales territories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'label'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'order_details', 'order_detail', 'Order Detail', 'Order Details',
    'Individual line items in orders',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'label'
);

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'us_states', 'us_state', 'US State', 'US States',
    'United States and territories',
    (SELECT id FROM modules WHERE module_name = 'nwind'),
    'nwind:view', 'nwind:manage', 'id', 'state_name'
);

-- =====================================================
-- FIELDS
-- =====================================================

-- categories
-- (category_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('categories', 'description',   'Description',   'text', FALSE, 20, 'default',  'w',       'Category description',          '', TRUE, '');

-- suppliers
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('suppliers', 'contact_name',   'Contact Name',   'text', FALSE, 20,  'default',  'default', 'Supplier contact person',      '', TRUE,  ''),
    ('suppliers', 'contact_title',  'Contact Title',  'text', FALSE, 30,  'default',  'default', 'Contact person title',         '', FALSE, ''),
    ('suppliers', 'address',        'Address',        'text', FALSE, 40,  'default',  'default', 'Street address',               '', FALSE, ''),
    ('suppliers', 'city',           'City',           'text', FALSE, 50,  'default',  'default', 'City',                         '', TRUE,  ''),
    ('suppliers', 'region',         'Region',         'text', FALSE, 60,  'default',  'default', 'State or region',              '', FALSE, ''),
    ('suppliers', 'postal_code',    'Postal Code',    'text', FALSE, 70,  'default',  'default', 'Postal/zip code',              '', FALSE, ''),
    ('suppliers', 'country',        'Country',        'text', FALSE, 80,  'default',  'default', 'Country',                      '', TRUE,  ''),
    ('suppliers', 'phone',          'Phone',          'text', FALSE, 90,  'default',  'default', 'Phone number',                 '', FALSE, ''),
    ('suppliers', 'fax',            'Fax',            'text', FALSE, 100, 'default',  'default', 'Fax number',                   '', FALSE, ''),
    ('suppliers', 'homepage',       'Homepage',       'text', FALSE, 110, 'default',  'default', 'Supplier web site',            '', FALSE, '');

-- customer_demographics
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('customer_demographics', 'customer_type_id', 'Customer Type ID', 'text', FALSE, 10, 'required', 'default', 'Original customer type identifier', '', FALSE, TRUE, '');

-- customers
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('customers', 'customer_id',    'Customer ID',    'text', FALSE, 10,  'required', 'default', 'Original Northwind customer identifier', '', TRUE,  TRUE,  ''),
    ('customers', 'contact_name',   'Contact Name',   'text', FALSE, 30,  'default',  'default', 'Primary contact name',                  '', TRUE,  FALSE, ''),
    ('customers', 'contact_title',  'Contact Title',  'text', FALSE, 40,  'default',  'default', 'Contact person job title',              '', FALSE, FALSE, ''),
    ('customers', 'address',        'Address',        'text', FALSE, 50,  'default',  'default', 'Street address',                        '', FALSE, FALSE, ''),
    ('customers', 'city',           'City',           'text', FALSE, 60,  'default',  'default', 'City',                                  '', TRUE,  FALSE, ''),
    ('customers', 'region',         'Region',         'text', FALSE, 70,  'default',  'default', 'State or region',                       '', FALSE, FALSE, ''),
    ('customers', 'postal_code',    'Postal Code',    'text', FALSE, 80,  'default',  'default', 'Postal/zip code',                       '', FALSE, FALSE, ''),
    ('customers', 'country',        'Country',        'text', FALSE, 90,  'default',  'default', 'Country',                               '', TRUE,  FALSE, ''),
    ('customers', 'phone',          'Phone',          'text', FALSE, 100, 'default',  'default', 'Phone number',                          '', FALSE, FALSE, ''),
    ('customers', 'fax',            'Fax',            'text', FALSE, 110, 'default',  'default', 'Fax number',                            '', FALSE, FALSE, '');

-- regions
-- (region_description is auto-created as the label_column; no additional fields needed)

-- shippers
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('shippers', 'phone',        'Phone',        'text', FALSE, 20, 'default',  'default', 'Phone number',          '', FALSE, '');

-- employees (non-reference fields)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('employees', 'first_name',         'First Name',         'text',  FALSE, 20,  'required', 'default', 'Employee first name',                   '',             TRUE,  ''),
    ('employees', 'title',              'Title',              'text',  FALSE, 30,  'default',  'default', 'Job title',                             '',             FALSE, ''),
    ('employees', 'title_of_courtesy',  'Title of Courtesy',  'text',  FALSE, 40,  'default',  'default', 'Courtesy title (Mr., Ms., Dr., etc.)', '',             FALSE, ''),
    ('employees', 'birth_date',         'Birth Date',         'date',  TRUE,  50,  'default',  'default', 'Date of birth',                         '',             FALSE, ''),
    ('employees', 'hire_date',          'Hire Date',          'date',  FALSE, 60,  'default',  'default', 'Date of hire',                          'CURRENT_DATE', FALSE, ''),
    ('employees', 'address',            'Address',            'text',  FALSE, 70,  'default',  'default', 'Home address',                          '',             FALSE, ''),
    ('employees', 'city',               'City',               'text',  FALSE, 80,  'default',  'default', 'City',                                  '',             FALSE, ''),
    ('employees', 'region',             'Region',             'text',  FALSE, 90,  'default',  'default', 'State or region',                       '',             FALSE, ''),
    ('employees', 'postal_code',        'Postal Code',        'text',  FALSE, 100, 'default',  'default', 'Postal/zip code',                       '',             FALSE, ''),
    ('employees', 'country',            'Country',            'text',  FALSE, 110, 'default',  'default', 'Country',                               '',             FALSE, ''),
    ('employees', 'home_phone',         'Home Phone',         'text',  FALSE, 120, 'default',  'default', 'Home phone number',                     '',             FALSE, ''),
    ('employees', 'extension',          'Extension',          'text',  FALSE, 130, 'default',  'default', 'Internal phone extension',              '',             FALSE, ''),
    ('employees', 'notes',              'Notes',              'text',  FALSE, 140, 'default',  'w',       'Employee notes and background',          '',             FALSE, ''),
    ('employees', 'photo_path',         'Photo Path',         'text',  FALSE, 150, 'default',  'default', 'Path to employee photo',                '',             FALSE, '');

-- employees self-reference (reports_to)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('employees', 'reports_to', 'Reports To', 'reference', TRUE, 160, 'default', 'default', 'Manager this employee reports to', 'employees', 'restrict', FALSE);

-- products (non-reference fields)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('products', 'quantity_per_unit', 'Quantity Per Unit', 'text',  FALSE, 30, 'default',  'default', 'Quantity per unit description',             '', FALSE, ''),
    ('products', 'unit_price',        'Unit Price',        'float', FALSE, 40, 'default',  'default', 'Price per unit',                            '0.0', FALSE, ''),
    ('products', 'units_in_stock',    'Units In Stock',    'int32', FALSE, 50, 'default',  'default', 'Current units in stock',                    '0', FALSE, ''),
    ('products', 'units_on_order',    'Units On Order',    'int32', FALSE, 60, 'default',  'default', 'Units currently on order',                  '0', FALSE, ''),
    ('products', 'reorder_level',     'Reorder Level',     'int32', FALSE, 70, 'default',  'default', 'Minimum stock level before reorder',        '0', FALSE, ''),
    ('products', 'discontinued',      'Discontinued',      'int32', FALSE, 80, 'default',  'default', 'Whether product is discontinued (1=yes, 0=no)', '0', FALSE, '');

-- products reference fields
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('products', 'supplier_id', 'Supplier', 'reference', TRUE, 20, 'default', 'default', 'Product supplier',  'suppliers',  'restrict', FALSE),
    ('products', 'category_id', 'Category', 'reference', TRUE, 25, 'default', 'default', 'Product category',  'categories', 'restrict', FALSE);

-- territories
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('territories', 'territory_id', 'Territory ID', 'text', FALSE, 10, 'required', 'default', 'Original Northwind territory identifier', '', FALSE, TRUE, '');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('territories', 'region_id', 'Region', 'reference', FALSE, 30, 'required', 'default', 'Geographic region for this territory', 'regions', 'restrict', FALSE);

-- orders (non-reference fields)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('orders', 'order_date',        'Order Date',        'date',  FALSE, 20,  'default',  'default', 'Date the order was placed',    'CURRENT_DATE', FALSE, ''),
    ('orders', 'required_date',     'Required Date',     'date',  FALSE, 30,  'default',  'default', 'Date order is required',       'CURRENT_DATE', FALSE, ''),
    ('orders', 'shipped_date',      'Shipped Date',      'date',  TRUE,  40,  'default',  'default', 'Date order was shipped',       '',             FALSE, ''),
    ('orders', 'freight',           'Freight',           'float', FALSE, 60,  'default',  'default', 'Freight charge',               '0.0',          FALSE, ''),
    ('orders', 'ship_address',      'Ship Address',      'text',  FALSE, 80,  'default',  'default', 'Shipping address',             '',             FALSE, ''),
    ('orders', 'ship_city',         'Ship City',         'text',  FALSE, 90,  'default',  'default', 'Shipping city',                '',             FALSE, ''),
    ('orders', 'ship_region',       'Ship Region',       'text',  FALSE, 100, 'default',  'default', 'Shipping region/state',        '',             FALSE, ''),
    ('orders', 'ship_postal_code',  'Ship Postal Code',  'text',  FALSE, 110, 'default',  'default', 'Shipping postal code',         '',             FALSE, ''),
    ('orders', 'ship_country',      'Ship Country',      'text',  FALSE, 120, 'default',  'default', 'Shipping country',             '',             FALSE, '');

-- orders reference fields
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('orders', 'customer_id', 'Customer',  'reference', TRUE, 10, 'default', 'default', 'Customer who placed the order',    'customers', 'restrict', FALSE),
    ('orders', 'employee_id', 'Employee',  'reference', TRUE, 15, 'default', 'default', 'Employee who handled the order',   'employees', 'restrict', FALSE),
    ('orders', 'ship_via',    'Ship Via',  'reference', TRUE, 50, 'default', 'default', 'Shipping method/company',          'shippers',  'restrict', FALSE);

-- customer_customer_demo (junction table - uses 'parent' format to auto-set is_child=TRUE)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('customer_customer_demo', 'customer_id',            'Customer',  'parent', FALSE, 10, 'required', 'default', 'Reference to customer',             'customers',             'restrict', FALSE),
    ('customer_customer_demo', 'customer_demographics_id', 'Customer Demographic', 'parent', FALSE, 20, 'required', 'default', 'Reference to customer demographic', 'customer_demographics', 'restrict', FALSE);

-- employee_territories (junction table)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('employee_territories', 'employee_id',  'Employee',  'parent', FALSE, 10, 'required', 'default', 'Reference to employee',  'employees',  'restrict', FALSE),
    ('employee_territories', 'territory_id', 'Territory', 'parent', FALSE, 20, 'required', 'default', 'Reference to territory', 'territories', 'restrict', FALSE);

-- order_details (junction table)
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('order_details', 'unit_price', 'Unit Price', 'float', FALSE, 30, 'default', 'default', 'Price at time of order',    '0.0', FALSE, ''),
    ('order_details', 'quantity',   'Quantity',   'int32', FALSE, 40, 'default', 'default', 'Quantity ordered',          '0',   FALSE, ''),
    ('order_details', 'discount',   'Discount',   'float', FALSE, 50, 'default', 'default', 'Discount percentage applied', '0.0', FALSE, '');

INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES
    ('order_details', 'order_id',   'Order',   'parent', FALSE, 10, 'required', 'default', 'Reference to order',   'orders',   'restrict', FALSE),
    ('order_details', 'product_id', 'Product', 'parent', FALSE, 20, 'required', 'default', 'Reference to product', 'products', 'restrict', FALSE);

-- us_states
INSERT INTO fields (table_name, field_name, title, format, is_nullable, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('us_states', 'state_abbr',   'Abbreviation', 'text', FALSE, 20, 'default',  'default', 'Two-letter state abbreviation', '', TRUE,  ''),
    ('us_states', 'state_region', 'Region',       'text', FALSE, 30, 'default',  'default', 'Geographic region of the state', '', FALSE, '');

-- =====================================================
-- MINIMAL TEST DATA
-- =====================================================

-- regions
INSERT INTO regions (id, region_description) VALUES
    (1, 'Eastern'),
    (2, 'Western'),
    (3, 'Northern'),
    (4, 'Southern');

SELECT setval('regions_id_seq', (SELECT MAX(id) FROM regions), true);

-- categories
INSERT INTO categories (id, category_name, description) VALUES
    (1, 'Beverages',    'Soft drinks, coffees, teas, beers, and ales'),
    (2, 'Condiments',   'Sweet and savory sauces, relishes, spreads, and seasonings'),
    (3, 'Confections',  'Desserts, candies, and sweet breads');

SELECT setval('categories_id_seq', (SELECT MAX(id) FROM categories), true);

-- shippers
INSERT INTO shippers (id, company_name, phone) VALUES
    (1, 'Speedy Express',   '(503) 555-9831'),
    (2, 'United Package',   '(503) 555-3199'),
    (3, 'Federal Shipping', '(503) 555-9931');

SELECT setval('shippers_id_seq', (SELECT MAX(id) FROM shippers), true);

-- suppliers
INSERT INTO suppliers (id, company_name, contact_name, contact_title, address, city, region, postal_code, country, phone, fax, homepage) VALUES
    (1, 'Exotic Liquids', 'Charlotte Cooper', 'Purchasing Manager', '49 Gilbert St.', 'London', '', 'EC1 4SD', 'UK', '(171) 555-2222', '', ''),
    (2, 'New Orleans Cajun Delights', 'Shelley Burke', 'Order Administrator', 'P.O. Box 78934', 'New Orleans', 'LA', '70117', 'USA', '(100) 555-4822', '', '#CAJUN.HTM#');

SELECT setval('suppliers_id_seq', (SELECT MAX(id) FROM suppliers), true);

-- customers
INSERT INTO customers (customer_id, company_name, contact_name, contact_title, address, city, region, postal_code, country, phone, fax) VALUES
    ('ALFKI', 'Alfreds Futterkiste',             'Maria Anders',   'Sales Representative', 'Obere Str. 57',                  'Berlin',    '', '12209', 'Germany', '030-0074321',  '030-0076545'),
    ('ANATR', 'Ana Trujillo Emparedados y helados', 'Ana Trujillo', 'Owner',               'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico',  '(5) 555-4729', '(5) 555-3745'),
    ('ANTON', 'Antonio Moreno Taquería',          'Antonio Moreno', 'Owner',               'Mataderos  2312',               'México D.F.', '', '05023', 'Mexico',  '(5) 555-3932', '');

-- employees (insert without reports_to first)
INSERT INTO employees (id, last_name, first_name, title, title_of_courtesy, birth_date, hire_date, address, city, region, postal_code, country, home_phone, extension, notes, photo_path) VALUES
    (1, 'Davolio', 'Nancy',  'Sales Representative',    'Ms.', '1948-12-08', '1992-05-01', '507 - 20th Ave. E.', 'Seattle', 'WA', '98122', 'USA', '(206) 555-9857', '5467', 'Nancy is a member of Toastmasters International.', 'http://accweb/emmployees/davolio.bmp'),
    (2, 'Fuller',  'Andrew', 'Vice President, Sales',   'Dr.', '1952-02-19', '1992-08-14', '908 W. Capital Way', 'Tacoma',  'WA', '98401', 'USA', '(206) 555-9482', '3457', 'Andrew received his BTS commercial in 1974.', 'http://accweb/emmployees/fuller.bmp');

UPDATE employees SET reports_to = 2 WHERE id = 1;

SELECT setval('employees_id_seq', (SELECT MAX(id) FROM employees), true);

-- products
INSERT INTO products (id, product_name, supplier_id, category_id, quantity_per_unit, unit_price, units_in_stock, units_on_order, reorder_level, discontinued) VALUES
    (1,  'Chai',           1, 1, '10 boxes x 20 bags', 18.00, 39, 0, 10, 0),
    (2,  'Chang',          1, 1, '24 - 12 oz bottles', 19.00, 17, 40, 25, 0),
    (3,  'Aniseed Syrup',  1, 2, '12 - 550 ml bottles', 10.00, 13, 70, 25, 0);

SELECT setval('products_id_seq', (SELECT MAX(id) FROM products), true);

-- territories
INSERT INTO territories (territory_id, territory_description, region_id) VALUES
    ('01581', 'Westboro',  1),
    ('01730', 'Bedford',   1),
    ('02116', 'Boston',    1);

-- orders (reference only customers ALFKI, ANATR and employees 1, 2 from test data)
WITH customer_map AS (
    SELECT customer_id AS code, id FROM customers
)
INSERT INTO orders (id, customer_id, employee_id, order_date, required_date, shipped_date, ship_via, freight, ship_name, ship_address, ship_city, ship_region, ship_postal_code, ship_country)
SELECT d.order_id, c.id, d.employee_id, d.order_date, d.required_date, d.shipped_date, d.ship_via, d.freight, d.ship_name, d.ship_address, d.ship_city, d.ship_region, d.ship_postal_code, d.ship_country
FROM (VALUES
    (10248::integer, 'ALFKI'::text, 1::integer, '2026-01-01'::date, '2026-02-01'::date, '2026-01-16'::date, 3::integer, 32.38::real, 'Alfreds Futterkiste'::text, 'Obere Str. 57'::text, 'Berlin'::text, ''::text, '12209'::text, 'Germany'::text),
    (10249::integer, 'ANATR'::text, 2::integer, '2026-01-05'::date, '2026-02-16'::date, '2026-01-10'::date, 1::integer, 11.61::real, 'Ana Trujillo'::text,         'Avda. de la Constitución 2222'::text, 'México D.F.'::text, ''::text, '05021'::text, 'Mexico'::text)
) AS d(order_id, cust_code, employee_id, order_date, required_date, shipped_date, ship_via, freight, ship_name, ship_address, ship_city, ship_region, ship_postal_code, ship_country)
LEFT JOIN customer_map c ON c.code = d.cust_code;

SELECT setval('orders_id_seq', (SELECT MAX(id) FROM orders), true);

-- order_details (reference products 1, 2, 3 from test data)
INSERT INTO order_details (order_id, product_id, unit_price, quantity, discount) VALUES
    (10248, 1, 18.00, 12, 0.0),
    (10248, 2, 19.00, 10, 0.0),
    (10249, 3, 10.00,  9, 0.0);

-- employee_territories
WITH territory_map AS (
    SELECT territory_id AS code, id FROM territories
)
INSERT INTO employee_territories (employee_id, territory_id)
SELECT d.emp_id, t.id
FROM (VALUES
    (1, '01581'::text),
    (1, '01730'::text),
    (2, '01581'::text)
) AS d(emp_id, terr_code)
JOIN territory_map t ON t.code = d.terr_code;

-- us_states (sample)
INSERT INTO us_states (id, state_name, state_abbr, state_region) VALUES
    (1, 'Alabama',    'AL', 'south'),
    (2, 'Alaska',     'AK', 'west'),
    (3, 'Arizona',    'AZ', 'west'),
    (4, 'California', 'CA', 'west'),
    (5, 'Colorado',   'CO', 'west');

SELECT setval('us_states_id_seq', (SELECT MAX(id) FROM us_states), true);
