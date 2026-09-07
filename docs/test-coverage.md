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
falls below `PCT`. That is the headline figure, so vendored code cannot drag a
build below the line. The percentage is validated before any database work
starts, so a typo fails immediately.

## What you get

Written to `coverage/`, which is gitignored:

| File | What it holds |
|---|---|
| `summary.json` | the totals, machine-readable |
| `uncovered.md` | every function the suite never called, grouped by schema |
| `lcov.info` | line coverage mapped onto `apps/_core/migrations/<file>.sql`, so editor coverage gutters work |

The console prints the three headline ratios - functions called, statements
executed, tables touched - and a fourth line for vendored code, which is
measured but deliberately not counted in the three above. See "What counts".

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

## What counts, and what is reported beside it

The universe is split in two, and every ratio is reported twice.

**The headline is the code this project writes and can fix.** It is the only
number worth setting a threshold on.

**`pgmq` is reported separately.** It is pgmq v1.11.1, third-party code that
happens to be inlined into `apps/_core/migrations/0160_pgmq.sql` rather than
installed as an extension, which is why schema membership is the only thing that
marks it. It stays in the measurement - the queue RPCs in `0170_queue.sql` depend
on it behaving, and a version bump arrives here as a migration edit that coverage
should notice - but it does not dilute the headline.

The reason for the split is that the two answer different questions. Most of what
pgmq ships is machinery Semantius never exposes: partman, partitioning, unlogged
queues, FIFO indexes, grouped reads, topic routing, and a long tail of overload
variants of entry points that are already covered. Those functions are
permanently uncalled through no fault of the suite. Counted together with ours,
they dragged the headline down far enough to hide the fact that every
hand-written function is exercised, and the only way to raise the number would
have been to call vendored entry points the project does not use - which tests
nothing. Reported apart, both numbers say something true.

Functions and tables are split the same way on purpose. Splitting one and not the
other would leave two headline ratios describing different universes.

## Reading the result

**Three numbers, and they are not the same kind of number.**

- **Statement coverage** says how much of the code the suite actually runs. It is
  the one with room left in it, and the one to move.
- **Function coverage** is a floor, not a gradient: it asks whether any function
  is entirely unexercised. On the headline universe it sits at 100%, and a drop
  means somebody added a function no test reaches. It is meaningful only because
  vendored code is excluded - counted together with pgmq it reads in the sixties
  and moves for reasons that are not regressions.
- **Table coverage** is a floor check too: a table nothing touches is usually a
  table nothing tests.

**Never-called is not the same as untested.** Check `coverage/uncovered.md`
against these two groups before treating an entry as a gap:

- **Vendored `pgmq` functions.** Not our code, and the queue is exercised through
  the RPCs rather than through pgmq directly. They appear in `uncovered.md` under
  a heading saying they are not counted; see "What counts" above.
- **Deliberate refusal paths.** Some functions exist to raise, and the raise is
  asserted from the caller's side.

What is left after those two is the real list.

**Generated functions are no longer in that category.**
`apps/test/tests/0371_test_label_generator_sweep.sql` calls every `_label`,
`<fk>_label` and single-argument `select_rule` function the data dictionary
generated for the entities this deployment ships. Calling all of them is not
metric-chasing: it is the only test that catches a generated function that fails
to compile, or raises at runtime, on a shape nobody wrote a fixture for - a
junction, a self-reference, a spine chain, an unmanaged audit table.
`0370_test_composed_labels.sql` cannot replace it, because pgTAP files roll back
and a test's own entities take their generated functions with them; only shipped
shapes survive to be measured. The sweep found a real defect on its first run:
the single-argument `select_rule` overload raised `Authentication required` for
any caller without JWT claims, which is why nothing had ever called it.

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
- **Eleven files run as the RLS-exempt owner** (`0015`, `0060`, `0130`, `0180`,
  `0200`, `0240`, `0305`, `0336`, `0371`, `0385`, `0990`), so their table access
  exercises no policy. A test that must prove a policy has to authenticate.
  `0371` is owner-run deliberately: it sweeps generated functions that are
  REVOKEd from PUBLIC, and a `select_rule` policy would reduce its value
  comparisons to zero rows and pass vacuously.

## Lint

Coverage says which code ran. The linter says what is wrong with code whether it
ran or not, and it is the only tool that sees a function no test reaches.

```sh
./pgdocker/pg-cli-retest.sh                 # a migrated database first
deno task lint-sql --database-url postgresql://postgres:<pw>@localhost:5432/appdb
```

It runs `plpgsql_check` over every PL/pgSQL function in `public`, `common`,
`rbac`, `audit` and `pgmq`, installing the extension into schema `extensions` if
the server has it but the database does not. The report goes to stdout and to
`coverage/lint.txt`, beside the coverage reports.

**Why it passes arguments a bare invocation does not.** `plpgsql_check` refuses
a trigger function outright without `relid` ("missing trigger relation"), and a
statement-level trigger function that reads its transition tables reports
`relation "new_rows" does not exist` unless it is told the names the trigger's
`REFERENCING` clause declares. Both are things a bound trigger already knows, so
the command reads them back out of `pg_trigger` rather than guessing - which is
what brings the seven trigger functions a plain invocation cannot see into the
report. What no binding supplies is in the `OVERRIDES` table at the top of
`packages/cli/commands/lint_sql.ts`, each entry with its reason.

**The skipped list is the point.** Any function the checker could not check at
all is listed with the reason it raised. One skip is expected -
`pgmq.notify_queue_listeners`, vendored and unbound by design - and anything
else prints as `unexpected skip:` and wants either an override or a recorded
reason. A function silently missing from the report is the failure mode this
command exists to prevent.

**It is not a gate.** The exit code is always 0. Style warnings do not fail
builds here, and `pgmq` findings are counted apart from ours for the same reason
coverage splits them: they are vendored, and closing them means editing code we
re-vendor.

**It leaves a footprint, and so does `--coverage`.** Installing `plpgsql_check`
creates schema `extensions` in the database it ran against. `pg-ext-lifecycle.sh`
step 10 compares a schema-only `pg_dump` of the CLI container against the
extension container, so a database that has been linted or coverage-measured is
no longer byte-identical to one that has not, and that step fails on the
difference. Run the lifecycle script first, or drop the extension and its schema
afterwards.

## When you add tests

Re-run with `--coverage` and compare against the previous run. A drop in
statement coverage after adding code means the new code is untested. A drop in
function coverage means a function no test reaches at all - including a generated
one, since the sweep covers those now, so a new entity shape the generator
mishandles shows up here rather than hiding in the denominator. If the number
moves for a reason worth remembering, put the reason in the test file, not here.
