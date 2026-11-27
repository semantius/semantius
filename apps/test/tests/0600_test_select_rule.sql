-- select_rule: the JsonLogic FOR SELECT policy on an entity, and the
-- $today / $now variables inside it.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. select_rule policy
--   2. $today / $now inside select_rule
--   3. is_a records under row security: base + extension permissions, the
--      whole-record skip, a derived select_rule over the whole record
--   4. The builder where no entity row backs it
--   5. A rule is checked when the entity is saved: an unknown operator and an
--      object with two keys are refused, the empty object is accepted
--   6. A stored rule the save would refuse: it still builds, and what a reader
--      sees under it
--   7. The predicate handed no request context answers false
--   8. The leading has_permission terms of a rule, checked once per statement
BEGIN;

SELECT plan(52);

-- =====================================================
-- PART 1: select_rule policy
-- =====================================================
-- Test select_rule: JsonLogic-based FOR SELECT RLS policy on entities

-- Authenticate as admin to create test entity
SELECT authenticate_as('user3');

-- =====================================================
-- TEST 1: Create an entity with a select_rule
-- =====================================================
-- Rule: admin can see all rows, otherwise only rows where assigned_to = $user_id
-- {"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'test_select_rule',
    'test_select_rule_item',
    'Test Select Rule Item',
    'Test Select Rule Items',
    'Table for testing select_rule',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb,
    1
);

-- Add an assigned_to field (reference to users)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, reference_table, reference_delete_mode)
VALUES ('test_select_rule', 'assigned_to', 'Assigned To', 'reference', 20, 'default', 'default', 'users', 'clear');

-- =====================================================
-- TEST 2: Verify the select_rule function was created
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_test_select_rule'
          AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    ),
    'select_rule function should be created for test_select_rule'
);

-- =====================================================
-- TEST 3: Verify the select policy was created
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'test_select_rule'
          AND policyname = 'test_select_rule_select_policy'
    ),
    'select policy should exist for test_select_rule'
);

-- =====================================================
-- TEST 4: Insert test data as admin
-- =====================================================
-- Get user IDs for user1 and user2
DO $$
DECLARE
    v_user1_id INTEGER;
    v_user2_id INTEGER;
BEGIN
    SELECT id INTO v_user1_id FROM users WHERE external_id = 'user1';
    SELECT id INTO v_user2_id FROM users WHERE external_id = 'user2';

    INSERT INTO test_select_rule (label, assigned_to)
    VALUES ('Item for user1', v_user1_id),
           ('Item for user2', v_user2_id),
           ('Unassigned item', NULL);
END $$;

-- Admin should see all 3 rows
SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    3,
    'admin (user3) should see all 3 rows'
);

-- =====================================================
-- TEST 5: user1 should only see their own row
-- =====================================================
SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    1,
    'user1 should see only 1 row (their assigned row)'
);

SELECT is(
    (SELECT label FROM test_select_rule LIMIT 1),
    'Item for user1',
    'user1 should see only their assigned item'
);

-- =====================================================
-- TEST 6: user2 should only see their own row
-- =====================================================
SELECT authenticate_as('user2');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    1,
    'user2 should see only 1 row (their assigned row)'
);

-- =====================================================
-- TEST 7: After removing select_rule, default policy is restored
-- =====================================================
SELECT authenticate_as('user3');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'test_select_rule';

-- Now all users with view permission should see all rows
SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    3,
    'user1 should see all 3 rows after select_rule is cleared (default policy restored)'
);

-- =====================================================
-- PART 2: $today / $now inside select_rule
-- =====================================================
-- Test: $today / $now reserved variables must be available inside select_rule.
--
-- build_select_rule_policy generates the per-row FOR SELECT rule function. The
-- compute/validate trigger injects $today, $now, $user_id, $old and $mode; the
-- SELECT rule function injects $today, $now and $user_id. A select_rule that filters
-- rows by server time (e.g. "only show rows still valid today") would otherwise see
-- $today/$now resolve to null -> jl_to_number(null)=0, so a ">=" comparison would pass
-- for EVERY row and the temporal filter would do nothing.
--
-- These tests pin the invariant that a select_rule can gate row visibility on server time.
--
-- Dates are chosen far in the past (2000) and far in the future (2999) so the result is
-- independent of the actual server clock.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

-- =====================================================
-- $today: a date-typed rule "valid_until >= $today"
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'sel_today_rule',
    'sel_today_rule_item',
    'Sel Today Rule Item',
    'Sel Today Rule Items',
    'select_rule referencing $today',
    '{">=":[{"var":"valid_until"},{"var":"$today"}]}'::jsonb,
    1
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sel_today_rule', 'valid_until', 'Valid Until', 'date', 10);

INSERT INTO sel_today_rule (label, valid_until)
VALUES ('future', '2999-01-01'), ('past', '2000-01-01');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule),
    1,
    '$today: only the still-valid (future) row is visible');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule WHERE label = 'past'),
    0,
    '$today: the expired (past) row is filtered out by the rule');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule WHERE label = 'future'),
    1,
    '$today: the future row is not over-filtered (rule is not hiding everything)');

-- =====================================================
-- $now: a date-time-typed rule "expires_at >= $now"
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'sel_now_rule',
    'sel_now_rule_item',
    'Sel Now Rule Item',
    'Sel Now Rule Items',
    'select_rule referencing $now',
    '{">=":[{"var":"expires_at"},{"var":"$now"}]}'::jsonb,
    1
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sel_now_rule', 'expires_at', 'Expires At', 'date-time', 10);

INSERT INTO sel_now_rule (label, expires_at)
VALUES ('future', '2999-01-01 00:00:00+00'), ('past', '2000-01-01 00:00:00+00');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule),
    1,
    '$now: only the unexpired (future) row is visible');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule WHERE label = 'past'),
    0,
    '$now: the expired (past) row is filtered out by the rule');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule WHERE label = 'future'),
    1,
    '$now: the future row is not over-filtered (rule is not hiding everything)');

-- =====================================================
-- $today is the UTC date whatever the session's zone
-- =====================================================
-- The two zones are on different calendar days at every instant, so at least one
-- of them differs from UTC.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'sel_utc_rule',
    'sel_utc_rule_item',
    'Sel Utc Rule Item',
    'Sel Utc Rule Items',
    'select_rule comparing with the UTC date',
    '{"==":[{"var":"valid_on"},{"var":"$today"}]}'::jsonb,
    1
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sel_utc_rule', 'valid_on', 'Valid On', 'date', 10);

INSERT INTO sel_utc_rule (label, valid_on)
VALUES ('today', (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date);

SET LOCAL timezone = 'Pacific/Kiritimati';
SELECT is(
    (SELECT count(*)::int FROM sel_utc_rule),
    1,
    '$today at UTC+14 is the UTC date inside a select_rule');

SET LOCAL timezone = 'Pacific/Pago_Pago';
SELECT is(
    (SELECT count(*)::int FROM sel_utc_rule),
    1,
    '$today at UTC-11 is the UTC date inside a select_rule');

SET LOCAL timezone = 'UTC';

-- =====================================================
-- PART 3: is_a records under row security
-- =====================================================
-- A derived entity's record is stored in its base's table and in its own
-- <entity>_ext, each carrying its own entity's policies. The view is
-- security_invoker, so a reader needs the view permission of every level; a
-- write runs as the caller, locks every level it writes first, and skips the
-- whole record when one of them cannot be locked - never half of it.
-- sec_parties is readable by everyone and editable with nwind:manage;
-- sec_leads is readable with nwind:view and editable by admin only. user1
-- holds neither nwind permission, user2 (Northwind Sales) both.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix,
                      view_permission, edit_permission)
VALUES ('sec_parties', 'Party', 'Parties', 1, 'typeid', 'secpty', 'public:read', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sec_parties', 'region', 'Region', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('sec_leads', 'Lead', 'Leads', 1, 'is_a', 'secled', 'sec_parties', 'nwind:view', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sec_leads', 'score', 'Score', 'int32', 30);

INSERT INTO sec_parties (label, region) VALUES ('p1', 'north');
INSERT INTO sec_leads (label, region, score) VALUES ('l1', 'north', 1), ('l2', 'south', 2);

SELECT authenticate_as('user1');
SELECT is(
    (SELECT count(*)::int FROM sec_parties)::text || '/' || (SELECT count(*)::int FROM sec_leads)::text,
    '3/0',
    'families: a reader sees the root rows its permission allows, and a subtype record only with every level''s view permission');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM sec_leads), 2,
    'families: with the view permission of every level the subtype records are readable');

SELECT throws_ok($$ INSERT INTO sec_leads (label) VALUES ('l3') $$,
    '42501', NULL,
    'families: an insert needs the edit permission of every level, and fails as a whole');

UPDATE sec_leads SET region = 'east' WHERE label = 'l1';
SELECT is((SELECT region FROM sec_leads WHERE label = 'l1'), 'north',
    'families: an update that cannot lock every level it writes skips the record, root row included');

UPDATE sec_parties SET region = 'west';
SELECT is(
    (SELECT string_agg(label || '=' || region, ', ' ORDER BY label) FROM sec_parties),
    'l1=north, l2=south, p1=west',
    'families: through the root table as well - the plain row changes, the subtype records are skipped whole');

DELETE FROM sec_parties;
SELECT is(
    (SELECT string_agg(label, ', ' ORDER BY label) FROM sec_parties),
    'l1, l2',
    'families: a delete through the root skips the subtype records it may not delete entirely');

-- A select_rule on a derived entity sees the whole record: its policy on
-- <entity>_ext merges the base's row under the own one.
SELECT authenticate_as('user3');
UPDATE entities SET select_rule = '{"==":[{"var":"region"},"north"]}'::jsonb WHERE table_name = 'sec_leads';
SELECT authenticate_as('user2');
SELECT is(
    (SELECT string_agg(label, ', ') FROM sec_leads),
    'l1',
    'families: a derived entity''s select_rule reads the fields its base stores');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'select_rule_sec_leads'
              AND pg_get_function_identity_arguments(oid) = 'p_row sec_leads_ext, p_ctx jsonb'),
    'families: the rule function takes the row of <entity>_ext and keeps the entity''s name');

-- =====================================================
-- PART 4: The builder and its trigger function where no entity row backs them
-- =====================================================
-- Asked to build the policy of a name the dictionary does not know,
-- build_select_rule_policy drops both overloads of select_rule_<name> and, with
-- them, the policies that call them; the table is not the builder's to touch.
-- Both overloads have to go, because a DROP naming one signature leaves the
-- other behind and the CASCADE that removes the policy rides on it. The stale
-- objects are made by hand as the owner, since no entity can produce them.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TABLE public.sr_stale (id int, label text);
ALTER TABLE public.sr_stale ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION public.select_rule_sr_stale(p_row public.sr_stale, p_ctx jsonb) RETURNS boolean
    LANGUAGE sql AS $$ SELECT TRUE $$;
CREATE FUNCTION public.select_rule_sr_stale(p_row public.sr_stale) RETURNS boolean
    LANGUAGE sql AS $$ SELECT TRUE $$;
-- The builder runs as the dictionary's owner, which drops only what it owns.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.sr_stale OWNER TO semantius_owner;
        ALTER FUNCTION public.select_rule_sr_stale(public.sr_stale, jsonb) OWNER TO semantius_owner;
        ALTER FUNCTION public.select_rule_sr_stale(public.sr_stale) OWNER TO semantius_owner;
    END IF;
END $$;
CREATE POLICY sr_stale_select_policy ON public.sr_stale FOR SELECT USING (public.select_rule_sr_stale(sr_stale.*));

SELECT is(
    (SELECT count(*)::int FROM pg_proc WHERE proname = 'select_rule_sr_stale' AND pronamespace = 'public'::regnamespace)::text
    || '/' || (SELECT count(*)::int FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sr_stale')::text,
    '2/1',
    'no entity: the stale rule functions and the policy that calls them exist before the builder runs');

SELECT lives_ok($$ SELECT public.build_select_rule_policy('sr_stale') $$,
    'no entity: the builder accepts a name the dictionary does not know');

SELECT is(
    (SELECT count(*)::int FROM pg_proc WHERE proname = 'select_rule_sr_stale' AND pronamespace = 'public'::regnamespace)::text
    || '/' || (SELECT count(*)::int FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sr_stale')::text,
    '0/0',
    'no entity: both overloads of the rule function and the policy that calls them are gone');

SELECT ok(to_regclass('public.sr_stale') IS NOT NULL,
    'no entity: and the table itself is left alone');

-- =====================================================
-- PART 5: A rule is checked when the entity is saved
-- =====================================================
-- The generated predicate answers FALSE for any error the rule raises, so an
-- operator the interpreter does not know hides every row from every reader
-- and nobody is told. A rule that is not one operator object does the
-- opposite: the interpreter reads an object with two keys as data, data is
-- truthy, and every reader sees every row. Neither is what its author meant,
-- so the save refuses both, on an insert and on an update alike; the empty
-- object stays the way to say that an entity has no rule. Each save names an
-- entity of its own, so a save that goes through changes nothing another
-- assertion reads.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
        VALUES ('sr_save_op', 'sr_save_op_item', 'Sr Save Op Item', 'Sr Save Op Items', 'Refused at save',
                '{"unknown_op":[1,2]}'::jsonb, 1)$$) ->> 'code',
    '90909',
    'save: a select_rule with an unknown operator is refused');

SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
        VALUES ('sr_save_two_keys', 'sr_save_two_keys_item', 'Sr Save Two Keys Item', 'Sr Save Two Keys Items', 'Refused at save',
                '{"==":[1,1],"x":2}'::jsonb, 1)$$) ->> 'code',
    '90919',
    'save: a select_rule that is an object with two keys is refused');

SELECT is(
    ARRAY(SELECT n
            FROM unnest(ARRAY['sr_save_op', 'sr_save_two_keys']) AS n
           WHERE EXISTS (SELECT 1 FROM entities WHERE table_name = n)
              OR to_regclass('public.' || n) IS NOT NULL),
    '{}'::text[],
    'save: a refused insert leaves neither the entity row nor its table behind');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id)
VALUES ('sr_save_update', 'sr_save_update_item', 'Sr Save Update Item', 'Sr Save Update Items', 'Refused at update', 1);

SELECT is(
    catch_error($$UPDATE entities SET select_rule = '{"unknown_op":[1,2]}'::jsonb
                   WHERE table_name = 'sr_save_update'$$) ->> 'code',
    '90909',
    'save: the same refusal when a rule is set on an existing entity');

SELECT is(
    (SELECT select_rule FROM entities WHERE table_name = 'sr_save_update'),
    '{}'::jsonb,
    'save: and the refused update leaves the entity without a rule');

SELECT lives_ok(
    $$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
      VALUES ('sr_save_empty', 'sr_save_empty_item', 'Sr Save Empty Item', 'Sr Save Empty Items', 'No rule',
              '{}'::jsonb, 1)$$,
    'save: the empty object is accepted');

-- The mistakes the interpreter answers without an error are refused as well
-- when the rule is set: here a permission that has no name, which no user
-- holds, so the rule would hide every row from everyone but the admins its
-- other branch lets through.
SELECT is(
    catch_error($$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
        VALUES ('sr_save_literal', 'sr_save_literal_item', 'Sr Save Literal Item', 'Sr Save Literal Items', 'Refused at save',
                '{"or": [{"has_permission": "admin"}, {"has_permission": ""}]}'::jsonb, 1)$$) ->> 'code',
    '90922',
    'save: a select_rule with a literal argument of the wrong kind is refused');

-- A $ name the rules are not given reads null, so the comparison below holds
-- for no row, or for every row whose owner is empty.
SELECT is(
    catch_error_hint($$UPDATE entities SET select_rule = '{"==": [{"var": "owner_id"}, {"var": "$user"}]}'::jsonb
                        WHERE table_name = 'sr_save_update'$$),
    '{"rule": "select_rule", "table": "sr_save_update", "path": "/==/1/var",
      "variable": "$user", "reason": "unknown", "op": ""}'::jsonb,
    'save: and so is a select_rule that reads a $ variable no rule is given, with the place in the hint');

-- A literal is no rule either, and for select_rule the table already says so:
-- the column takes an object and nothing else, so a condition typed as text,
-- which would be truthy and show every row, never reaches the interpreter.
SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
      VALUES ('sr_save_text', 'sr_save_text_item', 'Sr Save Text Item', 'Sr Save Text Items', 'Refused at save',
              '"owner == me"'::jsonb, 1)$$,
    '23514', 'new row for relation "entities" violates check constraint "select_rule_is_object"',
    'save: a select_rule that is a text literal is refused');

SELECT throws_ok(
    $$INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
      VALUES ('sr_save_true', 'sr_save_true_item', 'Sr Save True Item', 'Sr Save True Items', 'Refused at save',
              'true'::jsonb, 1)$$,
    '23514', 'new row for relation "entities" violates check constraint "select_rule_is_object"',
    'save: a select_rule that is the literal true is refused');

-- =====================================================
-- PART 6: A stored rule the save would refuse
-- =====================================================
-- A rule can be in the dictionary without having passed a save: a restored
-- dump, or a row written while the triggers of entities are off, which is how
-- the two below get there. The builder installs a rule as it stands, so the
-- generators can be run again over such an installation. A reader gets no row
-- under either rule: the unknown operator raises inside the predicate, and a
-- rule that is not one operator is no rule, which must not read as "everyone".
-- The entity itself cannot be saved again until the rule is put right.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id)
VALUES ('sr_stored_op', 'sr_stored_op_item', 'Sr Stored Op Item', 'Sr Stored Op Items', 'Unknown operator stored past the save', 1),
       ('sr_stored_two_keys', 'sr_stored_two_keys_item', 'Sr Stored Two Keys Item', 'Sr Stored Two Keys Items', 'Two keys stored past the save', 1);

INSERT INTO sr_stored_op (label) VALUES ('first'), ('second');
INSERT INTO sr_stored_two_keys (label) VALUES ('first'), ('second');

-- Turning the triggers of entities off takes its owner, and the builder is the
-- owner's as well.
RESET ROLE;

ALTER TABLE entities DISABLE TRIGGER USER;
UPDATE entities SET select_rule = '{"unknown_op":[1,2]}'::jsonb WHERE table_name = 'sr_stored_op';
UPDATE entities SET select_rule = '{"==":[1,1],"x":2}'::jsonb WHERE table_name = 'sr_stored_two_keys';
ALTER TABLE entities ENABLE TRIGGER USER;

SELECT lives_ok($$ SELECT public.build_select_rule_policy('sr_stored_op') $$,
    'stored rule: the builder installs a rule with an unknown operator as it stands');

SELECT lives_ok($$ SELECT public.build_select_rule_policy('sr_stored_two_keys') $$,
    'stored rule: the builder installs a rule with two keys as it stands');

-- What a reader gets from a table: the number of rows, or the SQLSTATE the
-- read raises. It runs as its caller, so the caller's policies apply.
CREATE FUNCTION pg_temp.sr_read(p_table TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_rows INT;
BEGIN
    EXECUTE format('SELECT count(*) FROM public.%I', p_table) INTO v_rows;
    RETURN v_rows || ' rows';
EXCEPTION WHEN OTHERS THEN
    RETURN 'raises ' || SQLSTATE;
END;
$$;

-- A rule that raises hides the row and says so once: a WARNING names the
-- entity and the SQLSTATE the first time in a transaction that the entity's
-- rule fails. pgTAP cannot capture a WARNING, so what is asserted here is the
-- transaction-local setting that keeps the entities already warned,
-- app.select_rule_warned, a comma-separated list of table names.
CREATE FUNCTION pg_temp.sr_warned(p_table TEXT) RETURNS INT LANGUAGE sql AS $$
    SELECT count(*)::int
    FROM unnest(string_to_array(COALESCE(current_setting('app.select_rule_warned', true), ''), ',')) AS w(name)
    WHERE w.name = p_table;
$$;

SELECT authenticate_as('user3');
SELECT is(pg_temp.sr_read('sr_stored_op'), '0 rows',
    'stored rule: an unknown operator hides every row from an administrator, and the read raises nothing');

SELECT is(pg_temp.sr_warned('sr_stored_op'), 1,
    'stored rule: the read leaves the entity in app.select_rule_warned');

SELECT authenticate_as('user1');
SELECT is(pg_temp.sr_read('sr_stored_op'), '0 rows',
    'stored rule: an unknown operator hides every row from a plain reader as well');

SELECT is(pg_temp.sr_warned('sr_stored_op'), 1,
    'stored rule: a second read in the transaction does not name the entity again');

SELECT is(pg_temp.sr_read('sr_stored_two_keys'), '0 rows',
    'stored rule: a rule with two keys hides every row, as a rule that is no single operator fails closed');

SELECT authenticate_as('user3');
SELECT is(
    COALESCE(catch_error($$UPDATE entities SET description = 'Edited after the upgrade'
                            WHERE table_name = 'sr_stored_op'$$) ->> 'code', 'no error'),
    '90909',
    'stored rule: a save of the entity that leaves the rule alone is refused all the same');

-- =====================================================
-- PART 7: The predicate without a request context
-- =====================================================
-- The two-argument predicate merges the context over the row. The request role
-- holds EXECUTE on it, because a policy runs with the caller's privileges, so
-- a caller can hand it NULL. Row and context are then both null, a rule such
-- as "user_id == $user_id" compares null with null, and the answer would be
-- true for any row. Without a context there is no caller to decide for: the
-- answer is false, whoever the row belongs to.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES ('sr_no_ctx', 'sr_no_ctx_item', 'Sr No Ctx Item', 'Sr No Ctx Items', 'Rows of their assignee',
        '{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}'::jsonb, 1);

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('sr_no_ctx', 'assigned_to', 'Assigned To', 'reference', 20, 'users', 'clear');

SELECT authenticate_as('user1');

SELECT is(
    public.select_rule_sr_no_ctx(
        jsonb_populate_record(NULL::public.sr_no_ctx, '{"id": 1, "assigned_to": 1001}'::jsonb), NULL::jsonb),
    FALSE,
    'no context: a row assigned to the caller does not pass the rule of a test entity');

SELECT is(
    public.select_rule_sr_no_ctx(
        jsonb_populate_record(NULL::public.sr_no_ctx, '{"id": 2, "assigned_to": 1002}'::jsonb), NULL::jsonb),
    FALSE,
    'no context: a row assigned to somebody else does not pass it either');

SELECT is(
    public.select_rule_user_bookmarks(
        jsonb_populate_record(NULL::public.user_bookmarks, '{"id": 1, "user_id": 1001}'::jsonb), NULL::jsonb),
    FALSE,
    'no context: the caller''s own bookmark does not pass the rule of user_bookmarks');

SELECT is(
    public.select_rule_user_bookmarks(
        jsonb_populate_record(NULL::public.user_bookmarks, '{"id": 2, "user_id": 1002}'::jsonb), NULL::jsonb),
    FALSE,
    'no context: somebody else''s bookmark does not pass it either');

SELECT is(
    public.select_rule_modules(
        jsonb_populate_record(NULL::public.modules, '{"id": 1, "view_permission": "public:read"}'::jsonb), NULL::jsonb),
    FALSE,
    'no context: a module whose view_permission everybody holds does not pass the rule of modules');

-- =====================================================
-- PART 8: The leading has_permission terms of a rule
-- =====================================================
-- The leading terms of a rule's top-level or that are has_permission of a
-- name written into the rule are checked once per statement, in front of the
-- per-row rule. The answer is the rule's own, because or stops at the first
-- term that holds. A has_permission term after any other term stays in the
-- per-row rule: a term before it that raises hides the row, and checking the
-- later term up front would show that row. The request context is asked in
-- front of the hoisted terms, so a statement is refused where the per-row
-- rule would refuse it, also for a holder of the permission whose check is
-- already answered from the transaction's cache.
--
-- Fixture, created as user3: spar_lead, whose rule is admin, then a term that
-- raises on the row labeled boom, then public:read, with the rows boom and
-- calm. pg_temp.spar_labels lists the rows of a table the caller reads.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.spar_labels(p_table TEXT) RETURNS TEXT AS $$
DECLARE
    v_labels TEXT;
BEGIN
    EXECUTE format('SELECT COALESCE(string_agg(label, '', '' ORDER BY label COLLATE "C"), '''') FROM public.%I', p_table)
       INTO v_labels;
    RETURN v_labels;
END;
$$ LANGUAGE plpgsql;

SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES ('spar_lead', 'spar_lead_item', 'Spar Lead', 'Spar Leads', 'Rows under a rule with a permission term behind a raising one',
        '{"or": [{"has_permission": "admin"}, {"if": [{"==": [{"var": "label"}, "boom"]}, {"throw_error": ["boom", "99001"]}, false]}, {"has_permission": "public:read"}]}'::jsonb, 1);
INSERT INTO spar_lead (label) VALUES ('boom'), ('calm');

SELECT authenticate_as('user1');
SELECT is(pg_temp.spar_labels('spar_lead'), 'calm',
    'leading terms: a has_permission term behind a term that raises is checked per row, so the row the term raises on stays hidden from a holder of that permission');
SELECT authenticate_as('user3');

SELECT rbac.has_permission('admin');
SELECT set_config('request.jwt.claim.role', 'bogus_role', true);
SELECT throws_ok(
    $$SELECT count(*) FROM entities$$,
    '42501', 'Authentication required: JWT role claim must be authenticated',
    'leading terms: the request context is asked first, so claims that are no longer valid refuse the statement although admin is already answered from the cache');
SELECT authenticate_as('user3');

SELECT * FROM finish();
ROLLBACK;
