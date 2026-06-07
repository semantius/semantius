# Examples

Runnable examples for integrating with a Semantic Platform database.

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`transport/`](transport/) | library | `@semantius/pg-oauthbearer` — a tiny, dependency-free Node client that authenticates to PostgreSQL 18 with an **OAuth bearer token** over SASL `OAUTHBEARER`. Also holds the shared `get-auth-token` helper. The shared building blocks. |
| [`kysely-raw/`](kysely-raw/) | example | List users with **Kysely** using **raw SQL** (no generated types) over an OAuth token. Vendors the building blocks above. |
| [`drizzle/`](drizzle/) | example | List users with **Drizzle**, **typed** via a schema generated from the catalog (`deno task drizzlegen`), over an OAuth token via `pg-proxy`. Includes Drizzle Studio. Vendors the building blocks above. |

Naming: a plain library name (`drizzle/`) is the **typed / schema-driven** flavor;
a `-raw` suffix (`kysely-raw/`) is **raw SQL with no generated types**.

Each folder is a self-contained npm package — `cd` into it, run `npm install`,
and follow its README. Examples **vendor** copies of the shared building blocks
(`pg-oauthbearer`, `get-auth-token`) so they run standalone; the canonical copies
live in [`transport/`](transport/).
