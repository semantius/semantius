-- Every field that must refuse a missing value has its check, core tables included,
-- and no other field has one. A check is created by several paths (a new field, a
-- changed field, adoption, the pass over existing fields after a migrate), so this
-- catches a path that forgets one. It reads the database the migrations left behind,
-- so it also proves the core tables, whose fields are seeded before the triggers
-- exist, got theirs.
BEGIN;

SELECT plan(2);

SELECT is_empty(
    $$SELECT f.id
        FROM fields f
        JOIN entities e ON e.table_name = f.table_name
       WHERE e.managed
         AND dd_required_test(f) IS NOT NULL
         AND NOT dd_constraint_exists(
                 dd_relation(e.table_name, e.id_type),
                 format('%s_%s_assert', dd_relation(e.table_name, e.id_type), f.field_name))$$,
    'every required field of every managed entity has its required check');

SELECT is_empty(
    $$SELECT c.conname::text
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
       WHERE n.nspname = 'public'
         AND c.contype = 'c'
         AND c.conname LIKE '%\_assert' ESCAPE '\'
         AND NOT EXISTS (
             SELECT 1
               FROM fields f
               JOIN entities e ON e.table_name = f.table_name
              WHERE dd_relation(e.table_name, e.id_type) = t.relname
                AND c.conname = format('%s_%s_assert', t.relname, f.field_name)::name
                AND dd_required_test(f) IS NOT NULL)$$,
    'no field that must not refuse a missing value has a required check');

SELECT * FROM finish();
ROLLBACK;
