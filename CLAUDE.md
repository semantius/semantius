# Agent Instructions

> **🔒 CRITICAL: Do not modify this file. It is a global SOP maintained by the human user only. It is shared across many repositories and organisations. Changes here are never required — if you think a rule needs changing, say so explicitly rather than editing this file.**

## Project Context

**Before starting any task**, read `CONTEXT-MEMORY.md`. It contains architecture decisions, lessons learned, and project state that you MUST incorporate into your work.

You are responsible for maintaining `CONTEXT-MEMORY.md`. Update it **only** when you discover something a future session would otherwise get wrong — non-obvious platform constraints, architectural patterns, or environmental quirks. Do **not** use it as a change log or to record individual bug fixes. Ask yourself: _"Would a capable developer, reading only the code and this file, make this mistake again?"_ If no, don't record it.

If you make a mistake, encounter a bug that takes more than one attempt to fix, or if I give you a direct preference (e.g., "always run tests"), you MUST:

1.  **Analyze:** Identify the root cause of the error or the core requirement.
2.  **Route:** Decide where the knowledge belongs before recording it:
    - **Specific file** → add a comment in that file explaining the _why_. Do NOT duplicate it in `CONTEXT-MEMORY.md`. If the fix is already self-evident from well-commented code, no further recording is needed.
    - **Cross-cutting / architectural / no single file home** → record in `CONTEXT-MEMORY.md`, but only if the knowledge represents a reusable principle that a future session would otherwise get wrong. Do not record one-off fixes.
    - **Rule of thumb:** if the knowledge would go stale or become wrong when the relevant code is refactored, it belongs in the code — not in a memory file.
    - **Concrete examples of what belongs in `CONTEXT-MEMORY.md`:** environment or toolchain constraints specific to this repo, third-party API quirks, monorepo-wide conventions that differ from the obvious default, architectural decisions and their reasoning, preferences the human has stated that should persist across sessions.
    - **Concrete examples of what never belongs in `CONTEXT-MEMORY.md`:** individual bug fixes, step-by-step task records, dates or session identifiers, anything already stated in this SOP.
3.  **Record:** If `CONTEXT-MEMORY.md` is the right place (step 2), update it by integrating the knowledge into the relevant existing section, grouped by topic. **Do not append chronologically. Do not add a "discovery log" or dated entries. Edit the document so it reads as a current, structured reference — not a history.**
4.  **Prevent:** Formulate a rule for yourself to prevent this specific issue in the future.

## Workspace

This is a **pnpm workspace monorepo** orchestrated by **Turborepo** (`turbo.json`). All packages live under the `apps/` and `packages/` directories.

- `pnpm` — package manager & workspace orchestration
- `turbo` — task runner (build, dev, lint pipelines defined in `turbo.json`)

## Environment

The workspace is provisioned automatically via `workplace/setup.sh` on session start. The following are installed globally and available on PATH:

- `agent-browser` — headless browser automation
- `dotenvx` — secret decryption
- `wrangler` — Cloudflare deployment
- `pnpm` — package manager

Do not re-run `setup.sh` manually unless the environment appears broken.

## Commands

```bash
pnpm dev              # start all apps in dev mode (Vite HMR at http://localhost:5173)
pnpm build            # build all apps
pnpm lint             # lint all apps
```

## Development vs. Completion

### During development — fast iteration

Use `pnpm dev` (or `pnpm --filter web dev`) for instant Vite HMR feedback while writing code. Use this freely during a task for rapid iteration. Localhost is a development tool only — **it is not a completion gate**.

### Task completion — mandatory

A task is **not complete** until it has been deployed to a Cloudflare branch preview and verified there. Do not mark a task done based on localhost behaviour alone.

## Secrets

Secrets are encrypted in `.env` and decrypted at runtime by dotenvx. The private key is provided via the `DOTENV_PRIVATE_KEY` environment variable (`.env.keys` does not exist in this sandbox). To run a command with secrets available:

```bash
dotenvx run -- <command>
```

To add or update a secret:

```bash
dotenvx set KEY value
```

Never expose or log secret values.

## Deployment

Branch previews deploy to Cloudflare Workers. After deployment, the preview URL is written to `.preview-url.md` at the repo root.

```bash
pnpm preview:wrangler   # deploy preview (run from repo root), writes URL to .preview-url.md
```

> ⚠️ **If `.preview-url.md` does not exist after `pnpm preview:wrangler` completes, the deployment failed.** Writing that file is the final step of the command — its absence is a reliable failure signal. Do not proceed to browser verification or screenshots. Diagnose and fix the deployment error first.

Read `.preview-url.md` to get the URL — do not guess or construct it manually.

## Browser Automation

Use `agent-browser` to verify deployed output or test the running dev server.

```bash
agent-browser open <url>
agent-browser snapshot                   # get accessibility tree with element refs
agent-browser click @ref
agent-browser fill @ref "value"
agent-browser screenshot --full <path>
```

Full skill documentation: `.agents/skills/agent-browser/SKILL.md`

## Screenshots

> ⚠️ **Screenshots must be taken from the Cloudflare preview URL, never from localhost.**
> Read `.preview-url.md` after deployment and open that URL before screenshotting.

All verification screenshots **must** be saved to the `screenshots/` folder at the repo root.

Filename format: `YYYYMMDDHHMMSS-<short-title>.png`
Example: `20240315143022-checkout-flow.png`

When referencing a screenshot in task results or comments, always include:

- The filename/path
- A short description of what the screenshot shows
- A confidence score (0–100%) reflecting how well the screenshot demonstrates that the task requirements have been met

Example result comment:

```
Screenshot: screenshots/20240315143022-checkout-flow.png
Description: Cloudflare preview showing the completed checkout flow with all three steps visible and the confirm button enabled.
Confidence: 92% — all acceptance criteria visible; minor responsive layout not tested on mobile.
```

## Verification Workflow

When asked to implement and verify a change:

1. Make the change
2. Use `pnpm dev` during development for fast feedback (localhost is for iteration only)
3. `pnpm build` — confirm no build errors
4. `pnpm preview:wrangler` — deploy to Cloudflare (**run from repo root**)
5. Read `.preview-url.md` — this is the only valid URL for verification screenshots

```bash
cat .preview-url.md   # e.g. https://abc123.your-project.workers.dev
```

6. `agent-browser open <url-from-.preview-url.md>` — **use this URL, not localhost**
7. `agent-browser screenshot --full screenshots/YYYYMMDDHHMMSS-<short-title>.png`
8. Confirm the screenshot URL/title bar reflects the Cloudflare domain, not localhost

---

## Pre-PR — COMPLETE THIS BEFORE report_progress

> ❌ **Known failure mode:** Finishing the task and taking screenshots but submitting the PR without the preview URL or without screenshots embedded in the PR description body. Screenshots saved to disk do NOT count. They must be visible inline in the PR description using an absolute GitHub URL.

> ❌ **Known failure mode:** Omitting the `CONTEXT-MEMORY.md` update status from the PR description. This section is mandatory on every PR, even when no update was made.

> ❌ **Known failure mode:** Running `pnpm preview:wrangler` and proceeding as if deployment succeeded when `.preview-url.md` was not created. A missing file means the build or deploy failed — not that the URL needs to be constructed manually. Stop and fix the error before continuing.

Before calling `report_progress`, confirm all of the following are true:

- You have run `cat .preview-url.md` and have the full Cloudflare URL in hand.
- The full preview URL is pasted as a bare URL in the PR description (not hidden behind link text).
- At least one screenshot was taken from the Cloudflare preview URL (not localhost).
- That screenshot is saved under `screenshots/` with the correct filename format.
- That screenshot is embedded in the PR description using an absolute `raw.githubusercontent.com` URL pointing to this repo and the current branch.
- The PR description includes the `CONTEXT-MEMORY.md` section with update status and a reason.

If any of the above is not true, fix it before proceeding. Do not call `report_progress` with unresolved items.

---

## PR Description Requirements — MANDATORY FOR EVERY PR

Copy the template below and fill in every placeholder. Do not paraphrase or omit sections.

```markdown
- [x] <task summary>

## Preview

<paste the full URL from .preview-url.md here — bare URL, no link text>

## Screenshots

![<short description of what the screenshot shows>](https://raw.githubusercontent.com/<org>/<repo>/<branch>/screenshots/<YYYYMMDDHHMMSS-short-title>.png)

## CONTEXT-MEMORY.md

<Updated — describe which section was changed and what knowledge was added> OR <No update needed — reason>
```

> ⚠️ **The org, repo, and branch in the screenshot URL must be the actual values for this repository and PR branch — not placeholders, not examples, not values from memory.** This file is shared across many repos and orgs; you must derive the correct values from git every time. Run `git remote get-url origin` and `git branch --show-current` to get them.

### Preview URL rules

- Read the URL from `.preview-url.md` — never guess or construct it
- Paste it as a bare URL so it is fully visible to reviewers

> ❌ Wrong: `[Live preview →](https://...)` — URL is hidden behind link text
> ✅ Correct: `https://...` — full URL visible

### Screenshot rules

- Screenshots must come from the Cloudflare preview URL, not localhost
- Embed screenshots using absolute `raw.githubusercontent.com` URLs — relative paths do not render in GitHub PRs before the branch is merged
- The URL must use the **actual org, repo, and branch** derived from git — not values from memory or a previous repo

URL format:

```
https://raw.githubusercontent.com/<org>/<repo>/<branch>/screenshots/YYYYMMDDHHMMSS-short-title.png
```

> ❌ Wrong: `![alt](screenshots/file.png)` — broken image in PR (relative path, branch not yet merged)
> ❌ Wrong: org/repo/branch copied from memory or another repo — always derive from git
> ✅ Correct: `![alt](https://raw.githubusercontent.com/acme-corp/my-actual-repo/feature/my-branch/screenshots/20240315143022-checkout.png)`

### CONTEXT-MEMORY.md rules

Every PR description **must** include a `CONTEXT-MEMORY.md` section, even when no update was made. There is no exception. Omitting it is a checklist failure. A reason is always required.

> ❌ Wrong: omitting the section entirely
> ❌ Wrong: `No update needed` with no reason given
> ✅ Correct: `Updated — added note to Deployment section: DOTENV_PRIVATE_KEY must be set before wrangler deploys or the build silently uses wrong env`
> ✅ Correct: `No update needed — fixed a typo in a button label, no architectural or process knowledge involved`
