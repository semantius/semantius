# kysely-raw — list users with Kysely (raw SQL) over OAuth (Node)

Connect to a **Semantius** database (**PostgreSQL 18**) from Node with
[Kysely](https://kysely.dev), authenticating as the `authenticated` role with an
**OAuth access token** over SASL `OAUTHBEARER` — then list users with **raw SQL**
(no generated types).

This example is **self-contained**: it vendors the dependency-free transport
([`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts)) and the token helper
([`src/get-auth-token.ts`](src/get-auth-token.ts)) from [`../transport`](../transport)
(the canonical copies). The only npm dependency is `kysely` itself.

### Files

- [`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts) — vendored transport: socket +
  `OAUTHBEARER` SASL handshake + extended-query protocol. Canonical copy lives in
  [`../transport`](../transport).
- [`src/get-auth-token.ts`](src/get-auth-token.ts) — vendored token helper. Mints a
  test token here; in a real app you'd return the current user's session token.
- [`src/kysely-dialect.ts`](src/kysely-dialect.ts) — a Kysely `Dialect` that reuses
  Kysely's Postgres compiler/adapter/introspector and swaps in the transport as a
  custom `Driver`.
- [`src/list-users.ts`](src/list-users.ts) — sample #1, "list users". Each sample is
  its own task-named file in `src/`; add more as sibling files.

## What it does

1. Get an access token (`get-auth-token` — mints a test token; swap in your session token for real use).
2. Connect as `authenticated`, presenting that token over SASL `OAUTHBEARER`.
3. Call `public.get_userinfo()` once — first-login provisioning. It assigns the
   `User` role (which carries `user:read`), so the RLS `SELECT` policy on `users`
   lets us read. Without it the list comes back empty.
4. Run a direct `select … from users` and print the rows visible under RLS.

## Prerequisites

A running pgdocker stack with the Semantius `_core` present. From `pgdocker/`:

- **CLI stack** (port **5432**): `./pg-cli-create.sh`, then deploy core —
  `export DATABASE_URL=… && deno task migrate --apps _core`.
- **Extension stack** (port **5433**): `./pg-ext-create.sh` — `_core` is installed
  by `CREATE EXTENSION` automatically. Run this example with `PGPORT=5433`.

The container must reach the issuer's HTTPS JWKS endpoint outbound, and you need
Node **≥ 20** (for global `fetch`).

## Run a sample

Each sample is its own task-named file in [`src/`](src). Run the one you want with
`tsx` (runs TypeScript directly, no build step):

```bash
npm install
npx tsx src/list-users.ts                # the "list users" sample (CLI stack on 5432)
PGPORT=5433 npx tsx src/list-users.ts    # extension stack
USER_ID=user2 npx tsx src/list-users.ts  # connect as a different test user
```

`npm start` is just a convenience alias for the first sample
(`tsx src/list-users.ts`). Further samples drop in as sibling files —
`src/<task>.ts` — and run the same way.

Expected output (fresh stack — `user3` / `admin@test.com` is the Administrator,
provisioned first by the CLI; admin is granted by login order, not by email):

```
Minting token for "user3" from https://oidc-test.semanti.us …
Connected: { current_user: 'authenticated', system_user: 'oauth:user3' }
```

The raw driver returns **every** `users` column, so the table is wide; the identity
row is `id 1 · external_id 'user3' · email 'admin@test.com' · display_name 'Wei Chen'`,
followed by `1 user(s) visible to "user3" under RLS.`

> Want more rows? Run it once per user (`USER_ID=user1`, `user2`, `user3`) to
> provision each, then list again — every provisioned user gets `user:read`.

## Configuration

| Env var | Default | Meaning |
| ------- | ------- | ------- |
| `PGHOST` | `localhost` | database host |
| `PGPORT` | `5432` | `5432` = CLI stack, `5433` = extension stack |
| `PGDATABASE` | `appdb` | database name |
| `USER_ID` | `user3` | test user to mint a token for (`user3` = `admin@test.com`, the admin; `user1` = `user@test.com`, a plain user; `user2` = `sales@test.com`) |
| `CLIENT_ID` | `test-client` | OAuth client id |
| `ISSUER` | `https://oidc-test.semanti.us` | OIDC issuer (must match `pg_hba.conf`) |

See [`../transport`](../transport) for the transport's API and caveats (one
connection, TEXT values, token-first, no TLS).
