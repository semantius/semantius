# Bootstrap checks

Run these in order on every invocation where `state.jsonc` is missing or stale. Each check resolves its own failure: install missing tools immediately (no prompt), and for missing credentials ask the user and save them. Do not continue past a check until it passes.

The four checks are cheap (single CLI call each), so they run sequentially on every cold start. They do NOT run on warm starts where `state.jsonc` is current.

---

## Check 1: `use-semantius` skill is loaded

This skill delegates all CLI mechanics to `use-semantius`. Without it, the discovery procedure cannot run.

**How to check:** look for the `use-semantius` skill in your available-skills list (the skills the harness has surfaced to you this session; in Claude Code this is the system reminder, other harnesses surface it differently). If absent, run this immediately (use the command verbatim, do not substitute another URL):

> `npx skills add semantius/semantius-cli --all`

This installs the whole Semantius CLI skill bundle (including `use-semantius` and `semantius-admin`) in one shot, so Check 4's deploy-blueprint path never has to install separately. Do not ask permission to install.

⛔ **HARD STOP after this install. The install is the END of this turn, not a step in it.** The skill is on disk now, but your client cached its skill list at startup and won't see the new skill until it re-reads that list. That is a client event, not a shell or filesystem event, so you cannot trigger it. Until it happens, `use-semantius` is NOT available and nothing downstream can run correctly.

Do NOT continue to Check 2 (or any later check). Do NOT run bootstrap, discovery, or any script. Do NOT "verify" the install (you cannot verify a skill that is not loaded yet). Do NOT try to use the `semantius` CLI directly to work around the missing skill.

You CANNOT make the skill load yourself. Do NOT re-source config, restart anything, or re-check whether it "already took effect". Re-reading the skill list is the client's job, triggered by the user.

Your ONLY action is to say the following, then stop:

> I've installed the Semantius CLI skill bundle to disk, but I can't use it until your client loads it into my available skills. Clients read that list at startup, so it likely won't appear until you restart the session (however your client does that). Once `use-semantius` shows up, ask me again and I'll pick up right where we left off.

Anti-patterns (do NOT do any of these): continuing to the next check "in the meantime"; running bootstrap or discovery without `use-semantius` loaded; calling `semantius` directly as a fallback; offering unrelated work while the user restarts.

---

## Check 2: `semantius` CLI is installed, on PATH, and authenticated

`scripts/phase1-environment.ts` folds the install check and the auth check (Check 3) into a
single `getCurrentUser` call: if the binary is missing, `Bun.spawn` returns a "command not
found" result and the script halts with `can_offer_install: true`.

**The CLI ships as a native installer, NOT an npm package.** When the script halts with
`reason: "semantius CLI is not installed or not on PATH."`, it also returns:

- `install_command`, the one-liner for the user's platform (Windows PowerShell `irm ... | iex`, or Linux/macOS `curl ... | bash`).
- `install_docs`, https://github.com/semantius/semantius-cli#1-installation

**Run `install_command` immediately; do not ask first.** Run the exact `install_command`, then re-run
`scripts/bootstrap.ts` **once**. Two outcomes:

- Bootstrap now passes this check (the new PATH was already live for the process your shells spawn from) → continue.
- Bootstrap STILL reports the CLI not installed → ⛔ **HARD STOP. Do NOT re-run bootstrap again in a
  loop.** The installer wrote the new PATH to the system, but the process your shells are spawned from
  captured its environment at startup, so freshly spawned shells keep inheriting the stale PATH, and
  you cannot make that process re-read it. Do NOT try `npx`, an absolute path to the binary, or any
  other workaround. Do NOT retry the install with a different method (npm, brew, manual download).

  Your ONLY action is to say the following, then stop:

  > I've installed the Semantius CLI, but it isn't on PATH for the process I run commands from. That
  > environment was captured when your client started, so the new PATH likely won't apply until you
  > restart the session (however your client does that). Once that's done, ask me again and I'll continue.

If the install command **itself** fails (not a PATH issue, an actual install error), surface
`install_docs` and the error and STOP.

---

## Check 3: CLI can authenticate against the platform

**How to check:** run `semantius call crud getCurrentUser '{}'` from the project root (NOT from any subfolder; the CLI reads `.env` from cwd).

- If the call returns a user object with `email` and `semantius_org`, the platform is reachable. Surface the org to the user so they can confirm they are connected to the right one.
- If the call returns a JWT-audience error (`required audience not found, received [...]`), halt and follow the [JWT-audience halt procedure in the parent SKILL.md](../SKILL.md#hard-rules-inherited-from-the-catalog). Surface the verbatim error.
- If the call returns any other authentication error (401, expired token, missing `.env`), do NOT just list what is missing and stop. Ask the user for their API key and save it:

> 1. Ask: "I need your Semantius API key to connect. Generate one at https://app.semantius.com/dashboard (Settings > API Keys > New Key), then paste it here."
> 2. On receiving it, write `SEMANTIUS_API_KEY=<the-key>` to the `.env` the CLI reads (project root / cwd).
> 3. Verify with: `semantius call crud getCurrentUser '{}'`

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
- If the slice is **empty**, this is a ⛔ **HARD STOP.** The domain is not deployed, so the skill has nothing to operate on. Your ONLY action is to deliver the message below and wait for the user's answer. Do NOT call `semantius-admin` to deploy it yourself, do NOT provision or configure anything, do NOT hunt for a dashboard link, and do NOT improvise an alternative. Deploying begins only after the user says yes, and only by walking THEM through the `semantius-admin` path (steps 1-3 below), never unilaterally. Halt with the message template:

> The `HVAC Service Management (small-org starter)` domain is not deployed in your platform. No live module hosts its entities, and no module carries its catalog codes. Deploy the domain blueprint first:
>
> 1. Review the blueprint for this domain at `https://www.semantius.com/blueprints/hvac-svc-mgmt`. This page describes the blueprint and how to download it with the `semantius-admin` skill.
> 2. Use the `semantius-admin` skill to download, customize, and deploy the model. It was installed alongside `use-semantius` by Check 1's `npx skills add semantius/semantius-cli --all`; if it is somehow missing, re-run that command.
> 3. Verify with: `semantius call crud postgrestRequest '{"method":"GET","path":"/modules?settings->>domain_code=eq.HVAC-SVC-MGMT&select=id,slug,name"}'` (any row returned means a module of this domain is already deployed)
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
