-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SEED DATA
-- =====================================================
-- Example data to demonstrate the dynamic table system
-- This will create actual tables and fields when executed
-- =====================================================

-- Insert sample modules if they don't exist
INSERT INTO modules (module_id, module_name, description, view_permission) VALUES
    (1001, 'CRM', 'Customer Relationship Management', 'sales:read'),
    (1002, 'HR', 'Human Resources', 'user:read'),
    (1003, 'Inventory', 'Inventory Management', 'user:read')
ON CONFLICT (module_id) DO NOTHING;

-- Adjust the sequence counter to ensure next module starts after test modules
SELECT setval('modules_module_id_seq', (SELECT MAX(module_id) FROM modules), true);

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
SELECT r.role_id, p.permission_id
FROM roles r, permissions p
WHERE r.role_name = 'Sales User' 
  AND p.permission_name IN ('sales:read', 'sales:manage');

-- =====================================================
-- SEED DYNAMIC TABLES
-- =====================================================
-- These will automatically create actual database tables
-- with proper RLS policies

-- Create "customers" table in CRM module
INSERT INTO tables (table_name, label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customers',
    'Customers',
    'Customer information and contact details',
    1001, -- CRM module
    'public:read',
    'sales:manage',
    'customer_id',
    'customer_name'
);

-- Create "employees" table in HR module
INSERT INTO tables (table_name, label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees',
    'Employees',
    'Employee records and information',
    1002, -- HR module
    'user:read',
    'admin:manage',
    'employee_id',
    'full_name'
);

-- Create "products" table in Inventory module
INSERT INTO tables (table_name, label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products',
    'Products',
    'Product catalog and inventory',
    1003, -- Inventory module
    'sales:read',
    'sales:manage',
    'product_id',
    'product_name'
);

-- =====================================================
-- SEED DYNAMIC FIELDS
-- =====================================================
-- These will automatically add columns to the tables created above
-- Note: id_column and label_column are created automatically by create_dd_table()
-- so we only add additional custom fields here

-- Add fields to customers table
INSERT INTO fields (table_name, field_name, label, data_type, is_pk, is_nullable, field_order, description)
VALUES 
    ('customers', 'email', 'Email Address', 'TEXT', FALSE, FALSE, 10, 'Customer primary email address'),
    ('customers', 'phone', 'Phone Number', 'TEXT', FALSE, TRUE, 20, 'Customer contact phone number'),
    ('customers', 'company', 'Company Name', 'TEXT', FALSE, TRUE, 30, 'Company or organization name'),
    ('customers', 'status', 'Status', 'TEXT', FALSE, FALSE, 40, 'Customer account status (active, inactive, etc.)'),
    ('customers', 'total_orders', 'Total Orders', 'INTEGER', FALSE, FALSE, 50, 'Total number of orders placed by customer');

-- Add fields to employees table
INSERT INTO fields (table_name, field_name, label, data_type, is_pk, is_nullable, field_order, description)
VALUES 
    ('employees', 'email', 'Email Address', 'TEXT', FALSE, FALSE, 10, 'Employee work email address'),
    ('employees', 'department', 'Department', 'TEXT', FALSE, FALSE, 20, 'Department or division'),
    ('employees', 'position', 'Position', 'TEXT', FALSE, FALSE, 30, 'Job title or position'),
    ('employees', 'hire_date', 'Hire Date', 'DATE', FALSE, FALSE, 40, 'Date employee was hired'),
    ('employees', 'salary', 'Salary', 'NUMERIC', FALSE, TRUE, 50, 'Annual salary amount'),
    ('employees', 'is_active', 'Active', 'BOOLEAN', FALSE, FALSE, 60, 'Whether employee is currently active');

-- Add fields to products table
INSERT INTO fields (table_name, field_name, label, data_type, is_pk, is_nullable, field_order, description)
VALUES 
    ('products', 'sku', 'SKU', 'TEXT', FALSE, FALSE, 10, 'Stock keeping unit - unique product identifier'),
    ('products', 'description', 'Description', 'TEXT', FALSE, TRUE, 20, 'Detailed product description'),
    ('products', 'price', 'Price', 'NUMERIC', FALSE, FALSE, 30, 'Product price in base currency'),
    ('products', 'quantity_in_stock', 'Quantity in Stock', 'INTEGER', FALSE, FALSE, 40, 'Current inventory quantity'),
    ('products', 'category', 'Category', 'TEXT', FALSE, TRUE, 50, 'Product category or classification'),
    ('products', 'is_discontinued', 'Discontinued', 'BOOLEAN', FALSE, FALSE, 60, 'Whether product is no longer available');

-- =====================================================
-- SEED SAMPLE DATA
-- =====================================================
-- Add some sample data to the dynamically created tables
-- Note: Tables use the default id_column ('id') and label_column ('label')
-- unless specified otherwise in the tables definition

-- Sample customers
-- Table: customers (id_column: customer_id, label_column: customer_name)
INSERT INTO customers (customer_name, email, phone, company, status, total_orders)
VALUES 
    ('John Smith', 'john.smith@example.com', '555-0101', 'Acme Corp', 'active', 15),
    ('Jane Doe', 'jane.doe@example.com', '555-0102', 'Tech Solutions', 'active', 8),
    ('Bob Johnson', 'bob.johnson@example.com', '555-0103', 'Global Industries', 'inactive', 3);

-- Sample employees
-- Table: employees (id_column: employee_id, label_column: full_name)
INSERT INTO employees (full_name, email, department, position, hire_date, salary, is_active)
VALUES 
    ('Alice Williams', 'alice.williams@company.com', 'Engineering', 'Senior Developer', '2020-03-15', 95000, TRUE),
    ('Charlie Brown', 'charlie.brown@company.com', 'Sales', 'Account Manager', '2021-06-01', 75000, TRUE),
    ('Diana Prince', 'diana.prince@company.com', 'HR', 'HR Manager', '2019-01-10', 80000, TRUE);

-- Sample products
-- Table: products (id_column: product_id, label_column: product_name)
INSERT INTO products (product_name, sku, description, price, quantity_in_stock, category, is_discontinued)
VALUES 
    ('Widget Pro', 'WGT-001', 'Professional grade widget', 29.99, 150, 'Widgets', FALSE),
    ('Gadget Plus', 'GAD-002', 'Advanced gadget with premium features', 49.99, 75, 'Gadgets', FALSE),
    ('Tool Basic', 'TL-003', 'Basic tool for everyday use', 19.99, 0, 'Tools', TRUE);

-- =====================================================
-- SEED TEST USERS
-- =====================================================

-- Add test users with fixed IDs for testing
INSERT INTO users (user_id, external_id, email) VALUES
    (1001, 'user1', 'user@test.com'),
    (1002, 'user2', 'sales@test.com'),
    (1003, 'user3', 'admin@test.com');

-- Adjust the sequence counter to the max user_id to avoid conflicts with future auto-generated IDs
SELECT setval('users_user_id_seq', (SELECT MAX(user_id) FROM users), true);

-- =====================================================
-- SEED USER-ROLE MAPPINGS
-- =====================================================

-- All three users are members of the "User" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.user_id, r.role_id
FROM users u, roles r
WHERE u.external_id IN ('user1', 'user2', 'user3')
  AND r.role_name = 'User';

-- user3 is also a member of the "Administrator" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.user_id, r.role_id
FROM users u, roles r
WHERE u.external_id = 'user3'
  AND r.role_name = 'Administrator';

-- user2 (sales@test.com) is also a member of the "Sales User" role
INSERT INTO user_roles (user_id, role_id)
SELECT u.user_id, r.role_id
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