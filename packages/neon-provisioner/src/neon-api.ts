/**
 * @semantius/neon-provisioner - Neon API v2 client
 *
 * Helper functions for interacting with the Neon API v2:
 *   https://neon.com/api_spec/release/v2.json
 *
 * All functions require a valid NEON_API_KEY for authentication.
 */

const NEON_API_BASE = "https://console.neon.tech/api/v2";

interface NeonApiOptions {
  apiKey: string;
}

async function neonFetch(
  path: string,
  options: NeonApiOptions,
  init?: RequestInit,
): Promise<Response> {
  const url = `${NEON_API_BASE}${path}`;
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${options.apiKey}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      ...((init?.headers as Record<string, string>) ?? {}),
    },
  });
  return res;
}

/**
 * Find a project by name from the list of projects.
 * Returns the project object if found, or null.
 */
export async function findProjectByName(
  projectName: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown> | null> {
  const res = await neonFetch("/projects", options);
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to list projects (HTTP ${res.status}): ${body}`);
  }
  const data = (await res.json()) as { projects: Array<Record<string, unknown>> };
  const project = data.projects.find(
    (p: Record<string, unknown>) => p.name === projectName,
  );
  return project ?? null;
}

/**
 * Create a new Neon project.
 * Returns the full create-project response (project, connection_uris, etc.).
 */
export async function createProject(
  projectName: string,
  regionId: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const res = await neonFetch("/projects", options, {
    method: "POST",
    body: JSON.stringify({
      project: {
        name: projectName,
        region_id: regionId,
      },
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to create project (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
}

/**
 * Get full project details (including connection_uris) for an existing project.
 */
export async function getProjectDetails(
  projectId: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const res = await neonFetch(`/projects/${projectId}/connection_uri`, options);
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to get project connection URI (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
}

/**
 * List JWKS entries for a project.
 */
export async function listProjectJwks(
  projectId: string,
  options: NeonApiOptions,
): Promise<Array<Record<string, unknown>>> {
  const res = await neonFetch(`/projects/${projectId}/jwks`, options);
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to list JWKS (HTTP ${res.status}): ${body}`);
  }
  const data = (await res.json()) as { jwks: Array<Record<string, unknown>> };
  return data.jwks ?? [];
}

/**
 * Add a JWKS entry for a project.
 */
export async function addProjectJwks(
  projectId: string,
  jwksUrl: string,
  jwtAudience: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const res = await neonFetch(`/projects/${projectId}/jwks`, options, {
    method: "POST",
    body: JSON.stringify({
      jwks_url: jwksUrl,
      jwt_audience: jwtAudience,
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to add JWKS (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
}

/**
 * List branches for a project. Returns the array of branch objects.
 */
export async function listBranches(
  projectId: string,
  options: NeonApiOptions,
): Promise<Array<Record<string, unknown>>> {
  const res = await neonFetch(`/projects/${projectId}/branches`, options);
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to list branches (HTTP ${res.status}): ${body}`);
  }
  const data = (await res.json()) as { branches: Array<Record<string, unknown>> };
  return data.branches ?? [];
}

/**
 * List databases on a branch. Returns the array of database objects.
 */
export async function listDatabases(
  projectId: string,
  branchId: string,
  options: NeonApiOptions,
): Promise<Array<Record<string, unknown>>> {
  const res = await neonFetch(
    `/projects/${projectId}/branches/${branchId}/databases`,
    options,
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to list databases (HTTP ${res.status}): ${body}`);
  }
  const data = (await res.json()) as { databases: Array<Record<string, unknown>> };
  return data.databases ?? [];
}

/**
 * Create (enable) the data API for a database on a branch.
 */
export async function createDataApi(
  projectId: string,
  branchId: string,
  databaseName: string,
  jwksUrl: string,
  jwtAudience: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const res = await neonFetch(
    `/projects/${projectId}/branches/${branchId}/data-api/${databaseName}`,
    options,
    {
      method: "POST",
      body: JSON.stringify({
        auth_provider: "external",
        jwks_url: jwksUrl,
        jwt_audience: jwtAudience,
      }),
    },
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to create data API (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
}
