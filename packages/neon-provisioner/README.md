# @semantius/neon-provisioner

A [Hono](https://hono.dev/) server for **Cloudflare Workers** that provisions
[Neon](https://neon.tech/) Postgres databases, configures external JWT auth,
runs `_core` (and optional module) migrations, and manages the Neon Data API
cache.

## Routes

| Method | Path                 | Purpose                                                                      |
| ------ | -------------------- | ---------------------------------------------------------------------------- |
| `POST` | `/neon-provisioner`  | Full provisioning: find/create project, JWKS, migrations, Data API           |
| `POST` | `/migrate`           | Run database migrations against an existing database                         |
| `POST` | `/refresh_cache`     | Reset the Neon Data API cache and bump `_settings.cache_version`             |

All three routes require authentication (see below). Static assets are served
without auth.

## Authentication

Every API route requires a bearer token that must match the
`NEON_PROVISIONER_API_KEY` environment variable:

```
Authorization: Bearer <NEON_PROVISIONER_API_KEY>
```

Requests without a valid token receive `401 Unauthorized`. If the server has no
`NEON_PROVISIONER_API_KEY` configured, it returns `500`.

## Environment bindings

Configured as Worker secrets / `.dev.vars` for local development.

| Variable                   | Required        | Purpose                                                                                   |
| -------------------------- | --------------- | ----------------------------------------------------------------------------------------- |
| `NEON_API_KEY_PAID`        | ✅              | Neon platform API key for the **paid** Neon org (projects, JWKS, roles, Data API).        |
| `NEON_API_KEY_FREE`        | ✅              | Neon platform API key for the **free** Neon org.                                          |
| `NEON_PROVISIONER_API_KEY` | ✅              | Shared secret callers pass as `Authorization: Bearer <key>` on every API route.           |

Requests select the key via `neon_org_id` (`"free"` \| `"paid"`): the worker reads
`NEON_API_KEY_<NEON_ORG_ID uppercased>`. Adding a Neon org = add a value to
`NEON_ORG_IDS` in `src/neon-org.ts` + a matching secret.

`.dev.vars` example:

```
NEON_API_KEY_PAID=napi_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
NEON_API_KEY_FREE=napi_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
NEON_PROVISIONER_API_KEY=your-shared-secret
```

> ⚠️ `.dev.vars` holds live secrets — keep it out of version control (gitignored).

## `POST /neon-provisioner`

Runs the full provisioning workflow:

1. Find the project by name, or create it if it doesn't exist.
2. Add the JWKS entry for external JWT auth (if not already present).
3. Recreate the `authenticator` / `authenticated` / `anonymous` roles.
4. Create the Neon Data API with external auth.
5. Run migrations (defaults to `_core`) against the project connection URI.
6. Save `jwt_aud` (and `slug`, if `name` is given) to the `_settings` table.

### Request body

| Field          | Type       | Required | Description                                                                          |
| -------------- | ---------- | -------- | ------------------------------------------------------------------------------------ |
| `project_name` | `string`   | ✅       | Neon project name to find or create.                                                 |
| `jwks_url`     | `string`   | ✅       | JWKS endpoint used to verify JWTs.                                                    |
| `jwt_audience` | `string`   | ✅       | Expected JWT audience; saved to `_settings.jwt_aud` for PostgREST verification.       |
| `region_id`    | `string`   | ✅       | Neon region used when creating a new project (e.g. `aws-us-east-1`).                  |
| `modules`      | `string[]` | ❌       | Migration modules to run. Defaults to `["_core"]`.                                    |
| `name`         | `string`   | ❌       | Tenant slug; saved to `_settings.slug` when provided.                                 |
| `neon_org_id`  | `string`   | ✅       | `"free"` or `"paid"` — selects `NEON_API_KEY_<ALIAS>` (the Neon org to provision in). |

### Example

```bash
curl -X POST https://<worker-host>/neon-provisioner \
  -H "Authorization: Bearer $NEON_PROVISIONER_API_KEY" \
  -H "Content-Type: application/json" \
  -d ' '
```

### Success response

```json
{
  "success": true,
  "project_id": "...",
  "branch_id": "...",
  "database_name": "...",
  "database_url": "postgresql://...",
  "database_url_direct": "postgresql://...",
  "connection": { "...": "..." },
  "data_api": { "...": "..." }
}
```

## `POST /migrate`

Runs migrations against an existing database.

| Field          | Type       | Required | Description                                        |
| -------------- | ---------- | -------- | -------------------------------------------------- |
| `database_url` | `string`   | ✅       | Postgres connection string to migrate.             |
| `modules`      | `string[]` | ❌       | Migration modules. Defaults to all bundled apps.   |

## `POST /refresh_cache`

Resets the Neon Data API cache for a database, then updates
`_settings.cache_version`.

| Field           | Type     | Required | Description                    |
| --------------- | -------- | -------- | ------------------------------ |
| `project_id`    | `string` | ✅       | Neon project ID.               |
| `branch_id`     | `string` | ✅       | Neon branch ID.                |
| `database_name` | `string` | ✅       | Target database name.          |
| `database_url`  | `string` | ✅       | Connection string to update.   |
| `neon_org_id`   | `string` | ✅       | `"free"` or `"paid"`.          |

Uses `NEON_API_KEY_<NEON_ORG_ID>` for the Data API PATCH call.

## Development

```bash
pnpm dev      # wrangler dev (local)
pnpm build    # tsc
pnpm deploy   # wrangler deploy
```
