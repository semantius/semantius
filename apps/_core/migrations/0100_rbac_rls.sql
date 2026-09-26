-- =====================================================
-- Description: Enable Row Level Security (RLS) policies
-- =====================================================

-- =====================================================
-- VERIFY BYPASSRLS ON FUNCTION OWNER
-- =====================================================
-- This check ensures SECURITY DEFINER functions can bypass RLS and avoid recursion
-- On Supabase: The 'postgres' role automatically has BYPASSRLS - no ALTER ROLE needed
-- On Neon: Roles created via Console/CLI/API inherit BYPASSRLS from 'neon_superuser' (projects after Aug 15, 2023)
-- On self-hosted: You may need to run: ALTER ROLE your_role BYPASSRLS;
-- Note: This verification will halt the script if BYPASSRLS is not available
-- Repeatable. The schema-wide grants are in 0110_rbac_grants.once.sql: they
-- reach every table that exists when they run, so running them again later
-- would grant semantius_user the tables created since.

-- RAISE, not ASSERT: assertions are silently skipped when
-- plpgsql.check_asserts is off, which would let the install proceed without
-- BYPASSRLS and fail much later, in the dictionary's definer code (B11).
DO $$
BEGIN
  IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'role "%" does not have BYPASSRLS, which the Semantius dictionary code requires', current_user
      USING ERRCODE = '55000',
            HINT = 'ALTER ROLE ' || quote_ident(current_user) || ' BYPASSRLS;';
  END IF;
END $$;

-- =====================================================
-- ENABLE RLS ON ALL RBAC TABLES
-- =====================================================

ALTER TABLE modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_hierarchy ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- POLICIES OF THE EIGHT RBAC TABLES
-- =====================================================
-- None here. These tables are data dictionary entities (0150_dd_bootstrap.once.sql registers them),
-- and the dictionary owns every policy named <table>_{select,insert,update,
-- delete}_policy: it drops and re-creates them whenever the entity's
-- view_permission, edit_permission or select_rule changes. A hand-written
-- copy would be replaced by the first such change and would overwrite the
-- dictionary's version whenever this file ran again. create_entity_policies()
-- generates them once the dictionary exists (0240_dd_bootstrap_complete.once.sql),
-- and modules gets its per-row rule from its select_rule in the same file. Until then RLS is on with no policy,
-- which denies the request role everything; the install itself runs as the
-- owner.

-- =====================================================
-- _VERSIONS - admin can query, deny insert/update/delete
-- =====================================================

DROP POLICY IF EXISTS versions_select_policy ON _versions;
CREATE POLICY versions_select_policy ON _versions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- There is deliberately no ALTER DEFAULT PRIVILEGES for tables or sequences in
-- this schema. A default grant would reach every table created in public from
-- then on, including one made by hand in a console, and such a table has no
-- policies: the grant is the whole of its access control, so the Data API would
-- serve all of its rows to every logged-in user. The grant is therefore issued
-- per table, at each site that creates one the request role must reach - the
-- dictionary at CREATE TABLE and at adoption, and the core migrations for what
-- they create - so that a grant is never in place without the policies that
-- bound it. The two ON ALL statements in 0110_rbac_grants.once.sql are not a
-- default: they cover the tables that exist at that point of the migration
-- order, every one of them ours and every one of them with RLS (pinned by
-- 0900_test_security.sql 2.1).

-- =====================================================
-- TRIGGER: Auto-assign role 1 (User) to new users
-- =====================================================
-- When a new user is inserted, automatically assign them to role 1 (User role)
-- This ensures all users have at least the basic User role

CREATE OR REPLACE FUNCTION rbac.auto_assign_user_role()
RETURNS TRIGGER AS $$
BEGIN
    -- Insert the user into role 1 (User) if not already assigned
    -- Note: Role ID 1 is explicitly seeded in 0090_rbac_seed.once.sql and reserved for the User role
    INSERT INTO user_roles (user_id, role_id)
    VALUES (NEW.id, 1)
    ON CONFLICT (user_id, role_id) DO NOTHING;

    -- Bootstrap admin: the first principal that actually reaches the system
    -- takes Administrator (role 2), so a fresh install is administrable without
    -- a back door. Two conditions, both load-bearing.
    --
    -- `NEW.last_seen IS NOT NULL`: a row created for somebody who has never
    -- authenticated is not a principal reaching the system, so provisioning a
    -- batch of users before anyone logs in elects nobody.
    --
    -- No role-2 row exists yet: this is the gate. The obvious cheaper test -
    -- whether any OTHER user has a last_seen - answers a different question and
    -- drifts away from this one. Pre-provisioned users keep last_seen NULL
    -- forever, so on a system whose administrator was pre-provisioned, or whose
    -- last_seen was cleared, that test reads true even though an administrator
    -- exists, and elects every later first login on top of it. Asking whether
    -- the role is taken cannot drift, survives any seed, and needs no marker row
    -- that every installer would then have to set.
    --
    -- Under pg_advisory_xact_lock because the read and the write are two
    -- statements: two first logins arriving together would both see an empty
    -- user_roles and both insert. The lock is transaction-scoped, so the loser
    -- waits for the winner to commit and then, under READ COMMITTED, takes a
    -- fresh snapshot in which the role is taken. The key is this function's own;
    -- hashtext('migrate') and hashtext('pgmq.queue_...') are already in use.
    --
    -- The election fires on INSERT only, so it is genuinely once per system and
    -- not a recovery mechanism. A principal whose users row already exists is
    -- updated in place by rbac.upsert_user_from_jwt, which fires UPDATE triggers
    -- and never this one - so an established user cannot be elected however many
    -- times they authenticate, even with the administrator set empty. That is why
    -- the set is not allowed to empty: rbac.assert_administrator_remains below
    -- refuses any statement that would.
    --
    -- One consequence stays open by design. A user holding user:manage - which
    -- is what the users policies require, admin or not - can elect a principal
    -- deliberately, by inserting a users row with last_seen set while no
    -- administrator exists. Reaching that needs a superuser to have emptied the
    -- set first, so it is accepted.
    IF NEW.last_seen IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('rbac.bootstrap_administrator'));

        IF NOT EXISTS (SELECT 1 FROM user_roles WHERE role_id = 2) THEN
            INSERT INTO user_roles (user_id, role_id)
            VALUES (NEW.id, 2)
            ON CONFLICT (user_id, role_id) DO NOTHING;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.auto_assign_user_role IS
'Trigger function to automatically assign role 1 (User) to newly created users. Also assigns role 2 (Administrator) to the first principal to arrive with a last_seen while no user holds role 2, under an advisory lock.';

CREATE OR REPLACE TRIGGER auto_assign_user_role_trigger
    AFTER INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION rbac.auto_assign_user_role();

COMMENT ON TRIGGER auto_assign_user_role_trigger ON users IS
'Automatically assigns role 1 (User) to new users after insertion.';

-- =====================================================
-- TRIGGER: Prevent deletion of role 1 from any user
-- =====================================================
-- This ensures that no user can have their User role removed,
-- maintaining the security principle that all users must have basic access

CREATE OR REPLACE FUNCTION rbac.prevent_user_role_deletion()
RETURNS TRIGGER AS $$
BEGIN
    -- Check if attempting to delete role 1 (User role)
    -- Note: Role ID 1 is explicitly seeded in 0090_rbac_seed.once.sql and reserved for the User role
    IF OLD.role_id = 1 THEN
        -- Allow cascade when the user itself is being deleted
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Cannot delete role 1 (User) from user. All users must have the User role.'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object('code', '90103')::text;
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.prevent_user_role_deletion IS 
'Trigger function to prevent deletion of role 1 (User) from any user.';

CREATE OR REPLACE TRIGGER prevent_user_role_deletion_trigger
    BEFORE DELETE ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.prevent_user_role_deletion();

COMMENT ON TRIGGER prevent_user_role_deletion_trigger ON user_roles IS
'Prevents deletion of role 1 (User) from any user in user_roles table.';

-- =====================================================
-- TRIGGER: An administrator must always remain
-- =====================================================
-- A system with no enabled Administrator cannot be administered and cannot be
-- repaired through the API: every route back in - granting a role, enabling a
-- user - is itself gated on `admin`. Three statements reach that state and all
-- three are ordinary things an administrator may do by accident:
--
--   DELETE FROM user_roles WHERE role_id = 2       (drop the role assignment)
--   DELETE FROM users WHERE id = <the admin>       (cascades to the row above)
--   UPDATE users SET is_disabled = TRUE ...        (the role survives, the
--                                                   administrator does not)
--
-- The third is why the check counts only users with is_disabled = FALSE, and
-- why it is not enough to look at user_roles: a disabled principal holds the
-- role and can do nothing with it, and rbac.user_has_permission ignores it for
-- exactly that reason.
--
-- This is a statement-level AFTER trigger, not a row-level BEFORE one, because
-- the rule is about the state the statement leaves behind. A row trigger
-- deleting two administrators one at a time has to reason about which rows the
-- same statement has already removed; asking once, at the end, does not.
--
-- SECURITY INVOKER, unlike everything else in this file, and it has to be:
-- current_user inside a SECURITY DEFINER function is the function owner, which
-- has BYPASSRLS, so the exemption below would let every caller through.
--
-- That exemption is the operator's escape hatch and matches fields_ctype_lock in
-- 0160_dd_functions.sql: a direct superuser or owner connection may still empty the administrator
-- set, which is how a database is repaired and how a test builds a system that
-- has never had one. It gives away nothing - such a connection already holds
-- everything the extension protects. It is also the only exemption, and that is
-- the load-bearing part.
--
-- The count therefore cannot come from the caller's own view of the tables. An
-- invoker trigger reads user_roles under RLS, where reading needs `admin`, so a
-- caller without it sees an empty set and every statement would look like the
-- last one. Excusing the caller who cannot see the rows is not a way out either:
-- writing users needs `user:manage`, not `admin`, so a caller who holds
-- user:manage and nothing else can disable or delete the last Administrator
-- while being excused from the check that exists to stop it.
-- rbac.count_enabled_administrators is SECURITY DEFINER for that reason: one
-- answer, the true one, whoever asks. It is never inlined - PostgreSQL does not
-- inline a definer function - so the owner's BYPASSRLS still applies inside it.
--
-- A statement trigger also fires when the statement matched no rows - a plain
-- user issuing `DELETE FROM users` that RLS silently reduces to nothing reaches
-- this code too. With a true count that costs nothing: the set is unchanged, so
-- it is non-empty unless it was already empty, and a system already in that
-- state is repaired through the exemption above.
CREATE OR REPLACE FUNCTION rbac.count_enabled_administrators()
RETURNS INTEGER AS $$
    SELECT count(*)::integer
    FROM user_roles ur
    JOIN users u ON u.id = ur.user_id
    WHERE ur.role_id = 2
      AND u.is_disabled = FALSE;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = rbac, public;

-- The invoker trigger above has to be able to call this, so semantius_user keeps
-- the EXECUTE that the ALTER DEFAULT PRIVILEGES in 0060_rbac_schema.once.sql
-- grants it. What that exposes is one bit - whether the system still has an
-- administrator - which any session can already read off the guard by issuing a
-- statement the guard watches.
REVOKE EXECUTE ON FUNCTION rbac.count_enabled_administrators() FROM PUBLIC;

COMMENT ON FUNCTION rbac.count_enabled_administrators IS
'Number of enabled users holding role 2 (Administrator). SECURITY DEFINER so the answer does not depend on what the caller may read.';

CREATE OR REPLACE FUNCTION rbac.assert_administrator_remains()
RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
        RETURN NULL;
    END IF;

    IF rbac.count_enabled_administrators() = 0 THEN
        RAISE EXCEPTION 'This would leave the system without an enabled Administrator'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object(
                      'code', '90104',
                      'hint', 'Grant the Administrator role to another enabled user first. A direct superuser connection is exempt from this check.')::text;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public;

-- Created after the blanket REVOKE ON ALL FUNCTIONS IN SCHEMA rbac at the end of
-- 0080_rbac_functions.sql, so it
-- carries PostgreSQL's built-in PUBLIC grant until this line takes it away. The
-- request role keeps EXECUTE: it is the invoker, and the trigger is useless if
-- the caller cannot run it.
REVOKE EXECUTE ON FUNCTION rbac.assert_administrator_remains() FROM PUBLIC;

COMMENT ON FUNCTION rbac.assert_administrator_remains IS
'Statement-level guard: refuses any statement that would leave no enabled user holding role 2 (Administrator). SECURITY INVOKER so the BYPASSRLS exemption tests the real caller.';

CREATE OR REPLACE TRIGGER assert_administrator_remains_on_user_roles
    AFTER DELETE ON user_roles
    FOR EACH STATEMENT
    EXECUTE FUNCTION rbac.assert_administrator_remains();

CREATE OR REPLACE TRIGGER assert_administrator_remains_on_user_delete
    AFTER DELETE ON users
    FOR EACH STATEMENT
    EXECUTE FUNCTION rbac.assert_administrator_remains();

-- Scoped to the one column that can revoke an administrator without touching a
-- role: an unscoped UPDATE trigger would run this query on every login, because
-- get_userinfo() refreshes last_seen on each one.
CREATE OR REPLACE TRIGGER assert_administrator_remains_on_disable
    AFTER UPDATE OF is_disabled ON users
    FOR EACH STATEMENT
    EXECUTE FUNCTION rbac.assert_administrator_remains();

COMMENT ON TRIGGER assert_administrator_remains_on_user_roles ON user_roles IS
'Refuses a DELETE that removes the last enabled Administrator.';
COMMENT ON TRIGGER assert_administrator_remains_on_user_delete ON users IS
'Refuses a DELETE that removes the last enabled Administrator (the user_roles rows go with the user).';
-- user_roles.role_id references roles ON DELETE CASCADE, so dropping the
-- Administrator role itself takes every assignment with it. That cascade runs as
-- the referencing table's owner, which is BYPASSRLS and therefore exempt from
-- the user_roles trigger above - this one fires in the caller's own context and
-- catches it.
CREATE OR REPLACE TRIGGER assert_administrator_remains_on_role_delete
    AFTER DELETE ON roles
    FOR EACH STATEMENT
    EXECUTE FUNCTION rbac.assert_administrator_remains();

COMMENT ON TRIGGER assert_administrator_remains_on_disable ON users IS
'Refuses an UPDATE that disables the last enabled Administrator.';
COMMENT ON TRIGGER assert_administrator_remains_on_role_delete ON roles IS
'Refuses a DELETE of the Administrator role while it is the only source of an enabled administrator.';

-- =====================================================
-- TRIGGER: Default assigned_by to current user
-- =====================================================
-- When a user_role record is inserted without an assigned_by value,
-- automatically set it to the current user ID from the session context

CREATE OR REPLACE FUNCTION rbac.default_assigned_by()
RETURNS TRIGGER AS $$
DECLARE
    v_current_user_id BIGINT;
BEGIN
    IF NEW.assigned_by IS NULL THEN
        BEGIN
            v_current_user_id := rbac.user_id();
        EXCEPTION WHEN OTHERS THEN
            v_current_user_id := NULL;
        END;
        IF v_current_user_id IS NOT NULL THEN
            NEW.assigned_by := v_current_user_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.default_assigned_by IS
'Trigger function to default assigned_by to the current user ID when not explicitly provided.';

CREATE OR REPLACE TRIGGER default_assigned_by_trigger
    BEFORE INSERT ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_assigned_by();

COMMENT ON TRIGGER default_assigned_by_trigger ON user_roles IS
'Defaults assigned_by to the current session user when not provided on insert.';

-- =====================================================
-- TRIGGER: Default granted_by to current user for user_permissions
-- =====================================================

CREATE OR REPLACE FUNCTION rbac.default_granted_by()
RETURNS TRIGGER AS $$
DECLARE
    v_current_user_id BIGINT;
BEGIN
    IF NEW.granted_by IS NULL THEN
        BEGIN
            v_current_user_id := rbac.user_id();
        EXCEPTION WHEN OTHERS THEN
            v_current_user_id := NULL;
        END;
        IF v_current_user_id IS NOT NULL THEN
            NEW.granted_by := v_current_user_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.default_granted_by IS
'Trigger function to default granted_by to the current user ID when not explicitly provided.';

CREATE OR REPLACE TRIGGER default_granted_by_trigger
    BEFORE INSERT ON user_permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_granted_by();

COMMENT ON TRIGGER default_granted_by_trigger ON user_permissions IS
'Defaults granted_by to the current session user when not provided on insert.';

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION rbac.auto_assign_user_role() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.prevent_user_role_deletion() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_assigned_by() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_granted_by() FROM PUBLIC;
