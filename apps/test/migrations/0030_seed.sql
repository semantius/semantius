-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SEED DATA
-- =====================================================
-- Example data to demonstrate the dynamic table system
-- This will create actual tables and fields when executed
-- =====================================================

-- Insert sample modules if they don't exist
INSERT INTO modules (id, module_name, description, view_permission, home_page) VALUES
    (1001, 'CRM', 'Customer Relationship Management', 'sales:read', '/crm/customers'),
    (1002, 'HR', 'Human Resources', 'user:read', DEFAULT),
    (1003, 'Inventory', 'Inventory Management', DEFAULT, '/inventory/products')
ON CONFLICT (id) DO NOTHING;

-- Adjust the sequence counter to ensure next module starts after test modules
SELECT setval('modules_id_seq', (SELECT MAX(id) FROM modules), true);

-- =====================================================
-- RBAC SEED DATA
-- =====================================================
-- Add test users and custom roles (MUST come before dynamic tables!)

-- Add custom permissions for sales module
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('sales:read', 'Permission to read sales information', 1001),
    ('sales:manage', 'Permission to manage sales (includes read, create, update, delete)', 1001);

-- Add custom role "Sales User" for CRM module
INSERT INTO roles (role_name, description, module_id) VALUES
    ('Sales User', 'Sales role with access to CRM module', 1001);

-- Add Sales User role permissions
INSERT INTO role_permissions (role_id, permission_id) 
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.role_name = 'Sales User' 
  AND p.permission_name IN ('sales:read', 'sales:manage');

-- =====================================================
-- SEED DYNAMIC TABLES
-- =====================================================
-- These will automatically create actual database tables
-- with proper RLS policies

-- Test case a: Create "customers" table WITHOUT providing plural value
-- The trigger should auto-set plural = 'customers' (matching table_name)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customers',
    'customer',
    'Customer',
    'Customers',
    'Customer information and contact details',
    1001, -- CRM module
    'public:read',
    'sales:manage',
    'id',
    'customer_name'
);

-- Test case b: Create "employees" table WITH a wrong plural value ('wrongplural')
-- The trigger should ignore 'wrongplural' and auto-set plural = 'employees'
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees',
    'employee',
    'wrongplural',  -- This value should be ignored by the trigger
    'Employee',
    'Employees',
    'Employee records and information',
    1002, -- HR module
    'user:read',
    'admin',
    'id',
    'full_name'
);

-- Test case c: Create "products" table with correct plural value
-- The trigger should still enforce plural = 'products'
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products',
    'product',
    'products',
    'Product',
    'Products',
    'Product catalog and inventory',
    1003, -- Inventory module
    'user:read',
    'sales:manage',
    'id',
    'product_name'
);

-- Test case d: Create "regions" table for CRM module
-- Customers will reference this table with ON DELETE default (restrict), not required
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'regions',
    'region',
    'Region',
    'Regions',
    'Geographic regions for customer segmentation',
    1001, -- CRM module
    'public:read',
    'sales:manage',
    'id',
    'region_name'
);

-- Test case f: Create "product_categories" table for Inventory module
-- Products will reference this table with ON DELETE restrict, required
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'product_categories',
    'product_category',
    'Product Category',
    'Product Categories',
    'Product categories for inventory classification',
    1003, -- Inventory module
    'user:read',
    'sales:manage',
    'id',
    'category_name'
);

-- Test case e: Create "departments" table for HR module
-- Employees will reference this table with ON DELETE restrict, required
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'departments',
    'department',
    'Department',
    'Departments',
    'Organizational departments',
    1002, -- HR module
    'user:read',
    'admin',
    'id',
    'department_name'
);

-- =====================================================
-- SEED DYNAMIC FIELDS
-- =====================================================
-- These will automatically add columns to the tables created above
-- Note: id_column and label_column are created automatically by create_dd_table()
-- so we only add additional custom fields here

-- Add fields to customers table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values, searchable, reference_table, reference_delete_mode)
VALUES 
    ('customers', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'required', 'm', 'Customer primary email address', '', NULL, TRUE, '', ''),
    ('customers', 'company', 'Company Name', 'text', FALSE, FALSE, 20, 'default', 'm', 'Company or organization name', '', NULL, TRUE, '', ''),
    ('customers', 'phone', 'Phone Number', 'text', FALSE, FALSE, 30, 'default', 'm', 'Customer contact phone number', '', NULL, TRUE, '', ''),
    ('customers', 'status', 'Status', 'enum', FALSE, FALSE, 40, 'default', 's', 'Customer account status (active, inactive, etc.)', 'active', '["active", "inactive", "pending", "suspended"]'::jsonb, TRUE, '', ''),
    ('customers', 'total_orders', 'Total Orders', 'int32', FALSE, FALSE, 50, 'readonly', 's', 'Total number of orders placed by customer', '0', NULL, FALSE, '', '');

-- Add reference field from customers to regions (not required, default restrict mode)
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES 
    ('customers', 'region_id', 'Region', 'reference', FALSE, TRUE, 35, 'default', 's', 'Geographic region for this customer', 'regions', 'restrict', FALSE);

-- Add fields to employees table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, searchable, reference_table, reference_delete_mode)
VALUES 
    ('employees', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'required', 'm', 'Employee work email address', '', TRUE, '', ''),
    ('employees', 'position', 'Position', 'text', FALSE, FALSE, 30, 'default', 'm', 'Job title or position', '', TRUE, '', ''),
    ('employees', 'hire_date', 'Hire Date', 'date', FALSE, FALSE, 40, 'default', 'm', 'Date employee was hired', 'CURRENT_DATE', FALSE, '', ''),
    ('employees', 'salary', 'Salary', 'double', FALSE, FALSE, 50, 'default', 'm', 'Annual salary amount', '0.0', FALSE, '', ''),
    ('employees', 'is_active', 'Active', 'boolean', FALSE, FALSE, 60, 'default', 's', 'Whether employee is currently active', 'TRUE', FALSE, '', '');

-- Add reference field from employees to departments (required, restrict mode)
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES 
    ('employees', 'department_id', 'Department', 'reference', FALSE, FALSE, 20, 'required', 's', 'Department this employee belongs to', 'departments', 'restrict', FALSE);

-- Add fields to products table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, searchable, reference_table, reference_delete_mode)
VALUES 
    ('products', 'sku', 'SKU', 'text', FALSE, FALSE, 10, 'required', 'm', 'Stock keeping unit - unique product identifier', '', TRUE, '', ''),
    ('products', 'description', 'Description', 'text', FALSE, FALSE, 20, 'default', 'w', 'Detailed product description', '', TRUE, '', ''),
    ('products', 'price', 'Price', 'double', FALSE, FALSE, 30, 'default', 's', 'Product price in base currency', '0.0', FALSE, '', ''),
    ('products', 'quantity_in_stock', 'Quantity in Stock', 'int32', FALSE, FALSE, 40, 'default', 's', 'Current inventory quantity', '0', FALSE, '', ''),
    ('products', 'is_discontinued', 'Discontinued', 'boolean', FALSE, FALSE, 60, 'default', 's', 'Whether product is no longer available', 'FALSE', FALSE, '', '');

-- Add reference field from products to product_categories (required, restrict mode)
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES 
    ('products', 'category_id', 'Category', 'reference', FALSE, FALSE, 50, 'required', 's', 'Product category classification', 'product_categories', 'restrict', FALSE);

-- Add fields to regions table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, searchable, reference_table, reference_delete_mode)
VALUES 
    ('regions', 'code', 'Region Code', 'text', FALSE, FALSE, 10, 'required', 's', 'Short code for the region', '', TRUE, '', ''),
    ('regions', 'description', 'Description', 'text', FALSE, FALSE, 20, 'default', 'w', 'Detailed description of the region', '', TRUE, '', '');

-- Add fields to departments table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, searchable, reference_table, reference_delete_mode)
VALUES 
    ('departments', 'code', 'Department Code', 'text', FALSE, FALSE, 10, 'required', 's', 'Short code for the department', '', TRUE, '', ''),
    ('departments', 'description', 'Description', 'text', FALSE, FALSE, 20, 'default', 'w', 'Detailed description of the department', '', TRUE, '', ''),
    ('departments', 'budget', 'Annual Budget', 'double', FALSE, FALSE, 30, 'default', 'm', 'Annual budget allocation', '0.0', FALSE, '', '');

-- Add fields to product_categories table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, searchable, reference_table, reference_delete_mode)
VALUES 
    ('product_categories', 'code', 'Category Code', 'text', FALSE, FALSE, 10, 'required', 's', 'Short code for the category', '', TRUE, '', ''),
    ('product_categories', 'description', 'Description', 'text', FALSE, FALSE, 20, 'default', 'w', 'Detailed description of the category', '', TRUE, '', '');

-- =====================================================
-- SEED SAMPLE DATA
-- =====================================================
-- Add some sample data to the dynamically created tables
-- Note: Tables use the default id_column ('id') and label_column ('label')
-- unless specified otherwise in the tables definition

-- Sample regions (inserted BEFORE customers since customers reference regions)
-- Table: regions (id_column: id, label_column: region_name)
INSERT INTO regions (id, region_name, code, description)
VALUES 
    (1, 'North America', 'NA', 'United States, Canada, and Mexico'),
    (2, 'Europe', 'EU', 'European Union countries and associated states'),
    (3, 'Asia Pacific', 'APAC', 'Asia and Pacific region'),
    (4, 'Latin America', 'LATAM', 'Central and South America excluding Mexico');

-- Sample departments (inserted BEFORE employees since employees reference departments)
-- Table: departments (id_column: id, label_column: department_name)
INSERT INTO departments (id, department_name, code, description, budget)
VALUES 
    (1, 'Engineering', 'ENG', 'Product development and engineering', 5000000.00),
    (2, 'Sales', 'SALES', 'Sales and business development', 2000000.00),
    (3, 'Human Resources', 'HR', 'Human resources and talent management', 800000.00),
    (4, 'Marketing', 'MKT', 'Marketing and brand management', 1500000.00);

-- Sample product_categories (inserted BEFORE products since products reference product_categories)
-- Table: product_categories (id_column: id, label_column: category_name)
INSERT INTO product_categories (id, category_name, code, description)
VALUES 
    (1, 'Widgets', 'WGT', 'Widget products and accessories'),
    (2, 'Gadgets', 'GAD', 'Gadget devices and electronics'),
    (3, 'Tools', 'TLS', 'Tools and equipment for various purposes');

-- Sample customers (now with region_id references)
-- Table: customers (id_column: id, label_column: customer_name)
INSERT INTO customers (customer_name, email, phone, company, status, total_orders, region_id)
VALUES 
    ('John Smith', 'john.smith@example.com', '+1-555-0101', 'Acme Corp', 'active', 15, 1),
    ('Jane Doe', 'jane.doe@example.com', '+1-555-0102', 'Tech Solutions', 'active', 8, 1),
    ('Bob Johnson', 'bob.johnson@example.com', '+1-555-0103', 'Global Industries', 'inactive', 3, 1),
    ('Müller Schmidt', 'mueller.schmidt@example.com', '+49-30-12345678', 'Deutsche Bank AG', 'active', 22, 2),
    ('François Dubois', 'francois.dubois@example.com', '+33-1-23456789', 'Société Générale', 'active', 18, 2),
    ('María García', 'maria.garcia@example.com', '+34-91-1234567', 'Banco Santander', 'active', 14, 2),
    ('José Rodríguez', 'jose.rodriguez@example.com', '+34-93-2345678', 'BBVA', 'active', 11, 2),
    ('André Lefèvre', 'andre.lefevre@example.com', '+33-1-34567890', 'BNP Paribas', 'active', 25, 2),
    ('Günther Weber', 'gunther.weber@example.com', '+49-89-23456789', 'Volkswagen AG', 'active', 9, 2),
    ('Björn Andersson', 'bjorn.andersson@example.com', '+46-8-12345678', 'Volvo Group', 'active', 16, 2),
    ('Søren Hansen', 'soren.hansen@example.com', '+45-33-123456', 'Maersk Line', 'active', 13, 2),
    ('Jürgen Fischer', 'jurgen.fischer@example.com', '+49-911-234567', 'Siemens AG', 'active', 20, 2),
    ('Stéphane Martin', 'stephane.martin@example.com', '+33-5-12345678', 'Airbus SE', 'active', 7, 2),
    ('Ángel Fernández', 'angel.fernandez@example.com', '+34-91-3456789', 'Telefónica', 'active', 19, 2),
    ('Håkan Nilsson', 'hakan.nilsson@example.com', '+46-10-1234567', 'Ericsson', 'active', 12, 2),
    ('Michèle Blanc', 'michele.blanc@example.com', '+33-1-45678901', 'Orange SA', 'active', 10, 2),
    ('José Luis Martínez', 'jose.martinez@example.com', '+34-91-4567890', 'Repsol', 'active', 21, 2),
    ('Åsa Bergström', 'asa.bergstrom@example.com', '+46-8-23456789', 'H&M', 'active', 8, 2),
    ('René Dubois', 'rene.dubois@example.com', '+33-1-56789012', 'Total Energies', 'active', 17, 2),
    ('Göran Johansson', 'goran.johansson@example.com', '+46-42-3456789', 'IKEA', 'active', 15, 2),
    ('Jörg Bauer', 'jorg.bauer@example.com', '+49-89-34567890', 'BMW Group', 'active', 23, 2),
    ('François Leroy', 'francois.leroy@example.com', '+33-1-67890123', 'Renault', 'active', 6, 2),
    ('Núria Sánchez', 'nuria.sanchez@example.com', '+34-93-5678901', 'CaixaBank', 'active', 14, 2),
    ('Øyvind Pedersen', 'oyvind.pedersen@example.com', '+47-51-234567', 'Equinor ASA', 'active', 11, 2),
    ('Mário Silva', 'mario.silva@example.com', '+351-21-1234567', 'EDP Energias', 'active', 9, 2),
    ('João Santos', 'joao.santos@example.com', '+351-21-2345678', 'Galp Energia', 'active', 13, 2),
    ('Sébastien Moreau', 'sebastien.moreau@example.com', '+33-4-78901234', 'Michelin', 'active', 18, 2),
    ('Gérard Bernard', 'gerard.bernard@example.com', '+33-1-78901234', 'Danone', 'active', 16, 2),
    ('Ramón López', 'ramon.lopez@example.com', '+34-94-6789012', 'Iberdrola', 'active', 20, 2),
    ('Óscar González', 'oscar.gonzalez@example.com', '+34-93-6789012', 'Naturgy Energy', 'active', 7, 2),
    ('Amélie Petit', 'amelie.petit@example.com', '+33-1-89012345', 'Carrefour', 'active', 12, 2),
    ('Jérôme Roux', 'jerome.roux@example.com', '+33-3-90123456', 'Peugeot', 'active', 19, 2),
    ('Andrés Díaz', 'andres.diaz@example.com', '+34-91-7890123', 'Inditex', 'active', 10, 2),
    ('Ángeles Torres', 'angeles.torres@example.com', '+34-91-8901234', 'El Corte Inglés', 'active', 21, 2),
    ('Rüdiger Meyer', 'rudiger.meyer@example.com', '+49-89-45678901', 'Allianz SE', 'active', 15, 2),
    ('Pär Lindström', 'par.lindstrom@example.com', '+46-8-34567890', 'Spotify AB', 'active', 8, 2),
    ('Jesús Romero', 'jesus.romero@example.com', '+34-91-9012345', 'Abertis', 'active', 17, 2),
    ('Rubén Jiménez', 'ruben.jimenez@example.com', '+34-91-0123456', 'Amadeus IT', 'active', 23, 2),
    ('José María Ruiz', 'jose.ruiz@example.com', '+34-91-1234567', 'Ferrovial', 'active', 6, 2),
    ('Céline Garnier', 'celine.garnier@example.com', '+33-4-01234567', 'Schneider Electric', 'active', 14, 2),
    ('Benoît Faure', 'benoit.faure@example.com', '+33-1-12345678', 'Veolia', 'active', 11, 2),
    ('Andrée Girard', 'andree.girard@example.com', '+33-1-23456789', 'Vinci SA', 'active', 9, 2),
    ('Özgür Yılmaz', 'ozgur.yilmaz@example.com', '+90-212-1234567', 'Turkish Airlines', 'active', 13, 2),
    ('Torbjörn Svensson', 'torbjorn.svensson@example.com', '+46-8-45678901', 'Scania AB', 'active', 18, 2),
    ('Eugène Lambert', 'eugene.lambert@example.com', '+33-1-34567890', 'Sanofi', 'active', 16, 2),
    ('Élise Bonnet', 'elise.bonnet@example.com', '+33-1-45678901', 'L''Oréal', 'active', 20, 2),
    ('Raphaël Durand', 'raphael.durand@example.com', '+33-1-56789012', 'Thales Group', 'active', 7, 2),
    ('Nicolás Vargas', 'nicolas.vargas@example.com', '+34-91-2345678', 'ACS Group', 'active', 12, 2),
    ('Inés Castro', 'ines.castro@example.com', '+34-93-3456789', 'Banco Sabadell', 'active', 19, 2),
    ('Ólafur Jónsson', 'olafur.jonsson@example.com', '+354-5-123456', 'Icelandair', 'active', 10, 2),
    ('Günter Hoffmann', 'gunter.hoffmann@example.com', '+49-511-1234567', 'Continental AG', 'active', 21, 2),
    ('Märta Karlsson', 'marta.karlsson@example.com', '+46-8-56789012', 'Electrolux', 'active', 15, 2),
    ('Frédéric Morel', 'frederic.morel@example.com', '+33-1-67890123', 'Bouygues', 'active', 8, 2),
    ('François-Xavier Simon', 'francois.simon@example.com', '+33-1-78901234', 'Saint-Gobain', 'active', 17, 2),
    ('Hervé Vincent', 'herve.vincent@example.com', '+33-1-89012345', 'Safran', 'active', 23, 2),
    ('João Pedro Costa', 'joao.costa@example.com', '+351-21-3456789', 'Jerónimo Martins', 'active', 6, 2),
    ('Zoë Anderson', 'zoe.anderson@example.com', '+44-20-12345678', 'British Airways', 'active', 14, 2),
    ('Günther Köhler', 'gunther.kohler@example.com', '+49-228-1234567', 'Deutsche Post', 'active', 11, 2),
    ('Émile Leclerc', 'emile.leclerc@example.com', '+33-2-90123456', 'E.Leclerc', 'active', 9, 2),
    ('Gösta Magnusson', 'gosta.magnusson@example.com', '+46-31-1234567', 'SKF AB', 'active', 13, 2),
    ('María José Pérez', 'maria.perez@example.com', '+34-91-4567890', 'NH Hotel Group', 'active', 18, 2),
    ('José Antonio Díaz', 'jose.diaz@example.com', '+34-91-5678901', 'Mapfre', 'active', 16, 2),
    ('Håkon Berg', 'hakon.berg@example.com', '+47-22-123456', 'DNB ASA', 'active', 20, 2),
    ('Björk Guðmundsdóttir', 'bjork.gudmundsdottir@example.com', '+354-5-234567', 'Iceland Foods', 'inactive', 7, 2),
    ('Åse Kristiansen', 'ase.kristiansen@example.com', '+47-51-345678', 'Statoil', 'active', 12, 2),
    ('Björn Ólafsson', 'bjorn.olafsson@example.com', '+354-5-345678', 'WOW Air', 'inactive', 19, 2),
    ('Désirée Fournier', 'desiree.fournier@example.com', '+33-3-12345678', 'Auchan', 'active', 10, 2),
    ('René-Charles Mercier', 'rene.mercier@example.com', '+33-3-23456789', 'Decathlon', 'active', 21, 2),
    ('Noël Rousseau', 'noel.rousseau@example.com', '+33-1-90123456', 'Accor Hotels', 'active', 15, 2),
    ('José Ángel Núñez', 'jose.nunez@example.com', '+34-93-4567890', 'Grifols', 'active', 8, 2),
    ('María Ángeles Vega', 'maria.vega@example.com', '+34-91-6789012', 'Técnicas Reunidas', 'active', 17, 2),
    ('Rubén Gutiérrez', 'ruben.gutierrez@example.com', '+352-26-123456', 'ArcelorMittal', 'active', 23, 2),
    ('Jörgen Lundqvist', 'jorgen.lundqvist@example.com', '+46-8-67890123', 'Alfa Laval', 'active', 6, 2),
    ('Søren Møller', 'soren.moller@example.com', '+45-33-234567', 'Carlsberg Group', 'active', 14, 2),
    ('François Gauthier', 'francois.gauthier@example.com', '+33-4-12345678', 'Groupe SEB', 'active', 11, 2),
    ('Aurélien Dubois', 'aurelien.dubois@example.com', '+33-1-01234567', 'Arkema', 'active', 9, 2),
    ('Björn-Erik Larsson', 'bjorn.larsson@example.com', '+46-8-78901234', 'Atlas Copco', 'active', 13, 2),
    ('Ömer Kaya', 'omer.kaya@example.com', '+90-216-2345678', 'Arçelik', 'active', 18, 2),
    ('Züleyha Demir', 'zuleyha.demir@example.com', '+90-212-3456789', 'Koç Holding', 'active', 16, 2),
    ('Jürgen Müller', 'jurgen.muller@example.com', '+49-6227-1234567', 'SAP SE', 'active', 20, 2),
    ('Rüdiger Schröder', 'rudiger.schroder@example.com', '+49-621-1234567', 'BASF SE', 'active', 7, 2),
    ('Günter Neumann', 'gunter.neumann@example.com', '+49-2173-1234567', 'Bayer AG', 'active', 12, 2),
    ('Jörn Zimmermann', 'jorn.zimmermann@example.com', '+49-211-1234567', 'Henkel AG', 'active', 19, 2),
    ('François-René Petit', 'francois.petit@example.com', '+33-4-23456789', 'Legrand SA', 'active', 10, 2),
    ('Cédric Thomas', 'cedric.thomas@example.com', '+33-1-12345670', 'Sodexo', 'active', 21, 2),
    ('Lucía Fernández', 'lucia.fernandez@example.com', '+34-91-7890123', 'Endesa', 'active', 15, 2),
    ('José Ramón Cruz', 'jose.cruz@example.com', '+34-91-8901234', 'Red Eléctrica', 'active', 8, 2),
    ('María Eugenia Ortiz', 'maria.ortiz@example.com', '+34-91-9012345', 'Aena', 'active', 17, 2),
    ('Aurélien Lefèvre', 'aurelien.lefevre@example.com', '+33-1-23456781', 'Publicis Groupe', 'active', 23, 2),
    ('Sébastien Müller', 'sebastien.muller@example.com', '+33-1-34567892', 'Air Liquide', 'active', 6, 2),
    ('Adrián González', 'adrian.gonzalez@example.com', '+34-96-1234567', 'Acerinox', 'active', 14, 2),
    ('Álvaro Jiménez', 'alvaro.jimenez@example.com', '+34-91-0123457', 'Bankinter', 'active', 11, 2),
    ('María Belén Torres', 'maria.torres@example.com', '+34-93-5678902', 'Cellnex Telecom', 'active', 9, 2),
    ('José Enrique Rojas', 'jose.rojas@example.com', '+34-91-1234568', 'Enagas', 'active', 13, 2),
    ('Björn-Ove Hansen', 'bjorn.hansen@example.com', '+47-67-123456', 'Telenor', 'active', 18, 2),
    ('Renée Martin', 'renee.martin@example.com', '+33-1-45678902', 'Kering', 'active', 16, 2),
    ('Géraldine André', 'geraldine.andre@example.com', '+33-1-56789013', 'Essilor', 'active', 20, 2),
    ('João Gonçalves', 'joao.goncalves@example.com', '+351-22-1234567', 'Sonae', 'active', 7, 2),
    ('António Rodrigues', 'antonio.rodrigues@example.com', '+351-21-4567890', 'Millennium BCP', 'active', 12, 2),
    ('Søren Eriksen', 'soren.eriksen@example.com', '+45-35-123456', 'Novo Nordisk', 'active', 19, 2);

-- Sample employees (now with department_id references)
-- Table: employees (id_column: id, label_column: full_name)
INSERT INTO employees (full_name, email, department_id, position, hire_date, salary, is_active)
VALUES 
    ('Alice Williams', 'alice.williams@company.com', 1, 'Senior Developer', '2020-03-15', 95000, TRUE),
    ('Charlie Brown', 'charlie.brown@company.com', 2, 'Account Manager', '2021-06-01', 75000, TRUE),
    ('Diana Prince', 'diana.prince@company.com', 3, 'HR Manager', '2019-01-10', 80000, TRUE),
    ('Eve Anderson', 'eve.anderson@company.com', 1, 'Junior Developer', '2022-09-01', 65000, TRUE),
    ('Frank Miller', 'frank.miller@company.com', 4, 'Marketing Manager', '2021-02-15', 85000, TRUE);

-- Sample products
-- Table: products (id_column: id, label_column: product_name)
INSERT INTO products (product_name, sku, description, price, quantity_in_stock, category_id, is_discontinued)
VALUES 
    ('Widget Pro', 'WGT-001', 'Professional grade widget', 29.99, 150, 1, FALSE),
    ('Gadget Plus', 'GAD-002', 'Advanced gadget with premium features', 49.99, 75, 2, FALSE),
    ('Tool Basic', 'TL-003', 'Basic tool for everyday use', 19.99, 0, 3, TRUE);

-- =====================================================
-- SEED TEST USERS
-- =====================================================

-- Add test users with fixed Ids for testing
-- user1 is created with last_seen to make them the first user accessing the system
-- This will trigger automatic assignment of Administrator role (role 2)
INSERT INTO users (id, external_id, email, last_seen) VALUES
    (1001, 'user1', 'user@test.com', NULL),
    (1002, 'user2', 'sales@test.com', NULL),
    (1003, 'user3', 'admin@test.com', null);

-- Adjust the sequence counter to the max user_id to avoid conflicts with future auto-generated Ids
SELECT setval('users_id_seq', (SELECT MAX(id) FROM users), true);

-- =====================================================
-- SEED USER-ROLE MAPPINGS
-- =====================================================

-- Note: Role 1 (User) is now auto-assigned by trigger when users are inserted
-- Note: Role 2 (Administrator) is auto-assigned to first user with last_seen (user3)
-- So we only need to add additional custom roles here

-- user2 (sales@test.com) is also a member of the "Sales User" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u, roles r
WHERE u.external_id = 'user2'
  AND r.role_name = 'Sales User';

-- =====================================================
-- SEED WEBHOOK RECEIVER SAMPLE DATA
-- =====================================================

-- Sample webhook receivers (using products table)
INSERT INTO webhook_receivers (label, table_name, description, auth_type, secret, header_name, header_value)
VALUES 
    ('GitHub Webhook', 'products', 'Receives push events from GitHub repositories', 'hmac', 'your-secret-key', '', ''),
    ('Stripe Webhook', 'products', 'Processes payment events from Stripe', 'hmac', 'whsec_test_secret', '', ''),
    ('Simple Webhook', 'products', 'Basic webhook receiver for testing', 'none', '', '', '');

-- Sample webhook receiver logs
-- Note: webhook_id is the label column, so it's not listed separately
INSERT INTO webhook_receiver_logs (webhook_receiver_id, webhook_id, webhook_timestamp, received_timestamp, payload, result, error_message)
VALUES 
    (1, 'gh-evt-12345', '2026-01-01 12:34:00'::timestamptz, '2026-01-01 12:34:01'::timestamptz, '{"action": "push", "ref": "refs/heads/main"}'::jsonb, 20, ''),
    (2, 'evt_1ABC123', '2026-01-01 12:35:00'::timestamptz, '2026-01-01 12:35:01'::timestamptz, '{"type": "payment_intent.succeeded", "amount": 1000}'::jsonb, 20, ''),
    (3, 'test-webhook-001', '2026-01-01 12:36:00'::timestamptz, '2026-01-01 12:36:01'::timestamptz, '{"message": "test"}'::jsonb, 10, ''),
    (1, 'gh-evt-67890', '2026-01-01 12:37:00'::timestamptz, '2026-01-01 12:37:01'::timestamptz, '{"action": "invalid"}'::jsonb, 90, 'Invalid action type');

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================
-- Run these to verify the system is working

-- View all dynamically created tables
-- SELECT table_name, label, view_permission, edit_permission FROM tables;

-- View all fields for a specific table
-- SELECT f.field_name, f.label, f.data_type, f.is_pk, f.is_nullable
-- FROM fields f
-- JOIN tables t ON f.table_id = t.table_id
-- WHERE t.table_name = 'customers'
-- ORDER BY f.field_order;

-- View data from dynamically created tables
-- SELECT * FROM customers;
-- SELECT * FROM employees;
-- SELECT * FROM products;

-- View test users and their roles
-- SELECT u.external_id, u.email, r.role_name
-- FROM users u
-- JOIN user_roles ur ON u.user_id = ur.user_id
-- JOIN roles r ON ur.role_id = r.role_id
-- ORDER BY u.external_id, r.role_name;

-- Test RLS policies (these will only work if proper permissions are set)
-- SELECT * FROM customers; -- Should work with public:read
-- INSERT INTO customers (customer_name, email, status, total_orders) 
-- VALUES ('Test User', 'test@example.com', 'pending', 0); -- Requires user:manage