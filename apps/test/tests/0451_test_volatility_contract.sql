-- The volatility contract: which functions may write, and what STABLE costs.
--
-- The permission readers (rbac.uid, user_id, has_permission, has_any_permission,
-- get_current_user_permissions, whoami, public.jl_request_context,
-- is_raci_actor, has_consultation, the generated select_rule_*) are declared
-- STABLE and they write, through rbac.ensure_context_initialized. That is
-- deliberate and the full reasoning sits above rbac.uid() in
-- 0030_rbac_functions.sql. This file pins the two properties that make it safe.
--
-- GROUP 1: every setting written on a read path is transaction-local. A
-- session-scoped write is the one side effect a ROLLBACK cannot undo, so it
-- would survive a transaction that never committed - and, if a planner ever did
-- evaluate the call while estimating, would survive a statement that never ran.
-- The sweep is over function source, because there is no catalog column for
-- "writes a GUC".
--
-- GROUP 2: nothing in the installed schema has the shape the planner folds.
-- estimate_expression_value() executes STABLE calls while estimating
-- selectivity, and the shape that reaches an estimator is
-- `col <op> stable_fn(<const>)`. The first assertion is the property P7 asks
-- for: EXPLAIN of a policy-guarded query in a session with no claims plans
-- without raising. The second is what keeps the first from being vacuous - the
-- same EXPLAIN over the foldable shape DOES raise, because the planner really
-- does run rbac.user_id() there, and rbac.uid() refuses a session with no
-- subject. A WITH CHECK expression is exempt: it is a per-row test applied
-- after the fact, never a scan qual, so no estimator sees it - which is why
-- user_bookmarks_insert_policy may carry `user_id = rbac.user_id()`.
--
-- GROUP 3: the labels themselves. The read-only RPCs are STABLE so PostgREST
-- serves them over GET in a read-only transaction; public.get_userinfo upserts
-- the user row and must stay VOLATILE. None of the readers may be IMMUTABLE:
-- that would let PostgreSQL fold a permission check into a cached plan and
-- reuse one caller's answer for another.
--
-- Fixtures: user3 = Administrator. GROUP 2 drops the JWT claims inside its own
-- transaction, so it must come last among the authenticated groups.
BEGIN;

SELECT plan(8);

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: no session-scoped write on a read path
-- =====================================================
RESET ROLE;

-- set_config's third argument is is_local: true = discarded at end of
-- transaction, false = survives it. Matching on the deparsed body is the only
-- way to see this; [^;] keeps the match inside one PL/pgSQL statement so a
-- later `false` in an unrelated statement cannot be mistaken for this one.
SELECT is(
    (SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('rbac', 'public', 'audit', 'common')
       AND p.prokind = 'f'
       AND pg_get_functiondef(p.oid) ~* 'set_config\s*\([^;]*,\s*false\s*\)'),
    NULL::text,
    'no core function writes a session-scoped setting'
);

-- pgtap.authenticate_as does write session-scoped settings, on purpose: it is
-- setting up a session, not serving a request. Asserting it here says the sweep
-- above is scoped rather than blind.
SELECT ok(
    pg_get_functiondef('pgtap.authenticate_as(text)'::regprocedure)
        ~* 'set_config\s*\([^;]*,\s*false\s*\)',
    'the test harness authenticate_as does write session-scoped settings, deliberately'
);

-- =====================================================
-- GROUP 3: the volatility labels
-- =====================================================
SELECT is(
    (SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.provolatile <> 's'
       AND ((n.nspname = 'public' AND p.proname IN
                ('get_schema', 'get_schemas', 'get_user_cubes', 'get_module_cubes',
                 'get_user_modules', 'list_api_keys'))
         OR (n.nspname = 'rbac' AND p.proname IN
                ('require_permission', 'require_any_permission', 'get_user_permissions')))),
    NULL::text,
    'the read-only RPCs are STABLE, so PostgREST serves them over GET'
);

SELECT is(
    (SELECT p.provolatile FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'get_userinfo'),
    'v'::"char",
    'get_userinfo stays VOLATILE: it upserts the user row'
);

SELECT is(
    (SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.provolatile = 'i'
       AND ((n.nspname = 'rbac' AND p.proname IN
                ('uid', 'user_id', 'user_id_or_null', 'has_permission', 'has_any_permission',
                 'user_has_permission', 'get_current_user_permissions', 'whoami'))
         OR (n.nspname = 'public' AND p.proname IN
                ('jl_request_context', 'is_raci_actor', 'has_consultation', 'has_permission')))),
    NULL::text,
    'no permission reader is IMMUTABLE'
);

-- =====================================================
-- GROUP 2: what the planner does and does not evaluate
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, audit_log)
VALUES ('p7_fold', 'p7_fold_item', 'P7 Fold', 'P7 Folds', 'plan-time folding probe',
    1, 'public:read', 'admin', 'id', 'label', FALSE);
INSERT INTO p7_fold (label) VALUES ('a'), ('b'), ('c');

-- No policy in the catalog compares a column against a bare permission reader
-- in a USING clause, which is where an estimator would reach it.
SELECT is(
    (SELECT string_agg(schemaname || '.' || tablename || '.' || policyname, ', '
                       ORDER BY schemaname, tablename, policyname)
     FROM pg_policies
     WHERE qual ~ 'rbac\.(uid|user_id|user_id_or_null)\('),
    NULL::text,
    'no policy USING clause calls a subject reader next to a column'
);

-- Drop the claims. Anything the planner executes from here on must raise.
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_external_id', '', true);

SELECT lives_ok(
    $$ EXPLAIN (COSTS OFF) SELECT * FROM p7_fold $$,
    'a policy-guarded query plans without claims: the permission check is not evaluated at plan time'
);

SELECT throws_ok(
    $$ EXPLAIN (COSTS OFF) SELECT * FROM p7_fold WHERE id = rbac.user_id() $$,
    '42501',
    NULL,
    'the foldable shape IS evaluated at plan time, so the assertion above is not vacuous'
);

SELECT * FROM finish();
ROLLBACK;
