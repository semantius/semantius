-- Test that should fail
BEGIN;

SELECT plan(8);

select authenticate_as('user1');

-- Test rbac.user_id() returns 1001
SELECT is(
    rbac.user_id(),
    1001::integer,
    'rbac.user_id() should return 1001'
);

SELECT hasnt_table(
    'public',  
    'table1',  
    'table1 should not exist in schema public'
);

SELECT throws_ok(
    $$
    CREATE TABLE public.table1();
    $$,
    '42501',  -- insufficient_privilege
    NULL,
    'User should not be allowed to create a table in schema public'
);


SELECT throws_ok(
    $$
    INSERT INTO entities(table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column) 
     VALUES ( 'table1', 'table1', 'table1', 'Table1', 'Table1', 'New test table', 1001, 'public:read', 'sales:manage', 'id', 'label' );
    $$,
    '42501',  -- insufficient_privilege (RLS violation)
    NULL,
    'Insert into entities should fail due to RLS policy'
);


-- admin should be able to create the table and add columns
select authenticate_as('user3');

-- Create "customers" table in CRM module
INSERT INTO entities(table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column) 
     VALUES ( 'table1', 'table1', 'table1', 'Table1', 'Table1', 'New test table', 1001, 'public:read', 'sales:manage', 'id', 'label' );

SELECT has_table(
    'public',  
    'table1',  
    'table1 should exist in schema public'
);


SELECT pgtap.hasnt_column(
    'public',    
    'table1',    
    'field1',     
    'column test1 should not exist in public.table1'
);

select authenticate_as('user1');

SELECT throws_ok(
    $$
        INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
        VALUES ('table1', 'field1', 'Email Address', 'email', FALSE, FALSE, 10, 'default', 'm', 'Customer primary email address');
    $$,
    '42501',  -- insufficient_privilege (RLS violation)
    NULL,
    'Insert into fields should fail due to RLS policy'
);

-- admin should be able to create the table and add columns
select authenticate_as('user3');

INSERT INTO fields(table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description)
VALUES ('table1', 'field1', 'Email Address', 'email', FALSE, FALSE, 10, 'default', 'm', 'Customer primary email address');

SELECT pgtap.has_column(
    'public',    
    'table1',    
    'field1',     
    'column test1 should exist in public.table1'
);






SELECT * FROM finish();
ROLLBACK;