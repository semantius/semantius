-- Test module visibility based on view_permission
BEGIN;

SELECT plan(6);

-- Test as user@test.com (has user:read permission)
select authenticate_as('user1');

-- user1 should see the _public, HR, and Inventory modules (ignoring any additional modules)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name IN ('_public', 'HR', 'Inventory')),
    3,
    'user@test.com should see _public, HR, and Inventory modules'
);

-- user1 should NOT see _core (requires admin permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name = '_core'),
    0,
    'user@test.com should NOT see _core module (requires admin permission)'
);

-- user1 should NOT see CRM (requires sales:read permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name = 'CRM'),
    0,
    'user@test.com should NOT see CRM module (requires sales:read permission)'
);

-- Test as sales@test.com (has user:read and sales:read permissions)
select authenticate_as('user2');

-- user2 should see the _public, CRM, HR, and Inventory modules (ignoring any additional modules)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name IN ('_public', 'CRM', 'HR', 'Inventory')),
    4,
    'sales@test.com should see _public, CRM, HR, and Inventory modules'
);

-- user2 should NOT see _core (requires admin permission)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name = '_core'),
    0,
    'sales@test.com should NOT see _core module (requires admin permission)'
);

-- Test as admin@test.com (has admin permission)
select authenticate_as('user3');

-- admin should see at least _public, _core, CRM, HR, and Inventory modules (ignoring any additional modules)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name IN ('_public', '_core', 'CRM', 'HR', 'Inventory')),
    5,
    'admin@test.com should see _public, _core, CRM, HR, and Inventory modules'
);

SELECT * FROM finish();
ROLLBACK;
