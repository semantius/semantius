-- Test that should fail
BEGIN;

SELECT plan(16);

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

-- Create "customers_test" table in CRM module
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
        INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description)
        VALUES ('table1', 'field1', 'Email Address', 'email', FALSE, 10, 'default', 'default', 'Customer primary email address');
    $$,
    '42501',  -- insufficient_privilege (RLS violation)
    NULL,
    'Insert into fields should fail due to RLS policy'
);

-- admin should be able to create the table and add columns
select authenticate_as('user3');

INSERT INTO fields(table_name, field_name, title, format, is_pk, field_order, input_type, width, description)
VALUES ('table1', 'field1', 'Email Address', 'email', FALSE, 10, 'default', 'default', 'Customer primary email address');

SELECT pgtap.has_column(
    'public',
    'table1',
    'field1',
    'column test1 should exist in public.table1'
);

-- CREATE sets the table comment to "<plural_label>" + blank line + description
SELECT is(
    obj_description('public.table1'::regclass),
    E'Table1\n\nNew test table',
    'CREATE sets COMMENT ON TABLE to plural label + blank line + description'
);

-- CREATE sets the column comment to "<title> (<format>)" + blank line + description
SELECT is(
    col_description(
        'public.table1'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'public.table1'::regclass AND attname = 'field1')
    ),
    E'Email Address (email)\n\nCustomer primary email address',
    'CREATE sets COMMENT ON COLUMN to "title (format)" + blank line + description'
);

-- UPDATE re-syncs the column comment when title/description change
UPDATE fields SET title = 'Primary Email', description = 'Updated field description'
WHERE table_name = 'table1' AND field_name = 'field1';

SELECT is(
    col_description(
        'public.table1'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'public.table1'::regclass AND attname = 'field1')
    ),
    E'Primary Email (email)\n\nUpdated field description',
    'UPDATE re-syncs COMMENT ON COLUMN when title/description change'
);

-- Test that permissions.module_id cannot be NULL
SELECT throws_ok(
    $$
        INSERT INTO permissions(permission_name, description, module_id)
        VALUES ('test:null_module', 'Should fail', NULL);
    $$,
    '23502',  -- not_null_violation
    NULL,
    'Inserting a permission with NULL module_id should fail'
);

-- Test that entities.module_id cannot be NULL
SELECT throws_ok(
    $$
        INSERT INTO entities(table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
        VALUES ('null_module_tbl', 'null_module_tbl', 'null_module_tbl', 'Null Module Table', 'Null Module Tables', '', NULL, 'public:read', 'admin', 'id', 'label');
    $$,
    '23502',  -- not_null_violation
    NULL,
    'Inserting an entity with NULL module_id should fail'
);






-- The entities/fields catalog tables' own COMMENT must match what the DDL trigger
-- would regenerate from their entity row (plural_label + blank line + description),
-- so the hand-authored bootstrap comment never diverges from the row data.
SELECT is(
    obj_description('public.entities'::regclass),
    (SELECT plural_label || E'\n\n' || description FROM entities WHERE table_name = 'entities'),
    'entities table comment = plural label + description of its own catalog row (no divergence)'
);

SELECT is(
    obj_description('public.fields'::regclass),
    (SELECT plural_label || E'\n\n' || description FROM entities WHERE table_name = 'fields'),
    'fields table comment = plural label + description of its own catalog row (no divergence)'
);

SELECT is(
    obj_description('public.modules'::regclass),
    (SELECT plural_label || E'\n\n' || description FROM entities WHERE table_name = 'modules'),
    'modules table comment = plural label + description of its own catalog row (no divergence)'
);

SELECT * FROM finish();
ROLLBACK;