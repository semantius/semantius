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
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, description)
VALUES 
    ('customers', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'Customer primary email address'),
    ('customers', 'phone', 'Phone Number', 'string', FALSE, TRUE, 20, 'Customer contact phone number'),
    ('customers', 'company', 'Company Name', 'string', FALSE, TRUE, 30, 'Company or organization name'),
    ('customers', 'status', 'Status', 'string', FALSE, FALSE, 40, 'Customer account status (active, inactive, etc.)'),
    ('customers', 'total_orders', 'Total Orders', 'integer', FALSE, FALSE, 50, 'Total number of orders placed by customer');

-- Add fields to employees table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, description)
VALUES 
    ('employees', 'email', 'Email Address', 'email', FALSE, FALSE, 10, 'Employee work email address'),
    ('employees', 'department', 'Department', 'string', FALSE, FALSE, 20, 'Department or division'),
    ('employees', 'position', 'Position', 'string', FALSE, FALSE, 30, 'Job title or position'),
    ('employees', 'hire_date', 'Hire Date', 'date', FALSE, FALSE, 40, 'Date employee was hired'),
    ('employees', 'salary', 'Salary', 'number', FALSE, TRUE, 50, 'Annual salary amount'),
    ('employees', 'is_active', 'Active', 'boolean', FALSE, FALSE, 60, 'Whether employee is currently active');

-- Add fields to products table
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, description)
VALUES 
    ('products', 'sku', 'SKU', 'string', FALSE, FALSE, 10, 'Stock keeping unit - unique product identifier'),
    ('products', 'description', 'Description', 'string', FALSE, TRUE, 20, 'Detailed product description'),
    ('products', 'price', 'Price', 'number', FALSE, FALSE, 30, 'Product price in base currency'),
    ('products', 'quantity_in_stock', 'Quantity in Stock', 'integer', FALSE, FALSE, 40, 'Current inventory quantity'),
    ('products', 'category', 'Category', 'string', FALSE, TRUE, 50, 'Product category or classification'),
    ('products', 'is_discontinued', 'Discontinued', 'boolean', FALSE, FALSE, 60, 'Whether product is no longer available');

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
    ('John Smith', 'john.smith@example.com', '555-0101', 'Acme Corp', 'active', 15),
    ('Jane Doe', 'jane.doe@example.com', '555-0102', 'Tech Solutions', 'active', 8),
    ('Bob Johnson', 'bob.johnson@example.com', '555-0103', 'Global Industries', 'inactive', 3),
    ('Müller Schmidt', 'mueller.schmidt@example.com', '555-0104', 'Deutsche Bank AG', 'active', 22),
    ('François Dubois', 'francois.dubois@example.com', '555-0105', 'Société Générale', 'active', 18),
    ('María García', 'maria.garcia@example.com', '555-0106', 'Banco Santander', 'active', 14),
    ('José Rodríguez', 'jose.rodriguez@example.com', '555-0107', 'BBVA', 'active', 11),
    ('André Lefèvre', 'andre.lefevre@example.com', '555-0108', 'BNP Paribas', 'active', 25),
    ('Günther Weber', 'gunther.weber@example.com', '555-0109', 'Volkswagen AG', 'active', 9),
    ('Björn Andersson', 'bjorn.andersson@example.com', '555-0110', 'Volvo Group', 'active', 16),
    ('Søren Hansen', 'soren.hansen@example.com', '555-0111', 'Maersk Line', 'active', 13),
    ('Jürgen Fischer', 'jurgen.fischer@example.com', '555-0112', 'Siemens AG', 'active', 20),
    ('Stéphane Martin', 'stephane.martin@example.com', '555-0113', 'Airbus SE', 'active', 7),
    ('Ángel Fernández', 'angel.fernandez@example.com', '555-0114', 'Telefónica', 'active', 19),
    ('Håkan Nilsson', 'hakan.nilsson@example.com', '555-0115', 'Ericsson', 'active', 12),
    ('Michèle Blanc', 'michele.blanc@example.com', '555-0116', 'Orange SA', 'active', 10),
    ('José Luis Martínez', 'jose.martinez@example.com', '555-0117', 'Repsol', 'active', 21),
    ('Åsa Bergström', 'asa.bergstrom@example.com', '555-0118', 'H&M', 'active', 8),
    ('René Dubois', 'rene.dubois@example.com', '555-0119', 'Total Energies', 'active', 17),
    ('Göran Johansson', 'goran.johansson@example.com', '555-0120', 'IKEA', 'active', 15),
    ('Jörg Bauer', 'jorg.bauer@example.com', '555-0121', 'BMW Group', 'active', 23),
    ('François Leroy', 'francois.leroy@example.com', '555-0122', 'Renault', 'active', 6),
    ('Núria Sánchez', 'nuria.sanchez@example.com', '555-0123', 'CaixaBank', 'active', 14),
    ('Øyvind Pedersen', 'oyvind.pedersen@example.com', '555-0124', 'Equinor ASA', 'active', 11),
    ('Mário Silva', 'mario.silva@example.com', '555-0125', 'EDP Energias', 'active', 9),
    ('João Santos', 'joao.santos@example.com', '555-0126', 'Galp Energia', 'active', 13),
    ('Sébastien Moreau', 'sebastien.moreau@example.com', '555-0127', 'Michelin', 'active', 18),
    ('Gérard Bernard', 'gerard.bernard@example.com', '555-0128', 'Danone', 'active', 16),
    ('Ramón López', 'ramon.lopez@example.com', '555-0129', 'Iberdrola', 'active', 20),
    ('Óscar González', 'oscar.gonzalez@example.com', '555-0130', 'Naturgy Energy', 'active', 7),
    ('Amélie Petit', 'amelie.petit@example.com', '555-0131', 'Carrefour', 'active', 12),
    ('Jérôme Roux', 'jerome.roux@example.com', '555-0132', 'Peugeot', 'active', 19),
    ('Andrés Díaz', 'andres.diaz@example.com', '555-0133', 'Inditex', 'active', 10),
    ('Ángeles Torres', 'angeles.torres@example.com', '555-0134', 'El Corte Inglés', 'active', 21),
    ('Rüdiger Meyer', 'rudiger.meyer@example.com', '555-0135', 'Allianz SE', 'active', 15),
    ('Pär Lindström', 'par.lindstrom@example.com', '555-0136', 'Spotify AB', 'active', 8),
    ('Jesús Romero', 'jesus.romero@example.com', '555-0137', 'Abertis', 'active', 17),
    ('Rubén Jiménez', 'ruben.jimenez@example.com', '555-0138', 'Amadeus IT', 'active', 23),
    ('José María Ruiz', 'jose.ruiz@example.com', '555-0139', 'Ferrovial', 'active', 6),
    ('Céline Garnier', 'celine.garnier@example.com', '555-0140', 'Schneider Electric', 'active', 14),
    ('Benoît Faure', 'benoit.faure@example.com', '555-0141', 'Veolia', 'active', 11),
    ('Andrée Girard', 'andree.girard@example.com', '555-0142', 'Vinci SA', 'active', 9),
    ('Özgür Yılmaz', 'ozgur.yilmaz@example.com', '555-0143', 'Turkish Airlines', 'active', 13),
    ('Torbjörn Svensson', 'torbjorn.svensson@example.com', '555-0144', 'Scania AB', 'active', 18),
    ('Eugène Lambert', 'eugene.lambert@example.com', '555-0145', 'Sanofi', 'active', 16),
    ('Élise Bonnet', 'elise.bonnet@example.com', '555-0146', 'L''Oréal', 'active', 20),
    ('Raphaël Durand', 'raphael.durand@example.com', '555-0147', 'Thales Group', 'active', 7),
    ('Nicolás Vargas', 'nicolas.vargas@example.com', '555-0148', 'ACS Group', 'active', 12),
    ('Inés Castro', 'ines.castro@example.com', '555-0149', 'Banco Sabadell', 'active', 19),
    ('Ólafur Jónsson', 'olafur.jonsson@example.com', '555-0150', 'Icelandair', 'active', 10),
    ('Günter Hoffmann', 'gunter.hoffmann@example.com', '555-0151', 'Continental AG', 'active', 21),
    ('Märta Karlsson', 'marta.karlsson@example.com', '555-0152', 'Electrolux', 'active', 15),
    ('Frédéric Morel', 'frederic.morel@example.com', '555-0153', 'Bouygues', 'active', 8),
    ('François-Xavier Simon', 'francois.simon@example.com', '555-0154', 'Saint-Gobain', 'active', 17),
    ('Hervé Vincent', 'herve.vincent@example.com', '555-0155', 'Safran', 'active', 23),
    ('João Pedro Costa', 'joao.costa@example.com', '555-0156', 'Jerónimo Martins', 'active', 6),
    ('Zoë Anderson', 'zoe.anderson@example.com', '555-0157', 'British Airways', 'active', 14),
    ('Günther Köhler', 'gunther.kohler@example.com', '555-0158', 'Deutsche Post', 'active', 11),
    ('Émile Leclerc', 'emile.leclerc@example.com', '555-0159', 'E.Leclerc', 'active', 9),
    ('Gösta Magnusson', 'gosta.magnusson@example.com', '555-0160', 'SKF AB', 'active', 13),
    ('María José Pérez', 'maria.perez@example.com', '555-0161', 'NH Hotel Group', 'active', 18),
    ('José Antonio Díaz', 'jose.diaz@example.com', '555-0162', 'Mapfre', 'active', 16),
    ('Håkon Berg', 'hakon.berg@example.com', '555-0163', 'DNB ASA', 'active', 20),
    ('Björk Guðmundsdóttir', 'bjork.gudmundsdottir@example.com', '555-0164', 'Iceland Foods', 'inactive', 7),
    ('Åse Kristiansen', 'ase.kristiansen@example.com', '555-0165', 'Statoil', 'active', 12),
    ('Björn Ólafsson', 'bjorn.olafsson@example.com', '555-0166', 'WOW Air', 'inactive', 19),
    ('Désirée Fournier', 'desiree.fournier@example.com', '555-0167', 'Auchan', 'active', 10),
    ('René-Charles Mercier', 'rene.mercier@example.com', '555-0168', 'Decathlon', 'active', 21),
    ('Noël Rousseau', 'noel.rousseau@example.com', '555-0169', 'Accor Hotels', 'active', 15),
    ('José Ángel Núñez', 'jose.nunez@example.com', '555-0170', 'Grifols', 'active', 8),
    ('María Ángeles Vega', 'maria.vega@example.com', '555-0171', 'Técnicas Reunidas', 'active', 17),
    ('Rubén Gutiérrez', 'ruben.gutierrez@example.com', '555-0172', 'ArcelorMittal', 'active', 23),
    ('Jörgen Lundqvist', 'jorgen.lundqvist@example.com', '555-0173', 'Alfa Laval', 'active', 6),
    ('Søren Møller', 'soren.moller@example.com', '555-0174', 'Carlsberg Group', 'active', 14),
    ('François Gauthier', 'francois.gauthier@example.com', '555-0175', 'Groupe SEB', 'active', 11),
    ('Aurélien Dubois', 'aurelien.dubois@example.com', '555-0176', 'Arkema', 'active', 9),
    ('Björn-Erik Larsson', 'bjorn.larsson@example.com', '555-0177', 'Atlas Copco', 'active', 13),
    ('Ömer Kaya', 'omer.kaya@example.com', '555-0178', 'Arçelik', 'active', 18),
    ('Züleyha Demir', 'zuleyha.demir@example.com', '555-0179', 'Koç Holding', 'active', 16),
    ('Jürgen Müller', 'jurgen.muller@example.com', '555-0180', 'SAP SE', 'active', 20),
    ('Rüdiger Schröder', 'rudiger.schroder@example.com', '555-0181', 'BASF SE', 'active', 7),
    ('Günter Neumann', 'gunter.neumann@example.com', '555-0182', 'Bayer AG', 'active', 12),
    ('Jörn Zimmermann', 'jorn.zimmermann@example.com', '555-0183', 'Henkel AG', 'active', 19),
    ('François-René Petit', 'francois.petit@example.com', '555-0184', 'Legrand SA', 'active', 10),
    ('Cédric Thomas', 'cedric.thomas@example.com', '555-0185', 'Sodexo', 'active', 21),
    ('Lucía Fernández', 'lucia.fernandez@example.com', '555-0186', 'Endesa', 'active', 15),
    ('José Ramón Cruz', 'jose.cruz@example.com', '555-0187', 'Red Eléctrica', 'active', 8),
    ('María Eugenia Ortiz', 'maria.ortiz@example.com', '555-0188', 'Aena', 'active', 17),
    ('Aurélien Lefèvre', 'aurelien.lefevre@example.com', '555-0189', 'Publicis Groupe', 'active', 23),
    ('Sébastien Müller', 'sebastien.muller@example.com', '555-0190', 'Air Liquide', 'active', 6),
    ('Adrián González', 'adrian.gonzalez@example.com', '555-0191', 'Acerinox', 'active', 14),
    ('Álvaro Jiménez', 'alvaro.jimenez@example.com', '555-0192', 'Bankinter', 'active', 11),
    ('María Belén Torres', 'maria.torres@example.com', '555-0193', 'Cellnex Telecom', 'active', 9),
    ('José Enrique Rojas', 'jose.rojas@example.com', '555-0194', 'Enagas', 'active', 13),
    ('Björn-Ove Hansen', 'bjorn.hansen@example.com', '555-0195', 'Telenor', 'active', 18),
    ('Renée Martin', 'renee.martin@example.com', '555-0196', 'Kering', 'active', 16),
    ('Géraldine André', 'geraldine.andre@example.com', '555-0197', 'Essilor', 'active', 20),
    ('João Gonçalves', 'joao.goncalves@example.com', '555-0198', 'Sonae', 'active', 7),
    ('António Rodrigues', 'antonio.rodrigues@example.com', '555-0199', 'Millennium BCP', 'active', 12),
    ('Søren Eriksen', 'soren.eriksen@example.com', '555-0200', 'Novo Nordisk', 'active', 19);

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
-- SELECT f.field_name, f.title, f.format, f.is_pk, f.is_nullable
-- FROM fields f
-- WHERE f.table_name = 'customers'
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