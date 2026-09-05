-- Tests for audit log system.
--
-- Covers:
--   1. DML audit: INSERT, UPDATE, DELETE are logged to audit_record_logs
--   2. DML audit disabled: no records logged when audit_log=FALSE
--   3. Audit toggle: changing audit_log enables/disables tracking
--   4. DDL audit: schema changes are logged to audit_ddl_logs
--   5. New entities get audit triggers automatically
--   6. audit_log field metadata exists in entities schema
--   7. user_id is captured from JWT context
--   8. record_pk is captured for easy lookup
--   9. audit tables registered in entities/fields metadata
--  10. _core tables have audit enabled
--  11. an upsert logs INSERT and UPDATE across the two trigger shapes
BEGIN;

SELECT plan(39);

-- Authenticate as admin
SELECT authenticate_as('user3');

-- =====================================================
-- SETUP: Create a test entity for audit testing
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, audit_log
) VALUES (
    'audit_test_items', 'item', 'Audit Test Item', 'Audit Test Items',
    'Test entity for audit log tests',
    1, 'public:read', 'nwind:manage', 'id', 'item_name', TRUE
);

-- Add a text field
INSERT INTO fields (
    table_name, field_name, title, format, field_order, input_type, width
) VALUES (
    'audit_test_items', 'status', 'Status', 'text', 10, 'default', 'default'
);

-- =====================================================
-- TEST 0: audit_log=TRUE persists after entity creation
-- =====================================================

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_test_items'),
    TRUE,
    'audit_log=TRUE should persist after entity creation'
);

-- =====================================================
-- TEST 1: audit_log column defaults to FALSE on entities
-- =====================================================

-- Create entity without specifying audit_log - should default to FALSE
INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column
) VALUES (
    'audit_default_test', 'item', 'Default Test', 'Default Tests',
    'Test default audit_log value',
    1, 'public:read', 'nwind:manage', 'id', 'item_name'
);

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_default_test'),
    FALSE,
    'audit_log should default to FALSE for new entities'
);

-- =====================================================
-- TEST 2: audit triggers exist when audit_log=TRUE
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'audit_i_u_d trigger should exist on audit_test_items (audit_log=TRUE)'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_t'
    ),
    'audit_t trigger should exist on audit_test_items (audit_log=TRUE)'
);

-- =====================================================
-- TEST 3: No audit triggers when audit_log=FALSE (default)
-- =====================================================

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_default_test'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'audit_i_u_d trigger should NOT exist on audit_default_test (audit_log=FALSE default)'
);

-- =====================================================
-- TEST 4: INSERT is logged to audit_record_logs
-- =====================================================

-- Clear any existing audit records for our test table
DELETE FROM audit_record_logs
WHERE table_name = 'audit_test_items';

-- Insert a test record
INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Alpha', 'active');

SELECT is(
    (SELECT count(*)::integer FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'),
    1,
    'INSERT should be logged to audit_record_logs'
);

-- Verify the logged record contains the new data
SELECT ok(
    (SELECT record->>'item_name' = 'Widget Alpha'
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit record should contain the inserted data'
);

-- =====================================================
-- TEST 5: record_pk is captured
-- =====================================================

SELECT ok(
    (SELECT record_pk != '' AND record_pk IS NOT NULL
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit INSERT record should have a non-empty record_pk'
);

-- =====================================================
-- TEST 6: user_id is captured from JWT context
-- =====================================================

SELECT ok(
    (SELECT user_id > 0
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit INSERT record should have a non-zero user_id from JWT'
);

-- =====================================================
-- TEST 7: UPDATE is logged to audit_record_logs
-- =====================================================

UPDATE audit_test_items SET status = 'inactive'
WHERE item_name = 'Widget Alpha';

SELECT is(
    (SELECT count(*)::integer FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'),
    1,
    'UPDATE should be logged to audit_record_logs'
);

-- Verify old_record contains old value
SELECT ok(
    (SELECT old_record->>'status' = 'active'
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'
     LIMIT 1),
    'Audit UPDATE old_record should contain previous value'
);

-- Verify record contains new value
SELECT ok(
    (SELECT record->>'status' = 'inactive'
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'
     LIMIT 1),
    'Audit UPDATE record should contain new value'
);

-- =====================================================
-- TEST 8: DELETE is logged to audit_record_logs
-- =====================================================

DELETE FROM audit_test_items WHERE item_name = 'Widget Alpha';

SELECT is(
    (SELECT count(*)::integer FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'DELETE'),
    1,
    'DELETE should be logged to audit_record_logs'
);

-- Verify old_record contains the deleted data
SELECT ok(
    (SELECT old_record->>'item_name' = 'Widget Alpha'
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'DELETE'
     LIMIT 1),
    'Audit DELETE old_record should contain deleted data'
);

-- =====================================================
-- TEST 9: Disable audit_log via toggle
-- =====================================================

-- Clear audit records
DELETE FROM audit_record_logs WHERE table_name = 'audit_test_items';

-- Disable audit logging
UPDATE entities SET audit_log = FALSE
WHERE table_name = 'audit_test_items';

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_test_items'),
    FALSE,
    'audit_log should be FALSE after disabling'
);

-- Verify audit triggers are removed
-- Every audit trigger, not just the row-level one: an audited table carries
-- four, and naming only one turns this control green while insert and delete
-- logging carries on.
SELECT is(
    (SELECT count(*)::int FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND starts_with(t.tgname::text, 'audit_')),
    0,
    'no audit trigger should exist after disabling audit_log'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_t'
    ),
    'audit_t trigger should NOT exist after disabling audit_log'
);

-- =====================================================
-- TEST 10: DML not logged when audit_log=FALSE
-- =====================================================

INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Beta', 'active');

UPDATE audit_test_items SET status = 'inactive'
WHERE item_name = 'Widget Beta';

DELETE FROM audit_test_items WHERE item_name = 'Widget Beta';

SELECT is(
    (SELECT count(*)::integer FROM audit_record_logs
     WHERE table_name = 'audit_test_items'),
    0,
    'No DML operations should be logged when audit_log=FALSE'
);

-- =====================================================
-- TEST 11: Re-enable audit_log via toggle
-- =====================================================

UPDATE entities SET audit_log = TRUE
WHERE table_name = 'audit_test_items';

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_test_items'),
    TRUE,
    'audit_log should be TRUE after re-enabling'
);

-- Verify audit triggers are back
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'audit_i_u_d trigger should exist after re-enabling audit_log'
);

-- =====================================================
-- TEST 12: DML logged again after re-enabling
-- =====================================================

-- Clear audit records
DELETE FROM audit_record_logs WHERE table_name = 'audit_test_items';

INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Gamma', 'active');

SELECT is(
    (SELECT count(*)::integer FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'),
    1,
    'INSERT should be logged after re-enabling audit_log'
);

-- =====================================================
-- TEST 13: DDL audit - schema changes are logged
-- =====================================================

-- The DDL event trigger logs all DDL commands.
-- Creating and altering tables (via entity system) generates DDL.
-- Verify that audit_ddl_logs has records from our entity creation.

SELECT ok(
    (SELECT count(*) FROM audit_ddl_logs WHERE command_tag = 'CREATE TABLE') > 0,
    'DDL audit should have logged CREATE TABLE events'
);

SELECT ok(
    (SELECT count(*) FROM audit_ddl_logs WHERE command_tag = 'CREATE INDEX') > 0,
    'DDL audit should have logged CREATE INDEX events'
);

SELECT ok(
    (SELECT count(*) FROM audit_ddl_logs WHERE command_tag = 'CREATE TRIGGER') > 0,
    'DDL audit should have logged CREATE TRIGGER events'
);

-- =====================================================
-- TEST 14: audit_log field metadata exists in entities schema
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = 'entities'
          AND field_name = 'audit_log'
    ),
    'audit_log field metadata should exist in fields table for entities'
);

SELECT is(
    (SELECT format FROM fields
     WHERE table_name = 'entities' AND field_name = 'audit_log'),
    'boolean',
    'audit_log field should have format=boolean'
);

SELECT is(
    (SELECT default_value FROM fields
     WHERE table_name = 'entities' AND field_name = 'audit_log'),
    'false',
    'audit_log field should have default_value=false'
);

-- =====================================================
-- TEST 15: Audit record has correct metadata
-- =====================================================

SELECT ok(
    (SELECT record_id IS NOT NULL
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit INSERT record should have a non-null record_id'
);

SELECT ok(
    (SELECT ts IS NOT NULL
     FROM audit_record_logs
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit record should have a non-null timestamp'
);

-- =====================================================
-- TEST 16: audit tables are in public schema (no separate audit namespace)
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'audit_record_logs'
    ),
    'audit_record_logs should be in public schema'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'audit_ddl_logs'
    ),
    'audit_ddl_logs should be in public schema'
);

-- =====================================================
-- TEST 17: audit tables are registered in entities metadata
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM entities
        WHERE table_name = 'audit_record_logs'
    ),
    'audit_record_logs should be registered in entities'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM entities
        WHERE table_name = 'audit_ddl_logs'
    ),
    'audit_ddl_logs should be registered in entities'
);

-- =====================================================
-- TEST 18: audit tables have field metadata
-- =====================================================

SELECT ok(
    (SELECT count(*) FROM fields
     WHERE table_name = 'audit_record_logs') > 0,
    'audit_record_logs should have field metadata in fields table'
);

SELECT ok(
    (SELECT count(*) FROM fields
     WHERE table_name = 'audit_ddl_logs') > 0,
    'audit_ddl_logs should have field metadata in fields table'
);

-- =====================================================
-- TEST 19: _core tables have audit_log enabled
-- =====================================================

SELECT is(
    (SELECT count(*)::integer FROM entities
     WHERE table_name IN ('entities', 'fields', 'users', 'modules', 'roles', 'permissions',
                           'user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy')
       AND audit_log = TRUE),
    10,
    'All 10 _core tables should have audit_log=TRUE'
);

-- Verify audit triggers exist on _core tables
SELECT is(
    (SELECT array_agg(t.tgname::text ORDER BY t.tgname) FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'users'
          AND c.relnamespace = 'public'::regnamespace
          AND starts_with(t.tgname::text, 'audit_')),
    ARRAY['audit_d', 'audit_i', 'audit_i_u_d', 'audit_t'],
    'users (_core) table should have the full set of audit triggers'
);

-- An upsert splits across the two shapes: the update half is logged row by row
-- as it executes, the insert half once at end of statement. Both must land, and
-- with the right op.
INSERT INTO users (external_id, email, display_name)
VALUES ('audit-upsert-probe', 'upsert@probe.test', 'Upsert Probe')
ON CONFLICT (external_id) DO UPDATE SET display_name = EXCLUDED.display_name;

INSERT INTO users (external_id, email, display_name)
VALUES ('audit-upsert-probe', 'upsert@probe.test', 'Upsert Probe Two')
ON CONFLICT (external_id) DO UPDATE SET display_name = EXCLUDED.display_name;

SELECT is(
    (SELECT array_agg(op::text ORDER BY op::text) FROM audit_record_logs
     WHERE table_name = 'users'
       AND COALESCE(record ->> 'external_id', old_record ->> 'external_id') = 'audit-upsert-probe'),
    ARRAY['INSERT', 'UPDATE'],
    'an upsert logs one INSERT and one UPDATE across the two trigger shapes'
);

-- =====================================================
-- TEST 20: DDL audit logs use user_id (not session user name)
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'audit_ddl_logs'
          AND column_name = 'user_id'
    ),
    'audit_ddl_logs should have user_id column (not user_name)'
);

-- =====================================================
-- CLEANUP
-- =====================================================

DELETE FROM entities WHERE table_name = 'audit_test_items';
DELETE FROM entities WHERE table_name = 'audit_default_test';

SELECT * FROM finish();
ROLLBACK;
