/**
 * Phase 2a, script-driven structural discovery via the provenance resolution ladder.
 *
 * Runs after Phase 1. For each DomainMap concept the domain assumes, resolves it
 * against the live deployment using the resolution ladder (deterministic platform
 * reads against the provenance columns shipped in core v0.1.2). First hit wins:
 *
 *   step 0  state resolution, a resolution the user already made in a prior Phase 2b
 *                               (recorded in state.jsonc: entity_renames / omitted /
 *                               custom_entities). Consumed here so the bootstrap loop
 *                               terminates instead of re-emitting the same ambiguity.
 *   step 1  FK reachability, a live FK in the domain's own entities whose
 *                               reference_table resolves to an entity carrying
 *                               catalog_entity_code = X  ->  that entity IS X for D.
 *   step 2  owned canonical, catalog_entity_code = X AND module_id in the domain's
 *                               slice. Catches masters D owns and D's own silos.
 *   step 3  alias, an entity whose catalog_entity_aliases contains
 *                               { alias_code: X, source_domain: D } (JSONB containment).
 *   step 4  absent, none of the above. A concept D OWNS is a true omission;
 *                               a concept D only references (embedded_master / consumer)
 *                               that is owned elsewhere is EXTERNAL context, not omitted
 *                               (IMPROVE 9: do not conflate "not deployed" with "owned
 *                               by another domain").
 *
 * The domain SLICE comes from Phase 1's entity-first resolution (the module_ids that
 * actually host the domain's entities), read from .phase1-cache.json; if the cache is
 * missing it is re-derived here from the canonical master codes.
 *
 * catalog_entity_code stamps the CANONICAL DomainMap code (D6); table_name holds the
 * deployed name and may drift (silo/dialect). A resolution whose live table_name differs
 * from X is a rename, recorded deterministically.
 *
 * The name/alias/label heuristic survives ONLY as a fallback for live rows whose
 * catalog_entity_code is EMPTY ('', created outside the deploy pipeline). Those raise an
 * ambiguity for Phase 2b (agent + user) UNLESS the user already resolved them in
 * state.jsonc. A fully stamped deployment resolves with zero ambiguities.
 *
 * Platform schema notes (core v0.1.2, verified live):
 *   - `entities` is keyed by `table_name` (no `name`, no `id` column).
 *   - Empties are '' (text) / '{}' (json object) / '[]' (json array) / 'unclassified'
 *     (entity_type). NEVER SQL NULL, test against the empty value, never `IS NULL`.
 *
 * Output:
 *   - discovered.json (sibling of spec.json), full snapshot + per-concept resolution map.
 *   - stdout JSON, pass/fail + ambiguities list for the agent (Phase 2b).
 *
 * Exit code: 0 on success (even with ambiguities), non-zero on hard failure.
 *
 * Run from the project root:
 *   bun run .claude/skills/use-<domain>/scripts/phase2a-structural.ts
 */

import { readFileSync, writeFileSync } from "fs";
import { resolve } from "path";

type LabelEntry = {
  name: string;
  singular_label?: string;
  plural_label?: string;
  aliases?: Array<{ name: string; source: string }>;
};

type Spec = {
  // Domain specs carry `domain` + `modules` + `data_objects`; domain-less bundles carry
  // `bundle` + `composes`. normalize() folds both into one view.
  domain?: { code: string; name: string };
  modules?: Array<{
    code: string;
    name: string;
    masters: string[];
    embedded_masters?: string[];
    consumers?: string[];
  }>;
  data_objects?: LabelEntry[];
  bundle?: { code: string; name: string };
  composes?: Array<{ name: string; singular_label?: string; plural_label?: string; role?: string; owning_domain?: string | null }>;
};

// Fold a domain spec OR a domain-less bundle spec into one model.
//   concepts      = every concept the unit assumes (resolved against the live deployment).
//   ownedConcepts = the concepts the unit MASTERS (drives the omitted-vs-external split and
//                   the domain slice). A bundle masters nothing, so ownedConcepts is empty
//                   and every composed entity it does not resolve is external, never omitted.
//   sliceCodes    = entity codes for the fallback slice re-derivation (matches phase1).
//   labelEntries  = name/label/alias rows for the empty-code name-fallback heuristic.
function normalize(spec: Spec): {
  code: string;
  isBundle: boolean;
  concepts: Set<string>;
  ownedConcepts: Set<string>;
  sliceCodes: string[];
  labelEntries: LabelEntry[];
} {
  if (spec.bundle) {
    const concepts = new Set<string>();
    const ownedConcepts = new Set<string>();
    const labelEntries: LabelEntry[] = [];
    for (const c of spec.composes ?? []) {
      concepts.add(c.name);
      if (c.role === "master") ownedConcepts.add(c.name);
      labelEntries.push({ name: c.name, singular_label: c.singular_label, plural_label: c.plural_label });
    }
    return { code: spec.bundle.code, isBundle: true, concepts, ownedConcepts, sliceCodes: [...concepts], labelEntries };
  }
  const concepts = new Set<string>();
  const ownedConcepts = new Set<string>();
  for (const m of spec.modules ?? []) {
    for (const n of m.masters ?? []) {
      concepts.add(n);
      ownedConcepts.add(n);
    }
    for (const n of [...(m.embedded_masters ?? []), ...(m.consumers ?? [])]) concepts.add(n);
  }
  for (const o of spec.data_objects ?? []) {
    concepts.add(o.name);
    ownedConcepts.add(o.name);
  }
  return {
    code: spec.domain?.code ?? "<unknown>",
    isBundle: false,
    concepts,
    ownedConcepts,
    sliceCodes: [...ownedConcepts],
    labelEntries: spec.data_objects ?? [],
  };
}

type Phase1Result = {
  ok: boolean;
  tenant?: { org?: string | null; email?: string | null; ui_baseurl?: string | null };
  domain_slice?: Array<{
    module_id: number;
    module_slug?: string | null;
    module_name?: string | null;
    catalog_module_code?: string | null;
    settings?: any;
  }>;
};

type AliasElement = { alias_code: string; source_domain: string; [k: string]: any };

type LiveEntity = {
  table_name: string;
  singular_label: string;
  plural_label: string;
  module_id: number;
  catalog_entity_code: string;
  canonical_owner_module: string;
  pattern_flags: Record<string, boolean>;
  entity_type: string;
  catalog_entity_aliases: AliasElement[];
  // Operational shape (persisted so the skill never re-queries it at runtime).
  id_column: string;
  label_column: string;
  description: string;
  view_permission: string;
  edit_permission: string;
  icon_url: string;
  // Operating contract: the deployment's live write guards + read visibility. These ship with
  // human-readable message/description and are the highest-value "how to operate safely" data.
  validation_rules: any[]; // jsonlogic write guards: { code, message, jsonlogic, description }
  select_rule: any; // jsonlogic row-level read visibility (RLS); null = no row filter
  computed_fields: any[]; // server-derived/virtual fields (do not write; may be missing on naive read)
  // Governance / behavior.
  edit_mode: string; // auto | manual: whether & how the entity is writable
  is_child: string | boolean; // sub-entity: edited via a parent, not standalone
  label_parent: string; // parent FK used to compose the display label
  audit_log: string | boolean; // writes audit-logged (compliance-relevant)
  cube_mode: string; // analytics (cube) exposure
  managed: string | boolean;
  searchable: string | boolean;
  updated_at: string; // last-modified; a cheap drift signal vs discovered_at
};

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

async function get(path: string): Promise<any> {
  const r = await call("crud", "postgrestRequest", { method: "GET", path });
  if (!r.ok) throw new Error(`GET ${path} failed: ${r.stderr}`);
  return r.data;
}

function chunk<T>(arr: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

// Empty-value tests (core v0.1.2): never IS NULL.
const codeEmpty = (v: unknown): boolean => !v || v === "";
const asAliases = (v: unknown): AliasElement[] => (Array.isArray(v) ? (v as AliasElement[]) : []);
const asFlags = (v: unknown): Record<string, boolean> =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, boolean>) : {};

// ---------- state.jsonc reader (SERIOUS 2: loop termination) ----------
//
// Phase 2b records the user's resolutions in state.jsonc; phase2a reads them back so the
// bootstrap loop converges instead of re-emitting the same ambiguities forever. The file is
// JSONC (JSON + // and /* */ comments + trailing commas), parsed with Bun's built-in
// Bun.JSONC.parse: a real parser, so comments and key ordering can never corrupt a value
// (the rev-2 failure of the old hand-rolled YAML reader). It is human-editable and
// committable, needs zero dependencies, and matches spec.json's JSON.parse. phase2a consumes
// four keys:
//   entity_renames:       { concept: live_table }          (rename "yes" / multi_owner pick)
//   omitted_entities:     ["concept", ...]                 (user-confirmed omissions)
//   custom_entities:      ["live_table", ...]              (user-confirmed custom rows)
//   unresolved_questions: ["concept_or_live_name", ...]    (user said "skip")
type StateResolutions = {
  entityRenames: Map<string, string>;
  omitted: Set<string>;
  customNames: Set<string>;
  deferred: Set<string>;
  warning?: string; // non-fatal: a state.jsonc was present but could not be parsed
};

// Parse JSONC via Bun's built-in. The skill already gates on Bun; if this build predates
// Bun.JSONC, throw a tagged error so readState can fail clear (NOT silently swallow it).
const JSONC_UNAVAILABLE = "JSONC_UNAVAILABLE";
function parseJsonc(text: string): any {
  const jsonc = (globalThis as any).Bun?.JSONC;
  if (jsonc && typeof jsonc.parse === "function") return jsonc.parse(text);
  throw new Error(JSONC_UNAVAILABLE);
}

const asArray = (v: unknown): any[] => (Array.isArray(v) ? v : []);
// Pull a name out of a string item or an object item (key order does not matter).
function itemName(item: unknown, keys: string[]): string | null {
  if (typeof item === "string") return item || null;
  if (item && typeof item === "object") {
    for (const k of keys) {
      const v = (item as any)[k];
      if (typeof v === "string" && v) return v;
    }
  }
  return null;
}

function readState(path: string): StateResolutions {
  const res: StateResolutions = { entityRenames: new Map(), omitted: new Set(), customNames: new Set(), deferred: new Set() };
  let text: string;
  try {
    text = readFileSync(path, "utf-8");
  } catch {
    return res; // no state file yet (first run / no Phase 2b)
  }
  let data: any;
  try {
    data = parseJsonc(text);
  } catch (e: any) {
    if (e?.message === JSONC_UNAVAILABLE) {
      // A state.jsonc EXISTS but this Bun cannot parse JSONC. Swallowing would silently
      // re-open the Phase 2b loop (the bug the JSONC switch removed), so fail clear: this
      // propagates to main().catch -> bootstrap halts phase2a with the message.
      throw new Error(
        `state.jsonc exists but Bun.JSONC.parse is unavailable in this Bun (${(globalThis as any).Bun?.version ?? "unknown"}). ` +
          "Upgrade Bun so recorded Phase 2b resolutions are honored.",
      );
    }
    // Genuine malformed JSONC: do not abort discovery, but do not fail SILENTLY either, surface
    // a warning so the ignored resolutions are visible rather than a quiet loop re-open.
    res.warning = `state.jsonc could not be parsed as JSONC (${e?.message ?? e}); recorded resolutions were ignored this run.`;
    return res;
  }
  if (!data || typeof data !== "object") return res;

  const er = data.entity_renames;
  if (er && typeof er === "object" && !Array.isArray(er)) {
    for (const [k, v] of Object.entries(er)) if (typeof v === "string" && v) res.entityRenames.set(k, v);
  }
  for (const x of asArray(data.omitted_entities)) {
    const n = itemName(x, ["concept", "name"]);
    if (n) res.omitted.add(n);
  }
  for (const x of asArray(data.custom_entities)) {
    const n = itemName(x, ["live_name", "name", "table_name", "concept"]);
    if (n) res.customNames.add(n);
  }
  for (const x of asArray(data.unresolved_questions)) {
    const n = itemName(x, ["concept", "live_name", "name"]);
    if (n) res.deferred.add(n);
  }
  return res;
}

async function main() {
  const skillDir = resolve(import.meta.dir, "..");
  const specPath = resolve(skillDir, "spec.json");
  const phase1Path = resolve(skillDir, ".phase1-cache.json");
  const statePath = resolve(skillDir, "state.jsonc");
  const discoveredPath = resolve(skillDir, "discovered.json");

  const spec: Spec = JSON.parse(readFileSync(specPath, "utf-8"));
  const view = normalize(spec);
  const domainCode = view.code.toLowerCase();
  const state = readState(statePath);

  // The concept set (every entity the unit assumes) and the owned subset (drives the
  // omitted-vs-external split and the slice). Each name IS its canonical code (D6).
  const concepts = view.concepts;
  const ownedConcepts = view.ownedConcepts;
  const masterCodes = view.sliceCodes;

  // ---- Resolve the domain slice (from Phase 1 cache, else re-derive entity-first). ----
  let sliceModuleIds: number[] = [];
  try {
    const phase1: Phase1Result = JSON.parse(readFileSync(phase1Path, "utf-8"));
    sliceModuleIds = (phase1.domain_slice ?? []).map((m) => m.module_id).filter((x) => typeof x === "number");
  } catch {
    /* re-derive below */
  }
  if (sliceModuleIds.length === 0) {
    const ids = new Set<number>();
    // Authoritative deploy stamp first (mirrors phase1): modules tagged for this domain.
    try {
      const rows = (await get(`/modules?settings->>domain_code=eq.${view.code}&select=id`)) as any[];
      for (const r of rows ?? []) ids.add(r.id as number);
    } catch { /* best-effort; entity-first below still resolves the slice */ }
    for (const part of chunk(masterCodes, 100)) {
      if (!part.length) continue;
      const rows = (await get(`/entities?catalog_entity_code=in.(${part.join(",")})&select=module_id`)) as any[];
      for (const r of rows ?? []) ids.add(r.module_id as number);
    }
    sliceModuleIds = [...ids];
  }
  const presentModuleIds = new Set(sliceModuleIds);

  // Module detail (slug/name/settings) from the Phase 1 cache, keyed by module_id. Persisted in
  // discovered.json so the skill builds correct UI URLs from the DEPLOYED slug (e.g. hiring-starter),
  // not the catalog code, and can read the deploy stamp (domain_code, module_kind, naming_mode).
  const sliceModules: Record<string, any> = {};
  try {
    const phase1: Phase1Result = JSON.parse(readFileSync(phase1Path, "utf-8"));
    for (const m of phase1.domain_slice ?? []) {
      sliceModules[String(m.module_id)] = {
        module_slug: m.module_slug ?? null,
        module_name: m.module_name ?? null,
        catalog_module_code: m.catalog_module_code ?? null,
        settings: m.settings ?? null,
      };
    }
  } catch { /* cache absent (re-derived slice); module detail simply omitted */ }

  // Tenant/deploy context for the skill: ui_baseurl (from getCurrentUser) is the base for UI deep-links;
  // org is the deployment identity. Read from the Phase 1 cache so links resolve from discovered.json.
  let deployment: { org: string | null; ui_baseurl: string | null } = { org: null, ui_baseurl: null };
  try {
    const phase1: Phase1Result = JSON.parse(readFileSync(phase1Path, "utf-8"));
    deployment = { org: phase1.tenant?.org ?? null, ui_baseurl: phase1.tenant?.ui_baseurl ?? null };
  } catch { /* cache absent; deployment context omitted */ }

  // ---- Pull live entities (with provenance + operational shape) for the slice modules. ----
  // The operational columns (id_column/label_column/description/permissions, and the field-level
  // title/ctype/input_type/reference_delete_mode/relationship_label/unique_value below) are
  // persisted once here so the skill operates from discovered.json and never re-queries the
  // platform per request. id_column/label_column are NOT assumable (usually `id`, but the label
  // column is entity-specific: candidate_name, application_ref, ...), so they are read, not guessed.
  const ENT_SELECT =
    "table_name,singular_label,plural_label,module_id,catalog_entity_code," +
    "canonical_owner_module,pattern_flags,catalog_entity_aliases,entity_type," +
    "id_column,label_column,description,view_permission,edit_permission,icon_url," +
    "validation_rules,select_rule,computed_fields,edit_mode,is_child,label_parent," +
    "audit_log,cube_mode,managed,searchable,updated_at";
  const FLD_SELECT =
    "table_name,field_name,catalog_field_code,format,is_nullable,default_value,reference_table,enum_values,field_order," +
    "title,description,ctype,is_pk,input_type,reference_delete_mode,relationship_label,unique_value," +
    "input_type_rule,cube_type,precision,searchable,singular_label_parent,plural_label_parent";

  const fetchErrors: string[] = [];
  const liveByTable = new Map<string, LiveEntity>();
  for (const mid of sliceModuleIds) {
    try {
      const ents = (await get(`/entities?module_id=eq.${mid}&select=${ENT_SELECT}`)) as LiveEntity[];
      for (const e of ents ?? []) liveByTable.set(e.table_name, e);
    } catch (e: any) {
      // IMPROVE 7: a transient failure on one module must not abort the whole run.
      fetchErrors.push(`entities for module ${mid}: ${e.message}`);
    }
  }
  const inDomain = [...liveByTable.values()];

  // Fields: ONE batched call per chunk of table names (IMPROVE 6), not one per entity.
  const fieldsByTable = new Map<string, any[]>();
  for (const e of inDomain) fieldsByTable.set(e.table_name, []); // default empty (fault tolerance)
  for (const part of chunk(inDomain.map((e) => e.table_name), 100)) {
    if (!part.length) continue;
    try {
      const rows = (await get(`/fields?table_name=in.(${part.join(",")})&select=${FLD_SELECT}&order=table_name.asc,field_order.asc`)) as any[];
      for (const f of rows ?? []) {
        const t = f.table_name as string;
        (fieldsByTable.get(t) ?? fieldsByTable.set(t, []).get(t)!).push(f);
      }
    } catch (e: any) {
      fetchErrors.push(`fields chunk [${part[0]}..(${part.length})]: ${e.message}`);
      // entities in this chunk keep their empty field list; run continues.
    }
  }

  // ---- Build the ladder indices. ----

  // step 2: catalog_entity_code -> in-domain entities owning that canonical code.
  const byOwnedCode = new Map<string, LiveEntity[]>();
  for (const e of inDomain) {
    if (codeEmpty(e.catalog_entity_code)) continue;
    (byOwnedCode.get(e.catalog_entity_code) ?? byOwnedCode.set(e.catalog_entity_code, []).get(e.catalog_entity_code)!).push(e);
  }

  // step 3: alias_code (scoped to this domain) -> host entity that absorbed it.
  const byAlias = new Map<string, LiveEntity[]>();
  for (const e of inDomain) {
    for (const a of asAliases(e.catalog_entity_aliases)) {
      if ((a.source_domain || "").toLowerCase() !== domainCode) continue;
      (byAlias.get(a.alias_code) ?? byAlias.set(a.alias_code, []).get(a.alias_code)!).push(e);
    }
  }

  // step 1: FK reachability. Resolve every FK's reference_table to its catalog_entity_code.
  const codeByTable = new Map<string, string>();
  for (const e of inDomain) if (!codeEmpty(e.catalog_entity_code)) codeByTable.set(e.table_name, e.catalog_entity_code);
  const refTables = new Set<string>();
  for (const fields of fieldsByTable.values()) for (const f of fields) if (f.reference_table) refTables.add(f.reference_table);
  const unresolved = [...refTables].filter((t) => !codeByTable.has(t));
  for (const part of chunk(unresolved, 100)) {
    if (!part.length) continue;
    try {
      const rows = (await get(`/entities?table_name=in.(${part.join(",")})&select=table_name,catalog_entity_code`)) as Array<{
        table_name: string;
        catalog_entity_code: string;
      }>;
      for (const r of rows ?? []) if (!codeEmpty(r.catalog_entity_code)) codeByTable.set(r.table_name, r.catalog_entity_code);
    } catch (e: any) {
      fetchErrors.push(`fk-target entities [${part[0]}..]: ${e.message}`);
    }
  }
  const fkReach = new Map<string, string>(); // catalog_entity_code -> reachable table_name
  for (const fields of fieldsByTable.values()) {
    for (const f of fields) {
      if (!f.reference_table) continue;
      const code = codeByTable.get(f.reference_table);
      if (code && !fkReach.has(code)) fkReach.set(code, f.reference_table);
    }
  }

  // ---- Run the ladder per concept. ----
  const resolutions: Record<string, any> = {};
  const entityRenames: Record<string, string> = {};
  const omitted: string[] = []; // concepts the domain OWNS that are not deployed
  const externalEntities: string[] = []; // concepts owned by another domain, not present here
  const resolvedTables = new Set<string>();
  const ambiguities: Array<{ kind: string; concept?: string; live_name?: string; reason: string }> = [];
  const deferred: Array<{ kind: string; concept?: string; live_name?: string; reason: string }> = [];
  let stateResolvedCount = 0;

  for (const X of concepts) {
    // step 0, a resolution the user already recorded in state.jsonc.
    if (state.entityRenames.has(X)) {
      const table = state.entityRenames.get(X) as string;
      if (liveByTable.has(table) || byOwnedCode.has(X)) {
        resolutions[X] = { via: "state_resolution", live_table: table, renamed: table !== X };
        if (table !== X) entityRenames[X] = table;
        resolvedTables.add(table);
        stateResolvedCount++;
        continue;
      }
      // stale state (the named table is gone): fall through to the live ladder.
    }
    if (state.omitted.has(X)) {
      resolutions[X] = { via: "absent", confirmed_by_user: true };
      (ownedConcepts.has(X) ? omitted : externalEntities).push(X);
      stateResolvedCount++;
      continue;
    }

    // step 1, FK reachability
    if (fkReach.has(X)) {
      const table = fkReach.get(X) as string;
      resolutions[X] = { via: "fk_reachability", live_table: table, renamed: table !== X };
      if (table !== X) entityRenames[X] = table;
      resolvedTables.add(table);
      continue;
    }
    // step 2, owned canonical code in the domain's module slice
    const owned = (byOwnedCode.get(X) ?? []).filter((e) => presentModuleIds.has(e.module_id));
    if (owned.length === 1) {
      const e = owned[0];
      resolutions[X] = { via: "owned_code", live_table: e.table_name, module_id: e.module_id, renamed: e.table_name !== X };
      if (e.table_name !== X) entityRenames[X] = e.table_name;
      resolvedTables.add(e.table_name);
      continue;
    }
    if (owned.length > 1) {
      // Not pre-resolved in state -> still a genuine multi_owner choice (or a "skip").
      const candidates = owned.map((e) => e.table_name);
      const amb = {
        kind: "multi_owner",
        concept: X,
        reason: `Concept "${X}" resolves to ${owned.length} entities in this domain (${candidates.join(", ")}). Cannot pick one deterministically.`,
      };
      if (state.deferred.has(X)) {
        deferred.push(amb);
        resolutions[X] = { via: "deferred", candidates }; // observable: a skipped multi_owner is not dropped
      } else {
        ambiguities.push(amb);
      }
      continue;
    }
    // step 3, alias (reuse/merge into a differently-named host)
    const aliased = byAlias.get(X) ?? [];
    if (aliased.length >= 1) {
      const e = aliased[0];
      resolutions[X] = { via: "alias", live_table: e.table_name, module_id: e.module_id, renamed: true };
      entityRenames[X] = e.table_name;
      resolvedTables.add(e.table_name);
      continue;
    }
    // step 4, absent. Owned -> true omission; external -> owned by another domain (IMPROVE 9).
    if (ownedConcepts.has(X)) {
      resolutions[X] = { via: "absent" };
      omitted.push(X);
    } else {
      resolutions[X] = { via: "external_absent" };
      externalEntities.push(X);
    }
  }

  // ---- Custom / unstamped entities: in-domain live rows not claimed by any concept. ----
  const conceptLower = new Map<string, string>();
  for (const X of concepts) conceptLower.set(X.toLowerCase(), X);
  for (const o of view.labelEntries) {
    for (const a of o.aliases ?? []) conceptLower.set(a.name.toLowerCase(), o.name);
    if (o.singular_label) conceptLower.set(o.singular_label.toLowerCase(), o.name);
    if (o.plural_label) conceptLower.set(o.plural_label.toLowerCase(), o.name);
  }

  const customEntities: Array<{ live_name: string; module_id: number; catalog_entity_code: string }> = [];
  for (const e of inDomain) {
    if (resolvedTables.has(e.table_name)) continue;
    if (!codeEmpty(e.catalog_entity_code)) {
      // Stamped but not claimed by a concept: a neighbor-domain master reused here. Record, no prompt.
      customEntities.push({ live_name: e.table_name, module_id: e.module_id, catalog_entity_code: e.catalog_entity_code });
      continue;
    }
    // Empty-code row. If the user already classified/confirmed it, suppress the ambiguity.
    if (state.customNames.has(e.table_name)) {
      customEntities.push({ live_name: e.table_name, module_id: e.module_id, catalog_entity_code: "" });
      continue;
    }
    const guess =
      conceptLower.get(e.table_name.toLowerCase()) ||
      conceptLower.get((e.singular_label || "").toLowerCase()) ||
      conceptLower.get((e.plural_label || "").toLowerCase());
    let amb: { kind: string; live_name: string; concept?: string; reason: string };
    if (guess && resolutions[guess]?.via === "absent") {
      amb = {
        kind: "rename_candidate",
        live_name: e.table_name,
        concept: guess,
        reason: `Live entity "${e.table_name}" has no catalog_entity_code (outside the deploy pipeline / not yet stamped) but its name/label matches the unresolved concept "${guess}". Possible rename, confirm.`,
      };
    } else {
      amb = {
        kind: "custom_entity",
        live_name: e.table_name,
        reason: `Live entity "${e.table_name}" (${e.singular_label}/${e.plural_label}) has no catalog_entity_code and matches no concept. Classify its role (master, log, reference data) or confirm it is custom.`,
      };
    }
    // "skip" recorded against the live_name (or matched concept) downgrades to non-blocking.
    (state.deferred.has(e.table_name) || (amb.concept && state.deferred.has(amb.concept)) ? deferred : ambiguities).push(amb);
    customEntities.push({ live_name: e.table_name, module_id: e.module_id, catalog_entity_code: "" });
  }

  // ---- Lifecycle-field check (D3): the lifecycle column is invariantly `workflow_state`. ----
  // The spec carries each master's lifecycle_states but NOT the column name. When a concept's
  // spec declares lifecycle states, its resolved live entity MUST expose a `workflow_state`
  // column. A missing one is real drift (renamed or undeployed lifecycle), surfaced as an
  // ambiguity for Phase 2b instead of silently emitting lifecycle_field: null. Bundles carry no
  // lifecycle_states, so this is a no-op for them.
  const specLifecycleByConcept = new Map<string, string[]>();
  for (const o of spec.data_objects ?? []) {
    const states = (Array.isArray((o as any).lifecycle_states) ? (o as any).lifecycle_states : [])
      .map((s: any) => (typeof s === "string" ? s : s?.name))
      .filter((n: any): n is string => typeof n === "string" && n.length > 0);
    if (states.length) specLifecycleByConcept.set(o.name, states);
  }
  for (const [concept, states] of specLifecycleByConcept) {
    const liveTable = resolutions[concept]?.live_table as string | undefined;
    if (!liveTable) continue; // not deployed here; absence handled by the omitted/external split.
    const hasWorkflowState = (fieldsByTable.get(liveTable) ?? []).some((f: any) => f.field_name === "workflow_state");
    if (hasWorkflowState) continue;
    const amb = {
      kind: "lifecycle_field_missing",
      concept,
      live_name: liveTable,
      reason: `Spec declares lifecycle states for "${concept}" (${states.join(", ")}) but live entity "${liveTable}" has no "workflow_state" column. The lifecycle column is invariably named workflow_state; confirm which column carries the lifecycle here, or record that the lifecycle is not deployed.`,
    };
    // "skip" recorded against the concept or the live name downgrades to non-blocking.
    (state.deferred.has(concept) || state.deferred.has(liveTable) ? deferred : ambiguities).push(amb);
  }

  // ---- Build discovered.json (full snapshot), keyed by table_name. ----
  const discoveredEntities: Record<string, any> = {};
  for (const e of inDomain) {
    const fields = (fieldsByTable.get(e.table_name) ?? []).slice().sort((a, b) => (a.field_order ?? 0) - (b.field_order ?? 0));
    // The lifecycle column is INVARIANTLY named `workflow_state` across every Semantius
    // deployment, never status/state/stage/disposition. Match it exactly; do not heuristically
    // guess. A concept whose spec declares lifecycle_states but whose live entity lacks this
    // column is real drift, surfaced as a `lifecycle_field_missing` ambiguity above, never a
    // silent null here.
    const lifecycleField = fields.find((f: any) => f.field_name === "workflow_state");
    discoveredEntities[e.table_name] = {
      catalog_entity_code: e.catalog_entity_code || "",
      canonical_owner_module: e.canonical_owner_module || "",
      entity_type: e.entity_type || "unclassified",
      pattern_flags: asFlags(e.pattern_flags),
      catalog_entity_aliases: asAliases(e.catalog_entity_aliases),
      module_id: e.module_id,
      singular_label: e.singular_label,
      plural_label: e.plural_label,
      description: e.description || "",
      // Operational identity (read, never assumed): the PK column and the human label column.
      id_column: e.id_column || "id",
      label_column: e.label_column || "",
      label_parent: e.label_parent || "", // parent FK that composes the display label
      view_permission: e.view_permission || "",
      edit_permission: e.edit_permission || "",
      icon_url: e.icon_url || "",
      // Operating contract (live): write guards + read visibility + virtual fields. Each
      // validation rule carries a human `message`/`description`; honor these before any write.
      validation_rules: asArray(e.validation_rules),
      select_rule: e.select_rule ?? null,
      computed_fields: asArray(e.computed_fields),
      // Governance / behavior.
      edit_mode: e.edit_mode || "",
      is_child: Boolean(e.is_child),
      audit_log: Boolean(e.audit_log),
      cube_mode: e.cube_mode || "",
      managed: Boolean(e.managed),
      searchable: Boolean(e.searchable),
      updated_at: e.updated_at || "",
      fields: fields.map((f: any) => ({
        name: f.field_name,
        title: f.title ?? "",
        description: f.description ?? "",
        catalog_field_code: f.catalog_field_code || "",
        format: f.format,
        ctype: f.ctype ?? "",
        cube_type: f.cube_type ?? "",
        is_pk: Boolean(f.is_pk),
        is_nullable: f.is_nullable,
        unique_value: Boolean(f.unique_value),
        searchable: Boolean(f.searchable),
        precision: f.precision ?? null,
        field_order: f.field_order ?? null,
        input_type: f.input_type ?? "",
        input_type_rule: f.input_type_rule ?? {}, // conditional required/readonly/visibility jsonlogic
        default_value: f.default_value,
        // Relationship shape: target table + how a delete cascades + the verb the UI renders.
        reference_table: f.reference_table || "",
        reference_delete_mode: f.reference_delete_mode || "",
        relationship_label: f.relationship_label || "",
        singular_label_parent: f.singular_label_parent ?? "",
        plural_label_parent: f.plural_label_parent ?? "",
        enum_values: f.enum_values || null,
      })),
      lifecycle_field: lifecycleField?.field_name ?? null,
      lifecycle_values: lifecycleField?.enum_values ?? null,
    };
  }

  const discovered = {
    discovered_at: new Date().toISOString().slice(0, 10),
    discovered_against_emitted: (spec as any).emitted,
    discovered_against_major: (spec as any).facts_major,
    domain_code: view.code,
    deployment, // { org, ui_baseurl }: ui_baseurl (from getCurrentUser) is the base for UI deep-links
    slice_module_ids: sliceModuleIds,
    modules: sliceModules, // per module_id: { module_slug, module_name, catalog_module_code, settings }
    resolution: resolutions, // per-concept: { via, live_table, renamed }
    entity_renames: entityRenames, // canonical concept -> live table_name
    omitted_entities: omitted, // concepts the domain owns that are not deployed here
    external_entities: externalEntities, // concepts owned by another domain, not present here
    custom_entities: customEntities,
    entities: discoveredEntities,
    fetch_errors: fetchErrors,
    state_warning: state.warning ?? null,
  };

  writeFileSync(discoveredPath, JSON.stringify(discovered, null, 2));

  const resolvedCount = Object.values(resolutions).filter((r: any) => !["absent", "external_absent", "deferred"].includes(r.via)).length;
  console.log(JSON.stringify({
    ok: true,
    phase: "2a",
    entities_discovered: Object.keys(discoveredEntities).length,
    slice_module_ids: sliceModuleIds,
    concepts_total: concepts.size,
    concepts_resolved: resolvedCount,
    renames: Object.keys(entityRenames).length,
    omitted: omitted.length,
    external: externalEntities.length,
    custom: customEntities.length,
    state_resolved: stateResolvedCount,
    fetch_errors: fetchErrors,
    state_warning: state.warning ?? null,
    ambiguities,
    deferred,
    next: ambiguities.length === 0
      ? "Phase 2a resolved every concept deterministically (ladder + recorded state). bootstrap.ts can write ready.flag."
      : `Phase 2a left ${ambiguities.length} genuine ambiguities (empty-code rows or multi-recurrence not yet resolved in state.jsonc). Phase 2b (agent-driven) must surface these to the user, record the resolutions in state.jsonc, then re-invoke bootstrap.ts.`,
  }, null, 2));
  process.exit(0);
}

main().catch((err) => {
  console.log(JSON.stringify({ ok: false, phase: "2a", reason: err.message }, null, 2));
  process.exit(2);
});
