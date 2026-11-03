# Bug: concurrent child writes can lose a rollup total

Status: **fix applied to the working tree, uncommitted, for review.** Found 2026-11-03 on
`v0.5.0-beta1-5-g4dd0339`, while verifying `semantius-cli`'s transfer tools against a disposable
stack. No tag contains rollups yet. The fix adds no `.once.` file, so a database that already has
rollups keeps its old generated functions until `rollup_rebuild_all()` runs or a field rebuilds them.

## Problem

When two transactions write children of the same parent at the same time, the parent's rollup can
end up wrong, with no error. It stays wrong until the next write to a child of that parent. A `count`
is the worst case: **it loses one on every overlapping pair of inserts.**

It takes only two ordinary writes. These results come from the script below, for a parent with a
`sum` and a `count` over one link:

| Two concurrent inserts on one parent | Stored total / count | Its rows say | Runs |
|---|---|---|---|
| Amounts 5 and 7 | 12 / **1** | 12 / 2 | 3 of 3 |
| Amounts 5 and 5 | **5 / 1** | 10 / 2 | 3 of 3 |

Bulk writes hit it often, because small contributions are often equal. `semantius-cli` importing with
four batches in flight:

| Load | Result |
|---|---|
| 50,000 lines over 2,050 parents and 5 groups | 9 runs: 7 reported success with wrong totals (28 to 62 parents, and all 5 groups), and 2 stopped with `40P01` |
| 10,000 lines over 50 parents and 5 groups | Wrong in 3 of 7 runs: 1 parent and its group |
| The same loads, one batch at a time | Correct in 21 of 21 runs |

One wrong row, for scale: a parent stored **627** while its 196 lines summed to **769**. All 196
lines had arrived, the source database was correct, and a no-op update of one line corrected it.

**Who is affected:** any writers that overlap, such as two users, a webhook and a user, or a bulk
load. `semantius-cli` now writes these tables one batch at a time (`b0211a0`), which only keeps its
own batches apart.

`docs/rollup-fields.md`, "Cost and concurrency", says concurrent writes to children of one parent
serialize on the parent row. The write does; the aggregate it writes was computed before the wait.

## Cause

The cause below comes from reading the generated SQL. The reproduction confirms what it predicts:
equal amounts fail and different amounts do not.

`rollup_build_link` (`apps/_core/migrations/0440_rollup.sql:847-850`) generates this statement, which
runs in the child's statement-level trigger:

```sql
UPDATE public.<parent> p SET total = s.total
  FROM (SELECT k.key, <aggregate> AS total FROM (SELECT DISTINCT ... FROM new_rows ...) k(key)) s
 WHERE p.<key> = s.key AND (p.total) IS DISTINCT FROM (s.total);
```

Under READ COMMITTED, starting from a parent at total B:

1. T1 inserts a child worth X. Its trigger sets the parent to B+X and holds the row lock.
2. T2 inserts a child worth Y. Its snapshot cannot see T1's child, so it computes `s.total` = B+Y.
3. T2's UPDATE waits for T1's row lock.
4. T1 commits. PostgreSQL re-checks T2's `WHERE` against the new row, but keeps the old `s.total`.
5. **If X = Y**, then B+X `IS DISTINCT FROM` B+Y is false, so the row is skipped. T2's child is never
   counted.
6. If X ≠ Y, the row is updated, and the guard (`0440_rollup.sql:958-959`) recomputes under a fresh
   snapshot. That sees both children, which is why this case comes out right.

**Why `count` is worse.** Two inserts each add 1, so their contributions are always equal. The guard
also recomputes a column only if its value changed, so a `count` beside a `sum` on one link loses its
count even when the `sum` differs. That is the first row of the table above.

**The deadlock has the same root.** The statement locks parents in whatever order the plan returns
them, so two statements over shared parents can deadlock, as `docs/rollup-fields.md` warns. It does
happen in practice: see the 50,000-line row.

## Reproduction

Run this against any migrated database. It needs no CLI and no PostgREST, and it removes what it
creates. It follows `pgdocker/pg-required-locks.sh`, because the pgTAP suite runs in one session and
cannot show a race.

```bash
#!/usr/bin/env bash
# pg-rollup-race.sh - two overlapping child writes must both reach the rollup.
set -euo pipefail

CONTAINER="${CONTAINER:-postgres18-cli}"
DB="${DB:-appdb}"
FAILED=0

q() {
  docker exec -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" \
    psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qtAc "$1" | tr -d '\r'
}

cleanup() {
  q "DELETE FROM public.fields WHERE table_name = 'race_parents' AND field_name IN ('total', 'line_count')" || true
  q "DELETE FROM public.entities WHERE table_name = 'race_lines'" || true
  q "DELETE FROM public.entities WHERE table_name = 'race_parents'" || true
}
trap cleanup EXIT

q "INSERT INTO public.entities (table_name, singular_label, plural_label, module_id)
   VALUES ('race_parents', 'Parent', 'Parents', 1), ('race_lines', 'Line', 'Lines', 1)"
q "INSERT INTO public.fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
   VALUES ('race_lines', 'parent_id', 'Parent', 'reference', 'race_parents', 'restrict'),
          ('race_lines', 'amount', 'Amount', 'number', '', '')"
q "INSERT INTO public.fields (table_name, field_name, title, format, rollup)
   VALUES ('race_parents', 'total', 'Total', 'number',
           '{\"link_field\": \"race_lines.parent_id\", \"function\": \"sum\", \"value_field\": \"amount\"}')"
q "INSERT INTO public.fields (table_name, field_name, title, format, rollup)
   VALUES ('race_parents', 'line_count', 'Lines', 'int64',
           '{\"link_field\": \"race_lines.parent_id\", \"function\": \"count\"}')"

race() { # race <amount of the first writer> <amount of the second writer>
  local parent
  parent=$(q "INSERT INTO public.race_parents (label) VALUES ('p') RETURNING id")
  # The first writer holds the parent's row lock for 2 s. The second waits for it.
  docker exec -d "$CONTAINER" psql -U postgres -d "$DB" -c \
    "BEGIN;
     INSERT INTO public.race_lines (label, parent_id, amount) VALUES ('a', $parent, $1);
     SELECT pg_sleep(2);
     COMMIT;" >/dev/null
  sleep 0.7
  q "INSERT INTO public.race_lines (label, parent_id, amount) VALUES ('b', $parent, $2)"
  sleep 2
  local got wanted
  got=$(q "SELECT round(total)::int || ' / ' || line_count FROM public.race_parents WHERE id = $parent")
  wanted=$(q "SELECT round(sum(amount))::int || ' / ' || count(*) FROM public.race_lines WHERE parent_id = $parent")
  if [ "$got" = "$wanted" ]; then
    echo "  ok: amounts $1 and $2: total / count $got"
  else
    echo "  FAILED: amounts $1 and $2: stored total / count $got, its rows say $wanted"
    FAILED=1
  fi
}

race 5 7
race 5 5
exit $FAILED
```

## Recommended fix

**Lock the touched parents first, in key order, then compute.** In `rollup_build_link`, the generated
function takes the row locks in a statement of its own, before the existing UPDATE:

```diff
     v_all  := format('SELECT p2.%I FROM public.%I p2', v_key, v_parent);
+    -- Lock before reading the children. The UPDATE then takes its snapshot after every
+    -- writer ahead of it has committed, so it counts their rows. Key order means two
+    -- statements over the same parents queue instead of deadlocking.
+    v_lock_head := format('PERFORM 1 FROM public.%I p WHERE p.%I IN (', v_parent, v_key);
+    v_lock_tail := format(') ORDER BY p.%I FOR NO KEY UPDATE', v_key);

     PERFORM rollup_create_function(v_fn, format($B$
 BEGIN
     IF TG_OP = 'INSERT' THEN
         IF NOT EXISTS (SELECT 1 FROM new_rows) THEN RETURN NULL; END IF;
+        %s;
         %s;
     ELSIF TG_OP = 'UPDATE' THEN
         IF NOT EXISTS (SELECT 1 FROM new_rows) THEN RETURN NULL; END IF;
+        %s;
         %s;
     ELSIF TG_OP = 'DELETE' THEN
         IF NOT EXISTS (SELECT 1 FROM old_rows) THEN RETURN NULL; END IF;
+        %s;
         %s;
     ELSE
+        %s;
         %s;
     END IF;
     RETURN NULL;
 END;
-$B$, v_head || v_ins || v_tail,
-     v_head || v_ins || ' UNION ' || v_del || v_tail,
-     v_head || v_del || v_tail,
-     v_head || v_all || v_tail));
+$B$, v_lock_head || v_ins || v_lock_tail, v_head || v_ins || v_tail,
+     v_lock_head || v_ins || ' UNION ' || v_del || v_lock_tail, v_head || v_ins || ' UNION ' || v_del || v_tail,
+     v_lock_head || v_del || v_lock_tail, v_head || v_del || v_tail,
+     v_lock_head || v_all || v_lock_tail, v_head || v_all || v_tail));
```

`v_lock_head` and `v_lock_tail` also need declaring.

**Why it works.** Each statement in the generated PL/pgSQL takes a new snapshot under READ COMMITTED.
Once T2 holds the lock, T1 has committed, so T2's UPDATE sees T1's child and computes B+X+Y. A writer
still behind T2 waits for T2's lock and then sees T2's child. The `IS DISTINCT FROM` gate stays, so a
parent whose total did not move is still not written, and fires no triggers.

**What it costs.** Every statement that touches children now takes a row lock on their parents, even
when no total moves, so writers to children of one parent wait for each other until commit. The lock
is `FOR NO KEY UPDATE`, the one an ordinary UPDATE takes, so it does not block the `FOR KEY SHARE` of
a foreign key check. A bulk import showed no measurable cost (see Verification), but many small
writers on one busy parent were not measured.

**Do not add a shortcut that skips the lock when the total looks unchanged.** Take T2 inserting a 3
under a `max` of 10 while T1 deletes the 10. T2 sees no change and skips, T1 cannot see T2's row and
stores the next value down, and the 3 is lost. The one safe narrowing, if the lock proves costly: skip
parents in the UPDATE branch when the child's link, value and filter columns did not change.

**Alternatives considered:**

- *Remove the gate.* The guard still would not recompute, since NEW equals OLD, and every parent would
  be written on every child write, firing its triggers and queue mappings.
- *Have the guard always recompute.* This fixes the value only if the row is reached, and the gate
  still skips it.
- *Advisory locks per parent.* These give the same serialization without the row lock, but add a second
  lock namespace to reason about, for no gain.

### Also needed with the fix

- **Regenerate the triggers.** The fix changes generated functions, so existing rollups need
  `rollup_rebuild_all()` to take effect.
- **Repair existing data.** Totals already wrong stay wrong. Run `rollup_backfill(table, field)` for
  each rollup on any database that has taken concurrent writes.
- **Regenerate the extension build:** `deno task extension <version>`, committed with the migration.
- **Add the regression test.** Keep the script above as `pgdocker/pg-rollup-race.sh`, since pgTAP cannot
  show this.
- **Correct `docs/rollup-fields.md`,** "Cost and concurrency", including its note that statements over
  several parents can deadlock in scan order.

## Verification

The fix was applied to a disposable database with `CREATE OR REPLACE FUNCTION rollup_build_link`, not
through a migration. That database ran image `postgres18-ext:local` (`deno task extension --check`
reports it current), behind PostgREST.

| Check | Unpatched | With the fix |
|---|---|---|
| Script above, 3 runs | Fails every run, as in the first table | **Passes every run:** 12 / 2 and 10 / 2 |
| 50,000 lines, four concurrent batches | 3 runs: 2 `40P01`, 1 with 62 parents and all 5 groups wrong | **5 of 5 correct, no deadlock** |
| Time for those imports | 3.6 to 4.4 s | 3.2 to 3.6 s |
| 50,000 lines, one batch at a time | 3.6 and 3.9 s, correct | 3.6 and 3.6 s, correct |
| pgTAP suite with `nwind,test` | Not run for comparison | **3,616 passing**, including `0555_test_rollup.sql` |
| `rollup_rebuild_all()` on existing rollups | | Generated functions with the lock went from 0 to 2 |
| `rollup_backfill` on a damaged database | 70 parents wrong, then 0 | |

**Not tested:**

- `min`, `max` and `avg` under concurrency, so the `max` example above comes from reasoning.
- A self-referencing tree under concurrency.
- Many small writers on one busy parent, where the extra lock would show most.
- The fix as a real migration, or the extension build from it.
