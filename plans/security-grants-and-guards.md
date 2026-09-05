# Security grants and guards: S5, S6, S7, S8, S9, S10, S11, Q7

Owner of those eight rows in `plans/pg_semantius-open-items.md`. Written
2026-09-05 for a fresh session, then reviewed the same day by an independent
agent against the source and the live catalog; three sections were wrong on
the first pass (S11, S8, Q7) and are corrected below, with the review's
findings kept where they change the work. Nothing here is decided yet: every
section ends with a question, because the project rule is that nothing
touching a trust boundary is decided by an agent alone. Answer the questions
in this file, in place, and the executing session works from the answers.

Facts below were checked on 2026-09-05 against the migrations, the tests, the
live `appdb` catalog on `postgres18-cli`, and the sibling repositories under
`C:\dev`. Re-check anything that looks stale before acting on it.

## One mechanism the whole plan rests on

`0010_create_core.sql:52-59` tries to revoke PUBLIC EXECUTE by default with
per-schema `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE FROM PUBLIC`. **That is
a no-op**: there is no `pg_default_acl` entry for functions in `public` or
`common` on the live database, and the functions this plan names are
PUBLIC-executable today. Only explicit per-function `REVOKE EXECUTE ... FROM
PUBLIC` works in this tree, which is why S6 and S11 exist at all. Every fix
below uses explicit revokes; none relies on default privileges.

## Order of work

Three changes, not one. Each lands with its pinning test and both harnesses
green (`pgdocker/pg-cli-retest.sh`, `pgdocker/pg-ext-retest.sh`), and each
gets its own dated section in `plans/ext-solved-items.md`.

1. **The mechanical six**: S5, S6, S9, S10, S11 and Q7. Every one is a
   `REVOKE`, a `SECURITY DEFINER` flip on a trigger function, or a
   self-or-admin guard, and every one is pinned by extending an existing guard
   test (`0060_test_security.sql`, `0240_test_no_unsafe_functions.sql`). One
   change.
2. **S7**, the API-key primitive. Its own change: it is an authentication
   function and the wrong choice is expensive.
3. **S8**, the first-user bootstrap. Its own change: it is a race, it
   invalidates an existing test, and its pin cannot live in pgTAP.

## Change 1: the mechanical six

### S5, audit tables writable by the request role

The tables live in `public`, not `audit`: `public.audit_record_logs` and
`public.audit_ddl_logs` (`0150:801-802`; a REVOKE against `audit.*` fails
with "relation does not exist"). They have INSERT policies `WITH CHECK
(true)` (`0150:813`, `:828`, the only two such policies in the tree) and the
live ACL for `semantius_user` is `arwd`: SELECT, INSERT and DELETE granted
explicitly at `0150:836-837`, UPDATE arriving through the default privileges
in `0290:154`. The writers are **five** `SECURITY DEFINER` functions, not
three: the four DML trigger functions at `0150:227`, `:302`, `:345`, `:388`
and `log_ddl_event` at `:573`. Nothing legitimate inserts as the request role.

**DELETE is designed, not dead.** It is gated by admin-only USING policies
(`0150:815-818`, `:830-833`) and exercised by `0300_test_audit_log.sql:120`,
`:226`, `:312` while authenticated as user3. Revoking it removes an admin
capability and breaks 0300. The first draft of this plan revoked it; do not.

- Fix: `REVOKE INSERT, UPDATE ON public.audit_record_logs,
  public.audit_ddl_logs FROM semantius_user`; drop the two INSERT policies.
  UPDATE is dead today only because no policy exists for it; revoke it so a
  future policy cannot resurrect the hole. Keep DELETE and its policies.
- Pin: user1 `INSERT` raises 42501; the definer triggers still write (the
  audit tests cover that already); 0300's admin deletes still pass.
- Question: keep the admin DELETE on audit rows? The tests say it is
  intended. If the answer is no, that is a separate decision with its own row,
  since it changes a documented admin capability. [ ]

### S6, `common.cache_*` definers executable by PUBLIC

Five `SECURITY DEFINER` functions with no `rbac.uid()`, PUBLIC-executable on
the live catalog, contradicting the header comment in
`0012_create_cache.sql`. `common.update_updated_at_column()` has the same
grant; harmless, but inconsistent. **No migration outside 0012 calls them**,
and `0130_test_cache.sql` runs as the installer, so nothing depends on the
grant.

- Fix: explicit `REVOKE EXECUTE ... FROM PUBLIC` on all six.
- Extending guard test 0060 to `common` and `audit`: **only its test 2.2**
  (the PUBLIC-EXECUTE check) can be widened as-is. Test 2.1 would flag
  `common._cache` (RLS enabled, no policies, `0012:24`, by design) and test
  2.3 would flag every definer there that legitimately has no `rbac.uid()`
  (`cache_*`, `refresh_schema_cache`, `audit.enable_tracking`). Widen 2.2,
  leave 2.1 and 2.3 scoped, and say so in the test.
- Pin: `has_function_privilege('semantius_user', 'common.cache_get(text)',
  'EXECUTE')` is false; 0060 green with 2.2 widened.
- Question: does any app tier call `common.cache_*`? The schema is not
  exposed by PostgREST, and nothing in `packages/` or `apps/` does. Confirm,
  then revoke. [ ]

### S9, reading another user's permissions

`rbac.user_has_permission(p_external_id, ...)` and
`rbac.get_user_permissions(p_external_id)` accept any target and are granted
to `semantius_user`. Internal callers pass the caller's own id, with one
exception listed under "Same class, not in the rows" below.

- Fix: allow `p_external_id = rbac.uid()`, otherwise require `admin`,
  mirroring `list_api_keys`.
- Pin: user1 calling `get_user_permissions('user3')` raises; user1 for user1
  still works; user3 (admin) for user1 works.
- Question: raise, or return empty? The row allows either. Raising is the
  consistent choice with `list_api_keys`. [ ]

### S10, upserting any user

`rbac.upsert_user_from_jwt` is granted to `semantius_user` and takes any
`external_id`. Its only in-database caller is `get_userinfo()`
(`0080:60`, replaced in `0190:95`), which is a definer, so the call keeps
working after a revoke.

- Fix: revoke from `semantius_user` and PUBLIC. No guard inside the function
  is needed.
- Pin: user1 calling it directly raises 42501; `get_userinfo()` still
  provisions a new principal.
- Question: is it called directly by any app tier? Repeat
  `grep -r upsert_user_from_jwt` over `C:\dev\semantius-cloud` and
  `C:\dev\oauth-hono-mcp` before acting. [ ]

### S11, schema-reload spam (corrected after review)

`common.refresh_schema_cache()` is **already** `SECURITY DEFINER SET
search_path = public, common` (`0090:35`). The first draft of this plan
proposed making it the definer and revoking it from the request role; that
changes nothing and then **breaks entity and field writes**, because the two
DML trigger functions that call it, `notify_pgrst_tables` (`0090:44-52`) and
`notify_pgrst_fields` (`:70-80`), are SECURITY INVOKER, fire as the request
role, and would hit 42501 on the `PERFORM`. The two event-trigger callers
(`:126`, `:158`) are not affected: they run as whoever executed the DDL, which
is the owner (definer dictionary code) or the installer, since
`semantius_user` has no CREATE on `public`.

- Fix: make `notify_pgrst_tables` and `notify_pgrst_fields` `SECURITY
  DEFINER` with `search_path` pinned (they contain no caller-controlled SQL),
  then revoke `refresh_schema_cache` from `semantius_user` **and from PUBLIC**,
  where it is executable today. Drop the grant and its comment at `0090:183`.
- Pin: unauthenticated call raises; an `entities` insert still emits the
  NOTIFY (`pg-ext-lifecycle.sh` step 11 probes this).
- Question: revoke outright, as above, or throttle and keep it callable? There
  is no caller outside the triggers. [ ]

### Q7, the vendored pgmq functions (corrected after review)

All 75 `pgmq.*` functions are PUBLIC-executable, none pins `search_path`, none
is `SECURITY DEFINER`, all are owned by `semantius_owner`. The request role
cannot read the queue tables, so what is exposed is information:
`list_queues`, `metrics_all`, `list_topic_bindings`. `SECURITY.md:92-95`
**documents that exposure as intended behaviour**, so closing it is a
documented-behaviour change, not only a hardening. The vendored file stays
byte-identical to upstream v1.11.1 (decision of 2026-09-05), so the fix lives
outside it. Semantius's own `queue_*` wrappers in `0170_queue.sql` are
`SECURITY DEFINER` (`:70`, `:89`, `:110`) and need no PUBLIC grant; the tests
call `pgmq.*` only as the installer.

Three options, smallest first:

- A. `REVOKE USAGE ON SCHEMA pgmq FROM semantius_user` (`0170:59`; the
  comment there, "needed for RPC wrappers", is wrong, the wrappers are
  definers). One line, closes everything the request role can reach.
- B. A migration after 0160 that revokes PUBLIC on every `pgmq.*` function.
- C. B plus `ALTER FUNCTION ... SET search_path = pgmq, pg_catalog` on each,
  which also closes the linter's 75 warnings. 23 of the functions are
  `LANGUAGE sql`; a `SET` clause disables inlining for those, which is
  negligible here.

Whatever is chosen, two things the first draft missed:

- The pin "0240 covers pgmq" means removing `pgmq` from the **search_path
  exclusion only** (`0240_test_no_unsafe_functions.sql:30`), not from the
  COMMENT exclusion at `:64`: none of the 75 functions has a comment, and
  that check would fail 75 times.
- The next vendor bump re-runs `CREATE OR REPLACE`, which drops any
  `proconfig` set from outside and re-grants PUBLIC on new functions. The
  widened 0240 and 0060 are what catch that; say so in the migration header.
- Update `SECURITY.md:92-95` in the same change.

- Question: A, B or C? A is one line and reversible; C is the only one that
  also makes the linter row go away. [ ]

## Change 2: S7, `public.validate_api_key(text)`

Granted to `semantius_user` although its header says it must not be
(`0110:122` says one thing, `:174` and `:177` do the other). No `rbac.uid()`.
Runs bcrypt at cost 10 and a definer UPDATE of `last_used_at`. The `key_id`
lookup returns before `crypt()` (`0110:158-163`), so timing distinguishes
known from unknown key ids. It is the single hard-coded exception in guard
test 0060 (lines 60 to 61 and 95).

Facts: **no caller exists** in this repository outside the migration that
defines it, none in `semantius-cloud`, `semantius-site`, `oauth-hono-mcp`,
`postgrest-mcp` or `saaszilla` (grep 2026-09-05), and the API-key tests
already `RESET ROLE` before calling it with the comment "not granted to
semantius_user" (`0260_test_apikeys.sql:153`, `:163`). The tests assume
option A.

- Fix A: revoke from `semantius_user` and PUBLIC; delete the 0060 exception.
  Internal auth primitive, callable only by definer code.
- Fix B: keep it callable, require `rbac.uid()` so only an authenticated
  session can probe keys, and make the miss path constant-time.
- Pin: `has_function_privilege('semantius_user',
  'public.validate_api_key(text)', 'EXECUTE')` is false (A), or an
  unauthenticated call raises (B).
- Question: who is supposed to call it? If "the PostgREST pre-request hook"
  or "the app tier", B; if "nothing yet", A. Everything in the tree says A.
  [ ]

## Change 3: S8, first-user bootstrap (corrected after review)

`0050_rbac_rls.sql:294-298`: Administrator (role 2) is granted when
`NEW.last_seen IS NOT NULL` and no other user has `last_seen`. Pre-provisioned
users who never logged in keep `last_seen` NULL, so the next new principal
becomes admin. The comment at `:289-293` already admits the second hole: two
concurrent first logins can both qualify.

Two facts the first draft missed:

- **The test seed depends on this trigger.** `apps/test/migrations/0030_seed.sql:16-19`
  inserts user3 *with* `last_seen` set and no explicit `user_roles` row; its
  Administrator role comes from this bootstrap at seed time. And
  `0110_test_first_user_get_userinfo.sql` clears `last_seen` on all three
  seeded users and expects a brand-new principal to become admin. Any fix
  that closes S8 as stated invalidates that test and must replace it, and the
  seed should grant user3's role explicitly so it stops depending on a
  security trigger.
- **A marker written by the trigger does not close S8.** Seeded users with
  `last_seen` NULL never enter the bootstrap branch, so no marker is ever
  written and the next principal still takes it. A marker only works if the
  seed sets it, which moves the problem to every installer.

The gate the file's own comment points at is simpler: **"no user holds role 2
yet"**, checked under `pg_advisory_xact_lock` in the trigger. It survives
seeded users (user3 holds role 2, so nobody else qualifies), needs no marker,
and the lock alone closes the race: under READ COMMITTED the waiter
re-snapshots after the first transaction commits and sees the role row.

- Fix: replace the `last_seen` test with "no `user_roles` row for role 2
  exists", under `pg_advisory_xact_lock` on a fixed key, keeping the `NEW.last_seen
  IS NOT NULL` clause so a seed of never-seen users still does not elect one.
  Use a key of its own: `hashtext('migrate')` and `hashtext('pgmq.queue_...')`
  are already taken (`0160:117`, extension script). Verified against the
  seed: `0030_seed.sql:16-19` inserts user3 last, with `last_seen` set, and
  no role-2 row exists before it (the only seeded `user_roles` row is
  1002/northwind at `:33-34`), so user3 still bootstraps.
- Two things the gate does not change, to be stated in the migration header:
  `rbac.prevent_user_role_deletion` guards only role 1 (`0050:329-345`), so
  deleting the last admin is possible and the re-bootstrap question below is
  real; and an admin holding `user:manage` can INSERT a user row through the
  API (`0050:74-78`), and a row inserted with `last_seen` set while no admin
  exists would be elected. Acceptable, since it takes an admin or an empty
  cluster to reach, but it should be written down.
- Pin, in pgTAP: seed one user with `last_seen` NULL and no admin, provision a
  new principal through `get_userinfo()`, assert it becomes admin; provision a
  second, assert it does not; with an existing admin, assert a new principal
  never does. Rewrite 0110 to this shape.
- Pin, concurrency: **cannot live in pgTAP**, which is a single session with
  no `dblink` in the tree. The only facility is
  `pgdocker/pg-ext-lifecycle.sh:157-170`, which already runs a second
  `psql` via `docker exec -d`. Add a step there: two sessions provisioning
  concurrently, exactly one admin.
- Question: is "re-bootstrapping" a cluster (an admin deletes the last admin
  and wants the next login to take it) a case to support? With the role-2
  gate it works by construction and needs no reset path; with a marker it
  needs one. If you want the marker anyway, say why. [ ]

## Same class, not in the rows

Found by the review; each is the S9/S10 shape and should be fixed in change 1
or given its own row, not left implicit:

- `rbac.validate_oauth_scopes(p_external_id, ...)` (`0030:860-883`):
  `SECURITY DEFINER`, granted to `semantius_user` on the live catalog,
  arbitrary target, no in-database caller. Applying the S9 guard inside
  `get_user_permissions` makes it raise for non-self targets, which is fine
  only if nothing calls it that way; revoke it or guard it explicitly.
- `rbac.get_user_by_external_id` (`0030:245`): user enumeration by the
  request role.
- `rbac.validate_permission_exists`: definer, granted, no `rbac.uid()`.
  Harmless on its own; inconsistent.

## Not in this plan

S17 (default privileges on future tables in `public`) is a policy decision
with no code attached until it is made; it stays unowned. S12 belongs to the
bearer-mode work in `docs/bearer-mode-status.md`. S14 is Info.
