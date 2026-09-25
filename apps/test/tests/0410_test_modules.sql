-- Test module visibility based on view_permission
--
-- Ladder (lowest to highest rung):
--   * 'Ladder Public' (in-tx, view_permission 'public:read')  -> every user
--   * 'Ladder Users'  (in-tx, view_permission 'user:read')    -> every user (User role)
--   * 'Northwind'     (persisted, view_permission 'nwind:view') -> user2, user3
--   * '_core'         (persisted, view_permission 'admin')      -> user3 only
-- The two ladder modules are inserted as user3 and rolled back with the tx.
BEGIN;

SELECT plan(6);

SELECT authenticate_as('user3');

INSERT INTO modules (module_name, module_slug, description, view_permission) VALUES
    ('Ladder Users',  'ladder_users',  'in-tx ladder rung', 'user:read'),
    ('Ladder Public', 'ladder_public', 'in-tx ladder rung', 'public:read');

-- Test as user@test.com (has public:read and user:read permissions)
select authenticate_as('user1');

-- user1 should see both ladder modules (ignoring any additional modules)
SELECT is(
    (SELECT array_agg(module_slug ORDER BY module_slug) FROM modules WHERE module_slug IN ('ladder_users', 'ladder_public')),
    ARRAY['ladder_public', 'ladder_users'],
    'user@test.com should see the ladder_users and ladder_public modules'
);

-- user1 should NOT see _core (requires admin permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_slug = 'admin'),
    0,
    'user@test.com should NOT see _core module (requires admin permission)'
);

-- user1 should NOT see Northwind (requires nwind:view permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_slug = 'nwind'),
    0,
    'user@test.com should NOT see Northwind module (requires nwind:view permission)'
);

-- Test as sales@test.com (has user:read and nwind:view permissions)
select authenticate_as('user2');

-- user2 should see the ladder modules and Northwind (ignoring any additional modules)
SELECT is(
    (SELECT array_agg(module_slug ORDER BY module_slug) FROM modules WHERE module_slug IN ('ladder_users', 'ladder_public', 'nwind')),
    ARRAY['ladder_public', 'ladder_users', 'nwind'],
    'sales@test.com should see the ladder modules and the Northwind module'
);

-- user2 should NOT see _core (requires admin permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_slug = 'admin'),
    0,
    'sales@test.com should NOT see _core module (requires admin permission)'
);

-- Test as admin@test.com (has admin permission)
select authenticate_as('user3');

-- admin should see every rung (ignoring any additional modules)
SELECT is(
    (SELECT array_agg(module_slug ORDER BY module_slug) FROM modules WHERE module_slug IN ('admin', 'ladder_users', 'ladder_public', 'nwind')),
    ARRAY['admin', 'ladder_public', 'ladder_users', 'nwind'],
    'admin@test.com should see _core, Northwind and both ladder modules'
);

SELECT * FROM finish();
ROLLBACK;
