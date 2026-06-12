-- Test (RED-FIRST): the user_process_raci view must not leak the RBAC/RACI graph to non-admins.
--
-- The view (0210_raci.sql:329) is created WITHOUT security_invoker, so it executes as its
-- owner (the BYPASSRLS migration role) and bypasses the admin-gated RLS on user_roles /
-- raci_assignments / processes. It is GRANTed to semantius_user, so any authenticated user
-- reads the entire user→role→raci→process graph. (spec v2 I-roles; fix = security_invoker=true.)
--
-- EXPECTED ON CURRENT main: the leak assertion FAILS (user1 sees user3's Administrator
-- assignment through the view). After the fix it goes green.
--
-- Fixtures: user1=1001 (User role only), user3=1003 (Administrator).
BEGIN;

SELECT plan(3);

-- =====================================================
-- SETUP (admin): one RACI assignment for the Administrator role (held by user3, NOT user1).
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO processes (name, process_key) VALUES ('Leak Test Process', 'leak_test_proc');

INSERT INTO raci_assignments (process_id, role_id, raci)
VALUES (
    (SELECT id FROM processes WHERE process_key = 'leak_test_proc'),
    (SELECT id FROM roles WHERE role_name = 'Administrator'),
    'accountable'
);

-- setup valid: admin sees the seeded assignment via the view
SELECT is(
    (SELECT count(*)::int FROM user_process_raci WHERE process_key = 'leak_test_proc'),
    1,
    'setup: admin sees the seeded RACI assignment through the view'
);

-- =====================================================
-- As user1 (non-admin, holds only the User role).
-- =====================================================
SELECT authenticate_as('user1');

-- sanity: the base raci_assignments table is correctly admin-gated (user1 sees none)
SELECT is(
    (SELECT count(*)::int FROM raci_assignments),
    0,
    'sanity: user1 cannot read the admin-gated raci_assignments table directly'
);

-- the leak: user1 must NOT read the RACI graph via the definer view
SELECT is(
    (SELECT count(*)::int FROM user_process_raci WHERE process_key = 'leak_test_proc'),
    0,
    'user_process_raci view must NOT leak RACI assignments to a non-admin (needs security_invoker)'
);

SELECT * FROM finish();
ROLLBACK;
