-- Test module visibility based on view_permission
BEGIN;

SELECT plan(2);

-- Test as user@test.com (has user:read permission)
select authenticate_as('user1', 'user@test.com');

-- user@test.com should see 3 modules (_public, HR, and Inventory)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    3,
    'user@test.com should see 3 modules (_public, HR, and Inventory)'
);

-- Test as sales@test.com (has user:read and sales:read permissions)
select authenticate_as('user2', 'sales@test.com');

-- sales@test.com should see 4 modules (_public, CRM, HR, and Inventory)
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    4,
    'sales@test.com should see 4 modules (_public, CRM, HR, and Inventory)'
);



SELECT * FROM finish();
ROLLBACK;
