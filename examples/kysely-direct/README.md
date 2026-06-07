# kysely-direct — list users with Kysely over OAuth (Node)

Connect to Semantius core (**PostgreSQL 18**) from Node with [Kysely](https://kysely.dev),
authenticating as the `authenticated` role with an **OAuth access token** over
SASL `OAUTHBEARER` — then list users with a direct SQL statement.

This example is **self-contained**: it vendors the dependency-free transport
([`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts)) from
[`../transport`](../transport) (the canonical copy). The only npm dependency is
`kysely` itself.

### Files

- [`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts) — vendored transport: socket +
  `OAUTHBEARER` SASL handshake + extended-query protocol. Canonical copy lives in
  [`../transport`](../transport).
- [`src/kysely-dialect.ts`](src/kysely-dialect.ts) — a Kysely `Dialect` that reuses
  Kysely's Postgres compiler/adapter/introspector and swaps in the transport as a
  custom `Driver`.
- [`src/kysely-direct.ts`](src/kysely-direct.ts) — the runnable example.

## What it does

1. Mint a fresh access token for a test user from the test OIDC issuer (no login).
2. Connect as `authenticated`, presenting that token over SASL `OAUTHBEARER`.
3. Call `public.get_userinfo()` once — first-login provisioning. It assigns the
   `User` role (which carries `user:read`), so the RLS `SELECT` policy on `users`
   lets us read. Without it the list comes back empty.
4. Run a direct `select … from users` and print the rows visible under RLS.

## Prerequisites

A running pgdocker stack with Semantius `_core` present. From `pgdocker/`:

- **CLI stack** (port **5432**): `./pg-cli-create.sh`, then deploy core —
  `export DATABASE_URL=… && deno task migrate --apps _core`.
- **Extension stack** (port **5433**): `./pg-ext-create.sh` — `_core` is installed
  by `CREATE EXTENSION` automatically. Run this example with `PGPORT=5433`.

The container must reach the issuer's HTTPS JWKS endpoint outbound, and you need
Node **≥ 20** (for global `fetch`).

## Run

```bash
npm install
npm start                            # CLI stack on 5432
PGPORT=5433 npm start                # extension stack
USER_ID=user2 npm start              # connect as a different test user
```

Expected output (fresh stack — `user1` becomes the admin on first login):

```
Minting token for "user1" from https://oidc-test.semanti.us …
Connected: { current_user: 'authenticated', system_user: 'oauth:user1' }
┌─────────┬─────┬─────────────┬─────────────────┬──────────────┐
│ (index) │ id  │ external_id │ email           │ display_name │
├─────────┼─────┼─────────────┼─────────────────┼──────────────┤
│    0    │ '1' │   'user1'   │ 'user@test.com' │ 'John Smith' │
└─────────┴─────┴─────────────┴─────────────────┴──────────────┘

1 user(s) visible to "user1" under RLS.
```

> Want more rows? Run it once per user (`USER_ID=user1`, `user2`, `user3`) to
> provision each, then list again — every provisioned user gets `user:read`.

## Configuration

| Env var | Default | Meaning |
| ------- | ------- | ------- |
| `PGHOST` | `localhost` | database host |
| `PGPORT` | `5432` | `5432` = CLI stack, `5433` = extension stack |
| `PGDATABASE` | `appdb` | database name |
| `USER_ID` | `user1` | test user to mint a token for (`user1`/`user2`/`user3`) |
| `CLIENT_ID` | `test-client` | OAuth client id |
| `ISSUER` | `https://oidc-test.semanti.us` | OIDC issuer (must match `pg_hba.conf`) |

See [`../transport`](../transport) for the transport's API and caveats (one
connection, TEXT values, token-first, no TLS).
