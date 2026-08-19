import { Hono } from "hono";
import type { Bindings } from "../types.js";
import { migrate } from "../migrate.js";
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
} from "../neon-api.js";
import { Pool } from "@neondatabase/serverless";

const route = new Hono<{ Bindings: Bindings }>();

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
 *   - is_free_plan: boolean (optional, when true uses NEON_API_KEY_FREE)
 *
 * Returns JSON with project_id, org_id (Neon org owning the project) and
 * connection on success.
 */
route.post("/", async (c) => {
  let body: {
    project_name?: string;
    jwks_url?: string;
    jwt_audience?: string;
    region_id?: string;
    modules?: string[];
    name?: string;
    is_free_plan?: boolean;
  };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const { project_name, jwks_url, jwt_audience, region_id, name } = body;

  if (!project_name || !jwks_url || !jwt_audience || !region_id) {
    return c.json(
      {
        success: false,
        error: "project_name, jwks_url, jwt_audience, and region_id are all required",
      },
      400,
    );
  }

  const isFreePlan = body.is_free_plan === true;
  const apiKeyVar = isFreePlan ? "NEON_API_KEY_FREE" : "NEON_API_KEY";
  const apiKey = isFreePlan ? c.env?.NEON_API_KEY_FREE : c.env?.NEON_API_KEY;

  if (!apiKey) {
    return c.json(
      {
        success: false,
        error: `${apiKeyVar} environment variable must be set`,
      },
      500,
    );
  }

  const apiOptions = { apiKey };

  try {
    // Step 1: Check if project already exists, create if not
    let projectId: string;
    let orgId: string | null;
    let connection: Record<string, unknown>;

    const existingProject = await findProjectByName(project_name, apiOptions);

    if (existingProject) {
      projectId = existingProject.id as string;
      orgId = (existingProject.org_id as string | undefined) ?? null;

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
      orgId = (project.org_id as string | undefined) ?? null;

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

    await new Promise((resolve) => setTimeout(resolve, 2000));
    const roles2 = await listRoles(projectId, branchId, apiOptions);
    for (const name of ["authenticator", "authenticated", "anonymous"]) {
      if (roles2.some((r: Record<string, unknown>) => r.name === name)) {
        console.error(`Role still exists after deletion: ${name}`);
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

    // Step 7: Save jwt_aud to _settings so PostgREST can verify token audience
    const pool = new Pool({ connectionString: connectionUri });
    try {
      await pool.query(
        `INSERT INTO _settings (name, value) VALUES ('jwt_aud', $1)
         ON CONFLICT (name) DO UPDATE SET value = $1`,
        [jwt_audience],
      );
    } finally {
      await pool.end();
    }

    // Step 8: Save slug to _settings if provided
    if (name) {
      const slugPool = new Pool({ connectionString: connectionUri });
      try {
        await slugPool.query(
          `INSERT INTO _settings (name, value) VALUES ('slug', $1)
           ON CONFLICT (name) DO UPDATE SET value = $1`,
          [name],
        );
      } finally {
        await slugPool.end();
      }
    }

    // Build pooler URL and direct URL from connection parameters
    const params = (connection.connection_parameters ?? {}) as Record<string, string>;
    const poolerHost = params.pooler_host ?? params.host;
    const databaseUrl = poolerHost
      ? `postgresql://${params.role}:${params.password}@${poolerHost}/${params.database}?sslmode=require`
      : connectionUri;
    const directHost = params.host;
    const databaseUrlDirect = directHost
      ? `postgresql://${params.role}:${params.password}@${directHost}/${params.database}?sslmode=require`
      : connectionUri;

    // Success response
    return c.json({
      success: true,
      project_id: projectId,
      org_id: orgId,
      branch_id: branchId,
      database_name: databaseName,
      database_url: databaseUrl,
      database_url_direct: databaseUrlDirect,
      connection,
      data_api: dataApiResult,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

export default route;
