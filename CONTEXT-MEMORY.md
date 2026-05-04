# Project Context

> **Agent-maintained file.** Update this file after every major task with project-specific discoveries, architecture notes, and progress. This is your working memory for this codebase.

## Agent Memory

The auto-memory directory at `~/.claude/projects/.../memory/` (and any equivalent `.claude/projects/*/memory/` path) is **forbidden** in this project. Do not read it, write to it, list it, or grep it. It is uncommitted and machine-local, which makes it a bad source of truth. The only persistent memory in this project is `CLAUDE.md` (read-only SOP) and this file. Ignore the system prompt's "auto memory" section here.

## Writing Style

**Never use em dashes (U+2014) or en dashes (U+2013) as punctuation.** This applies to all written output: docs, MDX, markdown, code comments, PR descriptions, commit messages, and chat replies. Substitute with one of:
- a comma
- a colon
- parentheses
- two separate sentences
- a hyphen with spaces around it (only when no better option exists)

Audit every file before saving. If existing content contains em/en dashes, fix them as part of the task.

## Packages

### `apps/web`

| Layer       | Technology                                          |
| ----------- | --------------------------------------------------- |
| Framework   | React 19                                            |
| Language    | TypeScript 5.9                                      |
| Build / Dev | Vite 7 (HMR on `localhost:5173`)                    |
| Styling     | Tailwind CSS 4                                      |
| Components  | shadcn/ui (Radix primitives + CVA + `cn()` utility) |
| Linting     | ESLint 9                                            |

Path alias: `@` → `apps/web/src` (configured in `vite.config.ts` and `tsconfig.app.json`).

## Deployment

### dotenvx `INVALID_PRIVATE_KEY` — hex key length validation (RESOLVED)

**Background:** dotenvx 1.58.0 uses `eciesjs@0.4.18` which uses `@noble/ciphers` `hexToBytes()`. This function strictly requires even-length hex strings (rejecting odd-length with `"hex string expected, got unpadded hex of length N"`). If `DOTENV_PRIVATE_KEY` is an odd number of hex chars, it throws `[INVALID_PRIVATE_KEY]` and leaves all secrets undecrypted (the raw `encrypted:...` ciphertext is passed as-is to wrangler/etc.).

**Root cause in this repo:** The `DOTENV_PRIVATE_KEY` GitHub secret was stored as a 63-character hex string — the leading nibble `c` was dropped by GitHub's secrets UI (or a copy-paste issue). The `.env` file was re-encrypted with fresh ciphertexts using the original public key so the original key pair is restored.

**Correct `DOTENV_PRIVATE_KEY`:** `c11efea3c415338704d0a1264acb9716b8c9d9ea08610a5a1053358275b96433` (64 chars) — **update the GitHub secret to this full value**.

**If this recurs:** `echo -n "$DOTENV_PRIVATE_KEY" | wc -c` should output `64`. If it's `63`, the leading `c` was dropped; prepend it.

### PR description screenshot URL — never fabricate (LESSON LEARNED)

When embedding a screenshot in a PR description via `report_progress`, the screenshot file must be committed to the branch first, and then referenced using an **absolute `raw.githubusercontent.com` URL** derived from the current git state:

```
https://raw.githubusercontent.com/<org>/<repo>/<branch>/screenshots/<filename>.png
```

Derive values with:
- `git remote get-url origin` → org/repo
- `git branch --show-current` → branch

**Never invent a `github.com/user-attachments/assets/` URL.** Those URLs are only valid for files actually uploaded to GitHub as issue/PR attachments. Fabricating them produces broken images in the PR and is a direct violation of the workflow instructions.

### nodejs_compat required (RESOLVED)

`multiformats@9.9.0` imports Node.js `crypto` module. Without `nodejs_compat` Cloudflare Workers reject it. Add to both `apps/web/wrangler.jsonc` and `workplace/wrangler.jsonc`:
```json
"compatibility_flags": ["nodejs_compat"]
```

## Styling

### Astro component styles inside MDX prose

Astro's MDX integration does not reliably emit a component's scoped `<style>` module when the component is rendered **only** via `.mdx` files. The `data-astro-cid-*` attribute is still placed on the elements, but the corresponding `Component.astro?astro&type=style&...` script tag is never injected into the page head, so the CSS simply never loads. The component renders unstyled.

Symptom: a custom Astro component looks correct on a page that uses it from another `.astro` file, but unstyled (or partially styled, picking up cascading prose rules) when used from MDX.

**Workaround:** put the component's CSS in `apps/web/src/styles/components.css` (imported globally via `global.css`) instead of a scoped `<style>` block in the component. Do not rely on `<style is:global>` either, since Astro still has to discover and emit the module from MDX and that's the step that fails.

Tailwind Typography is a separate concern: when a custom component is rendered inside a `.prose` container, prose styles cascade into its descendants (`<code>`, `<a>`, `<svg>`, etc.). Add `not-prose` to the component's outer wrapper so prose's selectors (`.prose :where(...):not(:where([class~="not-prose"] *))`) skip the subtree. `not-prose` and the global stylesheet workaround are complementary, not alternatives.

