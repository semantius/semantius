# Examples

**All samples moved to
[`../bearer-auth-experimental/examples/`](../bearer-auth-experimental/examples/)
on 2026-09-06.**

Every sample with a database tier was built around **PostgreSQL 18 bearer
authentication** - the client authenticates the database connection with the
end-user's OAuth token over SASL `OAUTHBEARER`. (`spa-frontend/` is the
exception: it is a browser SPA that calls the Hono API and never touches the
database.) That feature is not ready for production for our use cases: it runs
on self-hosted PostgreSQL 18 only, and no session pooler supports it. See
[docs/bearer-mode-status.md](../docs/bearer-mode-status.md).

Two of them (`nextjs/` and `spa-hono-backend/`) also run in
`DB_AUTH_MODE=session`, which is built for Neon and Supabase and needs none of
PostgreSQL 18's OAuth machinery - though neither has actually been run against
either platform yet. That path is **for mature audiences**: correctness depends
on the developer honoring the adapter contract on every request, and nothing in
the database enforces it. Read
[the folder's README](../bearer-auth-experimental/README.md) before using them
as a template.

**No sample puts PostgREST or the Supabase client in front of the database** -
including Neon's managed Data API, which is a PostgREST. The app-server half of
the portable path is covered by the two `session`-mode samples; the
API-in-front half is not. That gap is open.
