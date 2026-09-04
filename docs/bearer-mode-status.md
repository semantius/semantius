# Bearer mode status

**Status: experimental. Not a deployment target.** Last updated 2026-09-03.

Bearer mode is the deployment where a client connects to PostgreSQL 18
directly with an OAuth access token over SASL `OAUTHBEARER`, PostgreSQL
verifies the token in-database through a validator module, and the session
runs as the `authenticated` role with the identity pinned in `system_user`.
Session mode, the portable path, keeps PostgREST or your own app server in
front of the database and is what Supabase and Neon do. Wiring for both is in
[pgdocker/README.md](../pgdocker/README.md).

## Why bearer mode is experimental

Two facts about the ecosystem make it so, independent of anything in this
codebase:

1. **Neon and Supabase do not support bearer auth.** The `oauth` method in
   `pg_hba.conf` and the `oauth_validator_libraries` setting are server-side
   configuration that neither platform exposes, and neither ships a validator.
   Both authenticate with SCRAM behind their own proxy or pooler. Neon's
   answer to "the database verifies the user" is
   [`pg_session_jwt`](https://github.com/neondatabase/pg_session_jwt), which
   takes the token as a query parameter after a normal login, not as a SASL
   mechanism. So bearer mode runs only where you control `postgresql.conf`
   and `pg_hba.conf`: self-hosted PostgreSQL 18.
2. **No session pooler supports bearer auth.** PgBouncer's
   [`auth_type`](https://www.pgbouncer.org/config.html) accepts `cert`, `md5`,
   `scram-sha-256`, `plain`, `trust`, `any`, `hba`, `ldap` and `pam`; there
   is no OAuth value, no token passthrough, and no open issue asking for it
   (searched 2026-09-03). PgCat and Supavisor advertise nothing either. The
   obstacle is structural, not just missing code: `OAUTHBEARER` binds the
   identity to the server connection, so a transaction-mode pooler that
   multiplexes users onto one backend cannot preserve it. A pooler would have
   to hold one backend per distinct token or re-authenticate on every
   checkout. Until one does, bearer mode means one backend per user session,
   which rules it out for anything web-scale.

Three more reasons are ours to fix:

3. **The validator is a third-party compiled module.** PostgreSQL 18 ships the
   `oauth` method but no validator
   ([docs](https://www.postgresql.org/docs/18/auth-oauth.html)). We compile
   Percona's [`pg_oidc_validator`](https://github.com/percona/pg_oidc_validator)
   1.1.0 into the pgdocker image, plus a one-line patch that publishes the
   verified claims into `request.jwt.claims`. Upstream calls 1.0.0 its first
   stable release; it is still a dependency we build from source.
4. **The permission cache is bypassed in bearer sessions** (next section), so
   every permission check costs about a millisecond instead of tens of
   microseconds, and per-row workloads pay that per row.
5. **Only `sub` is trusted.** The `request.jwt.claims` setting published by the
   validator patch is an ordinary user-settable GUC, so a bearer client can
   rewrite `email`, `name` and any other claim. `rbac.uid()` takes the subject
   from `system_user`, which the client cannot touch, and everything that
   must be trusted is derived from that subject and the `users` row.

Bearer mode graduates when 1 and 2 have changed in the ecosystem and 3 to 5
are closed here. Tracking links are at the end.

## What is disabled in bearer sessions and why

`rbac.ensure_context_initialized()` resolves the caller once per transaction
and caches the result in transaction-local settings: `app.current_user_id`,
`app.current_external_id`, `app.user_permissions`, `app.context_initialized`.
Every later check reads those settings back. Custom settings have no owner:
whoever holds the session can overwrite them, and `has_permission` cannot tell
a value written by rbac from one written by the client. Behind PostgREST or an
app server that is harmless, because the client never runs SQL. In session
mode an attacker with SQL access can already rewrite the `sub` claim (release
review S14), so the cache adds nothing for them. In a bearer session the
client does run SQL while the identity is pinned, so the cache was the one
remaining way to escalate: a correctly identified user1 could write `admin`
into `app.user_permissions`. This is release review finding S2. For regular
configurations, PostgREST and app-server sessions, S2 is solved: the cache is
unreachable there. What remains is bearer-only and is tracked in this file.

What changed on 2026-09-03:

- `rbac.is_bearer_session()` returns true when `system_user LIKE 'oauth:%'`.
- `rbac.ensure_context_initialized()` skips its "already initialized" shortcut
  in bearer sessions and re-derives the context on every call. It raises one
  WARNING per session:
  `pg_semantius: OAuth bearer session detected; the transaction-scoped
  permission cache is disabled because app.* settings are client-writable in
  direct SQL sessions. Permissions are re-resolved on every check until the
  cache is hardened for bearer auth (release review S2).`
- The two readers that took `app.current_user_id` raw, `audit.current_user_id()`
  and the generated compute/validate trigger, now derive the id through
  `rbac.user_id_or_null()`, so a hand-written setting never reaches `$user_id`
  or audit attribution in any mode.
- `rbac.whoami()` reports `status / permission_cache` as `enabled` or
  `disabled (bearer session)`.

Nothing changed for session mode or PostgREST; the cache still works there.

Cost per permission check, measured warm on PostgreSQL 18 with the Northwind
sample as user3:

| Path | Cost |
|---|---|
| cached check (session mode) | 0.025 ms |
| uncached rebuild (bearer mode): `uid()` + user lookup + full permission list | about 1 ms |
| user lookup alone (`get_user_by_external_id`) | 0.1 ms |
| single-permission query instead of the full list (`user_has_permission`) | 0.6 ms |

Once per statement this is fine. Per row it is not: select-rule policies and
the validation, RACI and bookmark row triggers pay it per row in bearer mode.

How to verify, against the pgdocker CLI stack with `_core,nwind,test` deployed:

```sh
cd pgdocker
deno run --allow-net verify_oauth.ts          # token accepted, system_user = oauth:<sub>
deno run --allow-net test_oauth_security.ts   # forged sub claim ignored
deno run --allow-net test_bearer_cache.ts     # forged app.* cache ignored, WARNING once
```

`apps/test/tests/0435_test_bearer_context_bypass.sql` pins the parts pgTAP can
reach (pgTAP cannot open an OAuth session). The whole suite was also run once
with the detector forced on; everything passed except the assertions that say
the session is not a bearer session.

## Ways to bring the cache back

The cache is only as trustworthy as the place it is stored, and settings are
writable by whoever holds the session. There are exactly three places a
derived value can live that the client cannot write, and one future one:

| Option | Runs where | What it needs | Verdict |
|---|---|---|---|
| A. HMAC-signed settings (SQL only) | everywhere, including read-only PostgREST transactions | one secret row, pgcrypto (already required) | **recommended**; detailed below |
| B. Own guard extension: a superuser-context GUC | self-hosted only (needs `shared_preload_libraries`) | a 30-line C library built like the validator | cleanest for a self-hosted appliance; detailed below |
| C. Definer-owned `pg_temp` table | bearer sessions only (read-write SQL) | DDL on first use, audit trigger must skip `pg_temp` | works, but adds DDL per session; not pursued |
| D. Core session variables (`CREATE VARIABLE`, `LET`, with GRANT) | a future PostgreSQL | nothing | the native answer; missed 19, now in the PostgreSQL 20 commitfest |

Extensions that exist today do not cover this. `pg_oidc_validator` and
`pg_session_jwt` protect identity and claims; the Supabase pattern carries
roles inside the signed JWT and keeps no database-side cache. Bearer mode
already has identity. What is forgeable is a value our own SQL computes from
`user_roles` and `permission_hierarchy`, and no validator ever sees it.

## A. The HMAC-signed context, in detail

Keep the settings-based cache and its speed, make it unforgeable. The client
can still write the settings, but cannot produce the checksum that goes with
them, because the key is in `_settings`, which the request role cannot read.
An HMAC gives exactly the property needed: seeing valid (content, checksum)
pairs does not let you forge a checksum for different content.

### 1. Secret

New migration (for example `0300_context_signing.sql`):

```sql
INSERT INTO _settings (name, value)
VALUES ('rbac_context_secret', encode(gen_random_bytes(32), 'hex'))
ON CONFLICT (name) DO NOTHING;
```

`_settings` is deny-all for `semantius_user` and read only through SECURITY
DEFINER code. Since the 2026-09-03 extension rebuild it is an ordinary table
on both install paths — never an extension member — so `pg_dump` carries its
rows by default and no `pg_extension_config_dump` registry is involved;
the secret survives dump and restore. Rotating the row invalidates every
in-flight cache, which only forces a rebuild. If the row is missing, the
signer returns NULL and the cache is never trusted, so a broken install
degrades to "slow", never to "open".

### 2. Signer

```sql
CREATE OR REPLACE FUNCTION rbac.context_mac(
    p_external_id TEXT, p_user_id INTEGER, p_permissions TEXT, p_scopes TEXT
) RETURNS TEXT AS $$
DECLARE
    v_secret TEXT;
BEGIN
    SELECT value INTO v_secret FROM _settings WHERE name = 'rbac_context_secret';
    IF v_secret IS NULL OR v_secret = '' THEN
        RETURN NULL;
    END IF;
    RETURN encode(hmac(
        concat_ws(E'\x1f', p_external_id, p_user_id::text,
                  coalesce(p_permissions, ''), coalesce(p_scopes, ''),
                  now()::text, pg_backend_pid()::text),
        v_secret, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

REVOKE EXECUTE ON FUNCTION rbac.context_mac(TEXT, INTEGER, TEXT, TEXT)
    FROM PUBLIC, semantius_user;
```

`now()` is the transaction start time and `pg_backend_pid()` the session, so a
checksum captured in one transaction is useless in the next; a user whose
role was revoked cannot replay yesterday's cache. The unit separator keeps
field boundaries unambiguous.

This function is the only thing that must never be callable by the request
role; with it, a client could sign any payload. The explicit REVOKE is
required because the default privileges in `0030_rbac_functions.sql` grant
every new `rbac` function to `semantius_user`. The guard test
`0060_test_security.sql` requires SECURITY DEFINER functions to call
`rbac.uid()`; add `context_mac` and `write_context` to its exception list and
add an assertion that neither is executable by `semantius_user`.

### 3. One writer

```sql
CREATE OR REPLACE FUNCTION rbac.write_context(
    p_external_id TEXT, p_user_id INTEGER, p_permissions TEXT, p_scopes TEXT DEFAULT NULL
) RETURNS void AS $$
BEGIN
    PERFORM set_config('app.current_user_id',     p_user_id::text, true);
    PERFORM set_config('app.current_external_id', p_external_id, true);
    PERFORM set_config('app.user_permissions',    coalesce(p_permissions, ''), true);
    PERFORM set_config('app.oauth_scopes',        coalesce(p_scopes, ''), true);
    PERFORM set_config('app.context_mac',
        coalesce(rbac.context_mac(p_external_id, p_user_id,
                                  coalesce(p_permissions, ''), coalesce(p_scopes, '')), ''),
        true);
    PERFORM set_config('app.context_initialized', 'true', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

REVOKE EXECUTE ON FUNCTION rbac.write_context(TEXT, INTEGER, TEXT, TEXT)
    FROM PUBLIC, semantius_user;
```

Replace the hand-rolled writers with a call to it: the tail of
`ensure_context_initialized` in `0030` and the two `get_userinfo` bodies in
`0080` and `0190` (they pre-fill the cache
because a just-created user is not yet visible to the STABLE checkers in the
same statement).

### 4. Verifier

```sql
-- 'absent'  : nothing cached, rebuild
-- 'valid'   : checksum and subject match, trust it
-- 'invalid' : a checksum exists but does not match, or the subject changed
CREATE OR REPLACE FUNCTION rbac.context_state() RETURNS TEXT AS $$
DECLARE
    v_mac TEXT := current_setting('app.context_mac', true);
BEGIN
    IF v_mac IS NULL OR v_mac = '' THEN
        RETURN 'absent';
    END IF;
    IF v_mac = rbac.context_mac(
            current_setting('app.current_external_id', true),
            nullif(current_setting('app.current_user_id', true), '')::integer,
            current_setting('app.user_permissions', true),
            current_setting('app.oauth_scopes', true))
       AND current_setting('app.current_external_id', true) = rbac.uid() THEN
        RETURN 'valid';
    END IF;
    RETURN 'invalid';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;
```

In `ensure_context_initialized`, replace the shortcut
`IF v_initialized = 'true' THEN RETURN` and the bearer bypass with:

```sql
    CASE rbac.context_state()
        WHEN 'valid' THEN RETURN;
        WHEN 'invalid' THEN
            RAISE EXCEPTION 'Request context was modified outside rbac'
                USING ERRCODE = 'insufficient_privilege';
        ELSE NULL;  -- absent: fall through and rebuild
    END CASE;
```

Failing closed on `invalid` matters for scopes: a tampered cache that merely
triggered a rebuild would come back without scopes, which is the S12 trick in
a new costume. The legitimate ways the context changes inside a transaction
all go through `write_context` and stay valid. The test harness's
`authenticate_as` clears the settings when it switches users; it must clear
`app.context_mac` as well, which turns the state into `absent`.

With the checksum in place, `rbac.is_bearer_session()` stays for `whoami` and
the WARNING goes away: bearer sessions use the cache like everyone else.

### 5. Scopes inside the signature (release review S12)

Scopes are part of the signed payload, comma-delimited everywhere. Change the
space-delimited lookup in `user_has_permission` to a comma. `set_request_context`
was removed on 2026-09-03 (release review S3), so scopes need a new definer
entry point, say `rbac.set_request_scopes(p_oauth_scopes)`, that takes no
identity parameter: normalize the list (split on comma or space, trim, sort,
join with comma) and apply a narrow-only rule: if the current
context is `valid` and already carries scopes, the new set is the
intersection, never a replacement. A scoped session can then neither clear
nor widen its confinement.

### 6. Identity binding (release review S3)

Done on 2026-09-03 by removal: `set_request_context` no longer exists in
`0030` or `0190` (nothing called it). The scope entry point of step 5 must
not grow an identity parameter; the subject is always `rbac.uid()`.

### 7. Readers stay as they are

Every checker already calls `ensure_context_initialized` first and reads the
settings inside the same function body, where the client cannot interleave a
statement. `rbac.user_id_or_null()` stays for triggers and audit.

### 8. Cost

One primary-key lookup on `_settings` plus one HMAC per check, a few
microseconds. Pay for it with release review P3: remove the duplicated
`PERFORM rbac.uid()` in each checker, read `system_user` as an expression
instead of `SELECT ... INTO`, and fetch `jwt_aud` and the secret in one
`_settings` query.

### 9. Tests

Extend `0435`:

- forged settings with no checksum: `has_permission('admin')` false, state `absent`;
- a genuine checksum with a tampered permission list: state `invalid`, the next check raises 42501;
- a checksum captured in one transaction and replayed in the next: `invalid`;
- the secret row deleted: state `absent` on every call, results still correct;
- a scoped session calling the scope entry point with an empty or wider list: scopes unchanged.

Move the scope groups of `0405_test_rbac_helpers.sql` from `set_config` to
the scope entry point. `pgdocker/test_bearer_cache.ts` must stay green minus
its WARNING assertion, which flips to "no WARNING".

## B. The alternative: our own guard extension

PostgreSQL lets a loaded C library define settings with a stricter context
than the placeholder `app.*` settings get. A superuser-context setting can
only be set by superusers and by roles that were granted `SET` on it
(PostgreSQL 15 and later). Our SECURITY DEFINER writers run as
`semantius_owner`, so grant it to that role and the cache becomes
unwritable for the request role without any secret or checksum.

```c
/* pg_semantius_guard.c */
#include "postgres.h"
#include "fmgr.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

static char *semantius_context = NULL;

void _PG_init(void)
{
    DefineCustomStringVariable("semantius.context",
        "Request context written by rbac SECURITY DEFINER code",
        NULL, &semantius_context, "",
        PGC_SUSET, 0, NULL, NULL, NULL);
    MarkGUCPrefixReserved("semantius");
}
```

Deployment: build with PGXS like the validator (same Dockerfile pattern), add
`pg_semantius_guard` to `shared_preload_libraries`, then in a migration:

```sql
GRANT SET ON PARAMETER semantius.context TO semantius_owner;
```

`write_context` then does `set_config('semantius.context', payload, true)`
with the payload `external_id|user_id|permissions|scopes`; readers use
`current_setting('semantius.context', true)`. A request-role client that
tries the same gets `42501 permission denied to set parameter
"semantius.context"`, and any other `semantius.*` name is rejected because
the prefix is reserved. Cost per check: one setting read.

Trade-offs against A:

- Needs `postgresql.conf` access and a compiled artifact per PostgreSQL major.
  That is the same constraint bearer mode already has, so for a self-hosted
  appliance it is the better design.
- Impossible on Neon and Supabase, where S2 is unreachable anyway because
  PostgREST never lets the client run SQL. So a product that must run there
  either ships A everywhere or maintains both paths.
- Nothing to rotate, nothing to sign, no `_settings` dependency, no replay
  question, and `pg_dump` has no secret to leak.

If bearer mode is ever promoted for self-hosted only, B is the one to build.
If it is promoted alongside Neon and Supabase, A.

## Tracking

Ecosystem items that change the status above:

- PostgreSQL session variables (option D): commitfest entry
  [Declarative session variables, LET command](https://commitfest.postgresql.org/patch/1608/),
  Pavel Stehule, status "Needs review", moved through the PostgreSQL 19
  commitfests and now listed in PG20-1; design notes on the
  [wiki](https://wiki.postgresql.org/wiki/Implementation_of_declarative_catalog_session_variables).
  Variables would be catalog objects with ACLs, so a variable that only
  `semantius_owner` may `LET` would replace both A and B.
- PgBouncer OAuth: no issue exists yet ([issues](https://github.com/pgbouncer/pgbouncer/issues),
  [changelog](https://www.pgbouncer.org/changelog.html)). Worth opening one
  that asks for `OAUTHBEARER` passthrough and describes the per-token backend
  requirement, so there is something to watch.
- Driver support, as a proxy for ecosystem maturity:
  [pgjdbc #3816](https://github.com/pgjdbc/pgjdbc/issues/3816) (open since
  2025-09-26) and [pgadmin4 #9951](https://github.com/pgadmin-org/pgadmin4/issues/9951)
  (`libpq-oauth` missing from the image). PostgreSQL's own client side is
  the `libpq-oauth` module that ships with 18.
- Validator: [pg_oidc_validator releases](https://github.com/percona/pg_oidc_validator/releases)
  and the [announcement](https://www.postgresql.org/about/news/announcing-pg_oidc_validator-3160).
  We pin 1.1.0 in `pgdocker/Dockerfile` and both compose files; the claims
  patch lives in `pgdocker/patches/`.
- Server side: the [OAuth authentication chapter](https://www.postgresql.org/docs/18/auth-oauth.html)
  and the commit that added the mechanism,
  [b3f0be7](https://github.com/postgres/postgres/commit/b3f0be788afc17d2206e1ae1c731d8aeda1f2f59).

## Related

- Authorization spec: [authz-spec.md](authz-spec.md), invariant I-perm.
- pgdocker: [README.md](../pgdocker/README.md), sections "Identity comes from
  the validated session" and "Scalability & production caveats".
