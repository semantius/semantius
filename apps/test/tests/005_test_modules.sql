-- Test module visibility based on view_permission
BEGIN;

SELECT plan(6);

-- Test as user@test.com (has user:read permission)
select authenticate_as('user1', 'user@test.com');

-- user@test.com should see 2 modules (_public and HR)
-- _public has view_permission 'user:read'
-- HR (module 1002) has view_permission 'user:read'
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    2,
    'user@test.com should see 2 modules (_public and HR)'
);

-- Verify the specific modules visible to user@test.com
SELECT bag_eq(
    'SELECT module_name FROM modules ORDER BY module_name',
    $$VALUES ('_public'), ('HR')$$,
    'user@test.com should see _public and HR modules'
);

-- Test as sales@test.com (has user:read and sales:read permissions)
select authenticate_as('user2', 'sales@test.com');

-- sales@test.com should see 3 modules (_public, CRM, and HR)
-- _public has view_permission 'user:read'
-- CRM (module 1001) has view_permission 'sales:read'
-- HR (module 1002) has view_permission 'user:read'
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    3,
    'sales@test.com should see 3 modules (_public, CRM, and HR)'
);

-- Verify the specific modules visible to sales@test.com
SELECT bag_eq(
    'SELECT module_name FROM modules ORDER BY module_name',
    $$VALUES ('_public'), ('CRM'), ('HR')$$,
    'sales@test.com should see _public, CRM, and HR modules'
);

-- Test as admin@test.com (has admin:manage permission)
select authenticate_as('user3', 'admin@test.com');

-- admin@test.com should see 4 modules (_core, _public, HR, and Inventory)
-- _core has view_permission 'admin:manage'
-- _public has view_permission 'user:read'
-- CRM (module 1001) has view_permission 'sales:read' (admin doesn't have this, so won't see it)
-- HR (module 1002) has view_permission 'user:read'
-- Inventory (module 1003) has view_permission 'user:read'
SELECT is(
    (SELECT COUNT(*)::integer FROM modules),
    4,
    'admin@test.com should see 4 modules (_core, _public, HR, and Inventory)'
);

-- Verify the specific modules visible to admin@test.com
SELECT bag_eq(
    'SELECT module_name FROM modules ORDER BY module_name',
    $$VALUES ('_core'), ('_public'), ('HR'), ('Inventory')$$,
    'admin@test.com should see _core, _public, HR, and Inventory modules'
);

SELECT * FROM finish();
ROLLBACK;
