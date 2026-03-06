-- Test module visibility based on view_permission
BEGIN;

SELECT plan(3);

-- Test as user@test.com (has user:read permission)
select authenticate_as('user1');

-- user@test.com should see 3 modules (_public, HR, and Inventory)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    3,
    'user@test.com should see 3 modules (_public, HR, and Inventory)'
);

-- Test as sales@test.com (has user:read and sales:read permissions)
select authenticate_as('user2');

-- sales@test.com should see 4 modules (_public, CRM, HR, and Inventory)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    4,
    'sales@test.com should see 4 modules (_public, CRM, HR, and Inventory)'
);

-- Test as admin@test.com (has user:read permission)
select authenticate_as('user3');

-- admin@test.com should see all 6 modules (_public, _core, CRM, HR, Inventory, and nwind)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    6,
    'admin@test.com should see all 6 modules (_public, _core, CRM, HR, Inventory, and nwind)'
);

SELECT * FROM finish();
ROLLBACK;
