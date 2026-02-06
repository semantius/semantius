-- =====================================================
-- BACKWARD COMPATIBILITY VIEW
-- =====================================================
-- Create an updatable view named "tables" that maps to "entities" table
-- This ensures external applications using the old "tables" name continue to work
-- Goal: semantius-core uses "entities", but old apps can still use "tables" view
-- =====================================================

-- Create a simple view that maps to entities table
-- PostgreSQL automatically makes this view updatable because:
-- 1. It selects from a single table (entities)
-- 2. It uses only simple column references (no expressions, aggregates, etc.)
-- 3. It doesn't use GROUP BY, HAVING, LIMIT, OFFSET, DISTINCT, UNION, etc.
-- This means INSERT, UPDATE, and DELETE operations work transparently without INSTEAD OF triggers
CREATE OR REPLACE VIEW tables AS
SELECT * FROM entities;

COMMENT ON VIEW tables IS 
'Backward compatibility view for entities table. PostgreSQL automatically makes this view updatable, allowing INSERT/UPDATE/DELETE operations to work transparently. External apps can continue using "tables" name while semantius-core uses "entities".';
