-- =====================================================
-- APPLY FTS TO CORE TABLES
-- =====================================================
-- Core tables (entities, fields, users, modules, roles, permissions, etc.)
-- are created before the DD trigger system, so they need search_vector
-- columns applied explicitly. This runs after all migrations are complete.
-- Each table is processed individually to avoid active query conflicts.

-- Apply search_vector to core tables that have searchable fields
SELECT update_search_vector_column('users');
SELECT update_search_vector_column('modules');
SELECT update_search_vector_column('roles');
SELECT update_search_vector_column('permissions');
SELECT update_search_vector_column('entities');
SELECT update_search_vector_column('fields');
SELECT update_search_vector_column('webhook_receivers');
SELECT update_search_vector_column('webhook_receiver_logs');

-- Update searchable flags for all entities to ensure consistency
UPDATE entities t
SET searchable = EXISTS (
    SELECT 1 FROM fields f 
    WHERE f.table_name = t.table_name 
      AND f.searchable = TRUE
);
