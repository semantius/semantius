-- Test (CATALOG GUARD): I-roles hygiene, enforced against the live catalog (a sibling to
-- 0240_test_no_unsafe_functions). Unlike a behavioral test this asserts a structural property
-- of every policy/view that exists after all migrations + DD bootstrap have run, so it also
-- catches policies/views created DYNAMICALLY by the DD functions (build_select_rule_policy,
-- create_dd_table, ...), not just the ones authored literally in the migrations.
--
-- spec v2 I-roles: policies are authored ONLY `TO semantius_user` (never `TO authenticated`
-- / `TO public`); the request role is a non-owner, non-BYPASSRLS INHERIT member of
-- semantius_user. Every public view is `security_invoker = true` so it cannot launder a read
-- past RLS as its (BYPASSRLS) owner — this is the structural backstop for the b4 fix
-- (user_process_raci), generalized to ALL views so a future view can't silently reintroduce
-- the leak.
--
-- EXPECTED: green on current code (b4 set user_process_raci security_invoker; the compat
-- `tables` view already had it). It goes red the moment any public policy is authored to a
-- role other than semantius_user, or any public view is created without security_invoker.
BEGIN;

SELECT plan(2);

-- =====================================================
-- I-roles, part 1: no public-schema RLS policy targets a role other than semantius_user.
-- pg_policies.roles is a name[]; a `TO public` policy shows as {public}, a `TO authenticated`
-- policy as {authenticated}. The sole permitted value is exactly {semantius_user}.
-- =====================================================
SELECT is_empty(
    $$SELECT
        jsonb_build_object(
            'schema', schemaname,
            'table', tablename,
            'policy', policyname,
            'roles', roles
        ) AS metadata
    FROM pg_policies
    WHERE schemaname = 'public'
      AND roles IS DISTINCT FROM ARRAY['semantius_user']::name[]$$,
    'every public RLS policy must target exactly TO semantius_user (never authenticated/public)'
);

-- =====================================================
-- I-roles, part 2: every public-schema view runs with security_invoker = true, so it applies
-- the invoking user's RLS instead of laundering reads as its BYPASSRLS owner.
-- =====================================================
SELECT is_empty(
    $$SELECT
        jsonb_build_object(
            'schema', n.nspname,
            'view', c.relname,
            'reloptions', c.reloptions
        ) AS metadata
    FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND NOT EXISTS (
          SELECT 1
          FROM unnest(coalesce(c.reloptions, '{}')) AS opt
          WHERE opt ~* '^security_invoker=(true|on)$'
      )$$,
    'every public view must be security_invoker=true (no definer-owner read laundering)'
);

SELECT * FROM finish();
ROLLBACK;
