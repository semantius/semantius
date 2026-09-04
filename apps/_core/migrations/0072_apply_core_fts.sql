-- =====================================================
-- APPLY FTS TO CORE DD TABLES
-- =====================================================
-- Core tables (entities, fields, users, modules, roles, permissions)
-- are created in 0060_dd_schema.sql before the DD trigger system (0070),
-- so their field metadata inserts don't fire handle_field_searchable_insert_trigger.
-- We apply search_vector columns explicitly here.
-- Tables created later via the DD system (e.g. webhook_receivers in 0100)
-- get FTS automatically through the trigger.

-- Apply search_vector to core tables that have searchable fields
SELECT update_search_vector_column('entities');
SELECT update_search_vector_column('fields');
SELECT update_search_vector_column('users');
SELECT update_search_vector_column('modules');
SELECT update_search_vector_column('roles');
SELECT update_search_vector_column('permissions');

-- Update searchable flags for all core entities to ensure consistency
UPDATE entities t
SET searchable = EXISTS (
    SELECT 1 FROM fields f 
    WHERE f.table_name = t.table_name 
      AND f.searchable = TRUE
);

-- Update is_child flags for all core entities to ensure consistency
UPDATE entities t
SET is_child = EXISTS (
    SELECT 1 FROM fields f 
    WHERE f.table_name = t.table_name 
      AND f.format = 'parent'
);
