-- Dates are UTC whichever session wrote them. Two things hold that: the database
-- default, which is the only thing that can read a date-time sent with no offset
-- as UTC, and the settings on every function that turns a row into rule data,
-- because a client can change its own session.
--
-- The sweep runs over what the dictionary generates, so it needs one entity of
-- each kind to exist; the presence check keeps it from passing over nothing.
BEGIN;

SELECT plan(4);

SELECT ok(
    EXISTS (SELECT 1
              FROM pg_db_role_setting s
              JOIN pg_database d ON d.oid = s.setdatabase,
                   unnest(s.setconfig) AS c
             WHERE d.datname = current_database()
               AND s.setrole = 0
               AND lower(c) = 'timezone=utc'),
    'the database defaults to UTC');

SELECT ok(
    EXISTS (SELECT 1
              FROM pg_db_role_setting s
              JOIN pg_database d ON d.oid = s.setdatabase,
                   unnest(s.setconfig) AS c
             WHERE d.datname = current_database()
               AND s.setrole = 0
               AND lower(c) = 'intervalstyle=iso_8601'),
    'the database renders durations in ISO 8601');

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      edit_permission, select_rule, validation_rules)
VALUES ('utc_accounts', 'Account', 'Accounts', 1, 'typeid', 'utcac', 'nwind:manage',
        '{"==":[1,1]}'::jsonb,
        '[{"code":"99851","message":"always true","jsonlogic":true}]'::jsonb);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      edit_permission)
VALUES ('utc_premium', 'Premium Account', 'Premium Accounts', 1, 'is_a', 'utcpr', 'utc_accounts', 'nwind:manage');

RESET ROLE;

SELECT is(
    (SELECT count(*)::int FROM pg_proc
      WHERE proname IN ('record_rules_utc_accounts', 'compute_validate_utc_accounts',
                        'select_rule_utc_accounts', 'record_write_utc_premium')),
    5,
    'the sweep below has one function of each generated kind, and both select_rule overloads');

SELECT is_empty(
    $$
    SELECT p.oid::regprocedure::text
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE ((n.nspname = 'common' AND (p.proname LIKE 'record\_rules\_%' OR p.proname LIKE 'record\_write\_%'))
         OR (n.nspname = 'public' AND (p.proname LIKE 'compute\_validate\_%' OR p.proname LIKE 'select\_rule\_%'
                                       OR p.proname IN ('computed_backfill', 'jl_request_context'))))
       AND NOT (EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE lower(c) = 'timezone=utc')
            AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE lower(c) = 'intervalstyle=iso_8601'))
    $$,
    'every function that turns a row into rule data runs in UTC and ISO 8601');

SELECT * FROM finish();
ROLLBACK;
