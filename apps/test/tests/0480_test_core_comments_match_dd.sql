-- =====================================================
-- _core comments match the data dictionary (0480)
-- =====================================================
-- The table and column comments of the _core tables are generated from the DD
-- (dd_table_comment / dd_field_comment), in 0070 for the tables seeded before the
-- triggers exist and by the triggers for the rest. PostgREST shows these comments
-- as descriptions in its OpenAPI output, so the DD description has to stay their
-- only source. A COMMENT ON statement in a migration overwrites the generated text
-- and drifts from the DD the moment either side changes; both checks list every
-- table or column that no longer matches.
--
-- The two audit tables keep their longer table comments on purpose (what the
-- event triggers capture and why), so they are left out of the table check. Their
-- column comments come from the DD like every other and are checked.
BEGIN;

SELECT plan(2);

SELECT is_empty(
    $$SELECT f.id
      FROM fields f
      JOIN entities e ON e.table_name = f.table_name
      JOIN modules m ON m.id = e.module_id AND m.module_name = '_core'
      JOIN pg_attribute a
        ON a.attrelid = format('public.%I', f.table_name)::regclass
       AND a.attname = f.field_name AND NOT a.attisdropped
      WHERE col_description(a.attrelid, a.attnum)
            IS DISTINCT FROM dd_field_comment(f.title, f.format, f.description, f.enum_values)$$,
    'every _core column comment equals the comment generated from its DD field'
);

SELECT is_empty(
    $$SELECT e.table_name
      FROM entities e
      JOIN modules m ON m.id = e.module_id AND m.module_name = '_core'
      WHERE e.table_name NOT IN ('audit_record_logs', 'audit_ddl_logs')
        AND obj_description(format('public.%I', e.table_name)::regclass, 'pg_class')
            IS DISTINCT FROM dd_table_comment(e.plural_label, e.description)$$,
    'every _core table comment except the audit tables equals the comment generated from its entity'
);

SELECT * FROM finish();
ROLLBACK;
