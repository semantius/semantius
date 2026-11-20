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
-- BYPASSRLS and fail much later, in the dictionary's definer code.
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.auto_assign_user_role() TO semantius_user;

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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.prevent_user_role_deletion() TO semantius_user;

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
-- 0160_dd_functions.sql: a direct connection as a role with BYPASSRLS may still
-- empty the administrator set, which is how a database is repaired and how a
-- test builds a system that has never had one. A superuser without the
-- attribute is not exempt. It gives away nothing - such a connection already
-- holds everything the extension protects. It is also the only exemption, and
-- that is the load-bearing part.
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
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.count_enabled_administrators() TO semantius_user;

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
                      'hint', 'Grant the Administrator role to another enabled user first. A direct connection as a role with BYPASSRLS is exempt from this check.')::text;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.assert_administrator_remains() TO semantius_user;

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

-- An UPDATE reaches the same state as a DELETE: the last Administrator's
-- assignment pointed at another role, or at a user who is disabled. The count
-- runs after the statement, so an UPDATE that leaves an enabled holder of
-- role 2 is ordinary.
CREATE OR REPLACE TRIGGER assert_administrator_remains_on_user_roles_update
    AFTER UPDATE ON user_roles
    FOR EACH STATEMENT
    EXECUTE FUNCTION rbac.assert_administrator_remains();

COMMENT ON TRIGGER assert_administrator_remains_on_user_roles_update ON user_roles IS
'Refuses an UPDATE that points the last enabled Administrator''s assignment at another role or user.';

-- An Administrator is a holder of role 2, and role 2 is what it is because it
-- grants `admin`. The count above looks at who holds the role. This guard
-- keeps the grant: with it gone every holder of role 2 is counted and none
-- can administer anything. It watches the grant row itself and the permission
-- the row names, because role_permissions follows a delete and a rename of
-- the permission by cascade, and a cascade runs as the table's owner, who is
-- exempt like every BYPASSRLS connection.
--
-- BEFORE and per row, not after the statement: the foreign keys from entities
-- to permissions refuse the delete of `admin` as well, and they answer before
-- a statement trigger would, with an error that does not say why.
CREATE OR REPLACE FUNCTION rbac.assert_administrator_grant_remains()
RETURNS TRIGGER AS $$
DECLARE
    v_lost BOOLEAN;
BEGIN
    IF (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'role_permissions' THEN
        v_lost := OLD.role_id = 2 AND OLD.permission_name = 'admin'
                  AND (TG_OP = 'DELETE' OR NEW.role_id <> 2 OR NEW.permission_name <> 'admin');
    ELSE
        v_lost := OLD.permission_name = 'admin'
                  AND (TG_OP = 'DELETE' OR NEW.permission_name <> 'admin');
    END IF;

    IF v_lost THEN
        RAISE EXCEPTION 'The Administrator role has to keep the admin permission'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object(
                      'code', '90108',
                      'hint', 'Role 2 granting admin is what makes its holders Administrators. A direct connection as a role with BYPASSRLS is exempt from this check.')::text;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.assert_administrator_grant_remains() TO semantius_user;

REVOKE EXECUTE ON FUNCTION rbac.assert_administrator_grant_remains() FROM PUBLIC;

COMMENT ON FUNCTION rbac.assert_administrator_grant_remains IS
'Row-level guard on role_permissions and permissions: refuses removing or re-pointing the grant of admin to role 2, and deleting or renaming the permission admin (42501, hint.code 90108). SECURITY INVOKER so the BYPASSRLS exemption tests the real caller.';

CREATE OR REPLACE TRIGGER assert_administrator_grant_remains
    BEFORE DELETE OR UPDATE OF role_id, permission_name ON role_permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.assert_administrator_grant_remains();

CREATE OR REPLACE TRIGGER assert_administrator_permission_remains
    BEFORE DELETE OR UPDATE OF permission_name ON permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.assert_administrator_grant_remains();

COMMENT ON TRIGGER assert_administrator_grant_remains ON role_permissions IS
'Refuses a DELETE or UPDATE that takes admin from the Administrator role.';
COMMENT ON TRIGGER assert_administrator_permission_remains ON permissions IS
'Refuses a DELETE or rename of the permission admin, which would take it from the Administrator role by cascade.';

-- =====================================================
-- GUARD: external_id is written by an administrator only
-- =====================================================
-- external_id is the identity: a request is whoever's row carries the token's
-- sub claim (rbac.uid). Writing it is therefore not user administration but a
-- change of who a principal is. A caller who moves an administrator's
-- external_id to a sub it controls is that administrator at its next request,
-- without touching user_roles; one who inserts a row under the sub of a person
-- who has not signed in yet is that person from their first request on.
-- `user:manage` opens the users table for writing, so it must not be enough
-- for this one column: only a holder of `admin` chooses an external_id.
--
-- What stays possible without `admin`:
--   * an UPDATE that sends external_id back unchanged, which is what a client
--     that saves a whole record does;
--   * an INSERT that sends none. An agent then gets a generated one from
--     assign_agent_external_id_trigger (0370_raci.sql); a person's row is
--     refused by the column's NOT NULL, because a person's row is made by the
--     sign-in or by an administrator.
--
-- The sign-in (get_userinfo) writes as the owner of the dictionary code, and
-- the owner is exempt here as it is from every guard on these tables, so a
-- first login still creates its row. SECURITY INVOKER for that reason: the
-- BYPASSRLS test has to see the role the write really runs as.
CREATE OR REPLACE FUNCTION rbac.assert_external_id_writer()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.external_id IS NOT DISTINCT FROM OLD.external_id THEN
            RETURN NEW;
        END IF;
    ELSIF NEW.external_id IS NULL OR btrim(NEW.external_id) = '' THEN
        RETURN NEW;
    END IF;

    IF (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
        RETURN NEW;
    END IF;

    IF rbac.has_permission('admin') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Permission denied: only an administrator can set the external_id of a user'
        USING ERRCODE = 'insufficient_privilege',
              HINT = jsonb_build_object(
                  'code', '90107',
                  'hint', 'external_id is the identity a session resolves to. Send it unchanged, or leave it out, to save the rest of the record.')::text;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.assert_external_id_writer() TO semantius_user;

-- The request role keeps EXECUTE: it is the invoker, and the trigger is
-- useless if the caller cannot run it.
REVOKE EXECUTE ON FUNCTION rbac.assert_external_id_writer() FROM PUBLIC;

COMMENT ON FUNCTION rbac.assert_external_id_writer IS
'Row-level guard on users: refuses an INSERT that brings an external_id and an UPDATE that changes one unless the caller holds admin (42501, hint.code 90107). SECURITY INVOKER so the BYPASSRLS exemption tests the real caller.';

-- BEFORE INSERT triggers fire in name order, and this name sorts before
-- assign_agent_external_id_trigger on purpose: here an external_id on the new
-- row is still one the caller sent, not one the table assigned.
CREATE OR REPLACE TRIGGER assert_external_id_writer_trigger
    BEFORE INSERT OR UPDATE OF external_id ON users
    FOR EACH ROW
    EXECUTE FUNCTION rbac.assert_external_id_writer();

COMMENT ON TRIGGER assert_external_id_writer_trigger ON users IS
'Refuses a chosen external_id on INSERT and a changed one on UPDATE from a caller without admin.';

-- =====================================================
-- TRIGGER: Default assigned_by to current user
-- =====================================================
-- When a user_role record is inserted without an assigned_by value,
-- automatically set it to the current user ID from the session context

-- A trigger rather than a column default because it also fills an explicit NULL.
-- rbac.user_id_or_null() is the one place that resolves the user, and gives NULL in
-- a session without one (a migration, a seed script).
CREATE OR REPLACE FUNCTION rbac.default_assigned_by()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.assigned_by IS NULL THEN
        NEW.assigned_by := rbac.user_id_or_null();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.default_assigned_by() TO semantius_user;

COMMENT ON FUNCTION rbac.default_assigned_by IS
'Trigger function to default assigned_by to the current user ID when not explicitly provided.';

CREATE OR REPLACE TRIGGER default_assigned_by_trigger
    BEFORE INSERT ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_assigned_by();

COMMENT ON TRIGGER default_assigned_by_trigger ON user_roles IS
'Defaults assigned_by to the current session user when not provided on insert.';

-- =====================================================
-- TRIGGER: Default granted_by to current user, for role_permissions and
-- user_permissions
-- =====================================================

-- As rbac.default_assigned_by.
CREATE OR REPLACE FUNCTION rbac.default_granted_by()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.granted_by IS NULL THEN
        NEW.granted_by := rbac.user_id_or_null();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public, pg_temp;
GRANT EXECUTE ON FUNCTION rbac.default_granted_by() TO semantius_user;

COMMENT ON FUNCTION rbac.default_granted_by IS
'Trigger function to default granted_by to the current user ID when not explicitly provided.';

CREATE OR REPLACE TRIGGER default_granted_by_trigger
    BEFORE INSERT ON user_permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_granted_by();

COMMENT ON TRIGGER default_granted_by_trigger ON user_permissions IS
'Defaults granted_by to the current session user when not provided on insert.';

CREATE OR REPLACE TRIGGER default_granted_by_trigger
    BEFORE INSERT ON role_permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_granted_by();

COMMENT ON TRIGGER default_granted_by_trigger ON role_permissions IS
'Defaults granted_by to the current session user when not provided on insert.';

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION rbac.auto_assign_user_role() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.prevent_user_role_deletion() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_assigned_by() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_granted_by() FROM PUBLIC;
