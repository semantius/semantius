# Plan (FOUNDATION — must finish before the two sample plans): Dual-mode auth + `semantius_authenticator` role

## Why this is first
Both sample apps want a `DB_AUTH_MODE = bearer | session` switch. The `bearer` path (PG18 OAUTHBEARER)
already works. The `session` path (Supabase/Neon model: connect as a shared restricted role, `SET LOCAL ROLE
authenticated`, inject `request.jwt.claims`) needs a **dedicated restricted login role that exists identically
in every environment**. Today there is none: the only RLS-subject role (`authenticated`) is OAuth-only locally,
and the default login on managed platforms (`postgres`/owner) is **superuser → bypasses RLS → silently returns
all rows**. This plan defines that role (`semantius_authenticator`) uniformly, wires it into the local stacks,
and proves both modes with test commands. **The Next.js and Hono/SPA plans cannot start until this is signed off.**

## The key decision (reverses the earlier "pgdocker-only" idea)
`semantius_authenticator` is **created by the core migrations** (`apps/_core/migrations`), NOT just locally — so
local pgdocker, Neon, and Supabase all get the *same* restricted role automatically when the schema is deployed.
The password/LOGIN is set per-environment by a step **we** own (never in committed SQL). This mirrors exactly how
`authenticated` is created `NOLOGIN` in core and flipped to `LOGIN` by pgdocker.

- **Existence + privileges (core migration, idempotent `DO` guard, every deployment):**
  ```sql
  CREATE ROLE semantius_authenticator NOLOGIN NOSUPERUSER NOINHERIT;  -- only if not exists; never strip LOGIN if present
  GRANT authenticated TO semantius_authenticator;                      -- can SET ROLE authenticated (member of semantius_user)
  ```
  `NOSUPERUSER` + `NOINHERIT` ⇒ the role has **no privileges of its own** and can do **nothing** but `SET ROLE authenticated`.
  **This is exactly Supabase's `authenticator` pattern** — a NOINHERIT gatekeeper that *enforces* RLS by `SET ROLE`-ing into an
  RLS-subject role; it does **not** bypass RLS. (Supabase grants its `authenticator` → {`anon`, `authenticated`, `service_role`}
  and picks one per JWT; this RBAC model has only `authenticated` — public access is the `public:read` *permission*, not a separate
  role — so we grant just `authenticated`.) Namespaced (`semantius_*`) so it never collides with Supabase's own `authenticator`.
  **The only RLS-bypass risk on managed platforms is connecting as the `postgres`/project-owner role instead of `semantius_authenticator`.**
- **LOGIN + password (per-environment, we manage it; per-env secret):**
  - Local pgdocker: a new `init/11-session-role.sh` (shell, reads `$SEMANTIUS_AUTHENTICATOR_PASSWORD`) does an
    idempotent create-or-`ALTER ROLE semantius_authenticator LOGIN PASSWORD …` (+ ensures NOSUPERUSER/NOINHERIT/GRANT),
    using safe quoting (`psql -v pw=… ` + `format('… PASSWORD %L', :'pw')`).
  - Managed Supabase/Neon: a one-time setup task runs the same `ALTER … LOGIN PASSWORD` over the **privileged (owner)**
    connection. The app then connects as `semantius_authenticator`, never the owner.

## Trust model per mode + backend — drives the sample READMEs
For **RS256 tokens** (what the test issuer mints, and what most IdPs default to), in-DB signature verification is only available in `bearer` mode. Net:

| Path | Gate 1 (connect) | Signature verified in DB? | Net |
|---|---|---|---|
| `bearer` — self-hosted PG18 / local | the token itself (OAUTHBEARER), RS256 | ✅ `pg_oidc_validator` (RS256) | **DB-verified** |
| `session` — Supabase / Neon / self-hosted (RS256) | `semantius_authenticator` password | ❌ no off-the-shelf RS256 in-DB verifier | **one gate** — app MUST verify |

- **`session` mode is one-gate at the DB on *every* backend for RS256 tokens** — Supabase, Neon, and self-hosted alike. The only off-the-shelf in-DB JWKS verifier, Neon's **`pg_session_jwt`, verifies Ed25519/EdDSA *only*** (confirmed: `Cargo.toml`'s sole signature crate is `ed25519-dalek`; `src/lib.rs` builds an `Ed25519Okp` and verifies via `ed25519_dalek::verify_strict` — no RSA/ECDSA). Our RS256 tokens can't be verified by it on Neon *or* self-hosted; Supabase additionally can't install it. So the DB does **not** verify the signature in `session` mode — the app does, and the `semantius_authenticator` password + app verification are the protection.
- **For DB-enforced verification, use `bearer` mode** (RS256, verified in-DB by `pg_oidc_validator`, works today).
- **Two-gate `session` mode is not free** (see Phase 2): requires either EdDSA-signed tokens + `pg_session_jwt` (impractical — we don't control the test issuer's alg, most IdPs are RS256, and the bearer validator would need to accept EdDSA too) or a **custom RS256 in-DB verifier** (`plpython3u`+PyJWT, or extend `pg_oidc_validator`). Real work, not config.
- **Each sample README must state**: in `session` mode the app is the trust boundary on **Supabase and Neon** (the DB does not verify the signature); DB-enforced verification is the `bearer`/self-hosted path.

## Verified facts this builds on
- `semantius_user` = `INHERIT NOLOGIN` group; **all RLS policies are `TO semantius_user`**; grants go to it (`apps/_core/migrations/0010_create_core.sql:29`, grants throughout). `authenticated` is a **member of `semantius_user`** (`0010:32` = `GRANT semantius_user TO authenticated`). A NOINHERIT role GRANTed `authenticated` that does `SET ROLE authenticated` matches the policies and inherits the grants.
- pgdocker `init/10-roles.sql` flips `authenticated` to `LOGIN` for direct OAuth (the same create-NOLOGIN-in-core / flip-LOGIN-in-pgdocker pattern we reuse).
- `rbac.uid()` checks the JWT **`role` claim**, not the PG role name; pins identity to `system_user='oauth:<sub>'` **only** for bearer (`0030_rbac_functions.sql:168-174`). **In session mode injected claims are authoritative — the app is the sole trust boundary on every backend** (no off-the-shelf RS256 in-DB verifier; see Trust model). Only `bearer` mode verifies the signature in the DB.
- `rbac.uid()` is `STABLE`, **cached per transaction** (`0030:109,233`) → inject claims before the first rbac call.
- Both compose files mount `conf/pg_hba.conf` + `conf/pg_ident.conf` RO. CLI mounts the whole `./init` dir; **ext mounts init files individually** (`docker-compose.ext.yml:38-39`) → a new init `.sh` needs an explicit ext mount line.
- `.sql` init files get **no env interpolation**; `.sh` files do.
- Test runner: `pg-cli-test.sh`/`.cmd` → `verify_oauth.ts` (exports `mintToken`,`oauthConnect`,`runQuery`,`parseFlags`) + `test_oauth_security.ts`. `pg-ext-test.*` = 5433 equivalent. `.cmd` runners collapse any non-zero to exit 1.

## Session-mode connection contract (the artifact the samples consume)
Per request/transaction, the app (having already verified the JWT) runs:
```sql
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', $1::text, true);   -- LOCAL; inject BEFORE any rbac call
-- … queries …
COMMIT;
```
- **SET ROLE target is `authenticated`** (the identity role, a *member of* `semantius_user`) — **not** `semantius_user` itself. This matches Supabase's `authenticator → authenticated` and keeps `current_user = authenticated` consistent with `bearer` mode; `semantius_user` is the internal grant/policy group, never assumed directly.
- **Ordering:** `rbac.uid()` is STABLE/cached per tx — inject claims before the first rbac/RLS call; fresh tx per identity.
- Both `SET LOCAL ROLE` and `set_config(..., true)` are transaction-scoped, auto-revert on COMMIT/ROLLBACK, and are **transaction-pooling-safe** (one server connection per tx under PgBouncer/Supavisor). Never use session-level `SET ROLE` / `set_config(..., false)` for the legitimate path.
- **Minimal claims:** `{"sub": "...", "role": "authenticated"}` (both required by `rbac.uid()` `0030:177-186`), plus `"email"` for first-login provisioning, plus `"aud"` only if `_settings.jwt_aud` is seeded (off by default).
- **First login:** call `public.get_userinfo()` once before other reads, or `ensure_context_initialized()` raises "User not found" (`0030:335-337`). Works in session mode because `get_userinfo`/`upsert_user_from_jwt` are `SECURITY DEFINER` owned by the BYPASSRLS migration role — not because `semantius_authenticator` has any write grant.
- **Cheap DB hardening (recommended, no crypto):** have `rbac.uid()` also reject claims whose `exp` is in the past or whose `iss` ≠ the configured issuer. This catches expired/wrong-issuer mistakes even on Supabase (the one-gate path) and costs nothing. It is **not** a signature check (that needs the public key — Phase 2); it raises the floor, it doesn't replace Gate 2.

## Session-adapter security requirements (MANDATORY — the app is the sole trust boundary in `session` mode)
Nothing in the DB verifies the signature in `session` mode, so the adapter (in both samples) MUST:
1. **Verify before inject, fail closed.** Verify with jose against the remote JWKS, **pinning `algorithms: ['RS256']`** and passing `issuer` (== configured) and `audience` (== expected `aud`). **`aud` checking is mandatory** even though the DB default doesn't enforce it — else any same-issuer token minted for another client is accepted. On **any** failure (bad signature, expired, wrong `iss`/`aud`, JWKS unreachable, cold/expired cache) → **reject (401); never inject claims; never fall back to a stale/empty keyset.** Fail-open is forbidden.
2. **Inject the verified payload, not a re-decode.** `request.jwt.claims` MUST be the exact payload object returned by `jwtVerify` — never a separate `decodeJwt`, never merged with client-supplied headers/cookies. `role:'authenticated'` is set server-side, not trusted from the token.
3. **Only inside a transaction.** `SET LOCAL ROLE authenticated` + `set_config('request.jwt.claims', …, true)` must run on a connection with an open tx; the adapter MUST **throw if not in a tx**. Never use session-level `SET ROLE` or `set_config(…, false)` on the live path (that form appears ONLY in the adversarial tests, e.g. `test_oauth_security.ts:54`).
4. **Refuse a superuser/owner connection at startup.** On connect, `SELECT rolsuper, rolbypassrls` for `current_user`; **refuse to start if either is true** — catches a `DATABASE_URL` accidentally pointing at `postgres`/owner (which silently bypasses RLS and returns all rows).

Add negative tests for #1 (unreachable JWKS / forged sig → rejected) and #3 (inject outside a tx → throws).

**Bearer mode note:** a `bearer` connection is bound to one `sub` for its lifetime (the validator publishes `request.jwt.claims` at *session* scope). Never reuse a bearer connection across users, even with future per-user connection caching — identity stays correct via `system_user`, but stale session GUCs (incl. the `app.*` cache) are a foot-gun.

## pg_hba.conf (local only — managed platforms already allow scram for normal roles)
Add (shared conf → both local stacks); distinct user, so order vs the oauth lines is irrelevant:
```
host  all  semantius_authenticator  0.0.0.0/0  scram-sha-256
host  all  semantius_authenticator  ::0/0      scram-sha-256
```
Keep the existing `local trust`, `postgres scram`, and `authenticated oauth` lines untouched. (Supabase/Neon manage their own pg_hba and already permit password auth for non-superuser roles — no change there.)

## Env + compose wiring (local)
- Add `SEMANTIUS_AUTHENTICATOR_PASSWORD` to **`pgdocker/.env`** (the file compose reads) + **`pgdocker/.env.example`** (dev default). **NOT** `.env.pgdocker-cli/-ext` — those are repo-root Deno **DBA connection profiles** (a `DATABASE_URL` for `postgres`); they never reach the container.
- Pass it into **both** compose `environment:` blocks (`docker-compose.yml:13-17`, `docker-compose.ext.yml:23-26`) — else the init `.sh` can't see it.
- **Ext compose**: add an explicit mount line for `./init/11-session-role.sh` (CLI gets it via the dir mount).
- Init scripts run only on a **fresh** data volume; existing volumes need a re-create or a one-off manual `ALTER`.

## Verification commands (the heart of "test both")
Refactor `verify_oauth.ts`'s helpers for reuse. Session mode needs a **standard SCRAM driver** (the hand-rolled transport is OAUTHBEARER-only) — use the already-locked **`https://deno.land/x/postgres@v0.17.0`** (SCRAM impl at `deno.lock:149`). Flags `--allow-net --allow-env` (+`--allow-read` if it reads `.env`); no TLS on localhost.
- **`verify_oauth.ts`** (existing) — bearer happy path. Regression: green.
- **`test_oauth_security.ts`** (existing) — impersonation blocked (system_user authoritative). Regression: green.
- **`verify_session.ts`** (new):
  1. Connect as `semantius_authenticator` via SCRAM (password from env).
  2. In a tx: `SET LOCAL ROLE authenticated` + inject claims for a known sub (mint a token via `mintToken`, decode payload, inject that JSON — real claim shape), **before** any rbac call.
  3. Assert RLS-correct results (`SELECT rbac.uid()`, a `users` read).
  4. **First-login provisioning via session path**: fresh sub → `get_userinfo()` → `users` row created + `User` role auto-assigned by trigger → follow-up read works. **Order-sensitive**: the first provisioned user on a fresh DB also gets `Administrator` (`0050_rbac_rls.sql:290-294`) — design for it.
  5. **Guardrail**: `SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname='semantius_authenticator'` are both false.
- **`test_session_trust.ts`** (new) — inject `sub=user2` in session mode and assert `rbac.uid()` **returns user2** (no `system_user` override). Documents that the app is the sole trust boundary in session mode (mirror of `test_oauth_security.ts`); a teaching assertion, not a vuln.
- **Negatives**: (a) `semantius_authenticator` with no `SET ROLE`/claims → permission denied (NOINHERIT); (b) `SET ROLE authenticated` but no claims → `rbac.uid()` raises "Authentication required"; (c) claims with `role != authenticated` → rejected.

## Wire into the test runners
Extend `pg-cli-test.sh`/`.cmd` and `pg-ext-test.sh`/`.cmd` to also run `verify_session.ts` + `test_session_trust.ts` against the right port (5432/5433), aggregating exit codes (keep the `security 2 = _core not deployed` skip). Note the `.cmd` runners collapse non-zero to exit 1 (`pg-cli-test.cmd:8-19`) — mirror the `.sh` aggregation or accept the divergence.

## Scalability & production caveats (sample-acceptable; document honestly — both sample READMEs)
The mechanisms are correct (session mode is genuinely transaction-pooler-safe — LOCAL GUC discipline prevents cross-request leakage). But these are real ceilings the READMEs must state:
- **`bearer` mode does not scale past ~`max_connections` concurrent users.** The transport (`examples/transport/src/pg-oauthbearer.ts`) is **one connection per user/token, no pool**, opened per request with a TCP+SASL OAUTHBEARER handshake; queries within a request are **serialized, not pipelined** (≥5 sequential round-trips/request: BEGIN, SET ROLE, set_config, query, COMMIT). OAUTHBEARER can't be pooled (connection is bound to one `sub`) and PgBouncer can't passthrough it. A "per-user connection cache" is a foot-gun (stale session GUCs), not a free win. **Treat `bearer` as demo / low-concurrency self-host only.**
- **Per-request permission resolution.** `rbac.ensure_context_initialized()` runs the recursive CTE `rbac.get_user_permissions()` (`0030_rbac_functions.sql:686-734`) once per transaction, cached in the LOCAL GUC `app.user_permissions` (`0030:351`) — which resets at COMMIT, so it **re-runs on every request in both modes** (intentional, for RLS-safe per-tx isolation; `0030:347-348`). No app-level cache. For high-permission users / high RPS, document that production needs an app-side permission cache (keyed by `sub` + a roles-version); the samples don't implement one.
- **Validator JWKS caching (`bearer`).** Pin/document the `pg_oidc_validator` version — JWKS/discovery caching landed in **v0.2**; older builds (or IdPs that forbid caching) do a **fresh outbound JWKS fetch per connection**, compounding the per-request `bearer` cost. App-side (jose `createRemoteJWKSet`) caches in-process — fine.

## Open questions / risks
1. **Core migration placement**: which migration file creates `semantius_authenticator` (extend `0010_create_core.sql` next to `authenticated`/`semantius_user`, or a new file). Must be idempotent and must NOT strip `LOGIN` if the role already exists (local pgdocker init may have created it LOGIN first).
2. **Managed setup ergonomics**: the one-time `ALTER … LOGIN PASSWORD` over the owner connection — provide it as a `deno task` (preferred) or a documented SQL snippet. Confirm the owner role on Supabase/Neon may `ALTER ROLE … PASSWORD` (it can: postgres/owner has CREATEROLE).
3. **Deno SCRAM driver**: import via `https://deno.land/x/postgres@v0.17.0` (already locked); `jsr:@db/postgres` is the same project but may add a lock entry.
4. **Init-once semantics** (local): existing volumes won't gain the role without re-create / manual `ALTER`.
5. **Ext-stack individual mounts**: the new `11-session-role.sh` mount line is mandatory or the ext stack lacks the LOGIN/password. Verify the role exists + can SCRAM-connect on **both** 5432 and 5433.
6. **Password handling**: per-environment secret (not one shared static value); README must warn against reuse in shared/exposed deployments. The role's privilege floor (NOSUPERUSER/NOINHERIT/NOBYPASSRLS) is the real safety net.

## Milestones
0. Baseline: bring up both stacks; confirm `verify_oauth.ts` + `test_oauth_security.ts` pass on each (5432/5433).
1. **Core migration**: create `semantius_authenticator` (`NOLOGIN NOSUPERUSER NOINHERIT`, `GRANT authenticated`), idempotent, non-destructive of LOGIN. Re-deploy schema; confirm it exists on a migrated DB.
2. **Local LOGIN/password**: `init/11-session-role.sh` + `SEMANTIUS_AUTHENTICATOR_PASSWORD` env + both compose `environment:` blocks + ext mount line.
3. **pg_hba**: `semantius_authenticator` scram lines.
4. Re-create both stacks; confirm `semantius_authenticator` SCRAM-connects and `SET ROLE authenticated`; guardrail assertion (NOSUPERUSER/NOBYPASSRLS).
5. `verify_session.ts` — positive RLS path + session-path provisioning.
6. `test_session_trust.ts` + the three negative tests.
7. Regression: bearer scripts still green on both stacks.
8. Extend `pg-cli-test.*` / `pg-ext-test.*` to run all four checks; aggregate exit codes.
9. **Managed setup**: a `deno task` (or documented SQL) that sets `semantius_authenticator` LOGIN+password over the owner connection on Supabase/Neon (validated when the samples run against those).
10. Docs: `pgdocker/README.md` (two modes, `semantius_authenticator`, the `SET LOCAL ROLE` + claims contract, the managed-platform setup + RLS-bypass warning, **the first-user-becomes-Administrator warning**, the scalability caveats above, env, how to run); update `.env*` examples (placeholders, never literal passwords).
11. **Sign-off**: both modes green on both local stacks → unblocks the two sample plans.

## Considered and rejected: in-DB `session` verification (two-gate)
Investigated making `session` mode two-gate (DB *also* verifies the signature). **Rejected — doesn't make sense for this sample:**
- The only off-the-shelf in-DB JWKS verifier, `pg_session_jwt`, is **Ed25519/EdDSA-only** (confirmed from its `Cargo.toml`/`src`: only `ed25519-dalek`, no RSA/ECDSA). Our issuer + mainstream IdPs (Auth0/Clerk/Entra) use **RS256**, which it can't verify.
- An EdDSA issuer (e.g. better-auth, which *defaults* to EdDSA) would satisfy `pg_session_jwt`, but a token has one alg → it forces an **RS256-for-`bearer` / EdDSA-for-`session`** split (the RS256-only validator can't take EdDSA), **doesn't cover Supabase** (can't install the extension), and **doesn't generalize** to RS256 SaaS IdPs. Not worth it.
- A custom RS256 in-DB verifier (`plpython3u`+PyJWT / extending `pg_oidc_validator`) is heavy and out of scope.

**Decision:** `session` = **app-verify on every backend** (one gate at the DB); use **`bearer`** for DB-enforced verification. The cheap `rbac.uid()` `exp`/`iss` checks stay as a floor.

## Consumable contract for the samples (explicit deliverables)
- **Per-backend trust model → each sample README must spell it out:** for RS256 tokens, `session` mode is **one gate (app-verify) on every backend** — Supabase, Neon, and self-hosted — because no off-the-shelf RS256 in-DB verifier exists (`pg_session_jwt` is EdDSA-only; Supabase can't install it anyway). The `semantius_authenticator` password + the app's jose verification are the protection. **DB-enforced verification is the `bearer`/self-hosted path** (RS256 via `pg_oidc_validator`). See "Trust model" table; two-gate `session` would be Phase 2 (custom work).
- **Session role (uniform everywhere): `semantius_authenticator`** — NOSUPERUSER/NOINHERIT/NOBYPASSRLS, GRANTed `authenticated`, password we manage per-env. The app connects as this role on local, Neon, and Supabase — **never** the default `postgres`/owner string (that bypasses RLS).
- **Session connection string**: `postgresql://semantius_authenticator:<pw>@host:port/db` (local 5432/5433: no `?sslmode`; Neon & Supabase 6543: `?sslmode=require`). node-postgres is transaction-pooler-safe by default (unnamed statements) — no `prepare` flag, no `name:`/`.prepare()`. **Secret handling (do NOT regress):** the password must come from a **gitignored** source (`pgdocker/.env`, or the sample's own `.env.local`) — **never** commit it. `.env.pgdocker-cli`/`-ext` are **un-ignored by `.gitignore` (committed)**, so they must hold only a `<set-me>` placeholder with a "dev default — never reuse on anything shared/exposed" warning, never a real `SEMANTIUS_AUTHENTICATOR_URL`/password. (Supersedes any earlier note that put the URL there.)
- **Per-request SQL contract** + **minimal claims** + **call `get_userinfo()` first**: as in "Session-mode connection contract" above.

## Downstream changes this unblocks (do after sign-off)
- The Next.js and Hono/SPA plans already use `DB_AUTH_MODE = bearer | session` and connect as `semantius_authenticator` in `session` mode; ensure their connection-string + "never use the owner/superuser string" warnings match this contract.
