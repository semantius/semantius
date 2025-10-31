-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SEED DATA
-- =====================================================
-- Example data to demonstrate the dynamic table system
-- This will create actual tables and fields when executed
-- =====================================================

-- =====================================================
-- PREREQUISITE: Ensure modules exist
-- =====================================================
-- If you don't have modules table yet, create a simple one:
-- CREATE TABLE IF NOT EXISTS modules (
--     module_id SERIAL PRIMARY KEY,
--     module_name TEXT NOT NULL UNIQUE,
--     description TEXT
-- );

-- Insert sample modules if they don't exist
INSERT INTO modules (module_id, module_name, description) VALUES
    (1, 'CRM', 'Customer Relationship Management'),
    (2, 'HR', 'Human Resources'),
    (3, 'Inventory', 'Inventory Management')
ON CONFLICT (module_id) DO NOTHING;

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
    1, -- CRM module
    'public:read',
    'user:manage',
    'customer_id',
    'customer_name'
);

-- Create "employees" table in HR module
INSERT INTO tables (table_name, label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees',
    'Employees',
    'Employee records and information',
    2, -- HR module
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
    3, -- Inventory module
    'public:read',
    'user:manage',
    'product_id',
    'product_name'
);

-- =====================================================
-- SEED DYNAMIC FIELDS
-- =====================================================
-- These will automatically add columns to the tables created above
-- Note: id_column and label_column are created automatically

-- Add fields to customers table
INSERT INTO fields (table_id, field_name, label, data_type, is_pk, is_nullable, field_order)
VALUES 
    ((SELECT table_id FROM tables WHERE table_name = 'customers'), 'email', 'Email Address', 'TEXT', FALSE, FALSE, 10),
    ((SELECT table_id FROM tables WHERE table_name = 'customers'), 'phone', 'Phone Number', 'TEXT', FALSE, TRUE, 20),
    ((SELECT table_id FROM tables WHERE table_name = 'customers'), 'company', 'Company Name', 'TEXT', FALSE, TRUE, 30),
    ((SELECT table_id FROM tables WHERE table_name = 'customers'), 'status', 'Status', 'TEXT', FALSE, FALSE, 40),
    ((SELECT table_id FROM tables WHERE table_name = 'customers'), 'total_orders', 'Total Orders', 'INTEGER', FALSE, FALSE, 50);

-- Add fields to employees table
INSERT INTO fields (table_id, field_name, label, data_type, is_pk, is_nullable, field_order)
VALUES 
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'email', 'Email Address', 'TEXT', FALSE, FALSE, 10),
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'department', 'Department', 'TEXT', FALSE, FALSE, 20),
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'position', 'Position', 'TEXT', FALSE, FALSE, 30),
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'hire_date', 'Hire Date', 'DATE', FALSE, FALSE, 40),
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'salary', 'Salary', 'NUMERIC', FALSE, TRUE, 50),
    ((SELECT table_id FROM tables WHERE table_name = 'employees'), 'is_active', 'Active', 'BOOLEAN', FALSE, FALSE, 60);

-- Add fields to products table
INSERT INTO fields (table_id, field_name, label, data_type, is_pk, is_nullable, field_order)
VALUES 
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'sku', 'SKU', 'TEXT', FALSE, FALSE, 10),
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'description', 'Description', 'TEXT', FALSE, TRUE, 20),
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'price', 'Price', 'NUMERIC', FALSE, FALSE, 30),
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'quantity_in_stock', 'Quantity in Stock', 'INTEGER', FALSE, FALSE, 40),
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'category', 'Category', 'TEXT', FALSE, TRUE, 50),
    ((SELECT table_id FROM tables WHERE table_name = 'products'), 'is_discontinued', 'Discontinued', 'BOOLEAN', FALSE, FALSE, 60);

-- =====================================================
-- SEED SAMPLE DATA
-- =====================================================
-- Add some sample data to the dynamically created tables

-- Sample customers
INSERT INTO customers (customer_name, email, phone, company, status, total_orders)
VALUES 
    ('John Smith', 'john.smith@example.com', '555-0101', 'Acme Corp', 'active', 15),
    ('Jane Doe', 'jane.doe@example.com', '555-0102', 'Tech Solutions', 'active', 8),
    ('Bob Johnson', 'bob.johnson@example.com', '555-0103', 'Global Industries', 'inactive', 3);

-- Sample employees
INSERT INTO employees (full_name, email, department, position, hire_date, salary, is_active)
VALUES 
    ('Alice Williams', 'alice.williams@company.com', 'Engineering', 'Senior Developer', '2020-03-15', 95000, TRUE),
    ('Charlie Brown', 'charlie.brown@company.com', 'Sales', 'Account Manager', '2021-06-01', 75000, TRUE),
    ('Diana Prince', 'diana.prince@company.com', 'HR', 'HR Manager', '2019-01-10', 80000, TRUE);

-- Sample products
INSERT INTO products (product_name, sku, description, price, quantity_in_stock, category, is_discontinued)
VALUES 
    ('Widget Pro', 'WGT-001', 'Professional grade widget', 29.99, 150, 'Widgets', FALSE),
    ('Gadget Plus', 'GAD-002', 'Advanced gadget with premium features', 49.99, 75, 'Gadgets', FALSE),
    ('Tool Basic', 'TL-003', 'Basic tool for everyday use', 19.99, 0, 'Tools', TRUE);

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

-- Test RLS policies (these will only work if proper permissions are set)
-- SELECT * FROM customers; -- Should work with public:read
-- INSERT INTO customers (customer_name, email, status, total_orders) 
-- VALUES ('Test User', 'test@example.com', 'pending', 0); -- Requires user:manage