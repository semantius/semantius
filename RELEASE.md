# Releasing

Maintainer document. Consumers do not need it — installing is covered by
[README.md](README.md#postgresql-extension-alternative-distribution) and by the
generated `extension/README.md` that ships inside every archive.

Everything here is about **one artifact set**: the `pg_semantius` extension
build in `extension/`, the GitHub Release that carries its archive, and the
GHCR database image built from it. They always move together at one version.

## The rule: the highest version is mutable, everything below it is frozen

A version stays **mutable while it is the highest version built**. It may be
regenerated, re-tagged and re-released as often as needed. It becomes **frozen
the moment a higher version is committed** to `extension/versions.json`.

This is deliberate. `0.5.0-beta1` is the first version in the manifest, so
there is no upgrade chain into it. Until 0.5.0 is declared final its line is
developed in place rather than accreting patch versions for changes nobody has
consumed yet.

Two things enforce it:

- `deno task extension <ver>` **refuses** when `versions.json` already holds a
  higher version. Without that guard the run would leave a broken `extension/`:
  the edit detection is skipped (it only looks at versions *below* the target,
  and a superseded version has none), the higher version's full install is pruned
  away, its upgrade script is orphaned, and `default_version` moves backwards.
- The version argument is **required**: the command has no default version, so
  it never builds a version nobody named.

**A final release's migrations are frozen the moment it is tagged**, even while
it is the highest. A database it built is updated by every later release, and no
runner runs a run-once file a second time, so a re-release of a final may
change repeatable files and add files after its last one, and nothing else.
`release.sh` refuses it otherwise (the re-release check, below). A pre-release
stays fully mutable while it is the highest: its run-once files may still change
in place, and a database built from it is then refused with "replace the
database with a fresh install" instead of being updated.

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

One script, and the version argument selects the outcome. Its read-only
preflight includes the checks of the migrations against the released tags and
of PGXN (below). Then it regenerates `extension/` in release mode, runs all
three harnesses in the order they depend on, regenerates `schema.md` from the
database Path A just migrated and tested, runs the update test, builds the
image locally, commits the build, proves the generator is deterministic by
regenerating a second time, then tags and pushes. Pushing the tag is what starts
[the workflow](.github/workflows/extension-release.yml), which rebuilds from a
clean checkout and publishes the GitHub Release and the GHCR image.

### The checks against the released tags

Both compare `apps/_core/migrations` of the working tree with a tag, and both
refuse a run-once file that changed, any file that was removed or renamed, and
a file added that sorts before the tag's last file (the 9900 files run last on
every path, so they may be added anywhere):

- **The re-release check**, for a re-release of a final release, against that
  release's own tag. `--allow-edited-migrations` does not waive it. A
  re-release of a pre-release skips it.
- **The final-tag check**, for every release, against the highest released
  final tag: every database that release built must update to this one. It is
  skipped while no final release is tagged, and `--allow-edited-migrations`
  waives it.

### Release mode, and the update test

Every `_core` file's value in `extension/versions.json`, and in `_versions`
after a pg_semantius build applied it, is `<ts>.<sha256>`: the UTC time
(`YYYYMMDDHHMMSS`) of the release run that last changed its text, and the
SHA-256 of the text. The runners compare the ts to refuse a database a newer
build migrated, so ts values must rise with every release.

- **Development mode**, `deno task extension <ver>`, the mode of every local
  run and of CI: a file keeps a stamped value whose hash matches its text, and
  every other file gets the ts `99999999999999`. It sorts after every real ts,
  so every released runner refuses a database such a build installed as newer
  than itself, and that database has to be rebuilt.
- **Release mode**, `deno task extension <ver> --release <path>`, run only by
  `release.sh`, with the `versions.json` of the release this one follows: the
  version's own tag for a re-release, otherwise the highest released tag below
  it. A file keeps its working-tree value if that has a real ts and a matching
  hash, so a restarted release writes what its first run wrote; otherwise the
  tag's value, if that has a real ts and the same hash, so a file back at its
  released text keeps the released ts; otherwise it gets the run's ts, one UTC
  time for all such files, never earlier than one second after the latest real
  ts either manifest records.

The reproducibility check and CI's porcelain guard regenerate in development
mode, which keeps every stamped value whose hash still matches, so they rebuild
the release run's values byte for byte.

**The update test** runs after the lifecycle: a database the highest released
tag built, updated to this build, must equal a fresh install of this build,
through the CLI (`pgdocker/pg-compare-installs.sh --upgrade v<tag>` on the CLI
container) and through the extension (`--upgrade-ext v<tag>` on the extension
container: `ALTER EXTENSION pg_semantius UPDATE` and `migrate()` for a new
version, `DROP` and `CREATE EXTENSION` and `migrate()` for a re-release). When
that tag is a pre-release, a refusal with "replace the database with a fresh
install" passes too, if it left the ledger and the schema exactly as they were.

The duplication is the design. The harnesses run locally to prove the current
working tree is green; CI re-runs them to prove the result is **reproducible**
rather than green only on one machine. `./release.sh --help` lists the flags;
`--skip-tests` deliberately cannot tag.

PGXN is separate and manual — see below.

## How a change reaches an existing database

Every runner (the CLI's `migrate`, its script mode, the extension's
`CALL semantius.migrate()`, the provisioners) applies the same rules, recorded
per file in `public._versions` as `<app>.<file name>` with the file's value:
`<ts>.<sha256>` for a `_core` file of a pg_semantius build (see release mode
above), and the plain SHA-256 of the text for the files of every other app and
for a `_core` file the build does not hold with that text:

| File | Runs |
|---|---|
| `NNNN_name.sql`, `NNNN_name.jsonc` (repeatable) | when it has no ledger row, or its value changed since it last ran |
| `NNNN_name.once.sql`, `NNNN_name.once.jsonc` | when it has no ledger row; never again, even when changed |
| `9900_*` and above | last, and after every pass that ran anything, including a failed one |

So a fix to a function, trigger, view or policy is an edit of its repeatable
`.sql` file, and entity metadata is an edit of its `.jsonc` file; both reach an
existing database on its next migrate. A change to a table, a column or seed
data is a new `.once.` file numbered after every released file.

Before the first file, every runner refuses two kinds of database, looking at
the `_core.` rows only. A refusal changes nothing and releases the migration
lock; a row with a NULL checksum is never refused.

1. **Newer**: a stamped row whose ts is later than the runner's ts for that
   file, or, when the runner does not have the file or has no ts for it, later
   than the runner's latest ts. The message names a newer pg_semantius. Without
   this an older runner would re-apply its older text of every repeatable file
   and then fail on a schema it does not know, leaving a half-downgraded
   database. A database with content no release has stamped yet
   (`99999999999999`) is newer than every released runner.
2. **Replace**, checked after "newer": a run-once row whose value differs from
   the runner's, and a stamped row for a file the runner does not have. A plain
   row differs from every stamped value. The message ends with "this database
   cannot be updated; replace the database with a fresh install", because a
   run-once file never runs again and such a database would never get the
   schema the runner's text creates.

So a database the published `0.5.0-beta1` built, whose rows are plain, is
refused with "replace" by every later build. The provisioners record plain
values, so they are refused the same way on every database a pg_semantius build
migrated. Two gaps are accepted: a runner released without these checks (the
published `0.5.0-beta1`) is not stopped, and a development build does not
refuse a database as newer through the files it changed, because it stamps
them `99999999999999`.

**Through the CLI**, the next `migrate` runs whatever changed. **Through the
extension**, the migration texts are embedded in the installed
`semantius.migrate()`, so a database runs the texts of the version it has
installed:

- A **re-release of the same version** has no `0.5.0 -> 0.5.0` update path, so
  `ALTER EXTENSION pg_semantius UPDATE` is a no-op and `migrate()` keeps the old
  texts. A database takes the re-release through
  `DROP EXTENSION pg_semantius`, `CREATE EXTENSION pg_semantius` and
  `CALL semantius.migrate()`: `DROP EXTENSION` removes only the installer, and
  the new `migrate()` applies what changed.
- **A new version** ships an upgrade script that replaces `migrate()` with the
  full new bundle. `ALTER EXTENSION pg_semantius UPDATE` followed by
  `CALL semantius.migrate()` then runs the new files and every changed
  repeatable one.

`semantius.pending()` lists what is due by the run rules; it does not run the
refusal checks, so on a refused database it still lists files.
`semantius.status()` also lists, in `changed_versions`, the `.once.` files whose
recorded value differs from the build's. A database with such a `_core` file is
refused with "replace": a `.once.` file that shipped is never run again, so the
only remedy is a fresh install with the data moved across.

**`--allow-edited-migrations` strands databases.** A deliberate hot-patch of a
released `.once.` file gives the file a new value, so every database built
before the patch is refused with "replace the database with a fresh install".

**Forward only, additive only** once a version has been released: no down
migrations, no edits to a released `.once.` file, and no rename, drop or type
change of a table or column - add the new one, move the data, and leave the old
one marked deprecated in its description. This is what keeps the repeatable
files (current state, edited in place) and the `.once.` files (history, never
edited) consistent: every `.once.` file sees the same starting point on a
fresh install and on an upgrade. `pgdocker/pg-compare-installs.sh --upgrade
<previous tag>` and `--upgrade-ext <previous tag>` prove it, and `release.sh`
runs both as its update test: the previous release updated must equal a fresh
install.

A change to a dictionary generator (`create_dd_table`, `build_select_rule_policy`,
`build_record_logic_trigger`, ...) replaces the generator, not the policies,
functions and triggers it generated earlier. It therefore ships with a `.once.`
file that rebuilds the generated objects of every affected entity.

A field's required check is the exception, because a `.once.` file is one
transaction and its table locks would pile up until it commits, on a database
with no maintenance window. Every runner instead calls
`dd_install_missing_checks()` in a loop after the migration files, one table per
transaction, and it adds only what is missing. A field whose rows already have
missing values, or a table too busy to lock within 2 s, is skipped with a warning
and picked up by a later migrate.

## What the version argument selects

**The floor is what has been released, not what has been built.** `git tag -l 'v*'`
is the record of releases; `extension/versions.json` records builds, and a build
happens whenever anyone runs `deno task extension`. A stray local build must not
block the versions below it.

| `./release.sh v<a.b.c>` | |
|---|---|
| **a tag `v<a.b.c>` exists and it is the highest released** | refresh - a re-release. The tag moves, the GitHub Release is replaced, the version-pinned image is overwritten. Refused for a final whose migrations changed in a way its databases cannot follow, and for a version PGXN has published |
| **a tag exists but something higher is released** | rejected: published, superseded, frozen |
| **no tag, and it sorts above the highest released** | a new release |
| **no tag, and it does not sort above the highest released** | rejected: it is in the past |

If `versions.json` holds builds at or above the target that have **no tag**,
`release.sh` names them and drops them from the manifest before generating.
Nothing points at an unreleased build - no tag, no GitHub Release, no upgrade
script leading to it - so it is a stale artifact rather than history, and left in
place it would make the generator refuse the target.

From the moment a higher version is in the manifest, the lower one is frozen for
the generator too. The build then refuses:

- an edit of a `.once.` file an earlier version shipped - it would never run on
  a database that already has it, so fresh installs and upgrades would diverge;
- a removed or renamed file an earlier version shipped - the ledger key is the
  file name, so a renamed `.once.` file would run a second time;
- an added file that sorts before the last file an earlier version shipped
  (9900 and above excepted) - it would run mid-sequence on a fresh install but
  last on an upgrade.

`--allow-edited-migrations` waives the first two for a deliberate hot-patch, at
the cost of every database built before it (see above); the third is fixed by
renaming the file, never waived. Repeatable `.sql` and `.jsonc` files stay
editable - that is their purpose. `release.sh` applies the same three rules
against the released tags, in the checks described under "Doing it".

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

Nothing special handles this: `0.6.0-rc1` becomes frozen the moment `0.6.0`
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
  same total order, the rules of semver.org §11, and each one's comment says so;
  no test compares the two. Every guard here assumes they cannot disagree.

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
| git history | the `v<ver>` tag, on a commit whose `schema.md` is generated from that version's migrations and stamped with `<ver>` |
| GitHub Release | `pg_semantius-<ver>.zip` — the full install **plus the whole upgrade chain**, `META.json`, `.control`, `Makefile`, `README.md`, `CHANGES.md`, `SECURITY.md`, `LICENSE` — and the loose `.sql` and `.control` alongside it |
| GitHub Release | the five `pg_semantius-cli-<os>-<arch>[.exe]` CLI binaries and `checksums.txt`, which `install.sh` and `install.ps1` download by name |
| GHCR | `postgres:<ver>-pg<major>`, `postgres:latest-pg<major>`, `postgres:latest` |

`release.sh` also writes `<ver>` into `packages/cli/deno.json` and
`package.json` and commits them with `extension/`. The CLI imports the first of
those, so it is the only thing a compiled binary can report as its version —
and the release job refuses to publish a tag whose committed copy says
something else.

A **new** tag's release is created as a draft, filled with every asset, and
only then published. `releases/latest` does not move to a draft, so an upload
that fails halfway leaves the previous release installable rather than breaking
both install one-liners.

**A re-release does not get that protection.** The job runs `gh release delete`
first so the assets are replaced cleanly, and for the whole build-and-upload
window `releases/latest` falls back to the previous tag - which has no
`pg_semantius-*` binaries, so both install one-liners 404 until the new release
is published. Re-releasing the highest version is supported and expected (see
above); this is the cost of it.

`<major>` is parsed from `docker-postgres/Dockerfile`'s `FROM` line, so a base
bump moves the tag suffix with it. **`:latest` and `:latest-pg<major>` follow the
highest version released, pre-releases included** - highest, not most recent -
so `v0.5.0-beta1` publishes `:0.5.0-beta1-pg18` and moves both moving tags onto
it.

The rejected alternative is `:latest` as the highest *final* release. It sounds
safer and is the commoner convention, but it holds the tag on whatever shipped
last for as long as everything ahead of it is a pre-release - and "the last final
build" is only a useful thing to hand someone while that build is still
supported, which the tag cannot know. A moving tag that quietly points at a
dead end is worse than one that moves.

The guard that remains is the one that matters: a moving tag may only go
*forward*. Both are published only when the version being released is the
highest tag in the repo, so re-releasing an older version can never drag
`:latest` backwards. Anything that must not move pins `:<version>-pg<major>`,
which is always published.

**There is no `:stable` yet.** It belongs with the first final release: at that
point `:stable` follows the highest final and `:latest` keeps following the
highest of anything, which is the two-channel arrangement both tags need to mean
what they say. Until then nothing would point at it but the discarded lineage.

There is deliberately no bare `:<version>` image tag: a version tag that
silently changed PostgreSQL major later is the exact ambiguity the suffix
removes.

The gates, in order: the CLI binaries (the committed version in
`packages/cli/deno.json`, the builds, the smoke tests) → `deno task extension
<ver>` → committed build must equal the regenerated one → Path B → Path A →
lifecycle → PGXN manifest checks → package → release → image. If anything
fails, nothing is published; fix it and move the tag.

Building an image locally is [docker-postgres/build.sh](docker-postgres/build.sh)
and [publish.sh](docker-postgres/publish.sh). Neither regenerates the extension —
they package whatever is already in `extension/`.

## PGXN is not automated, and must not be

Nothing publishes to PGXN. Both workflows only *validate* `extension/META.json`
(`pgxn_meta validate` when it is installed, plus the explicit checks of
`scripts/check-pgxn-meta.sh` for what a spec validation does not catch: a
`git://` repository URL, a maintainer with no email, a missing `release_status`
and a missing `CHANGES.md`); neither uploads anything.

That is on purpose, because **PGXN is the one channel this project cannot take
back**. A GitHub Release is deleted and recreated on every re-release and a GHCR
tag is overwritten, which is what makes the highest version mutable. A PGXN
release is permanent: a version can never be replaced or withdrawn, only
superseded by a higher one. Publishing `0.5.0` there while it is still moving
would freeze a build that is going to change.

So it is a separate, manual, guarded step:

```bash
./scripts/pgxn-release.sh v0.5.0
```

[scripts/pgxn-release.sh](scripts/pgxn-release.sh) refuses unless the build on
disk is that version (full install, `META.json` and `default_version` all agree)
and equals a fresh regeneration, `extension/` has no uncommitted changes (others
only draw a warning), the tag `v<ver>` exists and matches origin, `HEAD` is the
commit that tag points at, and the
archive attached to the GitHub Release holds exactly the manifest's files with
the build's content. It refuses a `release_status` other than `stable` unless
`--allow-testing-release` is passed, requires the version to be typed, then
hands that archive to `pgxn release` (or tells you to upload it at
manager.pgxn.org).

**Publish to PGXN only when the version is final.** Afterwards, stop re-tagging
it: cut the next version for any further change. `release.sh` enforces that
for a re-release: it asks `https://api.pgxn.org/dist/pg_semantius.json` and
refuses when the version is among the distribution's releases. Only two answers
pass: 404 (the distribution does not exist) and a release list without the
version. Any other status, or no answer, refuses, since it says nothing about
what is published.
