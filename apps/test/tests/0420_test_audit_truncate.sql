-- =====================================================
-- TRUNCATE audit path (0420)
-- =====================================================
-- audit.truncate_trigger() (0150_audit_log.sql) was never executed by the
-- suite: 0300 covers INSERT/UPDATE/DELETE and DDL audit only. TRUNCATE needs
-- the TRUNCATE privilege, which semantius_user does not have on entity tables,
-- so the statement itself runs as the owner (RESET ROLE); the entity and its
-- rows are created as admin (user3) exactly like 0300 does.
BEGIN;

SELECT plan(6);

SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, audit_log
) VALUES (
    'audit_trunc_items', 'item', 'Audit Truncate Item', 'Audit Truncate Items',
    'Test entity for the TRUNCATE audit path',
    1, 'public:read', 'admin', 'id', 'item_name', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width)
VALUES ('audit_trunc_items', 'status', 'Status', 'text', 10, 'default', 'default');

INSERT INTO audit_trunc_items (item_name, status) VALUES ('a', 'x'), ('b', 'y');

SELECT is(
    (SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'audit_trunc_items' AND op = 'INSERT'),
    2, 'fixture: the two inserts are audited');

SELECT throws_ok($$TRUNCATE audit_trunc_items$$, '42501', NULL,
    'the request role cannot TRUNCATE an entity table');

RESET ROLE;
TRUNCATE audit_trunc_items;

SELECT is((SELECT count(*)::int FROM audit_trunc_items), 0, 'fixture: the table is empty after TRUNCATE');
SELECT is(
    (SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'audit_trunc_items' AND op = 'TRUNCATE'),
    1, 'TRUNCATE writes exactly one statement-level audit row');
SELECT is(
    (SELECT record_id IS NULL AND old_record_id IS NULL AND record IS NULL AND old_record IS NULL AND record_pk = ''
       FROM audit_record_logs WHERE table_name = 'audit_trunc_items' AND op = 'TRUNCATE'),
    true, 'the TRUNCATE audit row carries no record payload');
SELECT is(
    (SELECT table_schema::text || '.' || table_name::text
       FROM audit_record_logs WHERE table_name = 'audit_trunc_items' AND op = 'TRUNCATE'),
    'public.audit_trunc_items', 'the TRUNCATE audit row names the truncated table');

SELECT * FROM finish();
ROLLBACK;
