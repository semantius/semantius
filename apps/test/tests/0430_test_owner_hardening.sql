-- =====================================================
-- Owner hardening (0430)
-- =====================================================
-- 0290_owner_hardening moves every Semantius core object to the dedicated
-- semantius_owner role (NOLOGIN, NOSUPERUSER, BYPASSRLS) when the installer
-- was a superuser, so SECURITY DEFINER dictionary code no longer runs with
-- superuser powers. On managed platforms (installer not a superuser) the
-- migration is a no-op; every assertion below then reports a pass with a
-- "skipped" note instead of failing, so the suite stays meaningful on both.
BEGIN;

SELECT plan(8);

CREATE TEMP TABLE hardening_ctx AS
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') AS active;

-- 1. the role itself
SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    ok((SELECT NOT rolsuper AND NOT rolcanlogin AND rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolinherit
          FROM pg_roles WHERE rolname = 'semantius_owner'),
       'semantius_owner is NOLOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOINHERIT and BYPASSRLS')
ELSE pass('owner hardening not active (installer was not a superuser): role check skipped') END;

-- 2. every core relation is owned by it (other extensions and pgtap excluded)
SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    is((SELECT count(*)::int
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
           AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
           AND pg_get_userbyid(c.relowner) <> 'semantius_owner'
           AND NOT EXISTS (
               SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
                WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                  AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                  AND e.extname <> 'pg_semantius')),
       0, 'every table, sequence and view in the core schemas is owned by semantius_owner')
ELSE pass('owner hardening not active: relation ownership check skipped') END;

-- 3. every core function is owned by it
SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    is((SELECT count(*)::int
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
           AND pg_get_userbyid(p.proowner) <> 'semantius_owner'
           AND NOT EXISTS (
               SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
                WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                  AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                  AND e.extname <> 'pg_semantius')),
       0, 'every function in the core schemas is owned by semantius_owner')
ELSE pass('owner hardening not active: function ownership check skipped') END;

-- 4. SECURITY DEFINER dictionary code therefore runs as a non-superuser
SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    is((SELECT r.rolsuper FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
         WHERE p.proname = 'add_dd_field' AND p.pronamespace = 'public'::regnamespace),
       false, 'the DDL trigger functions no longer run as a superuser')
ELSE pass('owner hardening not active: definer check skipped') END;

-- 5.-8. objects the dictionary creates at runtime are owned by semantius_owner
--       and the request role keeps its privileges on them (default privileges)
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('own_probe', 'own_probe', 'Own Probe', 'Own Probes', 'owner hardening probe', 1, 'public:read', 'admin', 'id', 'label');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width)
VALUES ('own_probe', 'note', 'Note', 'text', 10, 'default', 'default');

SELECT lives_ok($$INSERT INTO own_probe (label, note) VALUES ('r1', 'n')$$,
    'an admin can insert into a table the dictionary just created');

RESET ROLE;

SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    is((SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.own_probe'::regclass),
       'semantius_owner', 'a table created through the dictionary is owned by semantius_owner')
ELSE pass('owner hardening not active: runtime table ownership check skipped') END;

SELECT CASE WHEN (SELECT active FROM hardening_ctx) THEN
    is((SELECT pg_get_userbyid(proowner) FROM pg_proc
         WHERE proname = 'compute_validate_own_probe' OR (proname = '_label' AND proargtypes[0] = 'public.own_probe'::regtype)
         LIMIT 1),
       'semantius_owner', 'functions generated for the entity are owned by semantius_owner')
ELSE pass('owner hardening not active: generated function ownership check skipped') END;

SELECT ok(has_table_privilege('semantius_user', 'public.own_probe', 'SELECT')
       AND has_table_privilege('semantius_user', 'public.own_probe', 'INSERT')
       AND has_table_privilege('semantius_user', 'public.own_probe', 'UPDATE')
       AND has_table_privilege('semantius_user', 'public.own_probe', 'DELETE'),
    'semantius_user holds the table privileges on a dictionary-created table');

SELECT * FROM finish();
ROLLBACK;
