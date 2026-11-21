-- The index inventory of the core tables: every index on a table that _core or
-- the migration runner (_versions) creates, pinned by the definition PostgreSQL
-- reports for it.
--
-- A unique index enforces a rule; a plain one keeps a lookup, or the check of a
-- foreign key, from scanning its table. Neither shows when it is missing: every
-- query still answers, only slower, and a lost unique index lets duplicates in
-- without an error. pg-compare-installs.sh and step 10 of pg-ext-lifecycle.sh
-- prove that the ways of installing agree with each other, not that an index is
-- there at all, and a test that names an index covers only the ones someone
-- thought of. This file lists them all. Adding, dropping or changing an index on
-- a core table means editing the list below, and the diff shows it - whether it
-- is a static one from a migration, or one the dictionary builds from a fields
-- row (idx_<table>_<field> for a reference, <table>_<field>_unique for
-- unique_value, <table>_search_vector_idx for searchable fields).
--
-- The definition is compared rather than the name alone, so a changed column
-- list, index method or partial predicate shows too. set_eq reports the rows
-- that are missing and the rows that are extra.
--
-- Scope: the tables in public, common and audit, apart from the tables of the
-- nwind sample module, which is not core (apps/nwind/tests/
-- 0020_test_nwind_schema.sql checks its foreign-key and unique indexes by
-- name). pgmq is left out: it is vendored from upstream and keeps upstream's
-- indexes as they are.
--
-- Every earlier test rolls back, so what this file sees is the installed schema.
BEGIN;

SELECT plan(4);

SELECT set_eq(
    $$SELECT i.indexdef FROM pg_indexes i
       WHERE i.schemaname = 'public'
         AND i.tablename NOT IN (SELECT e.table_name FROM entities e
                                   JOIN modules m ON m.id = e.module_id
                                  WHERE m.module_slug = 'nwind')$$,
    ARRAY[
        'CREATE UNIQUE INDEX _apikeys_key_id_key ON public._apikeys USING btree (key_id)',
        'CREATE UNIQUE INDEX _apikeys_pkey ON public._apikeys USING btree (id)',
        'CREATE INDEX idx_apikeys_user_id ON public._apikeys USING btree (user_id)',
        'CREATE UNIQUE INDEX _settings_pkey ON public._settings USING btree (name)',
        'CREATE UNIQUE INDEX _versions_pkey ON public._versions USING btree (name)',
        'CREATE INDEX audit_ddl_logs_event_time ON public.audit_ddl_logs USING brin (event_time)',
        'CREATE UNIQUE INDEX audit_ddl_logs_pkey ON public.audit_ddl_logs USING btree (id)',
        'CREATE INDEX audit_ddl_logs_search_vector_idx ON public.audit_ddl_logs USING gin (search_vector)',
        'CREATE INDEX audit_record_logs_old_record_id ON public.audit_record_logs USING btree (old_record_id) WHERE (old_record_id IS NOT NULL)',
        'CREATE UNIQUE INDEX audit_record_logs_pkey ON public.audit_record_logs USING btree (id)',
        'CREATE INDEX audit_record_logs_record_id ON public.audit_record_logs USING btree (record_id) WHERE (record_id IS NOT NULL)',
        'CREATE INDEX audit_record_logs_record_pk ON public.audit_record_logs USING btree (record_pk) WHERE (record_pk <> ''''::text)',
        'CREATE INDEX audit_record_logs_search_vector_idx ON public.audit_record_logs USING gin (search_vector)',
        'CREATE INDEX audit_record_logs_superuser ON public.audit_record_logs USING btree (ts DESC) WHERE is_superuser',
        'CREATE INDEX audit_record_logs_table_oid ON public.audit_record_logs USING btree (table_oid)',
        'CREATE INDEX audit_record_logs_ts ON public.audit_record_logs USING brin (ts)',
        'CREATE UNIQUE INDEX dashboards_pkey ON public.dashboards USING btree (id)',
        'CREATE INDEX dashboards_search_vector_idx ON public.dashboards USING gin (search_vector)',
        'CREATE INDEX idx_dashboards_module_id ON public.dashboards USING btree (module_id)',
        'CREATE INDEX idx_dashboards_view_permission ON public.dashboards USING btree (view_permission)',
        'CREATE UNIQUE INDEX entities_pkey ON public.entities USING btree (table_name)',
        'CREATE INDEX entities_search_vector_idx ON public.entities USING gin (search_vector)',
        'CREATE INDEX idx_entities_edit_permission ON public.entities USING btree (edit_permission)',
        'CREATE INDEX idx_entities_id_refentity ON public.entities USING btree (id_refentity)',
        'CREATE INDEX idx_entities_module ON public.entities USING btree (module_id)',
        'CREATE INDEX idx_entities_view_permission ON public.entities USING btree (view_permission)',
        'CREATE UNIQUE INDEX unique_current_id_prefix ON public.entities USING btree (id_prefix) WHERE (id_prefix <> ''''::text)',
        'CREATE UNIQUE INDEX fields_pkey ON public.fields USING btree (id)',
        'CREATE INDEX fields_search_vector_idx ON public.fields USING gin (search_vector)',
        'CREATE UNIQUE INDEX fields_table_field_unique ON public.fields USING btree (table_name, field_name)',
        'CREATE INDEX idx_fields_is_pk ON public.fields USING btree (is_pk) WHERE (is_pk = true)',
        'CREATE INDEX idx_fields_name ON public.fields USING btree (field_name)',
        'CREATE INDEX idx_fields_reference_table ON public.fields USING btree (reference_table) WHERE (reference_table <> ''''::text)',
        'CREATE UNIQUE INDEX one_pk_per_table_idx ON public.fields USING btree (table_name) WHERE is_pk',
        'CREATE INDEX idx_modules_admin_permission ON public.modules USING btree (admin_permission)',
        'CREATE INDEX idx_modules_default_admin_role ON public.modules USING btree (default_admin_role_id)',
        'CREATE INDEX idx_modules_default_manager_role ON public.modules USING btree (default_manager_role_id)',
        'CREATE INDEX idx_modules_default_viewer_role ON public.modules USING btree (default_viewer_role_id)',
        'CREATE INDEX idx_modules_manage_permission ON public.modules USING btree (manage_permission)',
        'CREATE INDEX idx_modules_view_permission ON public.modules USING btree (view_permission)',
        'CREATE UNIQUE INDEX modules_module_name_key ON public.modules USING btree (module_name)',
        'CREATE UNIQUE INDEX modules_module_slug_key ON public.modules USING btree (module_slug)',
        'CREATE UNIQUE INDEX modules_pkey ON public.modules USING btree (id)',
        'CREATE INDEX modules_search_vector_idx ON public.modules USING gin (search_vector)',
        'CREATE INDEX idx_permission_hierarchy_included ON public.permission_hierarchy USING btree (included_permission_name)',
        'CREATE UNIQUE INDEX permission_hierarchy_including_permission_name_included_per_key ON public.permission_hierarchy USING btree (including_permission_name, included_permission_name)',
        'CREATE UNIQUE INDEX permission_hierarchy_pkey ON public.permission_hierarchy USING btree (id)',
        'CREATE INDEX idx_permissions_module ON public.permissions USING btree (module_id)',
        'CREATE UNIQUE INDEX permissions_pkey ON public.permissions USING btree (permission_name)',
        'CREATE INDEX permissions_search_vector_idx ON public.permissions USING gin (search_vector)',
        'CREATE INDEX idx_process_gates_emit ON public.process_gates USING btree (entity) WHERE (emits_events = true)',
        'CREATE INDEX idx_process_gates_entity ON public.process_gates USING btree (entity)',
        'CREATE INDEX idx_process_gates_process_id ON public.process_gates USING btree (process_id)',
        'CREATE UNIQUE INDEX process_gates_pkey ON public.process_gates USING btree (id)',
        'CREATE UNIQUE INDEX process_gates_process_entity_gate_state_key ON public.process_gates USING btree (to_state, entity, gate_kind, process_id)',
        'CREATE INDEX process_gates_search_vector_idx ON public.process_gates USING gin (search_vector)',
        'CREATE UNIQUE INDEX idx_processes_global_key ON public.processes USING btree (process_key) WHERE ((module_id IS NULL) AND (process_key <> ''''::text))',
        'CREATE INDEX idx_processes_module_id ON public.processes USING btree (module_id)',
        'CREATE UNIQUE INDEX idx_processes_module_key ON public.processes USING btree (module_id, process_key) WHERE ((module_id IS NOT NULL) AND (process_key <> ''''::text))',
        'CREATE UNIQUE INDEX processes_pkey ON public.processes USING btree (id)',
        'CREATE INDEX processes_search_vector_idx ON public.processes USING gin (search_vector)',
        'CREATE INDEX idx_queue_table_events_queue_id ON public.queue_table_events USING btree (queue_id)',
        'CREATE INDEX idx_queue_table_events_table_name ON public.queue_table_events USING btree (table_name)',
        'CREATE UNIQUE INDEX queue_table_events_pkey ON public.queue_table_events USING btree (id)',
        'CREATE INDEX queue_table_events_search_vector_idx ON public.queue_table_events USING gin (search_vector)',
        'CREATE UNIQUE INDEX queue_table_events_table_name_unique ON public.queue_table_events USING btree (table_name) WHERE ((table_name IS NOT NULL) AND (table_name <> ''''::text))',
        'CREATE INDEX idx_queues_manage_permission ON public.queues USING btree (manage_permission)',
        'CREATE INDEX idx_queues_view_permission ON public.queues USING btree (view_permission)',
        'CREATE UNIQUE INDEX queues_pkey ON public.queues USING btree (id)',
        'CREATE UNIQUE INDEX queues_queue_name_unique ON public.queues USING btree (queue_name) WHERE ((queue_name IS NOT NULL) AND (queue_name <> ''''::text))',
        'CREATE INDEX queues_search_vector_idx ON public.queues USING gin (search_vector)',
        'CREATE INDEX idx_raci_assignments_process_id ON public.raci_assignments USING btree (process_id)',
        'CREATE INDEX idx_raci_assignments_role_id ON public.raci_assignments USING btree (role_id)',
        'CREATE UNIQUE INDEX idx_raci_one_accountable ON public.raci_assignments USING btree (process_id) WHERE (raci = ''accountable''::text)',
        'CREATE UNIQUE INDEX raci_assignments_pkey ON public.raci_assignments USING btree (id)',
        'CREATE UNIQUE INDEX raci_assignments_process_role_raci_key ON public.raci_assignments USING btree (raci, process_id, role_id)',
        'CREATE INDEX raci_assignments_search_vector_idx ON public.raci_assignments USING gin (search_vector)',
        'CREATE INDEX idx_raci_events_entity ON public.raci_events USING btree (entity)',
        'CREATE INDEX idx_raci_events_entity_record ON public.raci_events USING btree (record_id, entity)',
        'CREATE INDEX idx_raci_events_process_id ON public.raci_events USING btree (process_id)',
        'CREATE INDEX idx_raci_events_status ON public.raci_events USING btree (status) WHERE (status <> ''acted''::text)',
        'CREATE INDEX idx_raci_events_target_role_id ON public.raci_events USING btree (target_role_id)',
        'CREATE UNIQUE INDEX raci_events_pkey ON public.raci_events USING btree (id)',
        'CREATE INDEX raci_events_search_vector_idx ON public.raci_events USING gin (search_vector)',
        'CREATE INDEX idx_role_permissions_granted_by ON public.role_permissions USING btree (granted_by)',
        'CREATE INDEX idx_role_permissions_permission ON public.role_permissions USING btree (permission_name)',
        'CREATE UNIQUE INDEX role_permissions_pkey ON public.role_permissions USING btree (id)',
        'CREATE UNIQUE INDEX role_permissions_role_id_permission_name_key ON public.role_permissions USING btree (role_id, permission_name)',
        'CREATE INDEX idx_roles_module ON public.roles USING btree (module_id)',
        'CREATE UNIQUE INDEX roles_pkey ON public.roles USING btree (id)',
        'CREATE UNIQUE INDEX roles_role_name_key ON public.roles USING btree (role_name)',
        'CREATE INDEX roles_search_vector_idx ON public.roles USING gin (search_vector)',
        'CREATE UNIQUE INDEX roles_slug_key ON public.roles USING btree (slug)',
        'CREATE INDEX idx_user_bookmarks_user_id ON public.user_bookmarks USING btree (user_id)',
        'CREATE UNIQUE INDEX user_bookmarks_pkey ON public.user_bookmarks USING btree (id)',
        'CREATE INDEX user_bookmarks_search_vector_idx ON public.user_bookmarks USING gin (search_vector)',
        'CREATE INDEX idx_user_permissions_granted_by ON public.user_permissions USING btree (granted_by)',
        'CREATE INDEX idx_user_permissions_permission ON public.user_permissions USING btree (permission_name)',
        'CREATE UNIQUE INDEX user_permissions_pkey ON public.user_permissions USING btree (id)',
        'CREATE UNIQUE INDEX user_permissions_user_id_permission_name_key ON public.user_permissions USING btree (user_id, permission_name)',
        'CREATE INDEX idx_user_roles_assigned_by ON public.user_roles USING btree (assigned_by)',
        'CREATE INDEX idx_user_roles_role ON public.user_roles USING btree (role_id)',
        'CREATE UNIQUE INDEX user_roles_pkey ON public.user_roles USING btree (id)',
        'CREATE UNIQUE INDEX user_roles_user_id_role_id_key ON public.user_roles USING btree (user_id, role_id)',
        'CREATE INDEX idx_users_disabled ON public.users USING btree (is_disabled) WHERE (is_disabled = true)',
        'CREATE INDEX idx_users_email ON public.users USING btree (email)',
        'CREATE INDEX idx_users_enabled ON public.users USING btree (is_disabled) WHERE (is_disabled = false)',
        'CREATE UNIQUE INDEX users_external_id_unique ON public.users USING btree (external_id) WHERE ((external_id IS NOT NULL) AND (external_id <> ''''::text))',
        'CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id)',
        'CREATE INDEX users_search_vector_idx ON public.users USING gin (search_vector)',
        'CREATE INDEX idx_webhook_receiver_logs_webhook_receiver_id ON public.webhook_receiver_logs USING btree (webhook_receiver_id)',
        'CREATE UNIQUE INDEX webhook_receiver_logs_pkey ON public.webhook_receiver_logs USING btree (id)',
        'CREATE INDEX webhook_receiver_logs_search_vector_idx ON public.webhook_receiver_logs USING gin (search_vector)',
        'CREATE INDEX idx_webhook_receivers_table_name ON public.webhook_receivers USING btree (table_name)',
        'CREATE UNIQUE INDEX webhook_receivers_pkey ON public.webhook_receivers USING btree (id)',
        'CREATE INDEX webhook_receivers_search_vector_idx ON public.webhook_receivers USING gin (search_vector)'
    ],
    'public: the core tables carry exactly these indexes'
);

SELECT set_eq(
    $$SELECT indexdef FROM pg_indexes WHERE schemaname = 'common'$$,
    ARRAY[
        'CREATE UNIQUE INDEX _cache_key_key ON common._cache USING btree (key)',
        'CREATE UNIQUE INDEX _cache_pkey ON common._cache USING btree (id)',
        'CREATE INDEX idx_cache_expires ON common._cache USING btree (expires_at)'
    ],
    'common: the core tables carry exactly these indexes'
);

SELECT set_eq(
    $$SELECT indexdef FROM pg_indexes WHERE schemaname = 'audit'$$,
    ARRAY[
        'CREATE UNIQUE INDEX generated_ddl_pkey ON audit.generated_ddl USING btree (transaction_id)'
    ],
    'audit: the core tables carry exactly these indexes'
);

-- The rule the list above follows, stated so that a new index breaking it
-- fails here with its name rather than only as an unexpected row: no plain
-- index repeats the leading columns of another index on the same table. A
-- query that could use the shorter one can use the longer one as well, so the
-- shorter one is only write cost. Where the two are a reference's
-- idx_<table>_<field> and a key written by hand, the hand-written key changes
-- its column order instead (0360_raci_setup.once.sql), because the dictionary
-- builds idx_<table>_<field> again whenever a fields edit rebuilds the
-- reference's foreign key. A partial index is left out: it covers fewer rows.
SELECT is(
    (SELECT string_agg(t.relname || '.' || ci.relname || ' repeats ' || cl.relname, ', '
                       ORDER BY t.relname, ci.relname, cl.relname)
       FROM pg_index x
       JOIN pg_class ci ON ci.oid = x.indexrelid
       JOIN pg_class t ON t.oid = x.indrelid
       JOIN pg_namespace n ON n.oid = t.relnamespace
       JOIN pg_index l ON l.indrelid = x.indrelid AND l.indexrelid <> x.indexrelid
                      AND l.indpred IS NULL AND l.indexprs IS NULL
       JOIN pg_class cl ON cl.oid = l.indexrelid
      WHERE n.nspname IN ('public', 'common', 'audit')
        AND t.relname NOT IN (SELECT e.table_name FROM entities e
                                JOIN modules m ON m.id = e.module_id
                               WHERE m.module_slug = 'nwind')
        AND NOT x.indisunique AND x.indpred IS NULL AND x.indexprs IS NULL
        AND ci.relam = cl.relam
        AND l.indnkeyatts >= x.indnkeyatts
        AND (string_to_array(l.indkey::text, ' ')::int[])[1:x.indnkeyatts]
          = string_to_array(x.indkey::text, ' ')::int[]
        AND (string_to_array(l.indclass::text, ' ')::oid[])[1:x.indnkeyatts]
          = string_to_array(x.indclass::text, ' ')::oid[]
        AND (x.indnkeyatts < l.indnkeyatts OR l.indisunique OR ci.relname > cl.relname)),
    NULL::text,
    'no plain index on a core table repeats the leading columns of another index'
);

SELECT * FROM finish();
ROLLBACK;
