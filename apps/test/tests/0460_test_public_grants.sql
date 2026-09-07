-- =====================================================
-- Explicit table grants in public (0460)
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
BEGIN;

SELECT plan(13);

-- =====================================================
-- TEST 1: no default privilege on tables or sequences in public
-- =====================================================
-- Grantor-agnostic on purpose: 0050 wrote these for the installing role and
-- 0290 reproduced them for semantius_owner, and neither may come back.

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
-- USAGE on the id sequence the SERIAL default alone would raise 42501.

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
    id serial PRIMARY KEY,
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

SELECT * FROM finish();
ROLLBACK;
