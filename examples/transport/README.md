# `@semantius/pg-oauthbearer` — the transport

A tiny, **dependency-free** PostgreSQL client for Node that authenticates with a
**pre-minted OAuth bearer token** over SASL **`OAUTHBEARER`** (PostgreSQL 18), and
runs parameterized queries. It is the shared building block the examples use.

The client lives in one file: [`src/pg-oauthbearer.ts`](src/pg-oauthbearer.ts). A
companion helper [`src/get-auth-token.ts`](src/get-auth-token.ts) (also vendored by
the examples) returns the OAuth token to authenticate with — it mints a **test**
token here, and is the single place you'd swap for your real session-token source.

## Why it exists

PostgreSQL 18 added native OAuth via the SASL `OAUTHBEARER` mechanism, and the
Semantius self-host stack uses it: in [`pg_hba.conf`](../../pgdocker/conf/pg_hba.conf)
the `authenticated` role is **`oauth`-only**. So:

- **There is no "JWT in the connection string."** The bearer token is presented
  *inside* the SASL handshake (RFC 7628), not as a URL password. (The
  `postgresql://user:<JWT>@host/db` form is a different, proxy-based model —
  Supabase/Neon/PostgREST — and is rejected here.)
- **No Node Postgres driver speaks `OAUTHBEARER` yet** (`pg`, `postgres.js`), and
  none lets you inject a pre-minted token. Even libpq only supports the
  *interactive* device flow (the client fetches its own token).

So this module speaks just enough of the PostgreSQL v3 wire protocol, by hand, to
do the handshake and query. It is a Node port of the proven
[`pgdocker/verify_oauth.ts`](../../pgdocker/verify_oauth.ts) (which uses the
*simple* query protocol; this adds the *extended* protocol so `$1, $2, …`
parameters work).

## API

```ts
import { PgOAuthConnection } from "./pg-oauthbearer";

const conn = await PgOAuthConnection.connect({
  host: "localhost",
  port: 5432,
  database: "appdb",
  user: "authenticated", // default
  token,                  // a pre-minted OAuth access token (JWT)
});

const { fields, rows } = await conn.query(
  "select id, email from users where id = $1",
  [1],
);
// fields: string[]            (column names)
// rows:   (string|null)[][]   (TEXT values, in column order)

await conn.end();
```

Results come back in the **TEXT** wire format (values are strings or null) — the
caller maps them to JS types. Returning rows as arrays-of-values is intentional:
it is the raw wire shape, which both the Kysely `Driver` and Drizzle's `pg-proxy`
can consume directly.

## Reusing it

It is a single file with **no dependencies**, so pick whichever fits:

- **Copy** `src/pg-oauthbearer.ts` into your project (what the examples do — see
  [`../kysely-raw`](../kysely-raw)).
- **Import** it as a local package: add `"@semantius/pg-oauthbearer": "file:../transport"`
  to your `package.json` (works under bundler-style resolution / `tsx`).

## Caveats (example code, not a production driver)

- **One connection, not a pool** — queries are serialized on the wire.
- **TEXT wire format** — values arrive as strings.
- **Token-first** — you bring a pre-minted token; refresh/expiry is out of scope.
- **No TLS** — matches the local stack's plain `host`. For anything non-local,
  switch `pg_hba.conf` to `hostssl` and wrap the socket in `tls.connect()`.

## Type-check

```bash
npm install
npm run typecheck
```
