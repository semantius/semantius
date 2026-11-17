# Agent Execution Guidelines

The rules for agents are in [AGENTS.md](../../AGENTS.md); this page repeats
the ones about running the database.

## Where to Run
- Run every test cycle on the local pgdocker containers, never on a remote
  database. `./pgdocker/pg-cli-retest.sh` creates a fresh container, then
  drops everything, runs `migrate --apps _core,nwind,test` and the pgTAP
  suite on it (the migrate path). `./pgdocker/pg-ext-retest.sh` runs the same
  suite on a `CREATE EXTENSION` install (the extension path). Both take the
  connection from `pgdocker/.env` and pass it with `--database-url`.
- `DATABASE_URL` can name a remote database. Never run
  `deno task dropall` against it, nor `retest` or `reset`, which drop
  everything first.

## Required Agent Actions

### After Any Database Changes
1. **ALWAYS execute**: `./pgdocker/pg-cli-retest.sh`
2. **When the change touches packaging or the extension build**:
   `./pgdocker/pg-ext-retest.sh`
3. **VERIFY**: All tests pass before completing the task

### After Any CLI Changes
1. Test the new command functionality
2. Ensure it integrates with existing workflow
3. Verify error handling works correctly

### After Any Test Changes
1. Execute the full test cycle
2. Verify new tests run successfully
3. Ensure no existing tests are broken

## Migrations
After a release, migrations are forward only and additive only: never edit a
released `.once.` file, never rename or remove a released file, never rename,
drop or retype a table or column.

## Success Criteria
The agent has successfully completed a task when:
1. All requested changes are implemented
2. Full test cycle executes without errors on the local containers
3. All pgTAP tests pass
4. No breaking changes introduced
