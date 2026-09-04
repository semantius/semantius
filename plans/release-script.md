# Plan: `release.sh <version>` — one script for the whole release

Written 2026-09-04, executed the same day. Kept as the record of what was decided
and why, in the style of `plans/audit-ddl-noise.md`.

## Context

Releasing the extension was a manual procedure spread across `RELEASE.md`,
comments inside `.github/workflows/extension-release.yml`, and the headers of
`docker-postgres/build.sh` / `publish.sh`. Wrong shape: the requirement is **one
script that handles everything needed to build version a.b.c**, with documentation
*of the script*, not instead of it.

Split of responsibility, as stated by the owner: checks and tests run **locally
before tagging** to prove the current state is green; **CI re-runs tests and
builds** to prove the result is reproducible. So `release.sh` verifies, commits,
tags and pushes — it never publishes. The workflow publishes the GitHub Release and
the GHCR image. `scripts/pgxn-release.sh` takes the artifact **GitHub published**
and uploads it to PGXN.

| `a.b.c` vs current build | outcome |
|---|---|
| lower | rejected, instantly, before any work |
| equal | refresh the artifacts (re-release) |
| higher | build a new version (upgrade script, prune old install) |

## Decisions

1. **`--strict` becomes the default.** The "only migrations added in this version
   may be edited" rule was *already* the implemented semantics —
   `highestVersionBelow` filters strictly `< 0` so a version is never its own
   `prev`, and `edited` requires `k in prevFiles`. It was opt-in and unstated.
   Now always-on with `--allow-edited-migrations` as the override; `--strict` stays
   a warning no-op alias (it appeared in six committed files, including
   `.github/workflows/test.yml`).
2. **"Current" is `max(extension/versions.json)`**, not the git tags — it is what
   the generator's own frozen guard reads, and 0.5.0 is built but deliberately not
   yet tagged. `release.sh` refuses when `max(git tag v*) > max(versions.json)`:
   that means something was published the manifest does not know about, and every
   guard downstream is then blind. The tag is what CI *builds from*; `versions.json`
   is what may be built.
3. **`packages/triggerdev/src/migrations-bundle.ts` untracked.** It was listed in
   `.gitignore` yet tracked, and stale; its header carries a generation timestamp,
   so tracking it puts churn in every release commit. Closes open item B18 in the
   "build output" direction.
4. **`release.sh` never publishes.** No `gh release create`, no `docker push`. The
   maintainer's `gh` token has `repo, workflow, gist, read:org` — no
   `write:packages` — and that stays true.

## What was built

### Generator (`packages/cli/commands/extension.ts`, `packages/cli/cli.ts`)

- `strict?: boolean` → `allowEditedMigrations?: boolean`, inverted to
  `enforce = options.allowEditedMigrations !== true`. The failure message names the
  real reason: the `prev -> version` upgrade script carries only migrations *added*
  since `prev`, so an edit to an inherited one can never reach an existing install.
- The no-manifest case is loud. Every guard lives inside `if (prev)`, and
  `loadManifest` silently returns `{versions:{}}` for a missing file *and* for valid
  JSON of the wrong shape — so deleting `versions.json` used to disable every
  protection without a word.
- `compareVersions` was replaced with semver precedence (semver.org §11, minus
  build metadata), and `scripts/semver.sh` implements the same total order for
  the shell. The old comparator did `split(".").map(Number)`, so `0.6.0-rc1`
  gave `[0,6,NaN]` - and `NaN > 0` / `NaN < 0` are both false, so the frozen
  guard *and* `highestVersionBelow` went blind while `pruneOldFullInstalls`
  still deleted the current full install by filename.
- `sort -V` is used nowhere in the release path: GNU version sort ranks `0.6.0`
  BELOW `0.6.0-beta`, which would make cutting the final over an rc look like a
  downgrade. Both comparators are tested against the canonical semver chain.
- Pre-releases needed no rule of their own. `0.6.0-rc1` freezes the moment
  `0.6.0` enters the manifest, purely because the comparator ranks it lower -
  the owner said either behavior was acceptable, so the free one was taken.
- Build metadata (`+sha`), `--` and a trailing `-` are refused: the first has no
  precedence under semver (two keys would compare equal), the second is the
  upgrade-script filename separator, the third PostgreSQL rejects.

### `release.sh <version> [--dry-run] [--confirm] [--skip-tests] [--no-image] [--allow-edited-migrations] [--rerun-ci]`

Phase 0 decides from `versions.json` via `jq` (a grep would scan the nested `files`
keys at the same depth) and rejects a lower version before touching anything.
Phase 1 is a read-only preflight that accumulates every blocker. The results and
the plan are printed, and only then does it ask - a flag-only gate would mean
re-running everything to answer a question about a result you can no longer see,
and the second run's preflight is not the one you approved. `--confirm` skips the
prompt for non-interactive use; `--dry-run` stops after the plan. Phase 2 generates, phase 3 runs the three harnesses in the
load-bearing CI order, phase 4 commits and *then* proves determinism, phase 5 tags
and pushes.

Notable constraints encoded rather than documented:

- `tag_and_push()` is reachable only from `commit_build` and re-asserts its own
  preconditions, so the "commit `extension/` before moving the tag" trap is
  structural.
- Before the lifecycle script, `appdb` is asserted on **both** containers:
  `pg-ext-lifecycle.sh` calls `ok "skipped: …"` when either is missing, and `ok()`
  increments the pass counter, so the equivalence check read as a pass while not
  running.
- The push re-verifies fast-forward (phase 1's check is tens of minutes stale by
  then), pushes the branch before the tag, and deletes the local tag if the branch
  push is rejected.
- Every failure after the commit states its recovery command.
- "Nothing changed and the tag is already at HEAD" is refused: force-pushing a tag
  to the commit it already points at sends no ref update, so no push event and no
  workflow run — the script would otherwise exit 0 having published nothing.
  `--rerun-ci` deletes and re-pushes the remote tag, which produces a genuine push
  event and exercises the same code path a real release does.

### `scripts/pgxn-release.sh <version>`

Publishes the byte-identical archive attached to the GitHub Release, never a local
rebuild — which also removes a hard blocker, since `zip` is not installed on the
maintainer's machine. Verifies the local tag against origin's, the tree, `HEAD`,
the on-disk build, reproducibility, and then the downloaded zip's layout, manifest,
file contents and exact file set.

### Helpers

`scripts/check-pgxn-meta.sh` and `scripts/archive-manifest.sh` exist so CI and the
scripts cannot drift. `archive-manifest.sh` is driven by `versions.json` rather than
a `pg_semantius--*.sql` glob, so an orphaned upgrade script is excluded rather than
shipped — that is the fix for open item B17, and it is also what `release.sh` stages
with instead of `git add -A extension`.

Both need `chmod +x` in the workflow: `core.filemode=false` and every tracked `.sh`
is mode 100644, which is why the workflow already chmods `pgdocker/*.sh`.

## Corrections made during review

Two claims in the first draft were wrong and are recorded so they are not repeated:

- The `mktemp -d` + `--output` check in `pgxn-release.sh` was said to be broken on
  Windows because Deno resolves the MSYS path against the drive root. **Tested and
  refuted** — MSYS rewrites argv before Deno sees it. The change to
  regenerate-in-place was kept anyway, to use the same oracle as CI, and it needs a
  restore trap because it is *more* destructive than what it replaced.
- File-set equality between the working tree and the downloaded archive was said to
  catch B17. It cannot: an orphaned upgrade script sits in both, so the two sides
  agree. B17 needs a check against `versions.json`.
