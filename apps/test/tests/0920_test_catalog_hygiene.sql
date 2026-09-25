-- Guard: out-of-the-box entities must not be registered managed=FALSE.
--
-- managed=FALSE silently disables the DD machinery (create_table_trigger /
-- add_field_trigger) for a table, so foreign keys, columns, RLS policies and
-- enum CHECKs declared via field metadata are NOT created. That is exactly how
-- process_gates.entity ended up with a `reference` field but no backing FK,
-- which broke PostgREST embedding (PGRST200).
--
-- The ONLY sanctioned exceptions are the two audit log tables: they are
-- trigger-populated system logs (int64 ids, computed uuid columns) that
-- intentionally sit outside the managed DD model. If a new table legitimately
-- needs to be unmanaged, add it to the allowlist below together with a reason.
BEGIN;

SELECT plan(6);

SELECT authenticate_as('user3');

-- 1. No entity outside the allowlist may be unmanaged. On failure pgTAP prints
--    the offending table names, so a future reoccurence is named.
SELECT is(
    (SELECT COALESCE(array_agg(table_name ORDER BY table_name), ARRAY[]::text[])
       FROM entities
      WHERE managed = FALSE
        AND table_name NOT IN ('audit_record_logs', 'audit_ddl_logs')),
    ARRAY[]::text[],
    'No OOTB entity may be registered managed=FALSE (audit_record_logs / audit_ddl_logs are the only sanctioned exceptions)'
);

-- 2. The allowlisted audit tables are still present and still unmanaged. Keeps
--    the allowlist honest: if these are ever changed, revisit this test.
SELECT is(
    (SELECT count(*)::int
       FROM entities
      WHERE managed = FALSE
        AND table_name IN ('audit_record_logs', 'audit_ddl_logs')),
    2,
    'Both audit tables remain registered as the sanctioned unmanaged exceptions'
);

-- 3. The allowlist is enforced, not only asserted. enable_dd_table configures an
--    adopted table as a managed one - the four permission policies and a grant
--    of INSERT and UPDATE - and on these two that is not adoption but unlocking:
--    the log would become writable by whoever holds its edit_permission. The
--    flip itself is refused, which is what lets adoption stay unconditional for
--    every other table.

SELECT throws_ok(
    $$UPDATE entities SET managed = TRUE WHERE table_name = 'audit_record_logs'$$,
    '90602',
    NULL,
    'audit_record_logs cannot be made managed'
);

SELECT throws_ok(
    $$UPDATE entities SET managed = TRUE WHERE table_name = 'audit_ddl_logs'$$,
    '90602',
    NULL,
    'audit_ddl_logs cannot be made managed'
);

-- 4. An ordinary entity edit on those rows is untouched: the trigger is scoped
--    to the managed column and only refuses FALSE -> TRUE.
SELECT lives_ok(
    $$UPDATE entities SET description = 'DML audit trail' WHERE table_name = 'audit_record_logs'$$,
    'an ordinary edit of an audit entity is not affected by the guard'
);

SELECT lives_ok(
    $$UPDATE entities SET managed = FALSE WHERE table_name = 'audit_record_logs'$$,
    'writing managed = FALSE over FALSE is not a flip and is allowed'
);

SELECT * FROM finish();
ROLLBACK;
