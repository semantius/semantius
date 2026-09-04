# Releasing

Maintainer document. Consumers do not need it — installing is covered by
[README.md](README.md#postgresql-extension-alternative-distribution) and by the
generated `extension/README.md` that ships inside every archive.

Everything here is about **one artifact set**: the `pg_semantius` extension
build in `extension/`, the GitHub Release that carries its archive, and the
GHCR database image built from it. They always move together at one version.

## The rule: newest is mutable, everything before it is frozen

A version stays **mutable while it is the newest build**. It may be regenerated,
re-tagged and re-released as often as needed. It becomes **frozen the moment a
higher version is committed** to `extension/versions.json`.

This is deliberate. `0.5.0` is a fresh start: the 0.1.0/0.3.0/0.4.0 lineage was
cut off on 2026-09-03 and its version history discarded from the manifest, so
there is no upgrade chain into 0.5.0 and no `pg_semantius--0.4.0--0.5.0.sql`.
Until 0.5.0 is declared final it is developed in place rather than accreting
patch versions for changes nobody has consumed yet.

Two things enforce it:

- `deno task extension <ver>` **refuses** when `versions.json` already holds a
  higher version. Without that guard the run would leave a broken `extension/`:
  the edit detection is skipped (it only looks at versions *below* the target,
  and a superseded version has none), the newer full install is pruned away, the
  newer upgrade script is orphaned, and `default_version` moves backwards.
- The version argument is **required**. It used to fall back to the CLI
  package's own version (`0.1.0`), which quietly did all of the above.

The one channel that does not honor the rule is **PGXN** — see below.

## Doing it

```bash
./release.sh v0.5.0              # check, show the plan, then ask
./release.sh v0.5.0 --dry-run    # check and show the plan, then stop
```

The argument is the tag. A bare `0.5.0` works too and means the same thing: the
tag is `v0.5.0`, while the extension itself is versioned `0.5.0` in
`default_version`, `META.json` and `pg_semantius--0.5.0.sql`.

It prints the preflight results and exactly what it is about to do, and
*then* asks. `--confirm` skips the prompt for non-interactive use; it is not
the normal way to invoke it.

One script, and the version argument selects the outcome. It regenerates
`extension/`, runs all three harnesses in the order they depend on, builds the
image locally, commits the build, proves the generator is deterministic by
regenerating a second time, then tags and pushes. Pushing the tag is what starts
[the workflow](.github/workflows/extension-release.yml), which rebuilds from a
clean checkout and publishes the GitHub Release and the GHCR image.

The duplication is the design. The harnesses run locally to prove the current
working tree is green; CI re-runs them to prove the result is **reproducible**
rather than green only on one machine. `./release.sh --help` lists the flags;
`--skip-tests` deliberately cannot tag.

PGXN is separate and manual — see below.

## What a re-release does not do

**It does not reach a database that already ran this version.** `migrate()`
records each migration by name in `public._versions` and skips any name it has
already applied:

```sql
IF NOT EXISTS (SELECT 1 FROM public._versions WHERE name = '_core.0070_dd_functions') THEN
  ...
ELSE
  v_skipped := v_skipped + 1;
END IF;
```

There is no checksum comparison and no re-apply, and there is no 0.5.0 -> 0.5.0
update path, so `ALTER EXTENSION pg_semantius UPDATE` is a no-op as well. A
database that installed 0.5.0 before the re-release keeps the old SQL, and
`semantius.status()` lists the changed migration in `changed_versions` from then
on - the drift is detected, it just has no remedy.

**This is accepted, not a defect.** A re-release reaches fresh installs and
fresh containers; an existing database is rebuilt or left behind. That is the
price of developing 0.5.0 in place instead of accreting patch versions nobody
has consumed. `changed_versions` is the intended signal that a database predates
the current build.

The two escape hatches, in the order they become relevant:

- **When a live database first has to be updated in place**, add an opt-in
  `semantius.reapply('<app>.<migration>')` that re-runs one named migration and
  updates its checksum. Only the migrations a re-release actually touched need
  to be re-runnable, and they are known - so make them re-runnable as part of
  the edit. Blanket re-apply is not an option: across the 34 `_core` migrations
  there are 66 `CREATE TRIGGER` against 13 `DROP TRIGGER IF EXISTS`, 36
  `CREATE INDEX` without `IF NOT EXISTS`, 76 seed `INSERT`s and 28
  `ALTER TABLE ... ADD COLUMN`, so re-running an arbitrary migration fails or
  duplicates data.
- **Once 0.5.0 is final**, stop editing migrations at all: a fix becomes a new
  migration file. `migrate()` then picks it up by name on every install, old and
  new, with no new machinery - and it is the only form a `0.5.0 -> 0.5.1`
  upgrade script can carry, because upgrade scripts contain migrations *added*
  since the previous version.

## What the version argument selects

**The floor is what has been released, not what has been built.** `git tag -l 'v*'`
is the record of releases; `extension/versions.json` records builds, and a build
happens whenever anyone runs `deno task extension`. A stray local build must not
block the versions below it.

| `./release.sh v<a.b.c>` | |
|---|---|
| **a tag `v<a.b.c>` exists and it is the newest released** | refresh - a re-release. The tag moves, the GitHub Release is replaced, the version-pinned image is overwritten |
| **a tag exists but something higher is released** | rejected: published, superseded, frozen |
| **no tag, and it sorts above the newest released** | a new release |
| **no tag, and it does not sort above the newest released** | rejected: it is in the past |

If `versions.json` holds builds at or above the target that have **no tag**,
`release.sh` names them and drops them from the manifest before generating.
Nothing points at an unreleased build - no tag, no GitHub Release, no upgrade
script leading to it - so it is a stale artifact rather than history, and left in
place it would make the generator refuse the target.

From the moment a higher version is in the manifest, the lower one is frozen for
the generator too, and **only migrations added in the newer version may be
edited**. Editing one an earlier version already shipped fails the build, because
the upgrade script carries only migrations *added* since the previous version -
so such an edit could never reach an existing installation.
`--allow-edited-migrations` waives it for a deliberate hot-patch.

## Pre-releases

`v0.6.0-rc.1`, `v0.6.0-beta`, `v0.6.0-preview3` are ordinary versions here, with
**semver precedence**: a pre-release ranks *below* its release.

```
0.5.0  <  0.6.0-alpha  <  0.6.0-alpha.1  <  0.6.0-beta.2  <  0.6.0-beta.11  <  0.6.0-rc.1  <  0.6.0
```

So the sequence works the way you would expect:

| after | `./release.sh` | |
|---|---|---|
| `v0.6.0-rc1` | `v0.6.0-rc2` | new version |
| `v0.6.0-rc1` | `v0.6.0` | new version - the final outranks its pre-releases |
| `v0.6.0` | `v0.6.0-rc1` | rejected: it is lower, so it is frozen |
| `v0.5.0` | `v0.5.0-beta` | rejected for the same reason |

Nothing special was added for this: `0.6.0-rc1` becomes frozen the moment `0.6.0`
lands purely because the comparator says it is lower, and the existing "frozen
once a higher version is in the manifest" rule does the rest. The upgrade chain
follows too - cutting `0.6.0` after `0.6.0-rc1` writes
`pg_semantius--0.6.0-rc1--0.6.0.sql`.

Release notes follow the same shape: `extension/CHANGES.md` needs a `## 0.6.0`
section, and that one section covers `0.6.0-beta1`, `0.6.0-rc.1` and `0.6.0`.
You refine it as the line progresses instead of renaming the heading on every
cut. A `## 0.6.0-rc.1` heading is accepted too if you want notes specific to one
pre-release.

Two traps this avoids, both real:

- **`sort -V` is not semver.** GNU version sort puts `0.6.0` *before* `0.6.0-beta`,
  i.e. it treats a pre-release as higher. Using it would make cutting `0.6.0`
  after `0.6.0-rc1` look like a downgrade and get it rejected — the one release
  you actually want. `scripts/semver.sh` exists for this and nothing in the
  release path ranks versions any other way.
- **The shell and the generator must agree.** `semver_cmp` in `scripts/semver.sh`
  and `compareVersions()` in `packages/cli/commands/extension.ts` implement the
  same total order and are tested against the same cases, including the canonical
  chain from semver.org §11. Every guard here assumes they cannot disagree.

Two things are refused rather than ordered:

- **Build metadata** (`v0.6.0+sha`). Semver says it does not affect precedence,
  which would make two distinct manifest keys compare equal.
- **`--` anywhere, and a trailing `-`.** The first is the separator in
  `<name>--<from>--<to>.sql`; the second PostgreSQL rejects in an extension
  version.

## What a release actually produces

Pushing the tag runs
[.github/workflows/extension-release.yml](.github/workflows/extension-release.yml),
which resolves the version from the tag name and publishes:

| Artifact | |
|---|---|
| git history | the `v<ver>` tag |
| GitHub Release | `pg_semantius-<ver>.zip` — the full install **plus the whole upgrade chain**, `META.json`, `.control`, `Makefile`, `README.md`, `CHANGES.md`, `SECURITY.md`, `LICENSE` — and the loose `.sql` and `.control` alongside it |
| GHCR | `postgres:<ver>-pg<major>`, `postgres:latest-pg<major>`, `postgres:latest` |

`<major>` is parsed from `docker-postgres/Dockerfile`'s `FROM` line, so a base
bump moves the tag suffix with it. **A pre-release never moves `:latest` or
`:latest-pg<major>`** - those mean the current stable build, so `v0.5.0-beta1`
publishes only `:0.5.0-beta1-pg18` and a pre-release is consumed by asking for it
by name. There is deliberately no bare `:<version>`
image tag: a version tag that silently changed PostgreSQL major later is the
exact ambiguity the suffix removes.

The gates, in order: `deno task extension <ver> --strict` → committed build must
equal the regenerated one → Path B → Path A → lifecycle → PGXN manifest checks →
package → release → image. If anything fails, nothing is published; fix it and
move the tag.

Building an image locally is [docker-postgres/build.sh](docker-postgres/build.sh)
and [publish.sh](docker-postgres/publish.sh). Neither regenerates the extension —
they package whatever is already in `extension/`.

## PGXN is not automated, and must not be

Nothing publishes to PGXN. Both workflows only *validate* `extension/META.json`
(`pgxn_meta validate` plus explicit checks for the four defects open item B10
named); neither uploads anything.

That is on purpose, because **PGXN is the one channel this project cannot take
back**. A GitHub Release is deleted and recreated on every re-release and a GHCR
tag is overwritten, which is what makes the newest version mutable. A PGXN
release is permanent: a version can never be replaced or withdrawn, only
superseded by a higher one. Publishing `0.5.0` there while it is still moving
would freeze a build that is going to change.

So it is a separate, manual, guarded step:

```bash
./scripts/pgxn-release.sh v0.5.0
```

[scripts/pgxn-release.sh](scripts/pgxn-release.sh) refuses unless the build on
disk is that version (full install, `META.json` and `default_version` all agree),
the working tree is clean, the tag `v<ver>` exists, and `HEAD` is the commit that
tag points at. It warns when `release_status` is not `stable`, requires
the version to be typed, then hands the archive to
`pgxn release` (or tells you to upload it at manager.pgxn.org).

**Publish to PGXN only when the version is final.** Afterwards, stop re-tagging
it: cut the next version for any further change.
