-- Test public.jl_request_context() and the two-overload select_rule predicate.
--
-- jl_request_context() supplies the statement-constant half of the JsonLogic
-- data ($today, $now, $user_id) so the policies can resolve it once per
-- statement instead of once per scanned row; a predicate whose rule reads
-- $role_ids adds the caller's roles to it, once per statement as well. Moving that resolution out of the
-- per-row predicate moved the authentication gate with it: the select_rule
-- branch of a SELECT policy carries no permission conjunct, and the generated
-- predicate swallows every error raised while evaluating a rule, so this
-- function is the only thing that refuses a session with no valid claims on
-- that path. The refusal is asserted here twice - directly on the function, and
-- end to end through a policy - because a helper that stops raising fails
-- silently everywhere else.
--
-- The end-to-end assertion needs a rule-bearing table that actually holds a
-- row. A policy qual is only reached when there is a row to filter, so on an
-- empty table nothing evaluates and nothing raises, whatever the gate does.
-- The fixture below is built before the session drops its claims.
--
-- The predicate exists in two overloads. The two-argument form takes the
-- context as a parameter and is what the policies call; the one-argument form
-- resolves the context itself and is what callers outside a policy use,
-- get_record_by_id among them. Both are asserted, and so is the fact that a
-- rebuild drops both: a DROP that names only one signature is a silent no-op,
-- and the survivor then blocks the next CREATE.
--
-- Fixtures: user3 = Administrator.
BEGIN;

SELECT plan(19);

-- =====================================================
-- Fixture: a rule-bearing entity holding one row
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, select_rule)
VALUES ('ctx_gate', 'ctx_gate_item', 'Ctx Gate', 'Ctx Gates',
    'request context gate probe', 1, 'public:read', 'admin', 'id', 'label',
    '{"!=":[{"var":"label"},""]}'::jsonb);

INSERT INTO ctx_gate (label) VALUES ('gate row');

-- A rule that reads $role_ids: a row is seen by the members of its role.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('ctx_roles', 'Ctx Role Row', 'Ctx Role Rows', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format) VALUES ('ctx_roles', 'role_id', 'Role', 'int64');
UPDATE entities SET select_rule = '{"in": [{"var": "role_id"}, {"var": "$role_ids"}]}'::jsonb
 WHERE table_name = 'ctx_roles';
INSERT INTO ctx_roles (label, role_id)
SELECT 'mine', min(ur.role_id) FROM user_roles ur JOIN users u ON u.id = ur.user_id WHERE u.external_id = 'user3'
UNION ALL
SELECT 'nobody''s', 0;

-- A computed field that reads $role_ids, saved later over a record there is.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('ctx_backfill', 'Ctx Backfill', 'Ctx Backfills', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format) VALUES ('ctx_backfill', 'first_role', 'First role', 'int64');
INSERT INTO ctx_backfill (label) VALUES ('before the rule');

-- =====================================================
-- GROUP 1: the authentication gate
-- =====================================================
-- No claims are set, so this is an unauthenticated session.
SET ROLE semantius_user;

SELECT throws_ok(
    $$ SELECT public.jl_request_context() $$,
    '42501', NULL,
    'unauth: jl_request_context() raises rather than returning a context'
);

-- The gate has to hold through the policy, not only on the function. A rule
-- branch policy has no permission conjunct of its own, so if the context stops
-- raising this SELECT starts returning rows.
SELECT throws_ok(
    $$ SELECT count(*) FROM public.ctx_gate $$,
    '42501', NULL,
    'unauth: a SELECT on a rule-bearing table raises, not silently empty'
);

-- An unknown subject is a different refusal: the claims are well formed but no
-- users row matches. It is still 42501 on the wire, so PostgREST keeps
-- answering 403, and hint.code is what separates it: 90006, not 90001.
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'no-such-subject', true);

SELECT throws_ok(
    $$ SELECT public.jl_request_context() $$,
    '42501', NULL,
    'unknown subject: jl_request_context() raises rather than returning a null user'
);

SELECT throws_ok(
    $$ SELECT count(*) FROM public.ctx_gate $$,
    '42501', NULL,
    'unknown subject: a SELECT on a rule-bearing table raises'
);

RESET ROLE;

-- =====================================================
-- GROUP 2: the context contents
-- =====================================================
SELECT authenticate_as('user3');

SELECT is(
    (SELECT public.jl_request_context() ? '$today'
        AND public.jl_request_context() ? '$now'
        AND public.jl_request_context() ? '$user_id'),
    TRUE,
    'authenticated: the context carries $today, $now and $user_id'
);

SELECT is(
    (SELECT (public.jl_request_context() ->> '$user_id')::bigint),
    (SELECT rbac.user_id()),
    'authenticated: $user_id is the internal user id, not the JWT subject'
);

-- $user_id is a JSON number for a resolved user. The null arm is unreachable
-- while the gate holds - an unresolved caller raises before reaching it - so
-- this pins the authenticated shape only. jsonb null rather than SQL NULL
-- matters there because a SQL NULL would make the whole || merge in the
-- predicate NULL and silently empty the rule data.
SELECT is(
    (SELECT jsonb_typeof(public.jl_request_context() -> '$user_id')),
    'number',
    'authenticated: $user_id is a JSON number'
);

-- $role_ids reads user_roles, so it is not part of the context every policy
-- reads: only the predicate of a rule that reads it adds it.
SELECT ok(NOT (public.jl_request_context() ? '$role_ids'),
    'authenticated: $role_ids is not part of the context every policy reads');
SELECT is((SELECT string_agg(label, ', ') FROM public.ctx_roles), 'mine',
    'authenticated: a select_rule that reads $role_ids sees the caller''s roles');

UPDATE entities SET computed_fields = '[{"name": "first_role", "jsonlogic": {"var": "$role_ids.0"}}]'::jsonb
 WHERE table_name = 'ctx_backfill';
SELECT is((SELECT first_role FROM public.ctx_backfill), (rbac.user_role_ids())[1],
    'authenticated: a computed field that reads $role_ids is applied to the records there are with the roles of whoever saves it');

SELECT is(
    (SELECT count(*)::int FROM public.ctx_gate),
    1,
    'authenticated: the rule-bearing table is readable'
);

-- =====================================================
-- GROUP 3: both overloads exist and both are locked down
-- =====================================================
SELECT is(
    (SELECT count(*)::int
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'select_rule_ctx_gate'),
    2,
    'select_rule_ctx_gate exists in both the one- and two-argument forms'
);

SELECT is(
    (SELECT count(*)::int
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'select_rule_ctx_gate'
       AND p.proacl IS NOT NULL
       AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
       AND has_function_privilege('semantius_user', p.oid, 'EXECUTE')),
    2,
    'both overloads revoke PUBLIC and grant semantius_user'
);

SELECT is(
    (SELECT count(*)::int
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'select_rule_ctx_gate'
       AND obj_description(p.oid, 'pg_proc') IS NOT NULL),
    2,
    'both overloads carry a comment'
);

-- The one-argument form is the entry point for callers outside a policy, and
-- get_record_by_id is the one that ships.
SELECT isnt(
    (SELECT public.get_record_by_id('ctx_gate', (SELECT id FROM public.ctx_gate LIMIT 1))),
    NULL,
    'get_record_by_id still resolves on a rule-bearing entity'
);

-- =====================================================
-- GROUP 4: a rebuild drops both signatures
-- =====================================================
-- Two successive rule edits. If the rebuild dropped only one signature the
-- second CREATE would raise 42723 (duplicate function).
UPDATE entities SET select_rule = '{"!=":[{"var":"label"},"a"]}'::jsonb
WHERE table_name = 'ctx_gate';

UPDATE entities SET select_rule = '{"!=":[{"var":"label"},"b"]}'::jsonb
WHERE table_name = 'ctx_gate';

SELECT is(
    (SELECT count(*)::int
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'select_rule_ctx_gate'),
    2,
    'after two rule rebuilds there are still exactly two overloads'
);

-- =====================================================
-- GROUP 5: rename carries both signatures and all three policies
-- =====================================================
UPDATE entities SET table_name = 'ctx_gate_renamed' WHERE table_name = 'ctx_gate';

SELECT is(
    (SELECT count(*)::int
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'select_rule_ctx_gate_renamed'),
    2,
    'rename: both overloads are rebuilt under the new name'
);

-- An exact count, not an existence test: the rename path drops the functions by
-- their old name and lets the rebuild recreate the policies, so a policy left
-- behind under the old name would sit alongside the new one and widen access.
SELECT is(
    (SELECT count(*)::int FROM pg_policies WHERE tablename = 'ctx_gate_renamed'),
    4,
    'rename: exactly the four policies exist, none stranded from the old name'
);

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'ctx_gate_renamed'
       AND qual ~ 'SELECT \(*jl_request_context\('),
    3,
    'rename: the three rule-bearing policies resolve the context through a sub-select'
);

SELECT * FROM finish();
ROLLBACK;
