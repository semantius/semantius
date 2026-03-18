/**
 * @semantius/neon-provisioner - Hono server for Cloudflare Workers
 *
 * Routes:
 *   POST /migrate           — Run database migrations
 *   POST /neonnew           — Provision a new Neon database and run migrations
 *   POST /neon-provisioner  — Full Neon provisioning: project, JWKS, migration, data API
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
} from "./neon-api.js";

type Bindings = {
  DATABASE_URL?: string;
  NEON_API_KEY?: string;
  ASSETS?: Fetcher;
};

const app = new Hono<{ Bindings: Bindings }>();

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
 * POST /neonnew
 *
 * Accepts an optional JSON body with:
 *   - modules: string[] (optional, defaults to all bundled apps)
 *
 * Provisions a new Neon database via https://neon.new/api/v1/database,
 * then runs migrations against the returned data_url.
 *
 * Returns the full response from https://neon.new/api/v1/database.
 */
app.post("/neonnew", async (c) => {
  let body: { modules?: string[] } = {};

  try {
    body = await c.req.json();
  } catch {
    // body is optional
  }

  let neonResponse: Record<string, unknown>;

  try {
    const res = await fetch("https://neon.new/api/v1/database", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ref: "semantius" }),
    });
    neonResponse = (await res.json()) as Record<string, unknown>;
    if (!res.ok) {
      return c.json(
        {
          success: false,
          error: `Neon provisioning returned HTTP ${res.status}`,
          ...neonResponse,
        },
        500,
      );
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json(
      { success: false, error: `Failed to provision Neon database: ${message}` },
      500,
    );
  }

  const databaseUrl = neonResponse.data_url as string | undefined;

  if (!databaseUrl) {
    return c.json(
      {
        success: false,
        error: "No data_url returned from Neon provisioning",
        ...neonResponse,
      },
      500,
    );
  }

  try {
    const result = await migrate(databaseUrl, body.modules, { verbose: true });
    return c.json({ ...neonResponse, migrate: result });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json(
      { success: false, error: `Migration failed after successful provisioning: ${message}`, ...neonResponse },
      500,
    );
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
 *   - neon_api_key: string  (optional, falls back to NEON_API_KEY env)
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
    neon_api_key?: string;
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

  const apiKey = body.neon_api_key ?? c.env?.NEON_API_KEY;

  if (!apiKey) {
    return c.json(
      {
        success: false,
        error: "neon_api_key must be provided in the request body or set as the NEON_API_KEY environment variable",
      },
      400,
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

    // Success response
    return c.json({
      success: true,
      project_id: projectId,
      connection,
      data_api: dataApiResult,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

export default app;
