/**
 * @semantius/neon-provisioner - Hono server for Cloudflare Workers
 *
 * Routes:
 *   POST /migrate           — Run database migrations
 *   POST /neon-provisioner  — Full Neon provisioning: project, JWKS, migration, data API
 *   POST /refresh_cache     — Reset Neon Data API cache and update _settings cache_version
 */

import { Hono } from "hono";
import { migrate } from "./migrate.js";
import {
  findProjectByName,
  createProject,
  getProjectConnectionUri,
  listProjectJwks,
  addProjectJwks,
  listRoles,
  deleteRole,
  listBranches,
  listDatabases,
  createDataApi,
  patchDataApi,
} from "./neon-api.js";
import { Pool } from "@neondatabase/serverless";

type Bindings = {
  DATABASE_URL?: string;
  NEON_API_KEY?: string;
  NEON_PROVISIONER_API_KEY?: string;
  ASSETS?: Fetcher;
};

const app = new Hono<{ Bindings: Bindings }>();

// Require NEON_PROVISIONER_API_KEY to be configured — refuse all requests if missing
app.use("*", async (c, next) => {
  const provisionerKey = c.env?.NEON_PROVISIONER_API_KEY;
  if (!provisionerKey) {
    return c.json(
      {
        success: false,
        error: "Service misconfigured: NEON_PROVISIONER_API_KEY environment variable is not set",
      },
      500,
    );
  }
  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  // Use constant-time byte comparison to prevent timing attacks
  const enc = new TextEncoder();
  const a = enc.encode(token);
  const b = enc.encode(provisionerKey);
  let mismatch = a.byteLength !== b.byteLength ? 1 : 0;
  const len = Math.min(a.byteLength, b.byteLength);
  for (let i = 0; i < len; i++) {
    mismatch |= a[i] ^ b[i];
  }
  if (mismatch !== 0) {
    return c.json({ success: false, error: "Unauthorized" }, 401);
  }
  return next();
});

/**
 * POST /migrate
 *
 * Accepts a JSON body with:
 *   - database_url: string (required)
 *   - modules: string[]   (optional, defaults to all bundled apps)
 *
 * Returns JSON with migration result.
 */
app.post("/migrate", async (c) => {
  let body: { database_url?: string; modules?: string[] };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const databaseUrl = body.database_url ?? c.env?.DATABASE_URL;

  if (!databaseUrl) {
    return c.json(
      {
        success: false,
        error:
          "database_url must be provided in the request body or set as the DATABASE_URL environment variable",
      },
      400,
    );
  }

  try {
    const result = await migrate(databaseUrl, body.modules, { verbose: true });
    return c.json(result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

/**
 * POST /neon-provisioner
 *
 * Full Neon provisioning workflow:
 *   1. Check if project exists by name, create if not
 *   2. Check/create JWKS entry
 *   3. Run _core migrations using the project's connection URI
 *   4. Get branch_id for "main" branch
 *   5. Get database_name from databases list
 *   6. Create data API with external auth
 *
 * Accepts JSON body:
 *   - project_name: string  (required)
 *   - jwks_url: string      (required)
 *   - jwt_audience: string  (required)
 *   - region_id: string     (required)
 *   - modules: string[]     (optional, defaults to ["_core"])
 *
 * Returns JSON with project_id and connection on success.
 */
app.post("/neon-provisioner", async (c) => {
  let body: {
    project_name?: string;
    jwks_url?: string;
    jwt_audience?: string;
    region_id?: string;
    modules?: string[];
  };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const { project_name, jwks_url, jwt_audience, region_id } = body;

  if (!project_name || !jwks_url || !jwt_audience || !region_id) {
    return c.json(
      {
        success: false,
        error: "project_name, jwks_url, jwt_audience, and region_id are all required",
      },
      400,
    );
  }

  const apiKey = c.env?.NEON_API_KEY;

  if (!apiKey) {
    return c.json(
      {
        success: false,
        error: "NEON_API_KEY environment variable must be set",
      },
      500,
    );
  }

  const apiOptions = { apiKey };

  try {
    // Step 1: Check if project already exists, create if not
    let projectId: string;
    let connection: Record<string, unknown>;

    const existingProject = await findProjectByName(project_name, apiOptions);

    if (existingProject) {
      projectId = existingProject.id as string;

      // Discover the database name, then get connection URI
      const existingBranches = await listBranches(projectId, apiOptions);
      const existingMainBranch = existingBranches.find(
        (b: Record<string, unknown>) => b.name === "main",
      );
      if (!existingMainBranch) {
        return c.json(
          { success: false, error: "Could not find 'main' branch on existing project" },
          500,
        );
      }
      const existingDatabases = await listDatabases(projectId, existingMainBranch.id as string, apiOptions);
      if (!existingDatabases || existingDatabases.length === 0) {
        return c.json(
          { success: false, error: "No databases found on existing project's main branch" },
          500,
        );
      }
      const existingDbName = existingDatabases[0].name as string;
      const existingBranchId = existingMainBranch.id as string;

      const existingRoles = await listRoles(projectId, existingBranchId, apiOptions);
      if (!existingRoles || existingRoles.length === 0) {
        return c.json(
          { success: false, error: "No roles found on existing project's main branch" },
          500,
        );
      }
      const existingRoleName = existingRoles[0].name as string;

      const connDetails = await getProjectConnectionUri(projectId, existingDbName, existingRoleName, apiOptions);
      connection = connDetails;
    } else {
      const createResult = await createProject(project_name, region_id, apiOptions);

      const project = createResult.project as Record<string, unknown>;
      projectId = project.id as string;

      const connectionUris = createResult.connection_uris as Array<Record<string, unknown>>;

      if (!connectionUris || connectionUris.length === 0) {
        return c.json(
          {
            success: false,
            error: "No connection URIs returned from project creation",
          },
          500,
        );
      }

      connection = connectionUris[0];
    }

    // Step 2: Check if JWKS URL already exists, create if not
    const existingJwks = await listProjectJwks(projectId, apiOptions);
    const jwksExists = existingJwks.some(
      (j: Record<string, unknown>) => j.jwks_url === jwks_url,
    );

    if (!jwksExists) {
      await addProjectJwks(projectId, jwks_url, jwt_audience, apiOptions);
    }

    // Step 3: Get branch_id for "main" branch
    const branches = await listBranches(projectId, apiOptions);
    const mainBranch = branches.find(
      (b: Record<string, unknown>) => b.name === "main",
    );

    if (!mainBranch) {
      return c.json(
        { success: false, error: "Could not find 'main' branch" },
        500,
      );
    }

    const branchId = mainBranch.id as string;

    // Step 4: Get database_name from databases list
    const databases = await listDatabases(projectId, branchId, apiOptions);

    if (!databases || databases.length === 0) {
      return c.json(
        { success: false, error: "No databases found on main branch" },
        500,
      );
    }

    const databaseName = databases[0].name as string;

    // Step 5: Delete existing authenticator role if present, then create data API
    const roles = await listRoles(projectId, branchId, apiOptions);
    for (const name of ["authenticator", "authenticated", "anonymous"]) {
      if (roles.some((r: Record<string, unknown>) => r.name === name)) {
        await deleteRole(projectId, branchId, name, apiOptions);
      }
    }

    const dataApiResult = await createDataApi(
      projectId,
      branchId,
      databaseName,
      jwks_url,
      jwt_audience,
      apiOptions,
    );

    // Step 6: Run migrations using the connection URI (defaults to _core only)
    const connectionUri = (connection.connection_uri ?? connection.uri) as string;
    const modules = body.modules && body.modules.length > 0 ? body.modules : ["_core"];
    await migrate(connectionUri, modules, { verbose: true });

    // Build pooler URL from connection parameters
    const params = (connection.connection_parameters ?? {}) as Record<string, string>;
    const poolerHost = params.pooler_host ?? params.host;
    const databaseUrl = poolerHost
      ? `postgresql://${params.role}:${params.password}@${poolerHost}/${params.database}?sslmode=require`
      : connectionUri;

    // Success response
    return c.json({
      success: true,
      project_id: projectId,
      branch_id: branchId,
      database_name: databaseName,
      database_url: databaseUrl,
      connection,
      data_api: dataApiResult,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

/**
 * POST /refresh_cache
 *
 * Resets the Neon Data API cache for a specific database, then updates the
 * cache_version setting in the _settings table so downstream consumers know
 * the cache has been refreshed.
 *
 * Accepts JSON body:
 *   - project_id:    string  (required)
 *   - branch_id:     string  (required)
 *   - database_name: string  (required)
 *   - database_url:  string  (required)
 *
 * Returns JSON with success status and cache_reset_ts on success.
 */
app.post("/refresh_cache", async (c) => {
  const cache_reset_ts = Date.now();

  let body: {
    project_id?: string;
    branch_id?: string;
    database_name?: string;
    database_url?: string;
  };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const { project_id, branch_id, database_name, database_url } = body;

  if (!project_id || !branch_id || !database_name || !database_url) {
    return c.json(
      {
        success: false,
        error: "project_id, branch_id, database_name, and database_url are all required",
      },
      400,
    );
  }

  const apiKey = c.env?.NEON_API_KEY;

  if (!apiKey) {
    return c.json(
      {
        success: false,
        error: "NEON_API_KEY environment variable must be set",
      },
      500,
    );
  }

  try {
    // Step 1: PATCH the Neon Data API to trigger cache reset
    await patchDataApi(project_id, branch_id, database_name, { apiKey });

    // Step 2: Connect to the database and update _settings cache_version
    const pool = new Pool({ connectionString: database_url });
    try {
      const result = await pool.query(
        "SELECT value FROM _settings WHERE name = 'cache_version'",
      );

      const existing = (result.rows[0] as { value: string } | undefined)?.value;
      const shouldUpdate =
        existing === undefined ||
        Number(existing) < cache_reset_ts;

      if (shouldUpdate) {
        await pool.query(
          `INSERT INTO _settings (name, value) VALUES ('cache_version', $1)
           ON CONFLICT (name) DO UPDATE SET value = $1`,
          [String(cache_reset_ts)],
        );
      }
    } finally {
      await pool.end();
    }

    return c.json({ success: true, cache_reset_ts });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

export default app;
