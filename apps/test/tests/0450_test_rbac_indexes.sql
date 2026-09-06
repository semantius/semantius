-- The RBAC index set: what must not come back, and what must keep working.
--
-- Every table 0020_rbac_schema.sql creates already carries a unique index over
-- the columns its lookups filter on - either as the whole key (module_name,
-- permission_name, role_name, roles.slug) or as the leading columns of a
-- composite one (the four junction tables). A second plain index over the same
-- leading columns cannot be the only thing that answers a query, so the planner
-- reaches the unique index instead, and the duplicate is pure write cost.
--
-- GROUP 1 sweeps the catalog for that shape rather than naming index names, so
-- it fails when a duplicate is reintroduced under any name. GROUP 2 is the half
-- a name sweep cannot prove: that the remaining composite can still resolve the
-- recursive permission walk through an index. It runs with enable_seqscan off,
-- because these tables hold a handful of rows and the planner is right to scan
-- them sequentially - asserting a plan shape without that would be asserting
-- whatever ANALYZE last saw.
--
-- GROUP 3 states the uniqueness rule on users.external_id, which is a
-- data-integrity rule rather than an index detail: the only unique index on
-- that column is the dictionary's partial one, and it excludes the empty
-- string. So MANY rows may carry external_id = '' where a total UNIQUE
-- constraint allowed exactly one. That is deliberate - a pre-provisioned
-- principal with no external identity yet is a real state - and it is asserted
-- here so that changing it back is a visible decision. Nothing creates such a
-- row today: both upsert paths reject an empty external_id.
--
-- GROUP 4 is the regression that would otherwise reach production as a failed
-- login. A bare ON CONFLICT (external_id) cannot infer a partial index, so the
-- upsert sites repeat the index predicate; if one of them loses it, the second
-- call for the same subject raises instead of updating.
--
-- Fixtures: user3 = Administrator (users carries RLS requiring user:manage for
-- writes, plus audit triggers). The catalog sweep runs as the owner.
BEGIN;

SELECT plan(9);

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: no plain index duplicates a unique one
-- =====================================================
RESET ROLE;

-- A non-unique, non-partial index is redundant when some unique, non-partial
-- index on the same table starts with exactly its key columns. indkey is an
-- int2vector, hence the text round trip to compare a prefix.
SELECT is(
    (SELECT string_agg(ct.relname || '.' || ci.relname, ', ' ORDER BY ct.relname, ci.relname)
     FROM pg_index x
     JOIN pg_class ci ON ci.oid = x.indexrelid
     JOIN pg_class ct ON ct.oid = x.indrelid
     JOIN pg_namespace n ON n.oid = ct.relnamespace
     WHERE n.nspname = 'public'
       AND ct.relname IN ('modules', 'permissions', 'roles', 'users',
                          'user_roles', 'role_permissions', 'user_permissions',
                          'permission_hierarchy')
       AND NOT x.indisunique
       AND x.indpred IS NULL
       AND EXISTS (
           SELECT 1 FROM pg_index u
           WHERE u.indrelid = x.indrelid
             AND u.indisunique
             AND u.indpred IS NULL
             AND u.indnkeyatts >= x.indnkeyatts
             AND (string_to_array(u.indkey::text, ' ')::int[])[1:x.indnkeyatts]
               = (string_to_array(x.indkey::text, ' ')::int[])[1:x.indnkeyatts])),
    NULL::text,
    'no plain index on an RBAC table repeats the leading columns of a unique index'
);

-- Without this, the sweep above would also pass on a schema that had lost the
-- unique indexes, which is the opposite of what the drop was for.
SELECT is(
    (SELECT count(*)::int FROM pg_indexes
     WHERE schemaname = 'public'
       AND indexname IN ('modules_module_name_key', 'permissions_permission_name_key',
                         'roles_role_name_key', 'roles_slug_key',
                         'users_external_id_unique',
                         'user_roles_user_id_role_id_key',
                         'role_permissions_role_id_permission_id_key',
                         'user_permissions_user_id_permission_id_key',
                         'permission_hierarchy_including_permission_id_included_permi_key')),
    9,
    'the unique indexes that make the duplicates redundant are all present'
);

-- =====================================================
-- GROUP 2: the permission walk still resolves through indexes
-- =====================================================
SELECT authenticate_as('user3');

CREATE TEMP TABLE rbac_walk_plan(line text);

-- enable_seqscan = off is what makes this assertable rather than flaky. These
-- tables hold a handful of rows, so with real statistics a sequential scan is
-- the cheapest plan and the planner is right to pick one - the assertions below
-- would then report a fault that does not exist, and would flip with whatever
-- ANALYZE last saw. Turning the alternative off asks the question that actually
-- matters after dropping an index: is there still an index that CAN serve this
-- qual. If the composite could not, PostgreSQL would fall back to a sequential
-- scan even here, and the assertions would fail.
SET LOCAL enable_seqscan = off;

-- The body of rbac.user_has_permission's first EXISTS, verbatim. EXPLAIN cannot
-- appear in a subquery, so the rows are collected through EXECUTE.
DO $do$
DECLARE v_line text;
BEGIN
    FOR v_line IN EXECUTE $q$
        EXPLAIN (COSTS OFF)
        WITH RECURSIVE permission_tree AS (
            SELECT DISTINCT p.id AS permission_id
            FROM users u
            JOIN user_roles ur ON u.id = ur.user_id
            JOIN roles r ON ur.role_id = r.id
            JOIN role_permissions rp ON r.id = rp.role_id
            JOIN permissions p ON rp.permission_id = p.id
            WHERE u.external_id = 'user3' AND u.is_disabled = FALSE
            UNION
            SELECT DISTINCT p.id
            FROM users u
            JOIN user_permissions up ON u.id = up.user_id
            JOIN permissions p ON up.permission_id = p.id
            WHERE u.external_id = 'user3' AND u.is_disabled = FALSE
            UNION
            SELECT DISTINCT ph.included_permission_id
            FROM permission_tree pt
            JOIN permission_hierarchy ph ON pt.permission_id = ph.including_permission_id
        )
        SELECT 1 FROM permission_tree WHERE permission_id = 1
    $q$
    LOOP
        INSERT INTO rbac_walk_plan VALUES (v_line);
    END LOOP;
END
$do$;

SELECT is(
    (SELECT string_agg(btrim(line), '; ' ORDER BY btrim(line))
     FROM rbac_walk_plan
     WHERE line ~ 'Seq Scan on (user_roles|role_permissions|user_permissions)\M'),
    NULL::text,
    'the permission walk reads no junction table sequentially'
);

-- user_permissions holds no row for user3, so its side of the UNION can be
-- planned away; the two role legs are the ones that must stay indexed.
SELECT is(
    (SELECT count(*)::int FROM rbac_walk_plan
     WHERE line ~ '(Scan using|Bitmap Index Scan on) (user_roles_user_id_role_id_key|role_permissions_role_id_permission_id_key)\M'),
    2,
    'user_roles and role_permissions are reached through their composite unique index'
);

SELECT ok(
    EXISTS (SELECT 1 FROM rbac_walk_plan
            WHERE line ~ 'Scan using users_external_id_unique on users'),
    'the subject lookup uses the dictionary partial unique index on external_id'
);

RESET enable_seqscan;

-- =====================================================
-- GROUP 3: what the partial unique index allows
-- =====================================================
INSERT INTO users (external_id, email) VALUES ('', 'blank_a@example.com');
INSERT INTO users (external_id, email) VALUES ('', 'blank_b@example.com');

SELECT is(
    (SELECT count(*)::int FROM users WHERE external_id = ''),
    2,
    'many rows may carry an empty external_id: the unique index excludes it'
);

SELECT throws_ok(
    $$ INSERT INTO users (external_id, email) VALUES ('user3', 'clash@example.com') $$,
    '23505',
    NULL,
    'a non-empty external_id is still unique'
);

-- =====================================================
-- GROUP 4: the upsert still infers its arbiter
-- =====================================================
-- EXECUTE on this function is not granted to the request role - get_userinfo()
-- is the only caller and it is SECURITY DEFINER - so the owner drives it here.
-- What is under test is the ON CONFLICT arbiter, not the privilege.
RESET ROLE;

SELECT is(
    (SELECT rbac.upsert_user_from_jwt('p10_upsert_subject', 'first@example.com')),
    (SELECT rbac.upsert_user_from_jwt('p10_upsert_subject', 'second@example.com')),
    'upsert_user_from_jwt returns the same id for a repeated subject'
);

SELECT is(
    (SELECT count(*)::int FROM users WHERE external_id = 'p10_upsert_subject'),
    1,
    'a repeated subject leaves one user row'
);

SELECT * FROM finish();
ROLLBACK;
