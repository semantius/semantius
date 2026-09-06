# Measuring test coverage

How to measure what the pgTAP suite actually executes, and how to read the
result. **No coverage numbers live in this file.** They are stale the moment a
test is added, and the tooling produces them on demand.

## Run it

```sh
./pgdocker/pg-cli-retest.sh --coverage      # migrate path
./pgdocker/pg-ext-retest.sh  --coverage     # CREATE EXTENSION path
```

Both forward the flag to `deno task test --coverage`. Either path reports the
same function and statement numbers; they differ only in how the schema was
installed. Use the extension path when the change touches packaging, the migrate
path otherwise - it is the faster loop.

`--coverage-min <PCT>` implies `--coverage` and exits 1 when function coverage
falls below `PCT`. That is the form for CI, and the percentage is validated
before any database work starts, so a typo fails immediately.

## What you get

Written to `coverage/`, which is gitignored:

| File | What it holds |
|---|---|
| `summary.json` | the totals, machine-readable |
| `uncovered.md` | every function the suite never called, grouped by schema |
| `lcov.info` | line coverage mapped onto `apps/_core/migrations/<file>.sql`, so editor coverage gutters work |

The console prints the three headline ratios: functions called, statements
executed, tables touched.

## How it is measured

Two sources, because neither is enough alone:

- **`plpgsql_check`'s profiler** gives per-statement execution counts inside
  PL/pgSQL bodies. The `postgresql-18-plpgsql-check` package is in
  `pgdocker/Dockerfile`, so both stacks report statement data without a
  throwaway container. If a run says statements are "not measurable", that
  extension is missing from the image being used.
- **`pg_stat_user_functions`** gives call counts for every function, including
  SQL-language ones the profiler cannot see. It needs `track_functions`, which
  the harness sets for the run.

The universe is the five Semantius schemas on **both** install paths. It is
deliberately not derived from extension membership: since the 0.5.0 thin
installer, the extension's only members are the `semantius` schema and its
functions, so that would report four objects.

The implementation is `packages/cli/commands/coverage.ts`.

## Reading the result

**Three numbers, and only one of them is a target.**

- **Statement coverage** is the honest one. It says how much of the code the
  suite actually runs.
- **Function coverage** is diluted by design. A large share of the universe is
  **generated per entity** - the `_label` and `<fk>_label` computed-column
  functions the data dictionary builds for every table. Adding a Northwind entity
  adds functions and lowers the percentage without changing a line of behavior.
  Compare it against the previous run, never against an absolute goal.
- **Table coverage** is a floor check: a table nothing touches is usually a table
  nothing tests.

**Never-called is not the same as untested.** Check `coverage/uncovered.md`
against these three groups before treating an entry as a gap:

- **Vendored `pgmq` functions.** Not our code, and the queue is exercised through
  the RPCs rather than through pgmq directly.
- **Generated label functions.** One pair per entity. A handful being called
  proves the generator works; calling all of them proves nothing more.
- **Deliberate refusal paths.** Some functions exist to raise, and the raise is
  asserted from the caller's side.

What is left after those three is the real list.

## Known structural gaps

These are absent from the suite by construction, not by oversight. They change
slowly, which is why they are written down here rather than regenerated:

- **Identifier hardening.** No entity or field is ever created with a name
  containing `"`, `;`, `--`, spaces, 63+ bytes or non-ASCII, while the dictionary
  builds DDL dynamically (`create_dd_table`, `apply_field_ddl`,
  `rename_dd_table`, `build_select_rule_policy`).
- **Event triggers** (`pgrst_ddl_watch`, `pgrst_drop_watch`,
  `track_ddl_changes`) fire during the suite but are never asserted on.
- **Scope-confined sessions** (`app.oauth_scopes`) and `anon` / no-role sessions
  beyond `0390_test_unauthenticated_access.sql`.
- **Large inputs**: deep JsonLogic, huge enum sets, long text, a dictionary
  operation failing halfway.
- **Concurrency.** pgTAP runs one session, so races - the first-user election,
  advisory locks - cannot be expressed in it. Those live in
  `pgdocker/pg-ext-lifecycle.sh`, which also covers install,
  `pg_dump`/single-pass `pg_restore`, `DROP EXTENSION`, schema pinning and the
  refusals.
- **Ten files run as the RLS-exempt owner** (`0015`, `0060`, `0130`, `0180`,
  `0200`, `0240`, `0305`, `0336`, `0385`, `0990`), so their table access
  exercises no policy. A test that must prove a policy has to authenticate.

## When you add tests

Re-run with `--coverage` and compare against the previous run. A drop in
statement coverage after adding code means the new code is untested; a drop in
function coverage alone usually means new generated functions, which is not a
regression. If the number moves for a reason worth remembering, put the reason
in the test file, not here.
