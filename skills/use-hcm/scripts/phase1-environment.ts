/**
 * Phase 1, environment bootstrap check.
 *
 * Runs at bootstrap (when ready.flag is missing). Verifies the technical
 * prerequisites the skill needs before Phase 2 (structural discovery) can run.
 *
 * Checks in order (halt on first failure):
 *   1. semantius CLI installed, on PATH, and able to authenticate (getCurrentUser).
 *   2. The domain is deployed: a live module is stamped settings.domain_code = <CODE>,
 *      OR hosts an entity stamped with one of the domain's canonical master codes
 *      (ENTITY-FIRST), OR carries one of the spec's catalog_module_code / module_slug
 *      values (fallback).
 *
 * Domain membership is the UNION of two deterministic signals:
 *   (a) settings.domain_code, the deploy pipeline stamps every module it provisions
 *       with { domain_code: <CODE>, module_kind, ... } in its `settings` JSONB. This is
 *       the authoritative membership marker and, unlike the entity probe, holds even when
 *       a deployment's entities were created WITHOUT catalog_entity_code stamps.
 *   (b) ENTITY-FIRST, the module_ids that host the domain's OWNED entities, resolved
 *       from the canonical master codes (catalog_entity_code). This catches a deployment
 *       that packages the domain under any module name (e.g. a "hiring-starter" bundle)
 *       and a hand-built module whose settings were never stamped.
 * catalog_module_code / module_slug are kept only as weak hints. Keying the entity probe
 * on OWNED masters (not every referenced concept) keeps a foreign module that merely hosts
 * a shared/embedded master (e.g. an HR `org_units`) out of the slice.
 *
 * Output: structured JSON on stdout (machine-parseable for the agent + Phase 2a).
 *   { ok, phase, tenant, domain, domain_slice: [{module_id, ...}], modules, summary }
 * Exit code: 0 on success, non-zero on any check failure.
 *
 * Bun is required (this script is TypeScript on Bun). The agent verifies Bun via
 * `bun --version` before invoking this script.
 *
 * Run from the project root (semantius reads .env from cwd):
 *   bun run .claude/skills/use-<domain>/scripts/phase1-environment.ts
 */

import { readFileSync } from "fs";
import { resolve } from "path";

type Spec = {
  facts_major: number;
  emitted: string;
  // Domain specs carry `domain` + `modules` + `data_objects`; domain-less industry bundles
  // carry `bundle` + `composes`. The scripts normalize both into one shape (see normalize()).
  domain?: { code: string; name: string };
  modules?: Array<{
    code: string;
    name: string;
    masters?: string[];
    embedded_masters?: string[];
    consumers?: string[];
  }>;
  data_objects?: Array<{ name: string }>;
  bundle?: { code: string; name: string };
  composes?: Array<{ name: string; role?: string; owning_domain?: string | null }>;
};

// Normalize a domain spec OR a domain-less bundle spec into one model.
//   sliceCodes   = the entity codes used for the entity-first slice query. For a domain
//                  these are the OWNED masters only (so a foreign module that hosts a shared
//                  embedded master is not pulled in). A bundle owns nothing and its footprint
//                  spans the host-domain modules, so it uses ALL composed entity codes.
//   moduleHints  = [{code, name}] to probe by catalog_module_code / module_slug.
function normalize(spec: Spec): { code: string; name: string; isBundle: boolean; sliceCodes: string[]; moduleHints: Array<{ code: string; name: string }> } {
  if (spec.bundle) {
    const names = [...new Set((spec.composes ?? []).map((c) => c.name).filter(Boolean))];
    return {
      code: spec.bundle.code,
      name: spec.bundle.name,
      isBundle: true,
      sliceCodes: names,
      moduleHints: [{ code: spec.bundle.code, name: spec.bundle.name }],
    };
  }
  const dom = spec.domain ?? { code: "<unknown>", name: "<unknown>" };
  const sliceCodes = [...new Set([
    ...(spec.modules ?? []).flatMap((m) => m.masters ?? []),
    ...(spec.data_objects ?? []).map((o) => o.name),
  ])].filter(Boolean);
  return {
    code: dom.code,
    name: dom.name,
    isBundle: false,
    sliceCodes,
    moduleHints: (spec.modules ?? []).map((m) => ({ code: m.code, name: m.name })),
  };
}

type LiveModule = { id: number; module_slug: string; module_name: string; catalog_module_code: string; settings: any };
const MODULE_SELECT = "id,module_slug,module_name,catalog_module_code,settings";
type CmdResult = { ok: boolean; data: any; stderr: string; code: number };

async function call(server: string, tool: string, payload: any): Promise<CmdResult> {
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn(["semantius", "call", server, tool], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
  } catch (e: any) {
    // The binary is missing on PATH: Bun.spawn throws (ENOENT) instead of returning a
    // process. Translate to the recognizable "command not found" shape so the caller's
    // install-guidance branch fires (IMPROVE 4: this path was previously unreachable).
    return { ok: false, data: null, stderr: `command not found: semantius (${e?.message ?? e})`, code: 127 };
  }
  proc.stdin.write(JSON.stringify(payload));
  proc.stdin.end();
  const [out, err] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  if (code !== 0) return { ok: false, data: null, stderr: err.trim() || out.trim(), code };
  return { ok: true, data: out.trim() ? JSON.parse(out.trim()) : null, stderr: "", code };
}

async function get(path: string): Promise<any[]> {
  const r = await call("crud", "postgrestRequest", { method: "GET", path });
  if (!r.ok) throw new Error(r.stderr || `GET ${path} failed (exit ${r.code})`);
  return (r.data ?? []) as any[];
}

function halt(reason: string, fix: string): never {
  console.log(JSON.stringify({ ok: false, phase: 1, reason, fix }, null, 2));
  process.exit(1);
}

function moduleSlug(code: string): string {
  return code.toLowerCase().replace(/-/g, "_");
}

function chunk<T>(arr: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

// The CLI ships as a native installer (NOT an npm package). Emit the platform-specific
// one-liner so the agent can OFFER to run it for the user (IMPROVE 5). The agent must ask
// the user's go-ahead before running it (it modifies their system); it never auto-installs.
const INSTALL_DOCS = "https://github.com/semantius/semantius-cli#1-installation";
function installCommand(): string {
  return process.platform === "win32"
    ? "irm https://raw.githubusercontent.com/semantius/semantius-cli/main/install.ps1 | iex"
    : "curl -fsSL https://raw.githubusercontent.com/semantius/semantius-cli/main/install.sh | bash";
}
function haltMissingCli(): never {
  const cmd = installCommand();
  const platform = process.platform === "win32" ? "Windows (PowerShell)" : "Linux/macOS";
  console.log(JSON.stringify({
    ok: false,
    phase: 1,
    reason: "semantius CLI is not installed or not on PATH.",
    fix: `Install the semantius CLI, then restart your shell and re-run. ${platform}: ${cmd}  |  Guide: ${INSTALL_DOCS}`,
    can_offer_install: true,
    install_command: cmd,
    install_docs: INSTALL_DOCS,
  }, null, 2));
  process.exit(1);
}

async function main() {
  const skillDir = resolve(import.meta.dir, "..");
  const specPath = resolve(skillDir, "spec.json");

  let spec: Spec;
  try {
    spec = JSON.parse(readFileSync(specPath, "utf-8"));
  } catch (e: any) {
    halt(`Could not read spec.json at ${specPath}: ${e.message}`,
         "The skill bundle is incomplete. Reinstall the skill from the Semantius catalog.");
  }
  const view = normalize(spec);

  // Check 1: CLI installed + authenticated (folds install + auth into one call).
  const cu = await call("crud", "getCurrentUser", {});
  if (!cu.ok) {
    const stderr = cu.stderr.toLowerCase();
    if (cu.code === 127 || stderr.includes("command not found") || stderr.includes("not recognized") || stderr.includes("enoent")) {
      haltMissingCli();
    }
    if (stderr.includes("audience") || stderr.includes("jwt")) {
      halt(`JWT-audience error from semantius CLI: ${cu.stderr}`,
           "Known server-side issue. Surface this verbatim to the user and wait for direction. Do not retry in a loop.");
    }
    halt(`semantius CLI could not authenticate: ${cu.stderr}`,
         "Configure .env in the project root with SEMANTIUS_API_KEY=<your-key> (generate from Settings > API Keys). Docs: https://www.semantius.com/docs/agent-skills/installation/");
  }

  const tenantOrg = cu.data?.semantius_org ?? "<unknown>";
  const tenantEmail = cu.data?.email ?? "<unknown>";

  // ---- Check 2: resolve the domain SLICE (entity-first). ----
  // Canonical master codes = the entities the domain OWNS (spec.data_objects names ==
  // the union of every module's `masters`). Querying entities by these codes finds the
  // live modules hosting the domain regardless of how the deployment named them.
  const masterCodes = view.sliceCodes;

  const entityModuleIds = new Set<number>();
  const entityHits = new Map<number, number>();
  try {
    for (const part of chunk(masterCodes, 100)) {
      if (part.length === 0) continue;
      const rows = await get(`/entities?catalog_entity_code=in.(${part.join(",")})&select=module_id,catalog_entity_code`);
      for (const r of rows) {
        const mid = r.module_id as number;
        entityModuleIds.add(mid);
        entityHits.set(mid, (entityHits.get(mid) ?? 0) + 1);
      }
    }
  } catch (e: any) {
    const msg = String(e?.message ?? e).toLowerCase();
    if (msg.includes("audience") || msg.includes("jwt")) {
      halt(`JWT-audience error querying /entities: ${e.message}`,
           "Surface the verbatim error to the user and wait for direction. Do not retry in a loop.");
    }
    halt(`Could not query /entities for domain membership: ${e.message}`,
         "Check platform connectivity. If this is a JWT error, surface it verbatim.");
  }

  // ---- Authoritative deploy stamp: settings.domain_code = <CODE>. ----
  // The deploy pipeline writes { domain_code, module_kind, naming_mode, catalog_snapshot }
  // into each provisioned module's `settings` JSONB. Querying it resolves the slice directly,
  // and (unlike the entity probe) survives a deployment whose entities carry no
  // catalog_entity_code. Best-effort: a hand-built module may have settings = null, in which
  // case the entity-first union below still finds it.
  let byDomainCode: LiveModule[] = [];
  try {
    byDomainCode = (await get(`/modules?settings->>domain_code=eq.${view.code}&select=${MODULE_SELECT}`)) as LiveModule[];
  } catch { /* best-effort; entity-first + code/slug still resolve the slice */ }
  const settingsModuleIds = new Set<number>(byDomainCode.map((m) => m.id));

  // ---- Fallback / hint: module catalog_module_code + module_slug match. ----
  // SERIOUS 3: catalog_module_code is non-unique by design (clone-and-customize), so we
  // collect ALL matching module_ids; never collapse by code into a single row.
  const codes = view.moduleHints.map((m) => m.code).filter(Boolean);
  const slugs = view.moduleHints.map((m) => moduleSlug(m.code));
  let byCode: LiveModule[] = [];
  let bySlug: LiveModule[] = [];
  try {
    if (codes.length) byCode = (await get(`/modules?catalog_module_code=in.(${codes.join(",")})&select=${MODULE_SELECT}`)) as LiveModule[];
  } catch { /* hints are best-effort; entity-first is the source of truth */ }
  try {
    if (slugs.length) bySlug = (await get(`/modules?module_slug=in.(${slugs.join(",")})&select=${MODULE_SELECT}`)) as LiveModule[];
  } catch { /* best-effort */ }
  const codeModuleIds = new Set<number>(byCode.map((m) => m.id));
  const slugModuleIds = new Set<number>(bySlug.map((m) => m.id));

  const sliceIds = [...new Set<number>([...settingsModuleIds, ...entityModuleIds, ...codeModuleIds, ...slugModuleIds])];

  if (sliceIds.length === 0) {
    halt(
      `The ${view.name} (${view.code}) ${view.isBundle ? "bundle" : "domain"} is not deployed in this platform (${tenantOrg}). No live module is stamped settings.domain_code = ${view.code}, hosts its entities, or carries its catalog codes.`,
      `Deploy the blueprint first, then re-run this skill. Blueprint: https://www.semantius.com/blueprints/${view.code.toLowerCase()}`,
    );
  }

  // Resolve module detail for any slice members discovered only via entity codes.
  const sliceModuleById = new Map<number, LiveModule>();
  for (const m of [...byDomainCode, ...byCode, ...bySlug]) sliceModuleById.set(m.id, m);
  const missing = sliceIds.filter((id) => !sliceModuleById.has(id));
  if (missing.length) {
    try {
      for (const part of chunk(missing, 100)) {
        const rows = (await get(`/modules?id=in.(${part.join(",")})&select=${MODULE_SELECT}`)) as LiveModule[];
        for (const m of rows) sliceModuleById.set(m.id, m);
      }
    } catch { /* best-effort labels; module_id is what downstream needs */ }
  }

  const domainSlice = sliceIds
    .map((id) => {
      const m = sliceModuleById.get(id);
      const matchedBy: string[] = [];
      if (settingsModuleIds.has(id)) matchedBy.push("settings_domain_code");
      if (entityModuleIds.has(id)) matchedBy.push("entity_code");
      if (codeModuleIds.has(id)) matchedBy.push("catalog_module_code");
      if (slugModuleIds.has(id)) matchedBy.push("module_slug");
      return {
        module_id: id,
        module_slug: m?.module_slug ?? null,
        module_name: m?.module_name ?? null,
        catalog_module_code: m?.catalog_module_code ?? null,
        settings: m?.settings ?? null,
        matched_by: matchedBy,
        entity_hits: entityHits.get(id) ?? 0,
      };
    })
    .sort((a, b) => a.module_id - b.module_id);

  // Per-spec-module reporting hint (the "as-designed" mapping). Presence here no longer
  // gates: a deployment that bundles every module under one package shows all spec
  // modules present:false while domain_slice still carries the bundle's module_id.
  const codeSet = new Set(byCode.map((m) => m.catalog_module_code));
  const slugSet = new Set(bySlug.map((m) => m.module_slug));
  const moduleStatus = view.moduleHints.map((m) => {
    const sl = moduleSlug(m.code);
    const matchedCode = codeSet.has(m.code);
    const matchedSlug = slugSet.has(sl);
    return {
      code: m.code,
      name: m.name,
      slug: sl,
      present: matchedCode || matchedSlug,
      matched_by: matchedCode ? "catalog_module_code" : matchedSlug ? "module_slug" : null,
    };
  });
  const specMatched = moduleStatus.filter((m) => m.present).length;

  console.log(JSON.stringify({
    ok: true,
    phase: 1,
    tenant: { org: tenantOrg, email: tenantEmail },
    domain: { code: view.code, name: view.name, kind: view.isBundle ? "bundle" : "domain" },
    domain_slice: domainSlice,
    modules: moduleStatus,
    summary: {
      spec_modules_total: view.moduleHints.length,
      spec_modules_matched: specMatched,
      slice_modules: sliceIds.length,
      entities_matched: [...entityHits.values()].reduce((a, b) => a + b, 0),
      // Back-compat aliases consumed by bootstrap.ts:
      present: sliceIds.length,
      total: view.moduleHints.length,
    },
  }, null, 2));
  process.exit(0);
}

main().catch((err) => {
  console.log(JSON.stringify({ ok: false, phase: 1, reason: `unexpected error: ${err.message}`, fix: "Surface the error to the user and stop." }, null, 2));
  process.exit(2);
});
