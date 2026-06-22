/**
 * Phase 1, environment bootstrap check.
 *
 * Runs at bootstrap (when ready.flag is missing). Verifies the technical
 * prerequisites the skill needs before Phase 2 (structural discovery) can run.
 *
 * Checks in order (halt on first failure):
 *   1. semantius CLI installed, on PATH, and able to authenticate (getCurrentUser).
 *   2. The domain is deployed: one or more live modules are stamped settings.domain_code = <CODE>.
 *
 * The deploy stamp is the ONE authoritative signal. The deploy pipeline writes
 * { domain_code, module_kind, naming_mode, catalog_snapshot } into a module's `settings` JSONB
 * ONLY on a module it has fully provisioned (shell + RBAC + entities). So "a stamped module
 * exists" is both necessary and sufficient for "deployed", and a module without the stamp is, by
 * definition, not a complete deployment. We deliberately do NOT fall back to entity-code stamps,
 * catalog_module_code, or module_slug: those weaker signals also match half-provisioned modules,
 * which is exactly what let the skill proceed against an unconfigured deployment. The slice is
 * simply the set of stamped modules.
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
//   moduleHints  = [{code, name}] used only for the non-gating per-spec-module reporting hint.
function normalize(spec: Spec): { code: string; name: string; isBundle: boolean; moduleHints: Array<{ code: string; name: string }> } {
  if (spec.bundle) {
    return {
      code: spec.bundle.code,
      name: spec.bundle.name,
      isBundle: true,
      moduleHints: [{ code: spec.bundle.code, name: spec.bundle.name }],
    };
  }
  const dom = spec.domain ?? { code: "<unknown>", name: "<unknown>" };
  return {
    code: dom.code,
    name: dom.name,
    isBundle: false,
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

// The CLI ships as a native installer (NOT an npm package). Emit the platform-specific
// one-liner so the agent can run it for the user. On a missing CLI the agent runs it
// immediately (no prompt); the skill cannot proceed without the binary.
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
         "Ask the user for their API key (generate at https://app.semantius.com/dashboard, Settings > API Keys), save it to the .env the CLI reads (project root / cwd) as SEMANTIUS_API_KEY=<key>, then re-verify.");
  }

  const tenantOrg = cu.data?.semantius_org ?? "<unknown>";
  const tenantEmail = cu.data?.email ?? "<unknown>";
  // ui_baseurl powers UI deep-links (`{ui_baseurl}/{module_slug}/{table_name}`); never hardcode the org host.
  const tenantUiBaseurl = cu.data?.ui_baseurl ?? "";

  // ---- Check 2: is the domain deployed? ----
  // The slice is the set of live modules stamped settings.domain_code = <CODE>. That stamp is
  // written only on a fully provisioned module, so its presence IS deployment and its absence IS
  // "not deployed". No fallback to weaker signals: that is what kept the skill from stopping when
  // the domain was not configured.
  let sliceModules: LiveModule[] = [];
  try {
    sliceModules = (await get(`/modules?settings->>domain_code=eq.${view.code}&select=${MODULE_SELECT}`)) as LiveModule[];
  } catch (e: any) {
    const msg = String(e?.message ?? e).toLowerCase();
    if (msg.includes("audience") || msg.includes("jwt")) {
      halt(`JWT-audience error querying /modules: ${e.message}`,
           "Surface the verbatim error to the user and wait for direction. Do not retry in a loop.");
    }
    halt(`Could not query /modules for the deploy stamp: ${e.message}`,
         "Check platform connectivity. If this is a JWT error, surface it verbatim.");
  }

  if (sliceModules.length === 0) {
    halt(
      `The ${view.name} (${view.code}) ${view.isBundle ? "bundle" : "domain"} is not deployed in this platform (${tenantOrg}). No live module is stamped settings.domain_code = ${view.code}.`,
      `Deploy the blueprint first, then re-run this skill. Use the semantius-admin skill to download, customize, and deploy the model (install it with 'npx skills add semantius/semantius-cli --all' if it is not present). Blueprint info: https://www.semantius.com/blueprints/${view.code.toLowerCase()}`,
    );
  }

  const domainSlice = sliceModules
    .map((m) => ({
      module_id: m.id,
      module_slug: m.module_slug ?? null,
      module_name: m.module_name ?? null,
      catalog_module_code: m.catalog_module_code ?? null,
      settings: m.settings ?? null,
      matched_by: ["settings_domain_code"],
    }))
    .sort((a, b) => a.module_id - b.module_id);

  // Per-spec-module reporting hint (the "as-designed" mapping). Non-gating: a deployment that
  // bundles every spec module under one package shows all spec modules present:false while
  // domain_slice still carries the bundle's module_id. Matched against the stamped slice's own
  // catalog_module_code / module_slug, never a separate query.
  const sliceCodeSet = new Set(sliceModules.map((m) => m.catalog_module_code).filter(Boolean));
  const sliceSlugSet = new Set(sliceModules.map((m) => m.module_slug).filter(Boolean));
  const moduleStatus = view.moduleHints.map((m) => {
    const sl = moduleSlug(m.code);
    const matchedCode = sliceCodeSet.has(m.code);
    const matchedSlug = sliceSlugSet.has(sl);
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
    tenant: { org: tenantOrg, email: tenantEmail, ui_baseurl: tenantUiBaseurl },
    domain: { code: view.code, name: view.name, kind: view.isBundle ? "bundle" : "domain" },
    domain_slice: domainSlice,
    modules: moduleStatus,
    summary: {
      spec_modules_total: view.moduleHints.length,
      spec_modules_matched: specMatched,
      slice_modules: domainSlice.length,
      // Back-compat aliases consumed by bootstrap.ts:
      present: domainSlice.length,
      total: view.moduleHints.length,
    },
  }, null, 2));
  process.exit(0);
}

main().catch((err) => {
  console.log(JSON.stringify({ ok: false, phase: 1, reason: `unexpected error: ${err.message}`, fix: "Surface the error to the user and stop." }, null, 2));
  process.exit(2);
});
