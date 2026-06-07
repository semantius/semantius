# drizzle — list users with Drizzle over OAuth (Node)

Connect to a **Semantic Platform** database (**PostgreSQL 18**) from Node with
[Drizzle ORM](https://orm.drizzle.team), authenticating as the `authenticated`
role with an **OAuth access token** over SASL `OAUTHBEARER` — then list users with
a typed Drizzle query.

Drizzle is schema-first, so it needs a schema. That schema is **generated from the
catalog** by the CLI (`deno task drizzlegen`) — one file per module, every entity
included — and a snapshot is committed here under [`src/schema/`](src/schema). At
runtime Drizzle talks to the OAUTHBEARER transport through
[`drizzle-orm/pg-proxy`](https://orm.drizzle.team/docs/connect-drizzle-proxy) (see
[`src/drizzle-proxy.ts`](src/drizzle-proxy.ts)).

This example is **self-contained**: it vendors the dependency-free OAUTHBEARER
transport ([`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts)) and the token helper
([`src/get-auth-token.ts`](src/get-auth-token.ts)). The npm dependencies are
`drizzle-orm` + `pg-types` (runtime) plus `drizzle-kit` + `pg` (for Studio only).

### Files

- [`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts) — vendored transport: socket +
  `OAUTHBEARER` SASL handshake + extended-query protocol. Canonical copy lives in
  [`../transport`](../transport).
- [`src/get-auth-token.ts`](src/get-auth-token.ts) — vendored token helper. Mints a
  test token here; in a real app you'd return the current user's session token.
- [`src/drizzle-proxy.ts`](src/drizzle-proxy.ts) — builds a Drizzle db over the
  transport using `drizzle-orm/pg-proxy` (one async query callback; no custom
  dialect needed), decoding values by type OID via `pg-types`.
- [`src/schema/`](src/schema) — the committed schema snapshot generated from a
  fresh `_core` catalog (`admin.ts` = the `_core` module, plus `index.ts`).
- [`src/list-users.ts`](src/list-users.ts) — sample #1, "list users". Each sample is
  its own task-named file in `src/`; add more (a count, a join, …) as sibling files.
- [`drizzle.config.ts`](drizzle.config.ts) — config for `drizzle-kit studio`.

## What it does

1. Get an access token via [`src/get-auth-token.ts`](src/get-auth-token.ts) — it
   mints a test token here; in a real app you'd return the current user's session
   token instead.
2. Connect as `authenticated`, presenting that token over SASL `OAUTHBEARER`.
3. Call `public.get_userinfo()` once — first-login provisioning. It assigns the
   `User` role (which carries `user:read`), so the RLS `SELECT` policy on `users`
   lets us read. Without it the list comes back empty.
4. Run a typed `db.select(...).from(users)` and print the rows visible under RLS.

## Prerequisites

A running pgdocker stack with the Semantic Platform `_core` present. From `pgdocker/`:

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
(`tsx src/list-users.ts`). Further samples (a count, a join over `relations()`, …)
drop in as sibling files — `src/<task>.ts` — and run the same way.

Expected output (fresh stack — `user1` becomes the admin on first login):

```
Minting token for "user1" from https://oidc-test.semanti.us …
Connected: { current_user: 'authenticated', system_user: 'oauth:user1' }
┌─────────┬─────┬─────────────┬─────────────────┬──────────────┬──────────┐
│ (index) │ id  │ externalId  │ email           │ displayName  │ lastSeen │
├─────────┼─────┼─────────────┼─────────────────┼──────────────┼──────────┤
│    0    │  1  │   'user1'   │ 'user@test.com' │ 'John Smith' │   null   │
└─────────┴─────┴─────────────┴─────────────────┴──────────────┴──────────┘

1 user(s) visible to "user1" under RLS.
```

Note `id` is a real number (`1`, not `'1'`) — see [How values are typed](#how-values-are-typed).

> Want more rows? Run it once per user (`USER_ID=user1`, `user2`, `user3`) to
> provision each, then list again — every provisioned user gets `user:read`.

## Drizzle Studio

```bash
DATABASE_URL=postgresql://postgres:devpassword@localhost:5432/appdb npm run studio
```

Studio is **independent of the OAUTHBEARER transport**. `drizzle-kit` only speaks
the standard PostgreSQL drivers (here `pg`), configured through
[`drizzle.config.ts`](drizzle.config.ts) — so it connects with a normal password
connection string as the **`postgres` superuser** (SCRAM auth, see
`pgdocker/conf/pg_hba.conf`). Being a superuser it **bypasses RLS**, which is what
you want for a dev data browser: you see every row, not just the ones one OAuth
user can read. The OAuth path (role `authenticated`, RLS-enforced) is only used by
`npm start`.

Point `DATABASE_URL` at your stack's `postgres` login (port **5433** for the
extension stack). The generated `relations()` give Studio its relationship links.

## Regenerate the schema

The committed [`src/schema/`](src/schema) is generated from the catalog. To refresh
it (e.g. after changing entities/fields), run the CLI generator from the repo root
against a stack that has your catalog deployed:

```bash
deno task drizzlegen --output examples/drizzle/src/schema
```

It writes one file per module (named by `module_slug`) plus `index.ts`, covering
every entity in the catalog, with `.references()` and `relations()` for foreign
keys (`reference` / `parent` fields). `enum` fields become
`text(col, { enum: [...] })` — a `TEXT` column typed as a literal union (e.g.
`'system' | 'model' | …`), matching the DB's `TEXT` + `CHECK` (not a native PG
enum), with `''` included for non-required enums to mirror the column's allowed
set.

## Configuration

| Env var | Default | Meaning |
| ------- | ------- | ------- |
| `PGHOST` | `localhost` | database host |
| `PGPORT` | `5432` | `5432` = CLI stack, `5433` = extension stack |
| `PGDATABASE` | `appdb` | database name |
| `USER_ID` | `user1` | test user to mint a token for (`user1`/`user2`/`user3`) |
| `CLIENT_ID` | `test-client` | OAuth client id |
| `ISSUER` | `https://oidc-test.semanti.us` | OIDC issuer (must match `pg_hba.conf`) |
| `DATABASE_URL` | `postgresql://postgres:devpassword@localhost:5432/appdb` | **Studio only** — the `postgres` login `drizzle-kit` uses |

## How values are typed

The transport speaks PostgreSQL's TEXT wire format, so every value comes off the
socket as a string. But the wire `RowDescription` also carries the **type OID** of
each column, and the transport exposes those as `fieldTypes`. That's all the
information needed to type the results, so [`src/drizzle-proxy.ts`](src/drizzle-proxy.ts)
runs each value through node-postgres' own [`pg-types`](https://www.npmjs.com/package/pg-types)
parser keyed by its OID — the exact decoding node-postgres does internally.

The result is real JS values, which are precisely what Drizzle's column mappers
expect: `integer` → number, `boolean` → boolean, `timestamp`/`date` → `Date`,
`jsonb` → object, `numeric`/`bigint` → string (matching node-postgres). So a typed
`db.select()` returns correctly-typed rows, not strings.

See [`../transport`](../transport) for the transport's other caveats (one
connection, token-first, no TLS).
