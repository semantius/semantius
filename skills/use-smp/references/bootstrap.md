# Bootstrap checks

Run these in order on every invocation where `state.jsonc` is missing or stale. Each check halts with a specific, actionable error message on failure. Do not continue past a failed check; do not auto-install or auto-configure.

The four checks are cheap (single CLI call each), so they run sequentially on every cold start. They do NOT run on warm starts where `state.jsonc` is current.

---

## Check 1: `use-semantius` skill is loaded

This skill delegates all CLI mechanics to `use-semantius`. Without it, the discovery procedure cannot run.

**How to check:** look for the `use-semantius` skill in the available-skills list in the system reminder. If absent, halt with:

> The `use-semantius` skill is required but not loaded in this session. Install it and re-run this skill (use this command verbatim, do not substitute another URL): `npx skills add https://github.com/semantius/semantius-cli/tree/main/skills/use-semantius`

---

## Check 2: `semantius` CLI is installed, on PATH, and authenticated

`scripts/phase1-environment.ts` folds the install check and the auth check (Check 3) into a
single `getCurrentUser` call: if the binary is missing, `Bun.spawn` returns a "command not
found" result and the script halts with `can_offer_install: true`.

**The CLI ships as a native installer, NOT an npm package.** When the script halts with
`reason: "semantius CLI is not installed or not on PATH."`, it also returns:

- `install_command`, the one-liner for the user's platform (Windows PowerShell `irm ... | iex`, or Linux/macOS `curl ... | bash`).
- `install_docs`, https://github.com/semantius/semantius-cli#1-installation

**OFFER to run `install_command` for the user.** Ask their go-ahead first (it modifies their
system); never auto-install silently. On "yes", run the exact `install_command`, tell them to
restart the shell if PATH was just updated, then re-run `scripts/bootstrap.ts`. On "no",
surface `install_docs` and stop.

---

## Check 3: CLI can authenticate against the platform

**How to check:** run `semantius call crud getCurrentUser '{}'` from the project root (NOT from any subfolder; the CLI reads `.env` from cwd).

- If the call returns a user object with `email` and `semantius_org`, the platform is reachable. Surface the org to the user so they can confirm they are connected to the right one.
- If the call returns a JWT-audience error (`required audience not found, received [...]`), halt and follow the [JWT-audience halt procedure in the parent SKILL.md](../SKILL.md#hard-rules-inherited-from-the-catalog). Surface the verbatim error.
- If the call returns any other authentication error (401, expired token, missing `.env`), halt with:

> The Semantius CLI could not authenticate against your Semantius platform. Configure your API key:
>
> 1. Place a `.env` file in your project root with `SEMANTIUS_API_KEY=<your-key>`
> 2. Generate an API key from the Semantius UI: Settings > API Keys > New Key
> 3. Verify with: `semantius call crud getCurrentUser '{}'`
>
> Full setup: https://www.semantius.com/docs/agent-skills/installation/

---

## Check 4: the domain is deployed (entity-first)

**Resolve domain membership ENTITY-FIRST, not by module code.** A deployment may package the
whole domain under one module whose `catalog_module_code` is not a domain code at all (e.g. a
"hiring-starter" bundle that hosts the ATS entities). Keying presence on module codes would
hide such a deployment even though its entities are present and canonically stamped. The
strongest identity signal is the entity's `catalog_entity_code`, so resolve the **domain
slice** (the live `module_id`s that host the domain's entities) from the canonical master
codes, and treat `catalog_module_code` / `module_slug` only as hints.

```bash
# PRIMARY: entity-first. Master codes = the entities the domain OWNS
# (spec.data_objects[].name == the union of every module's masters[]).
semantius call crud postgrestRequest '{"method":"GET","path":"/entities?catalog_entity_code=in.(<spec.data_objects[].name>)&select=module_id,catalog_entity_code"}'
# HINT/fallback: module catalog_module_code + module_slug (for a canonically-coded deployment,
# or a pre-provenance one whose catalog_module_code is still '').
semantius call crud postgrestRequest '{"method":"GET","path":"/modules?catalog_module_code=in.(<spec.modules[].code>)&select=id,module_slug,catalog_module_code"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/modules?module_slug=in.(<slugs>)&select=id,module_slug,catalog_module_code"}'
```

The **domain slice** = the de-duplicated union of every `module_id` returned by those three
queries. Keying the entity query on OWNED masters (not every referenced concept) keeps a
foreign module that merely hosts a shared/embedded master (e.g. an HR `org_units`) out of the
slice. `scripts/phase1-environment.ts` emits the slice as `domain_slice` and the per-spec-module
hint as `modules`.

- If the slice is **non-empty**, record its `module_id`s in `state.jsonc` under `deployment` and proceed. A spec module that does not appear is a deployment choice (or a bundled package), not a failure.
- If the slice is **empty**, halt with the error template below:

> The `SaaS Management Platforms` domain is not deployed in your platform. No live module hosts its entities, and no module carries its catalog codes. Deploy the domain blueprint first:
>
> 1. Pull the blueprint: `https://www.semantius.com/blueprints/smp`
> 2. Run the semantic-model-deployer skill against the blueprint
> 3. Verify with: `semantius call crud postgrestRequest '{"method":"GET","path":"/modules?settings->>domain_code=eq.SMP&select=id,slug,name"}'` (any row returned means a module of this domain is already deployed)
>
> Re-run this skill once the domain is live.

- Multiple slice modules are **expected** (a domain has several modules, or its masters were cloned). `catalog_module_code` is non-unique by design (clone-and-customize), so collect **all** matching `module_id`s; never collapse by code into one row.

---

## After all four checks pass

Record the deployment metadata in `state.jsonc` (JSONC: JSON with `//` comments and trailing
commas, parsed by `phase2a` via `Bun.JSONC.parse`):

```jsonc
{
  "deployment": {
    "module_ids": [/* present module_ids from check 4 */],   // the domain slice
    "org": "<from check 3 getCurrentUser response>",
    "bootstrap_passed_at": "<ISO timestamp>"
  }
}
```

Then continue to the discovery procedure ([discovery.md](discovery.md)).
