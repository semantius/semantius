# Examples

Runnable examples for integrating with Semantius core.

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`transport/`](transport/) | library | `@semantius/pg-oauthbearer` — a tiny, dependency-free Node client that authenticates to PostgreSQL 18 with an **OAuth bearer token** over SASL `OAUTHBEARER`. The shared building block. |
| [`kysely-direct/`](kysely-direct/) | example | List users from Semantius core with **Kysely** over an OAuth token. Vendors the transport above. |

Planned: `drizzle-direct/` (Drizzle via `pg-proxy`, reusing the same transport).

Each folder is a self-contained npm package — `cd` into it, run `npm install`,
and follow its README. Examples **vendor** a copy of the transport so they run
standalone; the canonical copy lives in [`transport/`](transport/).
