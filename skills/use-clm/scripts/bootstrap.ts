/**
 * Bootstrap orchestrator.
 *
 * Runs Phase 1 (environment check), then Phase 2a (structural discovery), then
 * decides whether to write ready.flag. If Phase 2a reported ambiguities, the
 * flag is NOT written: Phase 2b (agent-driven ambiguity resolution) must run
 * first, and bootstrap must be re-invoked after the agent updates state.jsonc.
 *
 * Run from project root:
 *   bun run .claude/skills/use-<domain>/scripts/bootstrap.ts
 *
 * Behavior:
 *   - Halts on Phase 1 failure with a clear message + link.
 *   - Caches Phase 1 result to .phase1-cache.json (read by Phase 2a).
 *   - Halts on Phase 2a hard failure (cannot reach CLI, malformed spec).
 *   - On Phase 2a soft outcome (ambiguities): writes nothing, surfaces the
 *     ambiguities list to stdout for the agent. The agent runs Phase 2b
 *     (interactive resolution) and re-invokes bootstrap when state.jsonc is ready.
 *   - On Phase 2a clean outcome: writes ready.flag with schema fingerprint.
 *
 * The skill itself only ever checks for the existence (and freshness) of
 * ready.flag. Bootstrap is the single producer of that flag.
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync } from "fs";
import { resolve } from "path";
import { createHash } from "crypto";

type PhaseResult = { ok: boolean; phase: string | number; [k: string]: any };

async function runScript(scriptName: string): Promise<PhaseResult> {
  const scriptPath = resolve(import.meta.dir, scriptName);
  const proc = Bun.spawn(["bun", "run", scriptPath], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  try {
    const parsed = JSON.parse(out.trim());
    return { ...parsed, _exit_code: code, _stderr: err };
  } catch {
    return { ok: false, phase: scriptName, reason: `unparseable output from ${scriptName}: ${out || err}`, _exit_code: code };
  }
}

function halt(reason: string, fix: string): never {
  console.log(JSON.stringify({ ok: false, stage: "bootstrap", reason, fix }, null, 2));
  process.exit(1);
}

async function main() {
  const skillDir = resolve(import.meta.dir, "..");
  const specPath = resolve(skillDir, "spec.json");
  const phase1CachePath = resolve(skillDir, ".phase1-cache.json");
  const discoveredPath = resolve(skillDir, "discovered.json");
  const readyFlagPath = resolve(skillDir, "ready.flag");

  if (!existsSync(specPath)) {
    halt(`spec.json missing at ${specPath}`,
         "The skill bundle is incomplete. Reinstall the skill from the Semantius catalog.");
  }
  const spec = JSON.parse(readFileSync(specPath, "utf-8"));

  // Stage 1.
  console.error("bootstrap: running phase1-environment...");
  const phase1 = await runScript("phase1-environment.ts");
  if (!phase1.ok) {
    if (existsSync(phase1CachePath)) unlinkSync(phase1CachePath);
    if (existsSync(readyFlagPath)) unlinkSync(readyFlagPath);
    console.log(JSON.stringify({ ok: false, stage: "bootstrap", phase: 1, ...phase1 }, null, 2));
    process.exit(1);
  }
  writeFileSync(phase1CachePath, JSON.stringify(phase1, null, 2));

  // Stage 2a.
  console.error("bootstrap: running phase2a-structural...");
  const phase2a = await runScript("phase2a-structural.ts");
  if (!phase2a.ok) {
    if (existsSync(readyFlagPath)) unlinkSync(readyFlagPath);
    console.log(JSON.stringify({ ok: false, stage: "bootstrap", phase: "2a", ...phase2a }, null, 2));
    process.exit(1);
  }

  const ambiguities = (phase2a.ambiguities ?? []) as Array<{ kind: string; concept?: string; live_name?: string; reason: string }>;
  const deferred = (phase2a.deferred ?? []) as Array<{ kind: string; concept?: string; live_name?: string; reason: string }>;
  if (ambiguities.length > 0) {
    // Phase 2b is required before ready.flag can be written. Only ambiguities the user has
    // NOT yet resolved in state.jsonc reach here (phase2a consumes recorded resolutions), so
    // the loop converges: each pass the agent resolves, records, and re-invokes.
    if (existsSync(readyFlagPath)) unlinkSync(readyFlagPath);
    console.log(JSON.stringify({
      ok: false,
      stage: "bootstrap",
      phase: "2b-required",
      reason: `Phase 2a discovered ${ambiguities.length} ambiguities that need user resolution. ready.flag NOT written.`,
      ambiguities,
      deferred,
      next: "Agent runs Phase 2b (see references/discovery.md) to surface each ambiguity to the user, records resolutions in state.jsonc (entity_renames / omitted_entities / custom_entities / unresolved_questions), then re-invokes bootstrap.ts. phase2a reads those back so resolved items do not re-appear.",
    }, null, 2));
    process.exit(0);
  }

  // Stage 3: write ready.flag with fingerprint.
  const discovered = existsSync(discoveredPath)
    ? readFileSync(discoveredPath, "utf-8")
    : "";
  const schemaHash = createHash("sha256")
    .update(discovered)
    .digest("hex")
    .slice(0, 16);

  const sliceModuleIds = (phase1.domain_slice ?? []).map((m: any) => m.module_id);
  const flag = {
    ok: true,
    written_at: new Date().toISOString(),
    valid_through_emitted: spec.emitted,
    valid_through_major: spec.facts_major,
    schema_hash: schemaHash,
    slice_module_ids: sliceModuleIds,
    modules_present: sliceModuleIds.length || phase1.summary?.present || 0,
    modules_total: phase1.summary?.total ?? phase1.summary?.spec_modules_total ?? 0,
    entities_discovered: phase2a.entities_discovered,
    deferred_questions: deferred.length,
  };
  writeFileSync(readyFlagPath, JSON.stringify(flag, null, 2));

  console.log(JSON.stringify({
    ok: true,
    stage: "bootstrap",
    summary: flag,
    deferred,
    next: deferred.length
      ? "Skill is ready (ready.flag written). Some questions were deferred ('skip'); surface them at the start of the next session."
      : "Skill is ready. Subsequent invocations only need to verify ready.flag exists and that valid_through_emitted matches spec.emitted.",
  }, null, 2));
  process.exit(0);
}

main().catch((err) => {
  console.log(JSON.stringify({ ok: false, stage: "bootstrap", reason: err.message }, null, 2));
  process.exit(2);
});
