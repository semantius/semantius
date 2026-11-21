-- The RBAC index set: what must not come back, and what must keep working.
--
-- Every table 0060_rbac_schema.once.sql creates already carries a unique index over
-- the columns its lookups filter on - either as the whole key (module_name,
-- permission_name, role_name, roles.slug) or as the leading columns of a
-- composite one (the four junction tables). A second plain index over the same
-- leading columns cannot be the only thing that answers a query, so the planner
-- reaches the unique index instead, and the duplicate is pure write cost.
--
-- GROUP 1 sweeps the catalog for that shape rather than naming index names, so
-- it fails when a duplicate is added under any name. GROUP 2 is the half
-- a name sweep cannot prove: that the composite can resolve the
-- recursive permission walk through an index; GROUP 2b, that every rbac lookup
-- by external_id reaches its index in a plan made for any external_id as well
-- as in one made for a known value. Both run with enable_seqscan off,
-- because these tables hold a handful of rows and the planner is right to scan
-- them sequentially - asserting a plan shape without that would be asserting
-- whatever ANALYZE last saw.
--
-- GROUP 3 states the identity rule on users.external_id, which is a
-- data-integrity rule rather than an index detail: the only unique index on
-- that column is the dictionary's partial one, which excludes the empty
-- string, so the table refuses the empty string outright
-- (users_external_id_not_empty, 0060_rbac_schema.once.sql). A user must
-- bring an identity - the provider's sub - and is refused without one; an
-- agent (is_agent) saved without one gets agent:<uuid> from the
-- assign_agent_external_id trigger (0370_raci.sql).
-- Together these make the partial index total in effect and leave no row that
-- no session could act as. Asserted here so that weakening any of it is a
-- visible decision.
--
-- GROUP 4 is the regression that would otherwise reach production as a failed
-- login. A bare ON CONFLICT (external_id) cannot infer a partial index, so the
-- upsert sites repeat the index predicate; if one of them loses it, the second
-- call for the same subject raises instead of updating.
--
-- Fixtures: user3 = Administrator (users carries RLS requiring user:manage for
-- writes, plus audit triggers). The catalog sweep runs as the owner.
BEGIN;

SELECT plan(19);

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
       AND indexname IN ('modules_module_name_key', 'permissions_pkey',
                         'roles_role_name_key', 'roles_slug_key',
                         'users_external_id_unique',
                         'user_roles_user_id_role_id_key',
                         'role_permissions_role_id_permission_name_key',
                         'user_permissions_user_id_permission_name_key',
                         'permission_hierarchy_including_permission_name_included_per_key')),
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
            SELECT DISTINCT rp.permission_name
            FROM users u
            JOIN user_roles ur ON u.id = ur.user_id
            JOIN roles r ON ur.role_id = r.id
            JOIN role_permissions rp ON r.id = rp.role_id
            WHERE u.external_id = 'user3' AND u.external_id <> '' AND u.is_disabled = FALSE
            UNION
            SELECT DISTINCT up.permission_name
            FROM users u
            JOIN user_permissions up ON u.id = up.user_id
            WHERE u.external_id = 'user3' AND u.external_id <> '' AND u.is_disabled = FALSE
            UNION
            SELECT DISTINCT ph.included_permission_name
            FROM permission_tree pt
            JOIN permission_hierarchy ph ON pt.permission_name = ph.including_permission_name
        )
        SELECT 1 FROM permission_tree WHERE permission_name = 'admin'
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
     WHERE line ~ '(Scan using|Bitmap Index Scan on) (user_roles_user_id_role_id_key|role_permissions_role_id_permission_name_key)\M'),
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
-- GROUP 2b: every lookup by external_id reaches its index in a generic plan
-- =====================================================
-- The rbac functions are PL/pgSQL, so PostgreSQL may plan a statement once for
-- any value and reuse that plan. users_external_id_unique leaves out the empty
-- string, and a plan made for a parameter can use it only because every lookup
-- by external_id in 0080_rbac_functions.sql repeats external_id <> ''; without
-- that condition the lookup reads every enabled user through idx_users_enabled
-- instead. plan_cache_mode forces the generic plan from the first call,
-- enable_seqscan = off keeps the planner from preferring a scan of these few
-- rows, and the index's scan counter for this transaction shows whether a call
-- went through it. The context is warmed first, so that only the function's
-- own lookup can move the counter; ensure_context_initialized is measured on
-- its cold path.
CREATE FUNCTION pg_temp.external_id_scans() RETURNS bigint LANGUAGE sql AS
$$ SELECT pg_stat_get_xact_numscans('public.users_external_id_unique'::regclass) $$;

CREATE FUNCTION pg_temp.uses_external_id_index(p_call text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_before bigint := pg_temp.external_id_scans();
BEGIN
    EXECUTE p_call;
    RETURN pg_temp.external_id_scans() > v_before;
END $$;

SET LOCAL plan_cache_mode = force_generic_plan;
SET LOCAL enable_seqscan = off;
SELECT rbac.ensure_context_initialized();

SELECT ok(pg_temp.uses_external_id_index($$SELECT rbac.get_user_by_external_id('user3')$$),
    'rbac.get_user_by_external_id: a generic plan reaches the user through users_external_id_unique');
SELECT ok(pg_temp.uses_external_id_index($$SELECT rbac.user_has_permission('user3', 'admin')$$),
    'rbac.user_has_permission: a generic plan reaches the user through users_external_id_unique');
SELECT ok(pg_temp.uses_external_id_index($$SELECT * FROM rbac.get_user_permissions('user3')$$),
    'rbac.get_user_permissions: a generic plan reaches the user through users_external_id_unique');

SELECT set_config('app.context_initialized', 'false', true);
SELECT ok(pg_temp.uses_external_id_index($$SELECT rbac.ensure_context_initialized()$$),
    'rbac.ensure_context_initialized: a generic plan reaches the user through users_external_id_unique');

-- EXECUTE on upsert_user_from_jwt is not granted to the request role (see
-- GROUP 4), so the owner drives it.
RESET ROLE;
SELECT ok(pg_temp.uses_external_id_index($$SELECT rbac.upsert_user_from_jwt('user3', NULL)$$),
    'rbac.upsert_user_from_jwt: a generic plan reaches the user through users_external_id_unique');

RESET plan_cache_mode;
RESET enable_seqscan;
SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 3: a user must bring an identity, an agent is given one
-- =====================================================
SELECT throws_ok(
    $$ INSERT INTO users (external_id, email) VALUES ('', 'blank@example.com') $$,
    '23514',
    NULL,
    'a user with an empty external_id is refused'
);

SELECT throws_ok(
    $$ INSERT INTO users (email) VALUES ('nobody@example.com') $$,
    '23502',
    NULL,
    'a user without an external_id is refused: nothing generates one'
);

SELECT throws_ok(
    $$ UPDATE users SET external_id = '' WHERE external_id = 'user1' $$,
    '23514',
    NULL,
    'an existing identity cannot be blanked'
);

INSERT INTO users (email, is_agent) VALUES ('agent_a@example.com', TRUE), ('agent_b@example.com', TRUE);
INSERT INTO users (external_id, email, is_agent) VALUES ('', 'agent_c@example.com', TRUE);
INSERT INTO users (external_id, email, is_agent) VALUES ('bot-7', 'agent_d@example.com', TRUE);

SELECT is(
    (SELECT count(*)::int FROM users
     WHERE email IN ('agent_a@example.com', 'agent_b@example.com', 'agent_c@example.com')
       AND external_id ~ '^agent:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    3,
    'an agent saved without an external_id, or with an empty one, gets agent:<uuid>'
);

SELECT is(
    (SELECT count(DISTINCT external_id)::int FROM users
     WHERE email IN ('agent_a@example.com', 'agent_b@example.com', 'agent_c@example.com')),
    3,
    'generated agent identities differ'
);

SELECT is(
    (SELECT external_id FROM users WHERE email = 'agent_d@example.com'),
    'bot-7',
    'an agent saved with an external_id keeps it'
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
