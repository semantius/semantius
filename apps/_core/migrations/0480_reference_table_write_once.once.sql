-- =====================================================
-- fields.reference_table: set when the field is created
-- =====================================================
-- update_dd_field refuses a change of reference_table (90289): the stored
-- values of the column are keys of the referenced entity, and re-pointed they
-- would reference other records. The form asks for it while the field is being
-- created and shows it readonly afterward, as it does entities.id_refentity:
-- created_at is set by the database, so a field being created has none.
--
-- The fields rows of the bootstrap tables are seeded in 0150_dd_bootstrap.once.sql,
-- which never runs again on a database that already has it, so the changed rule
-- and description reach both fresh installs and upgrades from here.
UPDATE fields
   SET input_type_rule = '{"if":[{"in":[{"var":"format"},["reference","parent"]]},{"if":[{"var":"created_at"},"readonly","required"]},"hidden"]}'::jsonb,
       description = 'Entity this field references, by table name. Required for reference and parent fields, empty for all others, and must name an existing entity. Set when the field is created and never changed afterward, except that renaming the entity updates it.'
 WHERE table_name = 'fields' AND field_name = 'reference_table';
