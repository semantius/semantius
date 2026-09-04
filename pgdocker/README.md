# PostgreSQL 18 + OAuth/JWT — self-host target for Semantius Core

A Docker image and Compose stack that runs **PostgreSQL 18** preconfigured as a
third deployment target for Semantius Core — alongside Supabase and Neon — so
you can self-host on any PostgreSQL 18+ server **without** a managed provider.

It does three things:

1. **A full-DBA login** (`postgres`, password/SCRAM) — what `DATABASE_URL`
   points at for deploying migrations and admin (the Semantius CLI, `psql`, …).
2. **`bearer` mode — OAuth/JWT auth for application connections** — clients present
   an OIDC access token; PostgreSQL verifies it natively (SASL `OAUTHBEARER`)
   against the issuer's JWKS and maps it to the **`authenticated`** role — the
   *same* role name Supabase and Neon use for authenticated end users. The DB
   verifies the signature.
3. **`session` mode — the Supabase/Neon model** — the app (having already verified
   the JWT itself) connects as a restricted login role **`semantius_authenticator`**
   and, per transaction, does `SET LOCAL ROLE authenticated` + injects the verified
   claims into `request.jwt.claims`. The DB does **not** verify the signature here —
   the app is the trust boundary. See [Session mode](#session-mode).

The two modes are selected by the sample apps via `DB_AUTH_MODE = bearer | session`.

> ⚠️ The OAuth validator (`pg_oidc_validator`) is pinned to its **1.1.0 release**
> (upstream calls 1.0.0 the first stable release). Semantius **bearer mode** is
> still experimental on our side: a bearer client runs SQL as the request role,
> so the `app.*` permission cache is bypassed in those sessions (see
> "Per-request permission resolution" below). Treat bearer mode as a working
> starting point, not a hardened deploy. Status, graduation criteria and the
> hardening plan: [docs/bearer-mode-status.md](../docs/bearer-mode-status.md).

---

## How it actually works (read this first)

PostgreSQL 18 added native OAuth via SASL `OAUTHBEARER`, **but the server does
not validate tokens itself and ships no built-in validator.** You must load a
validator module. This image compiles Percona's
[`pg_oidc_validator`](https://github.com/percona/pg_oidc_validator), which:

- resolves the issuer's JWKS via `<issuer>/.well-known/openid-configuration` →
  `jwks_uri`,
- verifies each access token's RS256 signature against those keys, and
- extracts the identity claim (default `sub`) so PostgreSQL can map it to a role.

### The roles

| Role            | Auth method        | Used by                              | LOGIN |
| --------------- | ------------------ | ------------------------------------ | ----- |
| `postgres`      | password (SCRAM)   | migrations / admin (`DATABASE_URL`)  | yes   |
| `authenticated` | OAuth (`OAUTHBEARER`) | `bearer`-mode end-user connections + the `SET ROLE` target in `session` mode | yes (local) |
| `semantius_authenticator` | password (SCRAM) | `session`-mode app connections — can only `SET ROLE authenticated` | yes (local) |
| `semantius_user` | — (NOLOGIN group) | internal: holds the table/schema grants; all RLS policies are `TO semantius_user` | no |

`authenticated` is created with **`LOGIN`** ([init/10-roles.sql](init/10-roles.sql)).
This differs from the Supabase/Neon **PostgREST** model, where `authenticated`
is `NOLOGIN` and PostgREST logs in as `authenticator` and `SET ROLE`s into it.
Here clients connect **directly** and authenticate *as* `authenticated`, so the
role must be able to log in. The Semantius core migrations create
`semantius_user`, grant it the table/schema privileges, then grant
`semantius_user` → `authenticated`, so `authenticated` inherits its runtime
rights from there.

### Identity → role mapping

[conf/pg_hba.conf](conf/pg_hba.conf) carries `map="oidc"`, and
[conf/pg_ident.conf](conf/pg_ident.conf) maps **every** validated token identity
to `authenticated`:

```
# MAPNAME   SYSTEM-USERNAME   PG-USERNAME
oidc        /^(.*)$           authenticated
```

The token's own `sub` still identifies the individual user to the application
via the JWT claims (next section).

### Claims in the session — published by the bundled validator patch

PostgreSQL's stock OAuth interface only surfaces the *identity* (`authn_id` →
`system_user`); the rest of the verified claims are discarded. Semantius RLS,
however, reads the user from the GUC `request.jwt.claims`, exactly as PostgREST
sets it on Supabase/Neon. So this image ships a one-line patch to the validator
— [patches/0001-publish-jwt-claims.patch](patches/0001-publish-jwt-claims.patch)
— that publishes the **full, signature-verified payload** into
`request.jwt.claims` at connect time:

```cpp
res->authn_id = pstrdup(payload.at(authn_field).to_str().c_str());
SetConfigOption("request.jwt.claims",
                picojson::value(payload).serialize().c_str(),
                PGC_USERSET, PGC_S_SESSION);   // <- the patch
```

The GUC survives into the session (verified — see below), so **OAuth
connections work with RLS out of the box**, with no application cooperation:

```
$ deno run --allow-net verify_oauth.ts
AuthenticationOk: OAUTHBEARER token accepted
OK  current_user=authenticated  system_user=oauth:user1
    request.jwt.claims = {"sub":"user1","role":"authenticated","email":"user@test.com", ...}
```

`rbac.uid()` requires `role = 'authenticated'` and a non-empty `sub`; the test
tokens carry both, so it just works — no app step, no extension.

### Identity comes from the validated session, not the claims

Because clients connect **directly** (no PostgREST in between), `request.jwt.claims`
is set within the session and so is treated as a convenience, not proof of identity.
For OAuth sessions, core's `rbac.uid()` takes the subject from `system_user`
(`oauth:<sub>`, which PostgreSQL validated from the bearer token and a client cannot
forge), ignoring any client-set `sub`. (The Supabase/Neon PostgREST path,
`system_user = scram-sha-256:authenticator`, is unaffected.) Writes to the `users`
table additionally require the `user:manage` permission via RLS, so only admins can
change user rows; first-login provisioning runs through a `SECURITY DEFINER` function
that only ever touches the caller's own row.

> **Why not `pg_session_jwt`?** That Neon extension *re-validates* a raw JWT
> injected into a session var and exposes it via `auth.user_id()`. Here the
> token is already validated by PG18 OAuth (against the same JWKS), so it would
> be redundant — and it speaks a different claim API than the `request.jwt.*`
> convention this codebase (and the Neon **Data API** / Supabase) already uses.
> It fits Neon's proxy-injection model, not PG18 native OAuth.

---

## Session mode

`bearer` mode (above) is self-host-only and DB-verified. **`session` mode** is the
portable path — the *same* mechanism Supabase and Neon (Data API) use — so the
sample apps run unchanged on local pgdocker, Neon, and Supabase by flipping
`DB_AUTH_MODE = bearer | session`.

### The role: `semantius_authenticator`

Created by the **core migrations** ([../apps/_core/migrations/0011_session_authenticator.sql](../apps/_core/migrations/0011_session_authenticator.sql)),
so every deployment — local, Neon, Supabase — gets the *same* role automatically:

```sql
CREATE ROLE semantius_authenticator NOLOGIN NOSUPERUSER NOINHERIT;   -- migration (idempotent)
GRANT authenticated TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
```

`NOSUPERUSER NOINHERIT NOBYPASSRLS` ⇒ the role has **no privileges of its own** and
can do **nothing but `SET ROLE authenticated`** — a gatekeeper that *enforces* RLS
by `SET ROLE`-ing into an RLS-subject role; it never bypasses RLS. This is exactly
Supabase's `authenticator → authenticated` pattern (namespaced `semantius_*` so it
never collides with Supabase's own `authenticator`).

**LOGIN + password are set per-environment** (never in committed SQL), mirroring how
`authenticated` is created `NOLOGIN` in core and flipped to `LOGIN` by pgdocker:

- **Local pgdocker:** [init/11-session-role.sh](init/11-session-role.sh) reads
  `SEMANTIUS_AUTHENTICATOR_PASSWORD` (from `pgdocker/.env`) and sets LOGIN + password
  at first init. Default `devpassword` — **change it for anything shared/exposed.**
- **Managed (Neon/Supabase):** run the one-time setup task over the **owner** connection:
  ```bash
  SEMANTIUS_AUTHENTICATOR_PASSWORD='<a real secret>' deno task setup-session-role --env supabase
  ```
  ([scripts/setup-session-role.ts](../scripts/setup-session-role.ts) — idempotent;
  flips LOGIN + sets the password; never commits it).

### The per-request contract (what the app runs)

Having **already verified the JWT**, the app runs, per request/transaction:

```sql
BEGIN;
SET LOCAL ROLE authenticated;                              -- the identity role (member of semantius_user)
SELECT set_config('request.jwt.claims', $1::text, true);  -- LOCAL; inject BEFORE any rbac call
-- … queries …
COMMIT;
```

- **`SET ROLE` target is `authenticated`** (not `semantius_user`) — keeps
  `current_user = authenticated` consistent with `bearer` mode.
- **Ordering matters:** `rbac.uid()` is `STABLE` (cached per tx), so inject claims
  **before** the first rbac/RLS call. Use a fresh tx per identity.
- Both `SET LOCAL ROLE` and `set_config(…, true)` are **transaction-scoped** and
  auto-revert on COMMIT/ROLLBACK → **transaction-pooling-safe** (PgBouncer/Supavisor).
  Never use session-level `SET ROLE` / `set_config(…, false)` on the live path.
- **Minimal claims:** `{"sub":"…","role":"authenticated"}` (both required by
  `rbac.uid()`), plus `"email"` for first-login provisioning, plus `"aud"` only if
  `_settings.jwt_aud` is seeded (off by default).
- **First login:** call `public.get_userinfo()` once before other reads, or
  `ensure_context_initialized()` raises *"User not found"*. It works in session mode
  because `get_userinfo`/`upsert_user_from_jwt` are `SECURITY DEFINER` owned by the
  BYPASSRLS migration role — not because `semantius_authenticator` has any write grant.

### Trust model — who verifies the signature

For **RS256 tokens** (what the test issuer mints, and most IdPs default to):

| Path | Gate 1 (connect) | Signature verified in DB? | Net |
|------|------------------|---------------------------|-----|
| `bearer` (self-hosted PG18 / local) | the token itself (OAUTHBEARER) | ✅ `pg_oidc_validator` (RS256) | **DB-verified** |
| `session` (Supabase / Neon / self-hosted) | `semantius_authenticator` password | ❌ no off-the-shelf RS256 in-DB verifier | **app-verified** |

> **In `session` mode the app is the sole trust boundary on *every* backend**
> (Supabase, Neon, self-hosted) for RS256 tokens. The only off-the-shelf in-DB JWKS
> verifier, Neon's `pg_session_jwt`, is **Ed25519/EdDSA-only** (can't verify RS256),
> and Supabase can't install it anyway. So the DB does not verify the signature in
> session mode — the `semantius_authenticator` password **plus the app's own jose
> verification** are the protection. **For DB-enforced verification, use `bearer`.**

**The session adapter (in each sample) MUST:**

1. **Verify before inject, fail closed** — jose-verify against the remote JWKS,
   pinning `algorithms: ['RS256']`, checking `issuer` and `audience` (`aud` checking
   is mandatory). On *any* failure → reject (401); never inject; never fall back to a
   stale keyset. Fail-open is forbidden.
2. **Inject the verified payload**, not a re-decode; set `role:'authenticated'`
   server-side, never trusted from the token.
3. **Only inside a transaction** — throw if not in a tx (never session-level `SET ROLE`).
4. **Refuse a superuser/owner connection at startup** — `SELECT rolsuper, rolbypassrls`
   for `current_user`; refuse to start if either is true (catches a `DATABASE_URL`
   accidentally pointing at `postgres`/owner, which silently bypasses RLS).

> ⚠️ **The only RLS-bypass risk on a managed platform is connecting as the
> `postgres`/project-owner role instead of `semantius_authenticator`.** The owner is
> a superuser/BYPASSRLS and will **silently return all rows**. Always use the
> `semantius_authenticator` connection string for app traffic.

> ⚠️ **First user becomes Administrator.** On a fresh database the *first* provisioned
> user is auto-assigned the **Administrator** role (`rbac.auto_assign_user_role`), in
> both modes. Provision your intended admin first.

### Testing session mode

[verify_session.ts](verify_session.ts) and [test_session_trust.ts](test_session_trust.ts)
(shared helpers in [session_helpers.ts](session_helpers.ts)) use the standard SCRAM
driver (`deno.land/x/postgres`, already locked) — the hand-rolled transport in
`verify_oauth.ts` is OAUTHBEARER-only:

```bash
deno run --allow-net --allow-env --allow-read verify_session.ts        # 5432
deno run --allow-net --allow-env --allow-read test_session_trust.ts --port 5433
```

- **verify_session.ts** — guardrail (role is NOT superuser/bypassrls) → first-login
  provisioning via `get_userinfo()` → positive RLS path (`rbac.uid()` + a `users` read).
- **test_session_trust.ts** — asserts the trust model (injected `sub` is authoritative
  in session mode — the app is the trust boundary) plus three negatives: bare role
  denied (NOINHERIT), no-claims rejected, `role != authenticated` rejected.

`pg-cli-test` / `pg-ext-test` run these alongside the bearer checks (all four).

### Scalability & production caveats (sample-acceptable; state them honestly)

The mechanisms are correct (session mode is genuinely transaction-pooler-safe). But:

- **`bearer` does not scale past ~`max_connections` concurrent users** — the transport
  ([../examples/transport/src/pg-oauthbearer.ts](../examples/transport/src/pg-oauthbearer.ts))
  is one connection per user/token, no pool, with ≥5 serialized round-trips per
  request; OAUTHBEARER can't be pooled (bound to one `sub`) and PgBouncer can't
  passthrough it. Treat `bearer` as demo / low-concurrency self-host.
- **Per-request permission resolution** — in `session` mode `ensure_context_initialized()`
  runs the recursive `get_user_permissions()` once per tx (cached in a LOCAL GUC that
  resets at COMMIT), so it re-runs every request. In `bearer` mode the cache is
  **disabled**: the client runs SQL as the request role and could overwrite the `app.*`
  GUCs, so permissions are re-resolved on every check and the session receives a
  one-time WARNING saying so (release review S2). Per-row select rules and row triggers
  pay that cost per row in bearer mode; the cache needs a signed/verified form before
  bearer mode can be called production-ready. For high-RPS / high-permission users,
  production needs an app-side permission cache (keyed by `sub` + roles-version); the
  samples don't implement one.
- **Validator version (`bearer`)** — the image builds `pg_oidc_validator` 1.1.0
  (`OIDC_VALIDATOR_REF` in the Dockerfile / compose files). 1.x adds
  `pg_oidc_validator.authn_field`, `pg_oidc_validator.discovery_url_override`,
  relaxed empty-scope handling and HTTP/JWKS cache fixes; our one-line claims
  patch still applies on top. Older builds do a fresh outbound JWKS fetch per
  connection.

---

## Quick start

```bash
cp .env.example .env          # set POSTGRES_PASSWORD
docker compose up --build     # first build compiles the validator (~1-3 min)
```

The full-DBA connection string is then:

```
postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5432/appdb
```

Point the Semantius CLI at it and deploy:

```bash
export DATABASE_URL=postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5432/appdb
deno task reset --confirm     # drop + migrate _core
deno task retest --confirm    # migrate test + run pgTAP
```

---

## Two ways to load Semantius core

There are **two build commands**, for two ways to get the core schema into the
database. Pick one per database — they are alternatives, not layers:

| Build command | What the image contains | How core is loaded | Port |
| ------------- | ----------------------- | ------------------ | ---- |
| `pg-cli-create` (`.sh`/`.cmd`) | Plain PG18 + OAuth | You deploy with the CLI: `deno task migrate` / `reset` | 5432 |
| `pg-ext-create` (`.sh`/`.cmd`) | Same image **+ the Semantius core extension baked in** | `CREATE EXTENSION pg_semantius` runs automatically at first init | 5433 |

They are independent Docker Compose projects (separate container, data volume,
and port), so both can run at once. The extension variant must have the extension
generated first, from the repo root:

```bash
deno task extension 0.5.0    # writes ../extension/{pg_semantius.control, pg_semantius--<ver>.sql}
                             # (for a release use ../release.sh instead)
./pg-ext-create.sh           # builds the base image, then the extension image, and starts it
```

The extension variant uses a separate compose file
([docker-compose.ext.yml](docker-compose.ext.yml)) and Dockerfile
([Dockerfile.ext](Dockerfile.ext)), and runs `CREATE EXTENSION pg_semantius`
followed by `SELECT semantius.migrate()` (no `CASCADE`)
via [init-ext/20-extension.sql](init-ext/20-extension.sql). It has the **same full
set of lifecycle scripts** as the CLI stack, under the `pg-ext-*` prefix
(`pg-ext-start`, `pg-ext-stop`, `pg-ext-status`, `pg-ext-test`, `pg-ext-delete`) —
see the table below. Under the hood they wrap:

```bash
docker compose -f docker-compose.ext.yml -p semantius-ext <up|ps|stop|start|down|logs>
```

See [../extension/README.md](../extension/README.md) for the extension itself.

---

## Equivalence test paths (CLI vs extension)

The two install channels above must produce an **identical** `_core` schema. To
prove it, each stack has a one-command, non-interactive harness that deploys the
test apps and runs the **same** pgTAP suite (`deno task test` always reads
`./apps/test/tests`, regardless of which stack it points at). Both green ⇒
extension-`_core` ≡ migrate-`_core`.

| Path | Harness | What it does |
| ---- | ------- | ------------ |
| **A — plain CLI** | `pg-cli-retest` (`.sh`/`.cmd`) | `pg-cli-create` → `retest --confirm --env pgdocker-cli` (dropall → migrate `_core,nwind,test` → test), on port 5432 |
| **B — extension** | `pg-ext-retest` (`.sh`/`.cmd`) | `down -v` → `pg-ext-create` (`CREATE EXTENSION` installs `_core`) → migrate `nwind,test` → test, on port 5433 |

```bash
./pg-cli-retest.sh      # Path A — migrate-installed _core
./pg-ext-retest.sh      # Path B — extension-installed _core

# Same runs with a coverage report (extra arguments are forwarded to the CLI):
# which core functions, PL/pgSQL statements and tables the suite executed.
# Statement-level data needs the plpgsql_check extension in the image; the dev
# images ship it (postgresql-18-plpgsql-check in ./Dockerfile), the published
# image does not, and there the report is function-level only.
# Output: ../coverage/{summary.json,uncovered.md,lcov.info}
./pg-cli-retest.sh --coverage
./pg-ext-retest.sh --coverage
```

In **Path B**, `migrate --apps nwind,test` auto-prepends `_core`, but the
extension already seeded the `_versions` run-once guards, so every `_core.*`
migration is **skipped** (not re-run) and only `test`/`nwind` are
deployed onto the extension's `_core` — the exact same app set Path A migrates,
so the two paths run the identical suite over an identical schema. (The
`webhook_receivers`/`dashboards` tables that `test.0030_seed` and several test
files use are now part of `_core` itself, so they come from the extension —
no separate app needed.) That seed (plus the
`_versions` table the extension now creates) is what lets an extension-installed
database be managed by the CLI; it is also the fix for the `CREATE EXTENSION`
install itself (`_core/0050` attaches an RLS policy to `_versions`).

> The connection is not hard-coded: `pg-cli-retest` uses the `.env.pgdocker-cli`
> profile, while `pg-ext-retest` reads `POSTGRES_PASSWORD` from `pgdocker/.env`
> and passes `--database-url` (which also outranks any exported `DATABASE_URL`).
> The lighter `deploy-module` scripts (below) use the matching `--env pgdocker-cli`
> / `--env pgdocker-ext` profiles. Either way the profile's password must match
> `pgdocker/.env`. They wrap `retest`/`migrate`/`test` unchanged and forward any
> extra arguments (such as `--coverage`) to the CLI.

`pg-ext-retest` is also re-runnable without the reset: re-running just its
`migrate --apps nwind,test` + `test` steps stays green (migrate reports
`test`/`nwind` already applied and the tests roll back cleanly).

### Extension lifecycle: install, backup, restore, drop, uninstall

`pg-ext-lifecycle.sh` (no `.cmd` variant) proves the properties the pgTAP
suite cannot see from inside one database. It runs against the container
`pg-ext-create.sh` leaves behind and uses scratch databases of its own, so it
does not disturb `appdb`:

| Step | Proves |
|---|---|
| 0 | the control file (`schema = public`, `encoding = 'UTF8'`, no `requires`) and a generated script with no `skip_audit` |
| 1 | two-statement install with no CASCADE; members are only the schema and its functions; all 52 core relations are non-members; `extconfig IS NULL` |
| 1b | a second database on the same cluster, with the roles already present (B11) |
| 1c | two concurrent `migrate()` callers serialise on the advisory lock |
| 1d | `psql -1` installs; a rolled-back `migrate()` leaves nothing behind |
| 2 | plain `pg_dump` → **single-pass** `pg_restore`, with a custom field on a core entity (B16) |
| 2b | the same dump through `-Fp \| psql`, `-j 4` and `-1` |
| 4 | `DROP EXTENSION` is inert, with and without CASCADE |
| 4b | the documented uninstall recipe leaves no leftovers |
| 6 | schema pinning: a non-`public` search_path installs, `SCHEMA other` is refused (B2) |
| 6b | hostile `PGOPTIONS` produce a byte-identical install |
| 7 | refusals: a real `pgmq`, a misplaced `pgcrypto`, `migrate()` inside an extension script |
| 8 | privileges: a request role cannot reach `migrate()`, and a granted non-superuser still hits the superuser gate (B15) |
| 8b | a squatted `semantius_owner` is refused |
| 9 | LATIN1 and SQL_ASCII databases are refused (B9) |

```bash
./pg-ext-create.sh                  # first: an extension stack to run against
./pg-ext-lifecycle.sh               # the whole lifecycle; exits 1 on any failure
./pg-ext-lifecycle.sh --keep        # keep the scratch databases for triage
```

It replaced `pg-ext-dump-restore.sh`, which existed only to drive the old
three-pass restore. That procedure is gone: because `migrate()` creates the
core schema as ordinary objects rather than extension members, a plain
`pg_dump` and a single `pg_restore` round-trip everything, and
`apps/test/tests/0440_test_extension_membership.sql` pins the membership
invariants the round trip depends on.

### Just deploy a module (no reset, no tests)

To load one or more app modules onto an **already-running** container without
recreating it, dropping data, or running the suite, use the `deploy-module`
scripts. They take the module list as an argument (comma-separated, exactly as
`migrate --apps` expects) and run `migrate --apps <modules>` against the matching
`--env` profile (which auto-prepends `_core` — a no-op when it is already
present, whether from a CLI migrate or the extension):

| Stack | Script | What it does |
| ----- | ------ | ------------ |
| CLI | `pg-cli-deploy-module <modules>` (`.sh`/`.cmd`) | `migrate --apps <modules> --env pgdocker-cli`, on the running CLI container (port 5432) |
| extension | `pg-ext-deploy-module <modules>` (`.sh`/`.cmd`) | `migrate --apps <modules> --env pgdocker-ext`, on the running extension container (port 5433); `_core` comes from the extension and is skipped |

```bash
./pg-cli-deploy-module.sh nwind          # deploy the Northwind sample onto the CLI stack
./pg-cli-deploy-module.sh nwind,test     # deploy several modules at once
./pg-ext-deploy-module.sh nwind          # same, onto the extension stack
```

Re-runnable: a second run reports the modules already applied. (The Northwind
sample registers a module at `/nwind`.)

---

## Managing the container (prepare / start / stop / destroy)

This folder ships ready-to-run lifecycle scripts. **Every action exists for both
stacks**: `pg-cli-*` drives the CLI-testing container (default project, port 5432)
and `pg-ext-*` drives the extension container (project `semantius-ext`, port 5433).
Each name has a `.sh` form (macOS/Linux/Git-Bash) and a `.cmd` form (Windows) — run
them from this `pgdocker/` folder, e.g. `./pg-cli-start.sh` or `pg-cli-start.cmd`.

| Action | CLI-testing | Extension | Effect |
| ------ | ----------- | --------- | ------ |
| Create | `pg-cli-create` | `pg-ext-create` | build image + create `.env` (if missing) + start |
| Start  | `pg-cli-start`  | `pg-ext-start`  | start (reuse existing image) |
| Status | `pg-cli-status` | `pg-ext-status` | show created / running (healthy) / exited |
| Stop   | `pg-cli-stop`   | `pg-ext-stop`   | remove container+network, **keep data** |
| Delete | `pg-cli-delete` | `pg-ext-delete` | remove container+network+**data volume**+image (asks to confirm) |
| Test   | `pg-cli-test`   | `pg-ext-test`   | run all four checks (bearer OAuth + impersonation, session RLS + trust) against the stack |

> `pg-cli-test` / `pg-ext-test` run **four** checks — `verify_oauth` +
> `test_oauth_security` (bearer) and `verify_session` + `test_session_trust`
> (session) — against port 5432 / 5433. The `.sh` runners aggregate exit codes and
> treat *"2 = `_core` not deployed"* as a skip; the `.cmd` runners collapse any
> non-zero to exit 1, so deploy `_core` first there. (`pg-cli-test` needs `_core`
> deployed via the CLI; `pg-ext-test` gets `_core` from the extension.)

The token helpers are **not** stack-specific:

| Helper | bash | Windows | Effect |
| ------ | ---- | ------- | ------ |
| User token | `./get-user-token.sh <user>` | `get-user-token.cmd <user>` | mint + print a JWT for a user (+ how to present it, on stderr) |
| User-info | `./get-userinfo-jwt.sh <jwt>` | `get-userinfo-jwt.cmd <jwt>` | present a JWT over OAuth and print `get_userinfo()` (or the error) |

The scripts just wrap the `docker compose` commands below; reach for the raw
commands when you need a one-off. Both are run from this `pgdocker/` folder; only
env vars and the file copy differ between shells.

The two token tools chain — mint a JWT for a user, then look up its `get_userinfo()`:

```bash
TOKEN=$(./get-user-token.sh user2)
./get-userinfo-jwt.sh "$TOKEN"
```

**Windows (PowerShell)**

```powershell
cd pgdocker
Copy-Item .env.example .env          # PREPARE: then edit .env -> POSTGRES_PASSWORD
docker compose up -d --build         # START  (first build compiles the validator)
docker compose ps                    # wait for "(healthy)"
$env:DATABASE_URL = "postgresql://postgres:<PW>@localhost:5432/appdb"

docker compose stop                  # STOP, keep data  (resume: docker compose start)
docker compose down                  # remove container+network, KEEP data volume
docker compose down -v               # DESTROY: also delete the data volume (DATA GONE)
docker compose down -v --rmi local   # also delete the built image (fully clean)
```

**bash**

```bash
cd pgdocker
cp .env.example .env                 # PREPARE: then edit .env -> POSTGRES_PASSWORD
docker compose up -d --build         # START
docker compose ps
export DATABASE_URL="postgresql://postgres:<PW>@localhost:5432/appdb"

docker compose stop                  # STOP, keep data  (resume: docker compose start)
docker compose down                  # remove container+network, KEEP data volume
docker compose down -v               # DESTROY: also delete the data volume (DATA GONE)
docker compose down -v --rmi local   # also delete the built image (fully clean)
```

What each teardown level actually removes:

| Command | Container | Network | Data volume | Image |
| ------- | --------- | ------- | ----------- | ----- |
| `stop`  | stopped (kept) | kept | **kept** | kept |
| `down`  | removed | removed | **kept** | kept |
| `down -v` | removed | removed | **deleted** | kept |
| `down -v --rmi local` | removed | removed | **deleted** | removed |

`down` is safe — a later `up -d` recreates the container on the same data. `down -v`
is the real "destroy". Useful extras (any shell):

```bash
docker compose logs -f                                   # follow logs
docker compose ps                                        # status / health
docker exec -it postgres18-cli psql -U postgres -d appdb   # a shell into the DB
```

### After editing files — what to re-run

`pg_hba.conf`/`pg_ident.conf` are **mounted** (re-read on a fresh start), the
validator is **baked into the image**, and `init/*.sql` runs **only on a fresh
data volume**. So match the action to what you changed — you rarely need the
destructive path:

| You changed… | What to run | Why |
| ------------ | ----------- | --- |
| `conf/pg_hba.conf` / `conf/pg_ident.conf` (issuer, scope, maps) | **`pg-cli-stop` → `pg-cli-start`** (or `docker compose restart`, or `SELECT pg_reload_conf()`) | mounted file; re-read on fresh start / reload |
| `Dockerfile` / `patches/` (validator, packages) | **`pg-cli-create`** (rebuilds the image) | baked into the image |
| `init/*.sql` / `init/*.sh` (role bootstrap, incl. `11-session-role.sh`) | **`pg-cli-delete` → `pg-cli-create`** | init scripts run **only on a fresh data volume**; an existing volume needs a re-create or a one-off manual `ALTER ROLE … LOGIN PASSWORD` |
| the extension SQL (ran `deno task extension`) | **`pg-ext-delete` → `pg-ext-create`** | the extension files are baked into the image; init runs on a fresh volume |
| nothing — just resuming | **`pg-cli-start`** (or `pg-ext-start`) | reuses image + data |

> Changing the `issuer=` in `conf/pg_hba.conf` is the common case: a running
> server keeps the old issuer in memory until it restarts, so `pg-cli-stop` → `pg-cli-start`
> (which keeps your data) is all you need — not `pg-cli-delete`/`pg-cli-create`.

---

## The test OIDC server

This stack is preconfigured against the test issuer
**`https://oidc-test.semanti.us`**, which mints tokens without an
interactive login — handy for verifying the OAuth path.

> ⚠️ **Test server only — replace before any real deployment.**
> `https://oidc-test.semanti.us` is a public, throwaway OIDC test server. It mints
> tokens for anyone with no login, so it holds **no secrets or passwords** —
> nothing behind it is private by design. It exists solely to exercise the OAuth
> path out of the box. Before deploying anything that matters, point the issuer at
> your own trusted OIDC provider (see [Changing the issuer](#the-test-oidc-server)
> below — edit `issuer=` in [conf/pg_hba.conf](conf/pg_hba.conf) and the `ISSUER`
> constant in [verify_oauth.ts](verify_oauth.ts)).

```bash
# Mint an access token for a test user (no login required)
curl "https://oidc-test.semanti.us/getaccesstoken?user_id=user1&client_id=test-client"
```

Its tokens already match what Semantius expects:

```json
{
  "iss":   "https://oidc-test.semanti.us",
  "sub":   "user1",
  "aud":   ["test-client", "api://default"],
  "scope": "openid profile email",
  "email": "user@test.com",
  "name":  "John Smith",
  "role":  "authenticated"
}
```

Test users: `user1` (John Smith), `user2` (María García), `user3` (Wei Chen).
Discovery: `/.well-known/openid-configuration` · JWKS: `/jwks`.

To use a different issuer, edit the `issuer=` (and `scope=`) values in
[conf/pg_hba.conf](conf/pg_hba.conf) and rebuild. The issuer must serve an HTTPS
discovery document whose `jwks_uri` points at its JWKS.

---

## Testing the OAuth connection

`psql`/libpq in PG18 speaks OAuth, but the built-in client flow needs the issuer
to advertise a `device_authorization_endpoint` (the test issuer does not). So
this folder ships [verify_oauth.ts](verify_oauth.ts) — a dependency-free Deno
script that mints a fresh token from the test issuer and performs the
`OAUTHBEARER` SASL handshake by hand:

```bash
# DBA login (the DATABASE_URL path):
docker exec -e PGPASSWORD=<PW> postgres18-cli \
  psql "host=127.0.0.1 user=postgres dbname=appdb" -c "select 1"

# OAuth -> authenticated path (validator + JWKS + ident map + claims):
deno run --allow-net verify_oauth.ts
# minted token for sub=user1 (len=756)
# server offered SASL mechanisms: [ "OAUTHBEARER" ]
# AuthenticationOk: OAUTHBEARER token accepted
# OK  current_user=authenticated  system_user=oauth:user1
#     request.jwt.claims = {"sub":"user1","role":"authenticated", ...}
```

A successful validation requires the container to reach the issuer's HTTPS JWKS
endpoint outbound. Note `system_user=oauth:user1`: PostgreSQL records the
**validated** identity as `oauth:<sub>` — see the claims-bridge section above
for why that matters.

---

## Automated checks (CI)

Both scripts are dependency-free Deno (stdlib only) and exit non-zero on failure,
so they drop straight into CI once the container is healthy:

```bash
docker compose up -d --build
until docker exec postgres18-cli pg_isready -U postgres -d appdb; do sleep 1; done

# deploy core so rbac.uid() exists, then run the checks
export DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5432/appdb"
deno task migrate --apps _core
deno run --allow-net verify_oauth.ts          # OAuth validated + claims published -> exit 0
deno run --allow-net test_oauth_security.ts   # impersonation attempt is blocked   -> exit 0
deno run --allow-net test_bearer_cache.ts     # forged app.* permission cache ignored -> exit 0
```

(Outbound HTTPS to the issuer's JWKS endpoint is required.)

---

## TLS

- The issuer / JWKS endpoints **must be HTTPS** — PostgreSQL enforces this.
- The client↔server connection uses `host` (no TLS) here for local convenience.
  Bearer tokens are sensitive: for any non-local deployment, configure server
  certs and switch the `oauth` lines in [conf/pg_hba.conf](conf/pg_hba.conf)
  from `host` → `hostssl`.

---

## Cross-platform

The base `postgres:18` image is multi-arch (linux/amd64 + linux/arm64) and the
validator is compiled from source during the build, so the **same** Dockerfile
produces a working image on:

- **Linux** (x86-64 and ARM),
- **macOS** (Apple Silicon and Intel) via Docker Desktop,
- **Windows** (x64 and **ARM64**) via Docker Desktop / WSL2.

Docker always builds and runs the container for its own Linux VM architecture,
so no host-specific changes are needed.

---

## Files

- [Dockerfile](Dockerfile) — `postgres:18` + the validator (pinned commit + local patch)
- [docker-compose.yml](docker-compose.yml) — CLI-testing stack: service, volumes, validator/HBA/ident wiring, healthcheck
- [Dockerfile.ext](Dockerfile.ext) — extension variant: layers the generated `../extension` on the base image
- [docker-compose.ext.yml](docker-compose.ext.yml) — extension stack (separate project `semantius-ext`, port 5433)
- [conf/pg_hba.conf](conf/pg_hba.conf) — full-DBA SCRAM lines + the `oauth` rules
- [conf/pg_ident.conf](conf/pg_ident.conf) — token identity → `authenticated` role map
- [init/10-roles.sql](init/10-roles.sql) — creates the `authenticated` LOGIN role (both stacks)
- [init/11-session-role.sh](init/11-session-role.sh) — gives `semantius_authenticator` LOGIN + password for session mode (both stacks; reads `SEMANTIUS_AUTHENTICATOR_PASSWORD`)
- [init-ext/20-extension.sql](init-ext/20-extension.sql) — extension stack only: runs `CREATE EXTENSION pg_semantius CASCADE`
- [pg-cli-retest.sh](pg-cli-retest.sh) / [pg-cli-retest.cmd](pg-cli-retest.cmd) — Path A equivalence harness (migrate-installed `_core` → pgTAP)
- [pg-ext-retest.sh](pg-ext-retest.sh) / [pg-ext-retest.cmd](pg-ext-retest.cmd) — Path B equivalence harness (extension-installed `_core` → pgTAP)
- [pg-cli-deploy-module.sh](pg-cli-deploy-module.sh) / [pg-cli-deploy-module.cmd](pg-cli-deploy-module.cmd) — deploy given module(s) onto the running CLI container (`<module[,module...]>`)
- [pg-ext-deploy-module.sh](pg-ext-deploy-module.sh) / [pg-ext-deploy-module.cmd](pg-ext-deploy-module.cmd) — deploy given module(s) onto the running extension container (`<module[,module...]>`)
- [patches/](patches/) — validator patch that publishes `request.jwt.claims`
- [verify_oauth.ts](verify_oauth.ts) — bearer: end-to-end OAuth handshake + claims check
- [test_oauth_security.ts](test_oauth_security.ts) — bearer: hostile-client impersonation check
- [test_bearer_cache.ts](test_bearer_cache.ts) — bearer: hostile-client forges the `app.*` permission cache; must be ignored (release review S2)
- [verify_session.ts](verify_session.ts) — session: SCRAM connect → `SET ROLE` + claims → RLS, with provisioning + guardrail
- [test_session_trust.ts](test_session_trust.ts) — session: trust-model assertion + NOINHERIT/no-claims/bad-role negatives
- [session_helpers.ts](session_helpers.ts) — shared session helpers (SCRAM connect, password resolution, claims/tx)
- [../scripts/setup-session-role.ts](../scripts/setup-session-role.ts) — managed setup: set `semantius_authenticator` LOGIN + password over the owner connection (`deno task setup-session-role`)
- [get_user_token.ts](get_user_token.ts) — mint + print a JWT for a user
- [get_userinfo_jwt.ts](get_userinfo_jwt.ts) — print `get_userinfo()` for a given JWT
- [.env.example](.env.example) — DBA password, DB name, host port, `SEMANTIUS_AUTHENTICATOR_PASSWORD`

## Using it as the devcontainer database

The repo's [.devcontainer](../.devcontainer) can bring this image up as the `db`
service — but only **when no managed database is configured**. Its
[initializeCommand](../.devcontainer/select-db.sh) runs on the host before the
container is created (works in GitHub Codespaces too, where `DATABASE_URL` can be
a secret):

- `DATABASE_URL` **set** (Neon/Supabase) → the local Postgres is **not** built or
  run; the devcontainer just uses that URL.
- `DATABASE_URL` **unset** → the `localdb` compose profile is enabled and this
  image comes up, so the project works with no managed account.

See [../.devcontainer/docker-compose.yml](../.devcontainer/docker-compose.yml).
