-- Test JWT audience (aud) claim validation via _settings.jwt_aud
--
-- The row is optional by design: without it rbac.uid() accepts any token from
-- the trusted issuer, which is also what Neon does when a provider's audience
-- is left blank. What the install owes the operator is therefore not
-- enforcement but visibility, and semantius.status() is where that lives.
BEGIN;

SELECT plan(9);

-- semantius.status() exists only on the extension install path, and its name is
-- resolved when a statement is PARSED, so naming it directly would make this
-- whole file fail on the migrate path where the schema is absent. These
-- wrappers defer resolution to EXECUTE and return NULL when it is not there.
CREATE FUNCTION pg_temp.ext_status_jwt_aud_set() RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE v boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius') THEN
    RETURN NULL;
  END IF;
  EXECUTE 'SELECT jwt_aud_set FROM semantius.status()' INTO v;
  RETURN v;
END
$fn$;

CREATE FUNCTION pg_temp.ext_status_default_acls_ok() RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE v boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius') THEN
    RETURN NULL;
  END IF;
  EXECUTE 'SELECT default_acls_ok FROM semantius.status()' INTO v;
  RETURN v;
END
$fn$;

CREATE FUNCTION pg_temp.ext_status_db_version() RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius') THEN
    RETURN NULL;
  END IF;
  EXECUTE 'SELECT db_version FROM semantius.status()' INTO v;
  RETURN v;
END
$fn$;

-- =====================================================
-- TEST a) No jwt_aud entry in _settings → auth works normally
-- =====================================================

SELECT authenticate_as('user1');

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when no jwt_aud setting is present'
);

-- =====================================================
-- Setup: insert jwt_aud into _settings (requires superuser / BYPASSRLS),
-- then switch back to semantius_user manually so that subsequent SET ROLE
-- calls don't trigger the users-table RLS before the aud claim is set.
-- =====================================================

RESET ROLE;

-- status() is REVOKEd from PUBLIC, so these four run here as the installer -
-- after the RESET ROLE and before the SET ROLE below, not under a request
-- identity.

-- Every skip below tests for the absent schema as well as the NULL return. A
-- NULL alone would also be what a status() that stopped emitting its row
-- returns, and that would turn a real failure into a green "skipped" on the
-- extension path - which is exactly how db_version stayed NULL unnoticed.
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius')
    THEN pass('migrate path: semantius.status() absent, jwt_aud_set check skipped')
    ELSE is(pg_temp.ext_status_jwt_aud_set(), false,
            'status() reports jwt_aud_set = false while the row is absent') END;

INSERT INTO _settings (name, value) VALUES ('jwt_aud', 'myapp');

SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius')
    THEN pass('migrate path: semantius.status() absent, jwt_aud_set check skipped')
    ELSE is(pg_temp.ext_status_jwt_aud_set(), true,
            'status() reports jwt_aud_set = true once the row is written') END;

-- The claim that removing the table and sequence default privileges from
-- `public` did not change what default_acls_ok means: the rows it counts are
-- the installing role's own function and rbac entries, which stay.
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius')
    THEN pass('migrate path: semantius.status() absent, default_acls_ok check skipped')
    ELSE ok(pg_temp.ext_status_default_acls_ok(),
            'status() still reports default_acls_ok with no table or sequence defaults left') END;

-- db_version reads _settings by its real column name. It was reading a column
-- that does not exist, inside an exception block that swallowed the error, so
-- the column was silently NULL on every install.
INSERT INTO _settings (name, value) VALUES ('db_version', '9.9.9-probe')
ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;

SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius')
    THEN pass('migrate path: semantius.status() absent, db_version check skipped')
    ELSE is(pg_temp.ext_status_db_version(), '9.9.9-probe',
            'status() reads db_version from the _settings row') END;

-- Restore the semantius_user role and search_path (JWT claims from the
-- previous authenticate_as call are still in effect via SET LOCAL).
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- =====================================================
-- TEST b) aud matches single plain-string value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', 'myapp', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when aud matches the required single value'
);

-- =====================================================
-- TEST c) aud is a JSON array and contains the required value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', '["myapp","other"]', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when aud array contains the required value'
);

-- =====================================================
-- TEST d) aud is a plain string that does NOT match
-- =====================================================

SELECT set_config('request.jwt.claim.aud', 'wrongapp', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT throws_ok(
    $$ SELECT rbac.uid() $$,
    '42501',
    NULL,
    'uid() fails when aud single value does not match'
);

-- =====================================================
-- TEST e) aud is a JSON array with no matching value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', '["wrongapp","notmyapp"]', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT throws_ok(
    $$ SELECT rbac.uid() $$,
    '42501',
    NULL,
    'uid() fails when none of the aud array values match'
);

SELECT * FROM finish();
ROLLBACK;
