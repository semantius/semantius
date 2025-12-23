-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SEED DATA
-- =====================================================
-- Example data to demonstrate the dynamic table system
-- This will create actual tables and fields when executed
-- =====================================================

-- Insert sample modules if they don't exist
INSERT INTO modules (id, module_name, description, view_permission) VALUES
    (1001, 'CRM', 'Customer Relationship Management', 'sales:read'),
    (1002, 'HR', 'Human Resources', 'user:read'),
    (1003, 'Inventory', 'Inventory Management', DEFAULT)
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
INSERT INTO tables (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
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
INSERT INTO tables (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
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
INSERT INTO tables (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products',
    'product',
    'products',
    'Product',
    'Products',
    'Product catalog and inventory',
    1003, -- Inventory module
    'sales:read',
    'sales:manage',
    'id',
    'product_name'
);

-- =====================================================
-- SEED DYNAMIC FIELDS
-- =====================================================
-- These will automatically add columns to the tables created above
-- Note: id_column and label_column are created automatically by create_dd_table()
-- so we only add additional custom fields here

-- Add fields to customers table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value, enum_values)
VALUES 
    ('customers', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'required', 'm', 'Customer primary email address', NULL, NULL),
    ('customers', 'phone', 'Phone Number', 'text', FALSE, TRUE, 20, 'default', 'm', 'Customer contact phone number', NULL, NULL),
    ('customers', 'company', 'Company Name', 'text', FALSE, TRUE, 30, 'default', 'm', 'Company or organization name', NULL, NULL),
    ('customers', 'status', 'Status', 'text', FALSE, FALSE, 40, 'default', 's', 'Customer account status (active, inactive, etc.)', '''active''', '["active", "inactive", "pending", "suspended"]'::jsonb),
    ('customers', 'total_orders', 'Total Orders', 'int32', FALSE, FALSE, 50, 'readonly', 's', 'Total number of orders placed by customer', '0', NULL);

-- Add fields to employees table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
VALUES 
    ('employees', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'required', 'm', 'Employee work email address'),
    ('employees', 'department', 'Department', 'text', FALSE, FALSE, 20, 'default', 'm', 'Department or division'),
    ('employees', 'position', 'Position', 'text', FALSE, FALSE, 30, 'default', 'm', 'Job title or position'),
    ('employees', 'hire_date', 'Hire Date', 'date', FALSE, FALSE, 40, 'default', 'm', 'Date employee was hired'),
    ('employees', 'salary', 'Salary', 'double', FALSE, TRUE, 50, 'default', 'm', 'Annual salary amount'),
    ('employees', 'is_active', 'Active', 'boolean', FALSE, FALSE, 60, 'default', 's', 'Whether employee is currently active');

-- Add fields to products table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, default_value)
VALUES 
    ('products', 'sku', 'SKU', 'text', FALSE, FALSE, 10, 'required', 'm', 'Stock keeping unit - unique product identifier', NULL),
    ('products', 'description', 'Description', 'text', FALSE, TRUE, 20, 'default', 'w', 'Detailed product description', NULL),
    ('products', 'price', 'Price', 'double', FALSE, FALSE, 30, 'default', 's', 'Product price in base currency', '0.0'),
    ('products', 'quantity_in_stock', 'Quantity in Stock', 'int32', FALSE, FALSE, 40, 'default', 's', 'Current inventory quantity', '0'),
    ('products', 'category', 'Category', 'text', FALSE, TRUE, 50, 'default', 'm', 'Product category or classification', NULL),
    ('products', 'is_discontinued', 'Discontinued', 'boolean', FALSE, FALSE, 60, 'default', 's', 'Whether product is no longer available', 'FALSE');

-- =====================================================
-- SEED SAMPLE DATA
-- =====================================================
-- Add some sample data to the dynamically created tables
-- Note: Tables use the default id_column ('id') and label_column ('label')
-- unless specified otherwise in the tables definition

-- Sample customers
-- Table: customers (id_column: id, label_column: customer_name)
INSERT INTO customers (customer_name, email, phone, company, status, total_orders)
VALUES 
    ('John Smith', 'john.smith@example.com', '+1-555-0101', 'Acme Corp', 'active', 15),
    ('Jane Doe', 'jane.doe@example.com', '+1-555-0102', 'Tech Solutions', 'active', 8),
    ('Bob Johnson', 'bob.johnson@example.com', '+1-555-0103', 'Global Industries', 'inactive', 3),
    ('Müller Schmidt', 'mueller.schmidt@example.com', '+49-30-12345678', 'Deutsche Bank AG', 'active', 22),
    ('François Dubois', 'francois.dubois@example.com', '+33-1-23456789', 'Société Générale', 'active', 18),
    ('María García', 'maria.garcia@example.com', '+34-91-1234567', 'Banco Santander', 'active', 14),
    ('José Rodríguez', 'jose.rodriguez@example.com', '+34-93-2345678', 'BBVA', 'active', 11),
    ('André Lefèvre', 'andre.lefevre@example.com', '+33-1-34567890', 'BNP Paribas', 'active', 25),
    ('Günther Weber', 'gunther.weber@example.com', '+49-89-23456789', 'Volkswagen AG', 'active', 9),
    ('Björn Andersson', 'bjorn.andersson@example.com', '+46-8-12345678', 'Volvo Group', 'active', 16),
    ('Søren Hansen', 'soren.hansen@example.com', '+45-33-123456', 'Maersk Line', 'active', 13),
    ('Jürgen Fischer', 'jurgen.fischer@example.com', '+49-911-234567', 'Siemens AG', 'active', 20),
    ('Stéphane Martin', 'stephane.martin@example.com', '+33-5-12345678', 'Airbus SE', 'active', 7),
    ('Ángel Fernández', 'angel.fernandez@example.com', '+34-91-3456789', 'Telefónica', 'active', 19),
    ('Håkan Nilsson', 'hakan.nilsson@example.com', '+46-10-1234567', 'Ericsson', 'active', 12),
    ('Michèle Blanc', 'michele.blanc@example.com', '+33-1-45678901', 'Orange SA', 'active', 10),
    ('José Luis Martínez', 'jose.martinez@example.com', '+34-91-4567890', 'Repsol', 'active', 21),
    ('Åsa Bergström', 'asa.bergstrom@example.com', '+46-8-23456789', 'H&M', 'active', 8),
    ('René Dubois', 'rene.dubois@example.com', '+33-1-56789012', 'Total Energies', 'active', 17),
    ('Göran Johansson', 'goran.johansson@example.com', '+46-42-3456789', 'IKEA', 'active', 15),
    ('Jörg Bauer', 'jorg.bauer@example.com', '+49-89-34567890', 'BMW Group', 'active', 23),
    ('François Leroy', 'francois.leroy@example.com', '+33-1-67890123', 'Renault', 'active', 6),
    ('Núria Sánchez', 'nuria.sanchez@example.com', '+34-93-5678901', 'CaixaBank', 'active', 14),
    ('Øyvind Pedersen', 'oyvind.pedersen@example.com', '+47-51-234567', 'Equinor ASA', 'active', 11),
    ('Mário Silva', 'mario.silva@example.com', '+351-21-1234567', 'EDP Energias', 'active', 9),
    ('João Santos', 'joao.santos@example.com', '+351-21-2345678', 'Galp Energia', 'active', 13),
    ('Sébastien Moreau', 'sebastien.moreau@example.com', '+33-4-78901234', 'Michelin', 'active', 18),
    ('Gérard Bernard', 'gerard.bernard@example.com', '+33-1-78901234', 'Danone', 'active', 16),
    ('Ramón López', 'ramon.lopez@example.com', '+34-94-6789012', 'Iberdrola', 'active', 20),
    ('Óscar González', 'oscar.gonzalez@example.com', '+34-93-6789012', 'Naturgy Energy', 'active', 7),
    ('Amélie Petit', 'amelie.petit@example.com', '+33-1-89012345', 'Carrefour', 'active', 12),
    ('Jérôme Roux', 'jerome.roux@example.com', '+33-3-90123456', 'Peugeot', 'active', 19),
    ('Andrés Díaz', 'andres.diaz@example.com', '+34-91-7890123', 'Inditex', 'active', 10),
    ('Ángeles Torres', 'angeles.torres@example.com', '+34-91-8901234', 'El Corte Inglés', 'active', 21),
    ('Rüdiger Meyer', 'rudiger.meyer@example.com', '+49-89-45678901', 'Allianz SE', 'active', 15),
    ('Pär Lindström', 'par.lindstrom@example.com', '+46-8-34567890', 'Spotify AB', 'active', 8),
    ('Jesús Romero', 'jesus.romero@example.com', '+34-91-9012345', 'Abertis', 'active', 17),
    ('Rubén Jiménez', 'ruben.jimenez@example.com', '+34-91-0123456', 'Amadeus IT', 'active', 23),
    ('José María Ruiz', 'jose.ruiz@example.com', '+34-91-1234567', 'Ferrovial', 'active', 6),
    ('Céline Garnier', 'celine.garnier@example.com', '+33-4-01234567', 'Schneider Electric', 'active', 14),
    ('Benoît Faure', 'benoit.faure@example.com', '+33-1-12345678', 'Veolia', 'active', 11),
    ('Andrée Girard', 'andree.girard@example.com', '+33-1-23456789', 'Vinci SA', 'active', 9),
    ('Özgür Yılmaz', 'ozgur.yilmaz@example.com', '+90-212-1234567', 'Turkish Airlines', 'active', 13),
    ('Torbjörn Svensson', 'torbjorn.svensson@example.com', '+46-8-45678901', 'Scania AB', 'active', 18),
    ('Eugène Lambert', 'eugene.lambert@example.com', '+33-1-34567890', 'Sanofi', 'active', 16),
    ('Élise Bonnet', 'elise.bonnet@example.com', '+33-1-45678901', 'L''Oréal', 'active', 20),
    ('Raphaël Durand', 'raphael.durand@example.com', '+33-1-56789012', 'Thales Group', 'active', 7),
    ('Nicolás Vargas', 'nicolas.vargas@example.com', '+34-91-2345678', 'ACS Group', 'active', 12),
    ('Inés Castro', 'ines.castro@example.com', '+34-93-3456789', 'Banco Sabadell', 'active', 19),
    ('Ólafur Jónsson', 'olafur.jonsson@example.com', '+354-5-123456', 'Icelandair', 'active', 10),
    ('Günter Hoffmann', 'gunter.hoffmann@example.com', '+49-511-1234567', 'Continental AG', 'active', 21),
    ('Märta Karlsson', 'marta.karlsson@example.com', '+46-8-56789012', 'Electrolux', 'active', 15),
    ('Frédéric Morel', 'frederic.morel@example.com', '+33-1-67890123', 'Bouygues', 'active', 8),
    ('François-Xavier Simon', 'francois.simon@example.com', '+33-1-78901234', 'Saint-Gobain', 'active', 17),
    ('Hervé Vincent', 'herve.vincent@example.com', '+33-1-89012345', 'Safran', 'active', 23),
    ('João Pedro Costa', 'joao.costa@example.com', '+351-21-3456789', 'Jerónimo Martins', 'active', 6),
    ('Zoë Anderson', 'zoe.anderson@example.com', '+44-20-12345678', 'British Airways', 'active', 14),
    ('Günther Köhler', 'gunther.kohler@example.com', '+49-228-1234567', 'Deutsche Post', 'active', 11),
    ('Émile Leclerc', 'emile.leclerc@example.com', '+33-2-90123456', 'E.Leclerc', 'active', 9),
    ('Gösta Magnusson', 'gosta.magnusson@example.com', '+46-31-1234567', 'SKF AB', 'active', 13),
    ('María José Pérez', 'maria.perez@example.com', '+34-91-4567890', 'NH Hotel Group', 'active', 18),
    ('José Antonio Díaz', 'jose.diaz@example.com', '+34-91-5678901', 'Mapfre', 'active', 16),
    ('Håkon Berg', 'hakon.berg@example.com', '+47-22-123456', 'DNB ASA', 'active', 20),
    ('Björk Guðmundsdóttir', 'bjork.gudmundsdottir@example.com', '+354-5-234567', 'Iceland Foods', 'inactive', 7),
    ('Åse Kristiansen', 'ase.kristiansen@example.com', '+47-51-345678', 'Statoil', 'active', 12),
    ('Björn Ólafsson', 'bjorn.olafsson@example.com', '+354-5-345678', 'WOW Air', 'inactive', 19),
    ('Désirée Fournier', 'desiree.fournier@example.com', '+33-3-12345678', 'Auchan', 'active', 10),
    ('René-Charles Mercier', 'rene.mercier@example.com', '+33-3-23456789', 'Decathlon', 'active', 21),
    ('Noël Rousseau', 'noel.rousseau@example.com', '+33-1-90123456', 'Accor Hotels', 'active', 15),
    ('José Ángel Núñez', 'jose.nunez@example.com', '+34-93-4567890', 'Grifols', 'active', 8),
    ('María Ángeles Vega', 'maria.vega@example.com', '+34-91-6789012', 'Técnicas Reunidas', 'active', 17),
    ('Rubén Gutiérrez', 'ruben.gutierrez@example.com', '+352-26-123456', 'ArcelorMittal', 'active', 23),
    ('Jörgen Lundqvist', 'jorgen.lundqvist@example.com', '+46-8-67890123', 'Alfa Laval', 'active', 6),
    ('Søren Møller', 'soren.moller@example.com', '+45-33-234567', 'Carlsberg Group', 'active', 14),
    ('François Gauthier', 'francois.gauthier@example.com', '+33-4-12345678', 'Groupe SEB', 'active', 11),
    ('Aurélien Dubois', 'aurelien.dubois@example.com', '+33-1-01234567', 'Arkema', 'active', 9),
    ('Björn-Erik Larsson', 'bjorn.larsson@example.com', '+46-8-78901234', 'Atlas Copco', 'active', 13),
    ('Ömer Kaya', 'omer.kaya@example.com', '+90-216-2345678', 'Arçelik', 'active', 18),
    ('Züleyha Demir', 'zuleyha.demir@example.com', '+90-212-3456789', 'Koç Holding', 'active', 16),
    ('Jürgen Müller', 'jurgen.muller@example.com', '+49-6227-1234567', 'SAP SE', 'active', 20),
    ('Rüdiger Schröder', 'rudiger.schroder@example.com', '+49-621-1234567', 'BASF SE', 'active', 7),
    ('Günter Neumann', 'gunter.neumann@example.com', '+49-2173-1234567', 'Bayer AG', 'active', 12),
    ('Jörn Zimmermann', 'jorn.zimmermann@example.com', '+49-211-1234567', 'Henkel AG', 'active', 19),
    ('François-René Petit', 'francois.petit@example.com', '+33-4-23456789', 'Legrand SA', 'active', 10),
    ('Cédric Thomas', 'cedric.thomas@example.com', '+33-1-12345670', 'Sodexo', 'active', 21),
    ('Lucía Fernández', 'lucia.fernandez@example.com', '+34-91-7890123', 'Endesa', 'active', 15),
    ('José Ramón Cruz', 'jose.cruz@example.com', '+34-91-8901234', 'Red Eléctrica', 'active', 8),
    ('María Eugenia Ortiz', 'maria.ortiz@example.com', '+34-91-9012345', 'Aena', 'active', 17),
    ('Aurélien Lefèvre', 'aurelien.lefevre@example.com', '+33-1-23456781', 'Publicis Groupe', 'active', 23),
    ('Sébastien Müller', 'sebastien.muller@example.com', '+33-1-34567892', 'Air Liquide', 'active', 6),
    ('Adrián González', 'adrian.gonzalez@example.com', '+34-96-1234567', 'Acerinox', 'active', 14),
    ('Álvaro Jiménez', 'alvaro.jimenez@example.com', '+34-91-0123457', 'Bankinter', 'active', 11),
    ('María Belén Torres', 'maria.torres@example.com', '+34-93-5678902', 'Cellnex Telecom', 'active', 9),
    ('José Enrique Rojas', 'jose.rojas@example.com', '+34-91-1234568', 'Enagas', 'active', 13),
    ('Björn-Ove Hansen', 'bjorn.hansen@example.com', '+47-67-123456', 'Telenor', 'active', 18),
    ('Renée Martin', 'renee.martin@example.com', '+33-1-45678902', 'Kering', 'active', 16),
    ('Géraldine André', 'geraldine.andre@example.com', '+33-1-56789013', 'Essilor', 'active', 20),
    ('João Gonçalves', 'joao.goncalves@example.com', '+351-22-1234567', 'Sonae', 'active', 7),
    ('António Rodrigues', 'antonio.rodrigues@example.com', '+351-21-4567890', 'Millennium BCP', 'active', 12),
    ('Søren Eriksen', 'soren.eriksen@example.com', '+45-35-123456', 'Novo Nordisk', 'active', 19);

-- Sample employees
-- Table: employees (id_column: id, label_column: full_name)
INSERT INTO employees (full_name, email, department, position, hire_date, salary, is_active)
VALUES 
    ('Alice Williams', 'alice.williams@company.com', 'Engineering', 'Senior Developer', '2020-03-15', 95000, TRUE),
    ('Charlie Brown', 'charlie.brown@company.com', 'Sales', 'Account Manager', '2021-06-01', 75000, TRUE),
    ('Diana Prince', 'diana.prince@company.com', 'HR', 'HR Manager', '2019-01-10', 80000, TRUE);

-- Sample products
-- Table: products (id_column: id, label_column: product_name)
INSERT INTO products (product_name, sku, description, price, quantity_in_stock, category, is_discontinued)
VALUES 
    ('Widget Pro', 'WGT-001', 'Professional grade widget', 29.99, 150, 'Widgets', FALSE),
    ('Gadget Plus', 'GAD-002', 'Advanced gadget with premium features', 49.99, 75, 'Gadgets', FALSE),
    ('Tool Basic', 'TL-003', 'Basic tool for everyday use', 19.99, 0, 'Tools', TRUE);

-- =====================================================
-- SEED TEST USERS
-- =====================================================

-- Add test users with fixed Ids for testing
INSERT INTO users (id, external_id, email) VALUES
    (1001, 'user1', 'user@test.com'),
    (1002, 'user2', 'sales@test.com'),
    (1003, 'user3', 'admin@test.com');

-- Adjust the sequence counter to the max user_id to avoid conflicts with future auto-generated Ids
SELECT setval('users_id_seq', (SELECT MAX(id) FROM users), true);

-- =====================================================
-- SEED USER-ROLE MAPPINGS
-- =====================================================

-- Note: Role 1 (User) is now auto-assigned by trigger when users are inserted
-- So we only need to add additional roles here

-- user3 is also a member of the "Administrator" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u, roles r
WHERE u.external_id = 'user3'
  AND r.role_name = 'Administrator';

-- user2 (sales@test.com) is also a member of the "Sales User" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u, roles r
WHERE u.external_id = 'user2'
  AND r.role_name = 'Sales User';

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