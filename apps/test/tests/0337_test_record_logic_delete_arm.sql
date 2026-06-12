-- Test (NEW CAPABILITY, mutation-checked): the record-logic trigger fires on DELETE with the
-- $mode and $old reserved variables, so validation_rules can govern deletes (I7).
--
-- Before b5 the per-table trigger was BEFORE INSERT OR UPDATE only — deletes bypassed every
-- validation_rule entirely (spec v2 Appendix A I7). b5 extends it to BEFORE INSERT OR UPDATE OR
-- DELETE, injects $mode ('insert'|'update'|'delete'), and populates $old on DELETE (= the row
-- being removed). Computed-field output is discarded on DELETE; validation_rules may abort it.
--
-- MUTATION CHECK (why this test is not vacuous): the delete-blocking assertions below pass ONLY
-- because the trigger now runs on DELETE. On the pre-b5 trigger (no DELETE arm) the locked-row
-- DELETE would silently succeed, so `throws_ok` would fail and the count assertion would read 0.
-- The unlocked-row DELETE succeeding (rather than every delete being blocked) further proves
-- $old is non-null on DELETE — the old_present_on_delete rule would otherwise abort it.
--
-- Fixtures: user3 = Administrator (may author entities/fields and write data).
BEGIN;

SELECT plan(8);

SELECT authenticate_as('user3');

-- An entity whose validation rules reference $mode and $old:
--   * no_delete_when_locked  — blocks DELETE of a row with locked = true
--   * old_present_on_delete  — asserts $old is populated on DELETE (else blocks ALL deletes)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    validation_rules)
VALUES ('rl_delete_test', 'rl_delete', 'Lockable', 'Lockables', 'DELETE-arm probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[
        {"code": "no_delete_when_locked",
         "message": "locked records cannot be deleted",
         "jsonlogic": {"or": [
            {"!=": [{"var": "$mode"}, "delete"]},
            {"!=": [{"var": "locked"}, true]}
         ]}},
        {"code": "old_present_on_delete",
         "message": "$old must be present on delete",
         "jsonlogic": {"or": [
            {"!=": [{"var": "$mode"}, "delete"]},
            {"!=": [{"var": "$old"}, null]}
         ]}}
    ]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rl_delete_test', 'locked', 'Locked', 'boolean', 10);

-- The trigger must now be wired for DELETE as well as INSERT/UPDATE.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_trigger
            WHERE tgrelid = 'public.rl_delete_test'::regclass
              AND tgname = 'compute_validate_trigger'
              -- tgtype bit 0x08 = DELETE (see pg_trigger.h TRIGGER_TYPE_DELETE)
              AND (tgtype & 8) <> 0),
    'compute_validate_trigger fires on DELETE');

-- INSERT works in both states ($mode = insert → rules pass).
SELECT lives_ok(
    $$INSERT INTO rl_delete_test (label, locked) VALUES ('keep-me', true)$$,
    'INSERT of a locked row succeeds ($mode = insert, delete rules inert)');
SELECT lives_ok(
    $$INSERT INTO rl_delete_test (label, locked) VALUES ('free-me', false)$$,
    'INSERT of an unlocked row succeeds');

-- UPDATE works ($mode = update → rules pass).
SELECT lives_ok(
    $$UPDATE rl_delete_test SET label = 'still-free' WHERE label = 'free-me'$$,
    'UPDATE succeeds ($mode = update, delete rules inert)');

-- DELETE of a LOCKED row is blocked by the validation rule ($mode = delete, locked = true).
SELECT throws_ok(
    $$DELETE FROM rl_delete_test WHERE label = 'keep-me'$$,
    '23514',
    'locked records cannot be deleted',
    'DELETE of a locked row is aborted by the validation rule');

SELECT is(
    (SELECT count(*)::int FROM rl_delete_test WHERE label = 'keep-me'),
    1,
    'the locked row survives the rejected DELETE');

-- DELETE of an UNLOCKED row succeeds — proving the DELETE arm runs AND $old is non-null
-- (old_present_on_delete would otherwise abort every delete).
SELECT lives_ok(
    $$DELETE FROM rl_delete_test WHERE label = 'still-free'$$,
    'DELETE of an unlocked row succeeds (delete rules evaluate, $old populated)');

SELECT is(
    (SELECT count(*)::int FROM rl_delete_test WHERE label = 'still-free'),
    0,
    'the unlocked row is actually removed');

SELECT * FROM finish();
ROLLBACK;
