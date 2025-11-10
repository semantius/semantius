-- Generated dropall script
-- WARNING: This script will permanently delete ALL objects in the database
-- Execute with caution!

-- No views found in public schema

-- Drop all functions and procedures
DROP FUNCTION IF EXISTS "add_dd_field"() CASCADE;
DROP FUNCTION IF EXISTS "create_dd_table"() CASCADE;
DROP FUNCTION IF EXISTS "delete_dd_field"() CASCADE;
DROP FUNCTION IF EXISTS "delete_dd_table"() CASCADE;
DROP FUNCTION IF EXISTS "get_schema"(p_table_name text) CASCADE;
DROP FUNCTION IF EXISTS "get_userinfo"(version text) CASCADE;
DROP FUNCTION IF EXISTS "get_userinfo"() CASCADE;
DROP FUNCTION IF EXISTS "has_public_read"() CASCADE;
DROP FUNCTION IF EXISTS "notify_pgrst_fields"() CASCADE;
DROP FUNCTION IF EXISTS "notify_pgrst_tables"() CASCADE;
DROP FUNCTION IF EXISTS "ping"() CASCADE;
DROP FUNCTION IF EXISTS "update_dd_field"() CASCADE;

-- Drop all tables
DROP TABLE IF EXISTS "_versions" CASCADE;
DROP TABLE IF EXISTS "customers" CASCADE;
DROP TABLE IF EXISTS "employees" CASCADE;
DROP TABLE IF EXISTS "fields" CASCADE;
DROP TABLE IF EXISTS "modules" CASCADE;
DROP TABLE IF EXISTS "permission_hierarchy" CASCADE;
DROP TABLE IF EXISTS "permissions" CASCADE;
DROP TABLE IF EXISTS "products" CASCADE;
DROP TABLE IF EXISTS "role_permissions" CASCADE;
DROP TABLE IF EXISTS "roles" CASCADE;
DROP TABLE IF EXISTS "tables" CASCADE;
DROP TABLE IF EXISTS "user_roles" CASCADE;
DROP TABLE IF EXISTS "users" CASCADE;

-- Drop all sequences
DROP SEQUENCE IF EXISTS "customers_customer_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "employees_employee_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "modules_module_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "permissions_permission_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "products_product_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "roles_role_id_seq" CASCADE;
DROP SEQUENCE IF EXISTS "users_user_id_seq" CASCADE;

-- Drop all custom types
DROP TYPE IF EXISTS "_versions" CASCADE;
DROP TYPE IF EXISTS "customers" CASCADE;
DROP TYPE IF EXISTS "employees" CASCADE;
DROP TYPE IF EXISTS "fields" CASCADE;
DROP TYPE IF EXISTS "modules" CASCADE;
DROP TYPE IF EXISTS "permission_hierarchy" CASCADE;
DROP TYPE IF EXISTS "permissions" CASCADE;
DROP TYPE IF EXISTS "products" CASCADE;
DROP TYPE IF EXISTS "role_permissions" CASCADE;
DROP TYPE IF EXISTS "roles" CASCADE;
DROP TYPE IF EXISTS "tables" CASCADE;
DROP TYPE IF EXISTS "user_roles" CASCADE;
DROP TYPE IF EXISTS "users" CASCADE;

-- No domains found in public schema

-- No aggregates found in public schema

-- Drop all user-owned schemas
DROP SCHEMA IF EXISTS "common" CASCADE;
DROP SCHEMA IF EXISTS "pgtap" CASCADE;
DROP SCHEMA IF EXISTS "rbac" CASCADE;

