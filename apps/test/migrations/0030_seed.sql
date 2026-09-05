-- =====================================================
-- TEST IDENTITIES
-- =====================================================
-- This seed holds ONLY the identities the pgTAP suite authenticates as.
-- All persisted sample data (entities, rows, roles, permissions, webhook
-- receivers, dashboards, ...) lives in the Northwind module: apps/nwind.
-- Tests that need other fixtures create them inside their own transaction.
--
-- Requires apps/nwind to be migrated first:
--   deno task migrate --apps _core,nwind,test
-- =====================================================

-- Test users with fixed ids. user1 and user2 hold only the User role (role 1),
-- assigned by the trigger in 0050; user3 is the administrator.
--
-- user3's last_seen is set because the suite reads it, not to trigger anything:
-- the first-user bootstrap would elect user3 here (it is inserted last, with a
-- last_seen, and no role-2 row exists yet), but the identity does not lean on
-- that. The Administrator row is written explicitly below. A seed that gets its
-- administrator from a security trigger turns every change to that trigger into
-- an unexplained failure three files away, and 0110_test_first_user_get_userinfo
-- deletes role-2 rows to test the trigger properly.
INSERT INTO users (id, external_id, email, display_name, first_name, last_name, last_seen) VALUES
    (1001, 'user1', 'user@test.com',  'Test User',    'Test',  'User',   NULL),
    (1002, 'user2', 'sales@test.com', 'Sales Person', 'Sales', 'Person', NULL),
    (1003, 'user3', 'admin@test.com', 'Admin Boss',   'Admin', 'Boss',   '2026-01-01 12:34:00'::timestamptz);

INSERT INTO user_roles (user_id, role_id) VALUES (1003, 2)
ON CONFLICT (user_id, role_id) DO NOTHING;

-- Adjust the sequence counter so future auto-generated ids do not collide
SELECT setval('users_id_seq', (SELECT MAX(id) FROM users), true);

-- user2 is a member of the Northwind Sales role (nwind:view + nwind:manage),
-- i.e. the non-admin user that can read and write Northwind data.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM roles WHERE slug = 'northwind_sales') THEN
        RAISE EXCEPTION 'Role northwind_sales not found: migrate the nwind module before test (deno task migrate --apps _core,nwind,test)';
    END IF;
END $$;

INSERT INTO user_roles (user_id, role_id)
SELECT 1002, r.id FROM roles r WHERE r.slug = 'northwind_sales';

-- =====================================================
-- API KEYS (UAT)
-- =====================================================
-- Known API key for user 1002 (user2 / sales@test.com):
--   sk-seed001002-ab12cd340123456789abcdef01234567
INSERT INTO _apikeys (user_id, key_id, secret_hash, description)
VALUES (1002, 'sk-seed001002', crypt('ab12cd340123456789abcdef01234567', gen_salt('bf', 10)), 'Test key');

-- Known API key for user 1003 (user3 / admin@test.com):
--   sk-seed001003-ad22cd340123456789abcdef01234567
INSERT INTO _apikeys (user_id, key_id, secret_hash, description)
VALUES (1003, 'sk-seed001003', crypt('ad22cd340123456789abcdef01234567', gen_salt('bf', 10)), 'Test key');
