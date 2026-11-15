-- =====================================================
-- Explicit table grants in public (0960)
-- =====================================================
-- There is no ALTER DEFAULT PRIVILEGES on tables or sequences in `public`, so a
-- table the data dictionary did not create is unreachable by the request role.
-- The grant is what publishes a table through the Data API, and a table nobody
-- wrote policies for has no other access control, so the grant is issued only
-- where the policies are issued too: at CREATE TABLE through the dictionary,
-- and at adoption when an entity's `managed` flips to true.
--
--   1. no default privilege in public reaches the request role
--   2. every table and sequence in public that the request role must reach has
--      an explicit grant, so no creation site was missed
--   3. a table created by hand is invisible to the request role
--   4. a table the dictionary created is reachable, sequence included
--   5. adoption secures a hand-made table: RLS, four policies, the grants
--   6. the internal tables _settings and _apikeys cannot be registered as
--      entities or adopted, so adoption never opens them
BEGIN;

SELECT plan(27);

-- =====================================================
-- TEST 1: no default privilege on tables or sequences in public
-- =====================================================
-- Grantor-agnostic on purpose: earlier releases created these both for the
-- installing role and for semantius_owner (0110_rbac_grants.once.sql and
-- 9900_owner_hardening.sql revoke both), and neither may come back.

-- The grantee test is deliberately wider than semantius_user itself: a default
-- granted to PUBLIC (grantee 0) or to `authenticated`, which holds
-- semantius_user, reaches the request role just as surely.
SELECT is(
    (SELECT count(*)::integer
       FROM pg_default_acl a, aclexplode(a.defaclacl) x
      WHERE a.defaclnamespace = 'public'::regnamespace
        AND a.defaclobjtype IN ('r', 'S')
        AND (x.grantee = 0
             OR pg_has_role('semantius_user', x.grantee, 'USAGE'))),
    0,
    'no default privilege on tables or sequences in public reaches the request role'
);

-- =====================================================
-- TEST 2: no creation site was missed
-- =====================================================
-- The counterweight to TEST 1, and the assertion this whole change needs most.
-- Removing the default privilege means every site that creates a table the
-- request role must reach now has to grant it, and the failure mode is silent:
-- a table added to a migration without a grant is simply unreachable through
-- the Data API, which nothing else here would notice. Every table and sequence
-- in public is ours and is reachable, so the expected list is empty and any
-- future omission names itself.
--
-- Written as a list rather than a count so a failure says which object.

SELECT is(
    (SELECT coalesce(string_agg(c.relname, ', ' ORDER BY c.relname), '')
       FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind IN ('r', 'S')
        AND NOT has_table_privilege('semantius_user', c.oid, 'SELECT')),
    '',
    'every table and sequence in public is reachable by the request role'
);

-- =====================================================
-- TEST 3: a hand-made table is invisible to the request role
-- =====================================================
-- This is the shape the removed default made dangerous: a table created in a
-- console, with no policies at all, served to every logged-in user.

CREATE TABLE public.grant_probe_hand (id int, secret text);
INSERT INTO public.grant_probe_hand VALUES (1, 'not yours');

SELECT ok(
    NOT has_table_privilege('semantius_user', 'public.grant_probe_hand', 'SELECT'),
    'the request role holds no privilege on a table created by hand'
);

SELECT authenticate_as('user1');

SELECT throws_ok(
    'SELECT * FROM public.grant_probe_hand',
    '42501',
    NULL,
    'a plain user cannot read a table created by hand'
);

RESET ROLE;

-- =====================================================
-- TEST 4: a dictionary table is reachable, sequence included
-- =====================================================
-- user2 holds the Northwind Sales role (nwind:view + nwind:manage), so the
-- insert exercises the table grant and the sequence grant together: without
-- USAGE on the id sequence the identity default alone would raise 42501.

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('grant_probe_dict', 'grant_probe_dict', 'Grant Probe', 'Grant Probes', 'explicit grant probe', 1, 'nwind:view', 'nwind:manage', 'id', 'label');

RESET ROLE;

SELECT ok(
    has_table_privilege('semantius_user', 'public.grant_probe_dict', 'SELECT')
    AND has_table_privilege('semantius_user', 'public.grant_probe_dict', 'INSERT')
    AND has_table_privilege('semantius_user', 'public.grant_probe_dict', 'UPDATE')
    AND has_table_privilege('semantius_user', 'public.grant_probe_dict', 'DELETE'),
    'the request role holds all four privileges on a dictionary-created table'
);

SELECT ok(
    has_sequence_privilege('semantius_user',
        pg_get_serial_sequence('public.grant_probe_dict', 'id'), 'USAGE'),
    'the request role holds USAGE on the dictionary table''s id sequence'
);

SELECT authenticate_as('user2');

SELECT lives_ok(
    $$ INSERT INTO public.grant_probe_dict (label) VALUES ('row one') $$,
    'a user with the edit permission can insert into a dictionary-created table'
);

RESET ROLE;

-- =====================================================
-- TEST 5: adoption secures a hand-made table
-- =====================================================
-- Flipping `managed` to true on an entity whose table already exists is the
-- one path that used to grant nothing and enable nothing. It now enables RLS,
-- creates the four permission policies if they are absent, and grants last.
--
-- The table is handed to semantius_owner first because the adoption trigger is
-- SECURITY DEFINER as that role, and PostgreSQL refuses ALTER TABLE, CREATE
-- POLICY and GRANT to anyone but a table's owner. That is not new to the
-- grant: adding a missing column at adoption has always needed it. On a
-- managed platform, where owner hardening is a no-op, the installing role owns
-- both the dictionary and the console-made table and nothing is needed.

CREATE TABLE public.grant_probe_adopt (
    id bigserial PRIMARY KEY,
    label text NOT NULL DEFAULT ''
);

-- A policy the operator wrote before adoption. Adoption must leave it alone:
-- it is somebody's deliberate rule, and the four it adds carry their own names.
CREATE POLICY grant_probe_adopt_operator ON public.grant_probe_adopt
    FOR SELECT TO semantius_user USING (true);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.grant_probe_adopt OWNER TO semantius_owner;
        ALTER SEQUENCE public.grant_probe_adopt_id_seq OWNER TO semantius_owner;
    END IF;
END $$;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('grant_probe_adopt', 'grant_probe_adopt', 'Adopt Probe', 'Adopt Probes', 'adoption probe', 1, 'nwind:view', 'nwind:manage', 'id', 'label', false);

RESET ROLE;

-- The before-state, without which the four assertions after the flip would pass
-- just as well if registering the unmanaged entity had already done the work,
-- and would prove nothing about adoption.
SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.grant_probe_adopt'::regclass),
    'before the flip the hand-made table has no row level security'
);

SELECT ok(
    NOT has_table_privilege('semantius_user', 'public.grant_probe_adopt', 'SELECT'),
    'before the flip the request role holds no privilege on it'
);

SELECT authenticate_as('user3');

UPDATE entities SET managed = true WHERE table_name = 'grant_probe_adopt';

RESET ROLE;

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.grant_probe_adopt'::regclass),
    'adoption enables row level security on a hand-made table'
);

SELECT is(
    (SELECT count(*)::integer FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'grant_probe_adopt'
        AND policyname IN ('grant_probe_adopt_select_policy',
                           'grant_probe_adopt_insert_policy',
                           'grant_probe_adopt_update_policy',
                           'grant_probe_adopt_delete_policy')),
    4,
    'adoption creates the four permission policies'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'grant_probe_adopt'
               AND policyname = 'grant_probe_adopt_operator'),
    'a policy written before adoption survives it'
);

SELECT ok(
    has_table_privilege('semantius_user', 'public.grant_probe_adopt', 'SELECT')
    AND has_table_privilege('semantius_user', 'public.grant_probe_adopt', 'INSERT')
    AND has_table_privilege('semantius_user', 'public.grant_probe_adopt', 'UPDATE')
    AND has_table_privilege('semantius_user', 'public.grant_probe_adopt', 'DELETE')
    AND has_sequence_privilege('semantius_user',
            pg_get_serial_sequence('public.grant_probe_adopt', 'id'), 'USAGE'),
    'adoption grants the request role the table and its sequence'
);

-- =====================================================
-- Adoption of a table that was already secured
-- =====================================================
-- The probe above has a policy of its own but row-level security switched off,
-- which is how a hand-made table normally arrives. This one has RLS actually
-- enabled, and used to be skipped: adoption left it with its own policies, no
-- permission policies and no grant, so the entity claimed a permission model
-- the table did not enforce. A managed table is configured as a managed table
-- whatever it carried before.

RESET ROLE;

CREATE TABLE public.grant_probe_secured (
    id BIGSERIAL PRIMARY KEY,
    label TEXT NOT NULL DEFAULT ''
);

ALTER TABLE public.grant_probe_secured ENABLE ROW LEVEL SECURITY;

CREATE POLICY grant_probe_secured_operator ON public.grant_probe_secured
    FOR SELECT TO semantius_user USING (true);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_owner') THEN
        ALTER TABLE public.grant_probe_secured OWNER TO semantius_owner;
        ALTER SEQUENCE public.grant_probe_secured_id_seq OWNER TO semantius_owner;
    END IF;
END $$;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('grant_probe_secured', 'grant_probe_secured', 'Secured Probe', 'Secured Probes', 'adoption probe, pre-secured', 1, 'nwind:view', 'nwind:manage', 'id', 'label', false);

RESET ROLE;

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.grant_probe_secured'::regclass)
    AND NOT has_table_privilege('semantius_user', 'public.grant_probe_secured', 'SELECT'),
    'before the flip the table is secured on its own and the request role holds nothing'
);

SELECT authenticate_as('user3');

UPDATE entities SET managed = true WHERE table_name = 'grant_probe_secured';

RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'grant_probe_secured'
        AND policyname IN ('grant_probe_secured_select_policy',
                           'grant_probe_secured_insert_policy',
                           'grant_probe_secured_update_policy',
                           'grant_probe_secured_delete_policy')),
    4,
    'adoption creates the four permission policies on an already secured table'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'grant_probe_secured'
               AND policyname = 'grant_probe_secured_operator'),
    'the policy the table already carried survives adoption'
);

SELECT ok(
    has_table_privilege('semantius_user', 'public.grant_probe_secured', 'INSERT')
    AND has_table_privilege('semantius_user', 'public.grant_probe_secured', 'UPDATE')
    AND has_sequence_privilege('semantius_user',
            pg_get_serial_sequence('public.grant_probe_secured', 'id'), 'USAGE'),
    'adoption grants the request role the table and its sequence here too'
);

-- =====================================================
-- TEST 6: the internal tables are not entities
-- =====================================================
-- _settings and _apikeys are protected by having no permission model at all:
-- one deny-all policy, and SECURITY DEFINER functions as the only readers
-- (0390_test_rbac_write_protection.sql pins that nobody is exempt, an
-- administrator included). Registering either as an entity gives it one.
-- Created managed, or registered unmanaged and then flipped, the table gets
-- the four permission policies, and PostgreSQL ORs them with the deny-all one,
-- so every holder of the entity's view_permission reads the system settings
-- or the API key hashes through the Data API. The two audit logs have the same
-- problem for their write side and are refused at the flip
-- (0200_audit_log.sql); these two have nothing to offer an entity at any stage,
-- so the registration itself is refused, managed or not.
--
-- Each attempt declares the key and a label column the table really has, so
-- the refusal a mismatched key gets from dd_check_id_column (90235) cannot
-- stand in for the one asserted here.
--
-- An attempt runs in a subtransaction that is always rolled back, whatever
-- came of it, and reports from inside what it saw: the SQLSTATE, or 'accepted',
-- and how many rows of the table the caller could read once the statements had
-- run (after the rollback when they were refused). Undoing an accepted
-- registration by deleting the entity row is not an option: for a managed
-- entity that drops the table.

RESET ROLE;

CREATE FUNCTION pg_temp.registration_attempt(p_table TEXT, p_sql TEXT) RETURNS JSONB AS $$
DECLARE
    v_code    TEXT;
    v_message TEXT;
    v_rows    BIGINT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        EXECUTE format('SELECT count(*) FROM public.%I', p_table) INTO v_rows;
        RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = v_rows::text;
    EXCEPTION
        WHEN SQLSTATE 'ZZ001' THEN
            RETURN jsonb_build_object('code', 'accepted', 'rows_readable', SQLERRM::bigint);
        WHEN OTHERS THEN
            v_code := SQLSTATE;
            v_message := SQLERRM;
    END;
    EXECUTE format('SELECT count(*) FROM public.%I', p_table) INTO v_rows;
    RETURN jsonb_build_object('code', v_code, 'message', v_message, 'rows_readable', v_rows);
END;
$$ LANGUAGE plpgsql;

-- Both tables hold a row, so "reads no row" below is not true of an empty table.
SELECT ok(
    EXISTS (SELECT 1 FROM _settings) AND EXISTS (SELECT 1 FROM _apikeys),
    'setup: _settings and _apikeys each hold at least one row'
);

SELECT authenticate_as('user3');

CREATE TEMP TABLE registration_outcome AS
SELECT a.attempt, a.tbl, pg_temp.registration_attempt(a.tbl, a.sql) AS outcome
FROM (VALUES
    ('managed', '_settings', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column)
        VALUES ('_settings', '_setting', 'Setting', 'Settings', 'registration probe', 1, 'public:read', 'admin', 'name', 'text', 'value') $q$),
    ('unmanaged', '_settings', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column, managed)
        VALUES ('_settings', '_setting', 'Setting', 'Settings', 'registration probe', 1, 'public:read', 'admin', 'name', 'text', 'value', false) $q$),
    ('adopted', '_settings', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column, managed)
        VALUES ('_settings', '_setting', 'Setting', 'Settings', 'registration probe', 1, 'public:read', 'admin', 'name', 'text', 'value', false);
        UPDATE entities SET managed = true WHERE table_name = '_settings' $q$),
    ('managed', '_apikeys', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column)
        VALUES ('_apikeys', '_apikey', 'API Key', 'API Keys', 'registration probe', 1, 'public:read', 'admin', 'id', 'auto_increment', 'description') $q$),
    ('unmanaged', '_apikeys', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column, managed)
        VALUES ('_apikeys', '_apikey', 'API Key', 'API Keys', 'registration probe', 1, 'public:read', 'admin', 'id', 'auto_increment', 'description', false) $q$),
    ('adopted', '_apikeys', $q$
        INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, id_type, label_column, managed)
        VALUES ('_apikeys', '_apikey', 'API Key', 'API Keys', 'registration probe', 1, 'public:read', 'admin', 'id', 'auto_increment', 'description', false);
        UPDATE entities SET managed = true WHERE table_name = '_apikeys' $q$)
) AS a(attempt, tbl, sql);

RESET ROLE;

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_settings' AND attempt = 'managed'),
    '^90',
    'registering _settings as a managed entity is refused'
);

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_settings' AND attempt = 'unmanaged'),
    '^90',
    'registering _settings as an unmanaged entity is refused'
);

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_settings' AND attempt = 'adopted'),
    '^90',
    'registering _settings unmanaged and flipping it to managed is refused'
);

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_apikeys' AND attempt = 'managed'),
    '^90',
    'registering _apikeys as a managed entity is refused'
);

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_apikeys' AND attempt = 'unmanaged'),
    '^90',
    'registering _apikeys as an unmanaged entity is refused'
);

SELECT matches(
    (SELECT outcome ->> 'code' FROM registration_outcome WHERE tbl = '_apikeys' AND attempt = 'adopted'),
    '^90',
    'registering _apikeys unmanaged and flipping it to managed is refused'
);

-- What the refusal is for. Written as a list of the attempts that opened the
-- table, so a failure says which ones.
SELECT is(
    (SELECT string_agg(attempt, ', ' ORDER BY attempt) FROM registration_outcome
      WHERE tbl = '_settings' AND (outcome ->> 'rows_readable')::bigint <> 0),
    NULL,
    'no attempt leaves a row of _settings readable by the request role'
);

SELECT is(
    (SELECT string_agg(attempt, ', ' ORDER BY attempt) FROM registration_outcome
      WHERE tbl = '_apikeys' AND (outcome ->> 'rows_readable')::bigint <> 0),
    NULL,
    'no attempt leaves a row of _apikeys readable by the request role'
);

SELECT is(
    (SELECT count(*)::text FROM entities WHERE table_name IN ('_settings', '_apikeys'))
    || ' / '
    || (SELECT string_agg(tablename || '.' || policyname, ', ' ORDER BY tablename, policyname)
          FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('_settings', '_apikeys')),
    '0 / _apikeys.apikeys_deny_all, _settings.settings_deny_all',
    'after the attempts neither table is an entity and each carries its deny-all policy alone'
);

SELECT * FROM finish();
ROLLBACK;
