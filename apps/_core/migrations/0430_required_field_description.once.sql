-- =====================================================
-- fields.input_type: 'required' is enforced by the database
-- =====================================================
-- The fields rows of the bootstrap tables are seeded in 0150_dd_bootstrap.once.sql,
-- which never runs again on a database that already has it, so a changed description
-- reaches both fresh installs and upgrades from here.
UPDATE fields
   SET description = 'How the UI presents the field for input; input_type_rule can override it per record. On a required field with no input_type_rule, the database also refuses a missing value.'
 WHERE table_name = 'fields' AND field_name = 'input_type';
