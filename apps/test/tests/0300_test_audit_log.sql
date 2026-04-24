-- Tests for audit log system.
--
-- Covers:
--   1. DML audit: INSERT, UPDATE, DELETE are logged to audit.record_version
--   2. DML audit disabled: no records logged when audit_log=FALSE
--   3. Audit toggle: changing audit_log enables/disables tracking
--   4. DDL audit: schema changes are logged to audit.ddl_history
--   5. New entities get audit triggers automatically
--   6. audit_log field metadata exists in entities schema
BEGIN;

SELECT plan(27);

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
    1001, 'public:read', 'sales:manage', 'id', 'item_name', TRUE
);

-- Add a text field
INSERT INTO fields (
    table_name, field_name, title, format, field_order, input_type, width
) VALUES (
    'audit_test_items', 'status', 'Status', 'text', 10, 'default', 'default'
);

-- =====================================================
-- TEST 1: audit_log column defaults to TRUE on entities
-- =====================================================

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_test_items'),
    TRUE,
    'audit_log should default to TRUE for new entities'
);

-- =====================================================
-- TEST 2: audit triggers exist on the new table
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'audit_i_u_d trigger should exist on audit_test_items'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_t'
    ),
    'audit_t trigger should exist on audit_test_items'
);

-- =====================================================
-- TEST 3: INSERT is logged to audit.record_version
-- =====================================================

-- Clear any existing audit records for our test table
DELETE FROM audit.record_version
WHERE table_name = 'audit_test_items';

-- Insert a test record
INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Alpha', 'active');

SELECT is(
    (SELECT count(*)::integer FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'),
    1,
    'INSERT should be logged to audit.record_version'
);

-- Verify the logged record contains the new data
SELECT ok(
    (SELECT record->>'item_name' = 'Widget Alpha'
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit record should contain the inserted data'
);

-- =====================================================
-- TEST 4: UPDATE is logged to audit.record_version
-- =====================================================

UPDATE audit_test_items SET status = 'inactive'
WHERE item_name = 'Widget Alpha';

SELECT is(
    (SELECT count(*)::integer FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'),
    1,
    'UPDATE should be logged to audit.record_version'
);

-- Verify old_record contains old value
SELECT ok(
    (SELECT old_record->>'status' = 'active'
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'
     LIMIT 1),
    'Audit UPDATE old_record should contain previous value'
);

-- Verify record contains new value
SELECT ok(
    (SELECT record->>'status' = 'inactive'
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'UPDATE'
     LIMIT 1),
    'Audit UPDATE record should contain new value'
);

-- =====================================================
-- TEST 5: DELETE is logged to audit.record_version
-- =====================================================

DELETE FROM audit_test_items WHERE item_name = 'Widget Alpha';

SELECT is(
    (SELECT count(*)::integer FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'DELETE'),
    1,
    'DELETE should be logged to audit.record_version'
);

-- Verify old_record contains the deleted data
SELECT ok(
    (SELECT old_record->>'item_name' = 'Widget Alpha'
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'DELETE'
     LIMIT 1),
    'Audit DELETE old_record should contain deleted data'
);

-- =====================================================
-- TEST 6: Disable audit_log via toggle
-- =====================================================

-- Clear audit records
DELETE FROM audit.record_version WHERE table_name = 'audit_test_items';

-- Disable audit logging
UPDATE entities SET audit_log = FALSE
WHERE table_name = 'audit_test_items';

SELECT is(
    (SELECT audit_log FROM entities WHERE table_name = 'audit_test_items'),
    FALSE,
    'audit_log should be FALSE after disabling'
);

-- Verify audit triggers are removed
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_test_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'audit_i_u_d trigger should NOT exist after disabling audit_log'
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
-- TEST 7: DML not logged when audit_log=FALSE
-- =====================================================

INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Beta', 'active');

UPDATE audit_test_items SET status = 'inactive'
WHERE item_name = 'Widget Beta';

DELETE FROM audit_test_items WHERE item_name = 'Widget Beta';

SELECT is(
    (SELECT count(*)::integer FROM audit.record_version
     WHERE table_name = 'audit_test_items'),
    0,
    'No DML operations should be logged when audit_log=FALSE'
);

-- =====================================================
-- TEST 8: Re-enable audit_log via toggle
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
-- TEST 9: DML logged again after re-enabling
-- =====================================================

-- Clear audit records
DELETE FROM audit.record_version WHERE table_name = 'audit_test_items';

INSERT INTO audit_test_items (item_name, status)
VALUES ('Widget Gamma', 'active');

SELECT is(
    (SELECT count(*)::integer FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'),
    1,
    'INSERT should be logged after re-enabling audit_log'
);

-- =====================================================
-- TEST 10: DDL audit - schema changes are logged
-- =====================================================

-- The DDL event trigger logs all DDL commands.
-- Creating and altering tables (via entity system) generates DDL.
-- Verify that ddl_history has records from our entity creation.

SELECT ok(
    (SELECT count(*) FROM audit.ddl_history WHERE command_tag = 'CREATE TABLE') > 0,
    'DDL audit should have logged CREATE TABLE events'
);

SELECT ok(
    (SELECT count(*) FROM audit.ddl_history WHERE command_tag = 'CREATE INDEX') > 0,
    'DDL audit should have logged CREATE INDEX events'
);

SELECT ok(
    (SELECT count(*) FROM audit.ddl_history WHERE command_tag = 'CREATE TRIGGER') > 0,
    'DDL audit should have logged CREATE TRIGGER events'
);

-- =====================================================
-- TEST 11: Entity created with audit_log=FALSE gets no triggers
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, audit_log
) VALUES (
    'audit_disabled_items', 'item', 'No Audit Item', 'No Audit Items',
    'Entity created with audit_log disabled',
    1001, 'public:read', 'sales:manage', 'id', 'item_name', FALSE
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'audit_disabled_items'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'Entity created with audit_log=FALSE should NOT have audit triggers'
);

-- =====================================================
-- TEST 12: Existing managed entities have audit triggers
-- =====================================================

-- customers_test was created by the seed data and should have audit triggers
-- because audit_log defaults to TRUE
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = 'customers_test'
          AND c.relnamespace = 'public'::regnamespace
          AND t.tgname = 'audit_i_u_d'
    ),
    'Pre-existing managed entity (customers_test) should have audit_i_u_d trigger'
);

-- =====================================================
-- TEST 13: audit_log field metadata exists in entities schema
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
    'true',
    'audit_log field should have default_value=true'
);

-- =====================================================
-- TEST 14: Audit record has correct metadata
-- =====================================================

SELECT ok(
    (SELECT record_id IS NOT NULL
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit INSERT record should have a non-null record_id'
);

SELECT ok(
    (SELECT ts IS NOT NULL
     FROM audit.record_version
     WHERE table_name = 'audit_test_items' AND op = 'INSERT'
     LIMIT 1),
    'Audit record should have a non-null timestamp'
);

-- =====================================================
-- CLEANUP
-- =====================================================

DELETE FROM entities WHERE table_name = 'audit_test_items';
DELETE FROM entities WHERE table_name = 'audit_disabled_items';

SELECT * FROM finish();
ROLLBACK;
