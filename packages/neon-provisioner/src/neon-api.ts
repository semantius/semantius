/**
 * @semantius/neon-provisioner - Neon API v2 client
 *
 * Helper functions for interacting with the Neon API v2:
 *   https://neon.com/api_spec/release/v2.json
 *
 * All functions take the Neon API key (NEON_API_KEY_<NEON_ORG_ID>) via options.
 */

const NEON_API_BASE = "https://console.neon.tech/api/v2";

interface NeonApiOptions {
  apiKey: string;
}

const MAX_RETRIES = 10;
const RETRY_BASE_MS = 1000;

async function neonFetch(
  path: string,
  options: NeonApiOptions,
  init?: RequestInit,
): Promise<Response> {
  const url = `${NEON_API_BASE}${path}`;
  const fetchInit = {
    ...init,
    headers: {
      Authorization: `Bearer ${options.apiKey}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      ...((init?.headers as Record<string, string>) ?? {}),
    },
  };

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const res = await fetch(url, fetchInit);
    if (res.status !== 423 || attempt === MAX_RETRIES) {
      return res;
    }
    const delay = RETRY_BASE_MS * Math.pow(2, attempt);
    console.log(`[neon-api] 423 Locked on ${path}, retrying in ${delay}ms (attempt ${attempt + 1}/${MAX_RETRIES})`);
    await new Promise((r) => setTimeout(r, delay));
  }

  throw new Error("Unreachable");
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
 * Get the connection URI for an existing project.
 * Requires database_name as a query parameter per the Neon API spec.
 */
export async function getProjectConnectionUri(
  projectId: string,
  databaseName: string,
  roleName: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const params = new URLSearchParams({ database_name: databaseName, role_name: roleName });
  const res = await neonFetch(
    `/projects/${projectId}/connection_uri?${params}`,
    options,
  );
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
      provider_name: "external",
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to add JWKS (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
}

/**
 * List roles on a branch. Returns the array of role objects.
 */
export async function listRoles(
  projectId: string,
  branchId: string,
  options: NeonApiOptions,
): Promise<Array<Record<string, unknown>>> {
  const res = await neonFetch(
    `/projects/${projectId}/branches/${branchId}/roles`,
    options,
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to list roles (HTTP ${res.status}): ${body}`);
  }
  const data = (await res.json()) as { roles: Array<Record<string, unknown>> };
  return data.roles ?? [];
}

/**
 * Delete a role on a branch by name.
 */
export async function deleteRole(
  projectId: string,
  branchId: string,
  roleName: string,
  options: NeonApiOptions,
): Promise<void> {
  const res = await neonFetch(
    `/projects/${projectId}/branches/${branchId}/roles/${roleName}`,
    options,
    { method: "DELETE" },
  );
  if (!res.ok && res.status !== 404) {
    const body = await res.text();
    throw new Error(`Failed to delete role ${roleName} (HTTP ${res.status}): ${body}`);
  }
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
 * Patch (refresh) the data API for a database on a branch.
 * Sends PATCH with an empty JSON body to trigger a cache reset.
 */
export async function patchDataApi(
  projectId: string,
  branchId: string,
  databaseName: string,
  options: NeonApiOptions,
): Promise<Record<string, unknown>> {
  const res = await neonFetch(
    `/projects/${projectId}/branches/${branchId}/data-api/${databaseName}`,
    options,
    {
      method: "PATCH",
      body: JSON.stringify({}),
    },
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to patch data API (HTTP ${res.status}): ${body}`);
  }
  return (await res.json()) as Record<string, unknown>;
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
