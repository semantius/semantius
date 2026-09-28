# Families: test coverage for adding, changing and removing bases and children

Goal: pin with pgTAP every way an is_a / has_a family changes. This covers
adding, changing or removing a base (root or middle level) or a child: its
entity row, its fields, its records, its rules and permissions, and the
module that installs it. Each change must reach every level: views, `<t>_ext`
columns, generated routines, triggers, `_label` functions and `get_schema`.

Writing this plan turned up six bugs, B1-B6, all reproduced in rolled-back
scratch tests on Neon. Two reviewer agents checked the plan against the code
and against the user's requests. Their findings are included here. The user
decided every open question on 2026-09-28 (see Decisions).

The work runs tests first: the tests are written and run before any fix, so
every bug has a test that is seen to fail (see Order of work).

## Status (2026-09-28, afternoon)

**Steps 1-5 are done. Open: the Neon rebuild (needs the user's OK), the
commit (only when the user asks), then Step 6.** Nothing is committed beyond
the user's `63de58a wip` (the Step 1 tests).

Step 2 (first run on Neon, before any fix): 0436 311/353, 0490 66/76. Every
failure matched an expected item, and every item had a failing test:
- D1 (root `label_column`): 5 in 0436 PART 2, 1 in 0490 (v3)
- D2 (90253): 4 in PART 3
- B3/D4 (90254, 90255): 3 in PART 4
- `is_child`: 4 in PART 4
- B2 (`select_rule` after a base rename): 5 in PART 5
- B1/D3 (has_a write skips the is_a levels): 3 in PART 6
- B6/D6 (90256): 18 in PART 11
- B4 (installer and a child's label settings): 1 in 0490 (v4)
- B5/D5 (record order): 8 in 0490

Three test mistakes were fixed in 0436 (no code bug behind any of them):
- the `is_child` fixture had records, and a `parent` field (NOT NULL
  DEFAULT 0) cannot be added to a table with rows: `fc_build` takes
  `p_records => FALSE`
- `pgmq.read` as `user3` is denied: the queue counts run as the owner, as in
  0840
- a RESTRICT violation is 23001 on PG18 and 23503 before: `throws_like` on
  the message, as 0550 does

Step 3: fixes 1-9 as in the table below. Differences from the plan text:
- D1: descendants whose `label_column` differs from the new value are set,
  not only those with the old value, which also repairs a family the old bug
  left drifted.
- 90255 is raised wherever `dd_dispatch_case` is used (the root's dispatch
  and a supertype view's trigger), and by the has_a routing of fix 9; the
  part check is `common.is_a_part_missing`, SECURITY DEFINER, TRUE only for a
  record whose root row exists and a part is missing.
- 90256: `dd_check_family_dependents` walks `pg_depend` from the family views
  through generated objects only; it runs first in `dd_refresh_family`, and
  before the CASCADE drops of `delete_dd_field`, `update_search_vector_column`
  and `delete_dd_table`.

Step 4: fresh install on pgdocker PG18 (Path A): full suite 3201 passing, 0
failing; `lint-sql`: no unexpected skip, no finding in a new or changed
function, no new override needed. Neon (migrate only, PG17): 0436 349/353,
0490 76/76, 0435 173/173; the 4 red tests are the 90253 ones, because the
rule is in a `.once` file Neon ran before. They turn green only after
`deno task retest --confirm` on Neon, which wipes it.

Step 5: `docs/error-contract.md` (90253-90256), `AGENTS.md`, the 0435 header,
`docs/model-state-and-roadmap.md`, `schema.md` (from the Path A database),
`extension/CHANGES.md` and the build (`extension --check` is current), and
postgrest-mcp `src/SKILL.md` with its generated `instructions.ts`
(uncommitted in that repository). The deferred item in
`plans/2026-09-27-1909-is-a-has-a.md` (`:424`) is done; record it when both
plans are closed.

How 0436 is built (the `pg_temp` helpers at the top of the file):
- `fc_build(prefix, id stem [, key column])` builds the standard family and
  its records. Each fixture has its own name prefix (`fc1_`, `fc4n_`, ...) and
  its own TypeID stem (`fca`, `fcdn`, ...).
- `fc_checks(step, prefix)` / `fc_checks_on(step, root, org, bank, person,
  vendor, old name)` return the 7 checks after each change: one assertion
  per numbered check.
- `sqlstate_of` / `hint_of` run a statement and always roll it back; a
  statement that succeeds gives `00000`.
- `value_of` / `fc_write` return a value, or `ERROR <sqlstate>` instead of
  aborting.
- `fc_snapshot(root)` is an md5 over the family's view definitions,
  generated routine bodies and triggers.

Changes from the Tests section below:
- **PART 11 has four more 90256 cases:** a root field delete, a searchable
  change on the root, a root prefix change, and rules added to a middle
  level. D6 names all of these as changes that rebuild a family.
- **user1 is not used:** no test needed read denial.

Found while writing the tests, for fix 8 (D6):
- A field delete (`delete_dd_field`: `DROP COLUMN ... CASCADE`) and a
  searchable change (`update_search_vector_column`: `DROP COLUMN
  search_vector CASCADE`) take the family views, and anything built on them,
  down before `dd_refresh_family` runs. The check therefore has to come
  before those drops too, not only before the view drops in
  `dd_refresh_family`.
- A module delete has the same issue when the cascade reaches the root row
  first: `delete_dd_table` then runs `DROP TABLE <root> CASCADE`, which takes
  the family's views and their dependents with it. PART 11 tests the module
  case.

## What exists today

`0435_test_entity_id_types.sql` (173 tests):

- **PART 10**, is_a, is a three-level chain (`fam_activities` > `fam_emails`
  > `fam_classified`, sibling `fam_tasks`). It covers:
  - writes, rules and deletes through every level
  - a root prefix change (`:781`)
  - a rename of the middle entity, with a sweep for leftover names (`:858`)
  - the delete checks 90247/90248
  - a module delete of the whole family (`:878-896`)

  It changes no fields on this chain.
- **PART 11** is one has_a level (`fam_partners` > `fam_customers` /
  `fam_suppliers`). It covers:
  - a base field add reaching the extension
  - the extension's own field changes
  - searchable toggles
  - a base label field rename
  - attach, detach, 90251 and 90252

Family cases also exist in:
- 0600 (row security, PART 3: permission per level)
- 0620, 0650 (rules), 0670 (labels), 0700 (`get_schema`), 0720 (search)
- 0800 (the DDL audit marker)
- 0840 (queue, PART 3: 90249)
- 0850 (RACI)

`0490_test_ensure_entities.sql` PART 3 creates an is_a family from a file,
with records, and checks that a second apply writes nothing.

## Findings

### What works (probes, rolled back)

- **Root field `title` / `description`:** reaches the view comments of every
  level and the `get_schema` titles.
- **Root `singular_label` / `plural_label`:** stays on the root.
- **Root label field rename:** `label_column` of every descendant follows, and
  writes through the grandchild and through the root work.
- **Delete refusals:**
  - middle is_a with a child: 90248
  - has_a with records: 90247
  - a base whose only dependents are has_a entities: 90248
- **Drops in dependency order (has_a, grandchild, middle, root):** each one
  removes its generated objects. After the last subtype goes, the root's
  dispatch trigger and dispatch function are gone. The former root then drops
  like a plain entity, with its records.

### Bugs (reproduced)

- **B1: a write through a has_a view skips the is_a levels (security).**
  - Setup: a vendor extension is attached to a bank record.
  - `UPDATE vendors SET city = ...` updates the root row directly, at trigger
    depth 2. The root's dispatch acts only at depth 1
    (`0160_dd_functions.sql:3002-3014`, `:3342`).
  - The rules and edit permissions of the is_a levels are skipped.
    Reproduced: a subtype computed field stayed `T:A` after `city` became `B`.
  - A caller with edit permission on vendors and parties, but not on banks,
    can change a bank's root fields this way.
- **B2: renaming a base breaks reads of a child that has a `select_rule`.**
  - `select_rule_<child>` has the name of its **direct** base written into it
    (`0210_computed_validation.sql:630-632`).
  - Renaming that base cascades only `id_refentity`, and
    `manage_select_rule_policy` (`0210:742-748`) does not react to that.
  - Every read of the child by a non-admin then fails with
    `42P01 relation "public.<old base>" does not exist`.
  - Affected: a has_a entity or a direct is_a child when the root is renamed;
    a grandchild when the middle level is renamed.
- **B3: an update or delete of a record is silently skipped when a subtype
  takes a prefix the root gave up.**
  - Steps: the root changes its prefix `pca` → `pcb`, then a new subtype is
    created with `pca`. Only current prefixes are unique (`0130:131-135`).
  - The root's old `pca_` rows are now dispatched to the subtype, which has
    no part for them, and the dispatch returns NULL (`0160:3208-3211`).
  - `UPDATE` and `DELETE` through the root report success and change nothing.
- **B4: `ensure_entities` is not idempotent for a derived entity's
  `label_column`.**
  - A file value that differs from the root's is silently replaced on the
    first apply (`0160:2573`).
  - The second apply of the same file UPDATEs it and fails with 90242.
- **B5: `ensure_entities` fails when a root's records include subtype rows**
  (an export of a root table contains them).
  - Root records are written first, and a root row with a subtype id is
    refused by `typeid_assign` with 90237, even when the file also lists it
    under the subtype.
  - A has_a record attached to a subtype id fails the same way when it is
    written before the subtype's records.
- **B6: any family rebuild silently drops objects built on a family view.**
  - `dd_refresh_family` drops the views with `DROP VIEW ... CASCADE`
    (`0160:3454`), on every field change, even an add.
  - Reproduced: a hand-made view over a child's view disappeared, with no
    error, after a root field add.
  - On a plain entity, a field add never touches the views built on it.

### Other behavior found by the probes

- **Direct root `label_column` change**
  (`UPDATE entities SET label_column = ...`):
  - The root accepts it, and the descendants keep the old value.
  - From then on, every write to a descendant's `entities` row fails with
    90242, including the rows a root rename or a root searchable change
    writes.
  - `ensure_entities` reaches this path too: `label_column` is not create-only
    (`0290:256`).
- **`id_column` change:** accepted on every entity, plain ones included. No
  DDL runs, and the next field add fails with
  `42703 column "<new>" does not exist`. `ensure_entities` already treats
  `id_column` as create-only.
- **`is_child`** looks only at the entity's own fields (`0160:2428`), while
  `searchable` follows the family. A root with a `parent` field leaves its
  descendants' `is_child` FALSE, so the app lists subtypes in the navigation
  while it hides their root.

## Decisions (by the user, 2026-09-28)

**D1: a direct `label_column` change on a root with dependents propagates.**
- A new AFTER UPDATE trigger on `entities`
  (`WHEN OLD.label_column IS DISTINCT FROM NEW.label_column`) sets the
  `label_column` of every descendant that still has the old value. The label
  functions are rebuilt by the existing triggers.
- The second statement in the label rename of `0170_dd_rename.sql:420-432`
  becomes redundant and is removed.
- A plain entity keeps its current behavior.

**D2: `id_column` is write-once for every entity.**
- A platform rule next to 90233 in the seeded entities row
  (`0150_dd_bootstrap.once.sql:41`), code **90253**: "id_column is set when an
  entity is created and cannot be changed".
- It uses the same `value_changed` / `$old` form as 90233, so an update that
  writes the same value passes.

**D3 (B1): a has_a write routes base changes to the record's own type.**
- When an update through a has_a view changes base fields of a record whose
  key carries an is_a subtype prefix, the has_a write routine hands the base
  update to that subtype's `record_write_*`, as the root's dispatch does.
- The rules and edit permissions of every is_a level then apply, and a record
  the caller cannot write whole is skipped.
- A plain root record is written as today.

**D4 (B3): both guards.**
- Creating an is_a entity whose prefix appears on existing rows of its root is
  refused, code **90254**. It is a one-time scan of the root at creation, by
  `common.typeid_prefix(<key>)`, in `check_entity_family`.
- The root's dispatch raises, code **90255**, when a root row carries a
  subtype prefix but the subtype has no part for it.
  - The part check runs as the definer on the `_ext` table.
  - A record the caller merely cannot see still skips, as today: a NULL
    result, no error.
- The `0130:131-134` comment ("another entity may take it") is updated.

**D5 (B5): `ensure_entities` writes records from the deepest is_a level up,
then has_a.**
- The order among a family's entities that have records in the file:
  1. is_a entities, deepest level first
  2. then their bases, up to the root
  3. then the has_a entities
- The root's rows for subtype ids then already exist: the root's pass skips
  them on insert and updates them through the dispatch. A has_a record
  attaches to a record that exists.
- The reference ordering still applies on top. A record that references a
  record of its own base in the same file forms a cycle, and fails with the
  existing "reference each other" error (22023).

**D6 (B6): a rebuild refuses when non-generated objects depend on a family
view.**
- Before dropping any view, `dd_refresh_family` looks up (`pg_depend` /
  `pg_rewrite`) the objects that depend on the family's views.
- Objects the dictionary generates don't count:
  - the family's own views
  - `view_write` triggers
  - `record_write_*`
  - `_label` / `<fk>_label`
  - `select_rule_*`
- If any other object is found, the change is refused with code **90256**,
  and its HINT lists the objects. The admin drops them, makes the change and
  recreates them. Nothing is dropped silently.
- This covers every change that rebuilds a family: field changes, renames, a
  prefix change, rules added or removed, and a family entity's delete (which
  rebuilds its base's family).
- **Deleting an is_a or has_a entity is refused the same way** (user
  decision) while non-generated objects depend on its own view.
  `delete_dd_table` checks this before its `DROP VIEW ... CASCADE`
  (`0160:1881`). This is stricter than a plain entity, whose delete still
  drops what depends on its table.

**B2 fix: rebuild on rename.** `manage_select_rule_policy`
(`0210:742-748`) also rebuilds when `id_refentity` changes. Only a base rename
can change it, through the foreign key's ON UPDATE CASCADE. Nothing is looked
up at read time.

**B4 fix:** `ensure_entities` ignores `label_column` and `label_parent` of
is_a and has_a entities, as creating one directly does
(`check_entity_family`). Reinstalling the same file always works.

**`is_child` follows the family**, like `searchable`.
- A descendant is a child when it, or any level above it, has a `parent`
  field. The app then hides subtypes from the navigation together with their
  root.
- A root field changed to or from format `parent`, added or deleted, updates
  the descendants.

**Queue mapping on a root with subtypes: keep, and pin it in a test.**
- The root's queue reports changes to root rows only.
- Inserting or deleting a subtype record sends a root message.
- An update of only subtype fields sends none.

Error codes: 90253-90256 are unused today.

## Tests

### Conventions for the new tests

- `BEGIN; SELECT plan(N); ... ROLLBACK;` with an exact count.
- Every PART after the first starts with `RESET ROLE;` and
  `SET LOCAL search_path TO public, pgtap;`, and sets up **its own fixture**
  (AGENTS.md). No PART depends on another PART's state. A refusal that does
  not exist yet (90253-90256) succeeds today, and in a shared fixture it
  would change the state for every later PART.
- **Fixture helper:** at the top of the file, a `pg_temp` function builds the
  standard family under a given name prefix and id prefix. Each PART calls it
  with its own prefix (`fc1_`, `fc2_`, ...).
- **Refusal helper:** a `pg_temp` function takes a statement and returns the
  SQLSTATE it raised.
  - It runs the statement in a block that always ends by raising a sentinel
    error, so the statement's effects are rolled back even when it succeeds.
  - Refusals are asserted with
    `is(pg_temp.sqlstate_of($$...$$), '90253', ...)`.
  - Where a test needs a refused change to have had no effect, this helper
    replaces `throws_ok`.
- **Test users:**
  - `user3` (admin) for DDL and positive controls
  - `user2` for mixed permissions: it holds `nwind:view` and
    `nwind:manage`, not `admin` (the 0600 PART 3 pattern)
  - `user1` holds neither, for read denial
- Test descriptions and comments describe behavior. They never carry the
  B1-B6 / D1-D6 ids; the mapping from tests to those ids is part of the Step 2
  report, not of the file.

### Standard fixture (built per PART by the helper; shown for prefix `fch_`)

```
fch_parties       typeid  (label, city)       view public:read  edit nwind:manage
  fch_orgs        is_a    (vat)               view nwind:view   edit nwind:manage
    fch_banks     is_a    (bic, tag)          view nwind:view   edit admin
  fch_persons     is_a    (birth)             view nwind:view   edit nwind:manage
  fch_vendors     has_a   (terms)             view nwind:view   edit nwind:manage
```

- `fch_banks.tag` is a computed field, `"T:" + city`. It proves that a root
  change reached the bank's level, through the dispatch or through the D3
  routing.
- There is one record at each level, plus a vendor extension attached to a
  bank record, so has_a and is_a share a base record.
- There are four views; the root is a table.

### Checks after each change (a `pg_temp` helper returning assertions)

1. **Existence:**
   - the four views
   - `record_write_*` and `view_write_*` for each, plus the `view_write`
     trigger on each view
   - `is_a_dispatch_<root>` and the `a_is_a_dispatch` trigger
   - `a_ext_write_guard` on every `_ext`, `a_has_a_guard` on the root
   - `_label(<view>)` for each view
   - checked with `to_regclass`, `to_regprocedure` and `pg_trigger`
2. **Columns:** the view column list, with base fields first.
3. **Writes:** an update through each level's view, read back.
4. **Dispatch:** an update of the bank record's `city` through the root and
   through `fch_orgs` (the `view_write` CASE branch, `0160:3280-3294`). Read
   back `city` **and** `tag`: `tag` only follows if the dispatch ran.
5. **Trigger arguments:**
   - `typeid_assign(key, root prefix, subtype prefixes)`
   - `pk_immutable(key)` on the root and every `_ext`
   - `a_has_a_guard(key, extensions)`
6. **No old names:** after a rename, no old name in the bodies of
   `view_write_*`, `is_a_dispatch_<root>`, `record_write_*`, `_label` /
   `<fk>_label` and `select_rule_*`. `record_rules_*` is left out: its body
   comes from the rules JSON. Check 1 has already shown that each routine
   exists, so an absent routine cannot pass this check.
7. **Readable:** every view answers `SELECT ... LIMIT 0`.

### New file `apps/test/tests/0436_test_entity_family_changes.sql`

**PART 1: root and middle field changes** (the checks after each change)
- **Add a root field:** in all four views; writable via `fch_banks`.
- **Rename a root field** (not the label).
- **Default change on a root field:** set on the root table and copied to
  every view (`pg_attrdef`). An insert through `fch_banks` that omits it gets
  the default.
- **Description or `title` change:** reaches the column comments
  (`col_description`) of every view.
- **Delete a root field:** gone from every view; the views are valid.
- **Format change, same type** (text → email): allowed, and the column
  comments of every view are refreshed (`0160:727`).
- **Format change, different type** (text → int32): 90223
  (`0170:551-563`); views and routines unchanged.
- **Root reference field:**
  - Adding one creates `public.<fk>_label(public.fch_banks)`, a function,
    not a column. Check it with `to_regprocedure` and a call.
  - Changing `reference_table` repoints it.
  - Deleting the field removes it.
- **Delete modes on root fields** (90249 guards only an is_a entity's own
  fields):
  - `cascade` or `parent` on the root: deleting the referenced record fails
    with 23503 for a bank record, and with 90251 for a record with a vendor
  - `clear` nulls the root column
  - `UPDATE fields SET reference_delete_mode = 'cascade'` on an is_a field:
    90249 (0435 tests only the insert)
  - a has_a field with `cascade` only detaches the extension
- **`unique_value` on a root field:** an insert through `fch_persons` that
  repeats a bank's value fails with 23505.
- **Field-name uniqueness across the family (90243), on the rename path**
  (`0160:2669`):
  - renaming a root field to a name `fch_banks` uses: 90243
  - renaming a `fch_banks` field to a root field's name: 90243
  - a sibling (`fch_persons`) may reuse a `fch_banks` field name
  - a sibling's field changes leave `fch_orgs` and `fch_banks` untouched
- **Middle level (`fch_orgs`) field add, rename or delete:** reaches
  `fch_banks`, but not `fch_persons` or `fch_vendors`.
- **Searchable on the root:** every level gets a `search_vector`; a search
  through `fch_banks` finds text stored in the root.
- **`get_schema('fch_banks')`** shows a root field's new title, with
  `inherited_from = fch_parties`.

**PART 2: the root's label**
- **Root label field rename across three levels:**
  - the descendants' `label_column` and the view columns follow
  - writes through the grandchild and through the root work
  - renaming it back leaves no trace of the intermediate name
- **Direct `label_column` change on the root** (propagates):
  - every descendant's `label_column` follows
  - `_label(fch_banks)`, and the `<fk>_label` of a plain entity referencing
    `fch_banks`, return the new column's value
  - `get_schema` shows it in `table.label_column`, and in
    `reference_table_label_column` of that referencing field (`0250:247`)
  - a later root rename, a later root searchable change, and a child created
    afterwards all succeed (each fails with 90242 today)
- **A descendant's own `label_column` / `label_parent` change:** 90242, on
  the child and on the grandchild.
- **Root `label_parent` on a spine parent:** the descendants' `_label` shows
  the composed label.

**PART 3: the key column**
- **`UPDATE entities SET id_column`:** 90253 on a root, an is_a entity, a
  has_a entity and a plain entity. Use the refusal helper, so that today's
  accepted change is rolled back.
  - An update that writes the same value passes.
  - Afterwards the id field row and the physical key are unchanged, and a
    field add still works.
- **A root created with a key column other than `id`:** the descendants
  inherit it, and their views, routines and writes use it. Every fixture
  today uses `id`.

**PART 4: entity-level changes**
- **Root labels:** a root `singular_label` / `plural_label` / `description`
  change reaches the root's table comment and its `get_schema`. The
  descendants' view comments and `get_schema` labels stay their own.
- **A derived entity's own `plural_label` / `description`:** reaches its view
  comment (`0160:1047`).
- **Root rename:**
  - the children's `id_refentity` follows
  - `is_a_dispatch_<old>` is gone and rebuilt under the new name
    (`0170:241`)
  - no trace of the old name remains (the 0435 sweep query), and the checks
    after each change pass
- **Rename of a has_a entity:** `a_has_a_guard` on the base carries the new
  name (`0160:3486-3498`). Deleting a base record with a vendor still raises
  90251, not 42P01.
- **Root prefix change after a has_a exists:**
  `INSERT INTO fch_vendors (label)` mints the new prefix (`0160:3127`, rebuilt
  by `dd_sync_typeid_prefix`), and a supplied id with the old prefix raises
  90237.
- **A new is_a under `fch_orgs`, which already has records and a child:**
  - `typeid_assign` accepts the new prefix
  - the dispatch and the `fch_orgs` CASE branch route to it
  - existing records are untouched, and the checks after each change pass
- **Prefix reuse:**
  - The root changes its prefix `a` → `b`, and a new subtype then claims `a`:
    90254 (refusal helper), and the root's old `a_` rows stay reachable
    (update and delete through the root work).
  - A prefix that no root row carries can still be claimed.
- **A root row with a subtype prefix but no part:**
  - An update or delete of it through the root raises 90255.
  - Setup: as the owner (`RESET ROLE`), disable `a_ext_write_guard` on
    `fch_banks_ext`, delete a part row, enable the guard again, then
    `authenticate_as('user3')`.
  - Use a bank record with no vendor and no reference to it.
- **A subtype record that `user2` cannot see** (in this PART's fixture,
  `fch_banks` has view permission `admin`): an update through the root skips
  it silently, with no 90255. Positive control: `user3` updates it.
- **Root `order_column` with descendants:** allowed. The column is absent
  from the views, and an insert through `fch_banks` gets an order value
  (`0230:90-133`).
- **`is_child` follows the family:**
  - adding a root `parent` field sets it on every descendant
  - deleting that field, or changing its format away from `parent`, clears it
  - a `parent` field on `fch_orgs` sets it on `fch_orgs` and `fch_banks`
    only
  - a descendant created under a root that is already a child is created
    with it

**PART 5: rules and permissions**
- **Rules added to `fch_orgs` after `fch_banks` exists** (`0210:131`): the
  rule is enforced through `fch_banks` and through the root. After the rules
  are cleared (`0210:371`), `record_rules_fch_orgs` is gone and writes still
  work (no 42883).
- **`view_permission` of `fch_orgs` changed to `admin`:** for `user2`,
  `fch_banks` returns 0 rows and `get_schema('fch_banks')` raises
  `undefined_table` (`0160:186`). `user3` still reads them.
- **`select_rule` on the root:** filters every descendant view and the
  writes dispatched from the root.
- **A child's `select_rule` after its base is renamed:**
  - `select_rule`s on `fch_orgs` and `fch_vendors`, then a root rename:
    `user2` can still read both, and their `select_rule_*` name the new root
  - a `select_rule` on `fch_banks`, then a rename of `fch_orgs`: the same
    for `fch_banks`
- **Queue mapping on the root** (kept as is):
  - inserting a bank record sends one root message
  - an update of only `bic` sends none
  - an update of `city` sends one
  - a delete sends one
  - mapping `fch_banks` itself raises 90249

**PART 6: is_a and has_a on one base record**
- Reading `fch_vendors` shows the root fields.
- An attach that sends a root value different from the stored one: 90246.
- A root field change reaches `fch_vendors` and `fch_banks` in the same
  statement.
- **A root field changed through `fch_vendors`, on the bank record:**
  - `UPDATE fch_vendors SET city` recomputes `fch_banks.tag`
  - a `fch_orgs` validation rule on `city` refuses a bad value with that
    rule's code
  - `user2` (edit on parties, orgs and vendors, not banks): the record is
    skipped, and neither the root nor the vendor part changes. Positive
    control: `user3` succeeds.
  - a vendor attached to a plain root record (no subtype) still writes the
    base fields directly, as 0435 PART 11 expects
  - a change of only `terms` does not touch the subtype levels
- **Deleting the bank through `fch_banks` and through `fch_parties`:** 90251
  while the extension exists. After the vendor detaches, the delete runs the
  delete rules of `fch_orgs` and `fch_banks`, and the root's own
  `compute_validate` trigger.

**PART 7: records**
- **Root default change, then an attach through `fch_vendors` that omits the
  field:** no 90246. The attach check has the default expression written
  into it (`0160:3052-3060`).

**PART 8: references from other entities**
- **A plain entity referencing `fch_banks`:**
  - its `<fk>_label` still resolves after a family rebuild, which drops
    `_label(fch_banks)` with the view (`0160:3454`)
  - after a rename of `fch_banks`, the foreign key targets the new `_ext`
    and `<fk>_label` is rebuilt (`0180:904-909`)
- **`cascade` and `clear` on a reference to `fch_banks`:** deleting a bank
  through the root runs them.

**PART 9: rebuild order and refusals**
- After each change in PARTs 1-4, the checks show every object present and
  every view readable: no view was left dropped.
- A refused change leaves every view, routine and trigger exactly as before.
  Compare `md5` over the view definitions, `prosrc` and `pg_get_triggerdef`
  before and after:
  - a 90243 clash between the root and `fch_banks`
  - a 90256 refusal (PART 11)

  Both are raised before any DDL. PostgreSQL rolls back a failure inside the
  rebuild together with the statement.
- `audit_ddl_logs`: a family rebuild adds no rows beyond the field change's
  own (the 0800 marker tests, on three levels).

**PART 10: dropping family entities**

Refusals, each asserting that nothing was dropped:
- middle is_a (`fch_orgs`, child `fch_banks`): 90248, also when every level
  is empty
- an empty root with dependents: 90248
- has_a with records: 90247
- a base whose only dependents are has_a entities (a separate typeid base):
  90248
- the root with records and both kinds of dependents: 90248 comes before
  90247
- **a family across two modules** (root in module A, child in module B):
  deleting module A raises 90248 (`0160:1838`); deleting B, then A, succeeds

Drops, in dependency order (a second has_a, `fch_clients`, is added to this
PART's fixture):
- **Empty `fch_clients`, not the last extension:** its view, `_ext` and
  routines are gone. `a_has_a_guard` is rebuilt with `fch_vendors` only, and
  a base record with a vendor still raises 90251.
- **Empty `fch_vendors`, the last extension:** `a_has_a_guard` is gone, and a
  base record can be deleted again.
- **Empty `fch_banks`:** `fch_orgs` is rebuilt without it; writes through
  `fch_orgs` and the root work.
- **`fch_orgs`, once it has no child:** the root's `typeid_assign` drops its
  prefixes.
- **`fch_persons`, the last subtype:** afterwards the root's
  `a_is_a_dispatch` trigger and `common.is_a_dispatch_<root>()` are gone, and
  the root is writable as a plain typeid entity.
- **The root:** it drops like a plain entity, with its records. No name of it
  remains in `pg_class`, `pg_proc` (`proname` and `prosrc`), `pg_trigger` or
  `pg_policy`.

**PART 11: objects built on family views**
- A hand-made view over `fch_banks` (created as the owner after
  `RESET ROLE`). Each of these raises 90256, and the HINT names the view:
  - a root field add
  - a `fch_orgs` field change
  - a root rename

  Nothing changes (PART 9's comparison), and the view still exists.
- The same for a view over `fch_orgs` when `fch_banks` is deleted: that
  delete rebuilds the `fch_orgs` family.
- After the view is dropped, the same changes succeed.
- Generated objects don't count. The following don't block any change:
  - the `<fk>_label` of a plain entity referencing `fch_banks`
  - the family's own views and routines
  - a `select_rule`
- A view over the root **table** is not affected by a root field add, as for
  a plain entity.
- Deleting `fch_banks` (empty) while a view depends on `fch_banks` itself:
  90256 naming the view, and `fch_banks` still exists. After the view is
  dropped, the delete succeeds.
- A module delete of a family whose views have a hand-made dependent: 90256
  as well.

### New PART 4 in `apps/test/tests/0490_test_ensure_entities.sql`

- **v2 of a family file**, applied to a root that has records:
  - it adds an is_a child and a has_a; the new entities work and the existing
    records are untouched
  - it adds a root field, which reaches the existing children
- **The root's `label_column` changed in the v2 file, with the descendants
  still carrying the old one, as an export made before would:** the change
  propagates to the descendants, and a second apply writes nothing. This
  tests the propagation and the installer ignoring a child's label settings
  together.
- **A derived entity whose `label_column` in the file differs from the
  root's:** two applies both succeed, and the second writes nothing.
- **Records, deepest is_a first, then the base, then has_a:**
  - Root records that include a subtype id, with the same record also listed
    under the subtype: the import succeeds, and the record is whole (root,
    `_ext` and the subtype's own fields). A second apply writes nothing.
  - A root-only field value given in the root's copy of the record wins, as
    the later write.
  - **The mixed case:** a has_a record attached to a subtype id, with the
    has_a entity listed before the subtype in the file. The import succeeds,
    and the vendor is attached to the bank record.
  - A subtype id listed only under the root still fails with 90237.
  - A subtype record that references a record of its base in the same file
    fails with 22023.

## Order of work: tests first, then fixes

A test that has never failed does not show that it catches its bug. So the
tests are written against the decided behavior before any fix. The first run
also separates the two kinds of work: tests that pass at once are coverage
that was missing, and tests that fail are the items that need a fix.

Nothing is committed unless the user asks. A commit that changes migrations
must include the regenerated extension build (`deno task extension
0.5.0-beta1`), which CI (`test.yml`) checks.

### Step 1: write the tests, change no code

- Write 0436 (PARTs 1-11) and 0490 PART 4 as specified, using the decided
  codes (90253-90256) and behavior.
- Every assertion that can fail today must report instead of aborting the
  file:
  - the statement under test goes in `lives_ok`, the refusal helper, or a
    checked result
  - a later assertion must not depend on an object a failing statement did
    not create: guard it with `to_regclass` / `to_regprocedure`
- Each PART has its own fixture (see Conventions), so a refusal that succeeds
  today cannot change another PART's state.
- Exact `plan(N)` counts.
- The new tests stay uncommitted while they are red.

### Step 2: run and report, change no code

- `deno task migrate` on Neon first, so the database matches the working
  tree (the is_a/has_a work, committed as `fa0a92e`). Already done on
  2026-09-28, see Status.
- Run `deno task test "0436*"` and `"0490*"`.
- Report every test as passing or failing. For each failing test, give the
  item it belongs to (B1-B6, D1-D6, `is_child`) and its actual result
  (have/want or error code).
- Each failure must match an expected item, and each expected item must
  have at least one failing test:
  - a failure that matches no expected item is a new finding, and goes to the
    user before any fix
  - an expected item with no failing test has a test that does not reproduce
    the bug, and that test is rewritten until it does

### Step 3: fix one item at a time

The smallest changes first, the generators last.

| # | Item | Where |
|---|------|-------|
| 1 | `id_column` write-once, 90253 | `0150_dd_bootstrap.once.sql:41` (rule next to 90233) |
| 2 | installer ignores a child's label settings | `0290_ensure_entities.sql` |
| 3 | `select_rule_*` rebuilt after a base rename | `0210_computed_validation.sql` (`manage_select_rule_policy`) |
| 4 | root `label_column` propagation | `0160_dd_functions.sql` (new AFTER UPDATE trigger on `entities`); remove the second statement in `0170_dd_rename.sql:420-432` |
| 5 | `is_child` follows the family | `0160_dd_functions.sql` (`update_table_is_child_flag`, and its callers for descendants) |
| 6 | prefix reuse: 90254 at creation, 90255 in the dispatch | `0160_dd_functions.sql` (`check_entity_family`, the dispatch generator); comment at `0130:131-134` |
| 7 | install order: deepest is_a first, then the base, then has_a | `0290_ensure_entities.sql` (the record loop at `:780-805`) |
| 8 | rebuild and entity delete refuse non-generated dependents, 90256 | `0160_dd_functions.sql` (`dd_refresh_family` before the drops, `delete_dd_table` before its `DROP VIEW` and before a root's `DROP TABLE`, `delete_dd_field` and `update_search_vector_column` before their `DROP COLUMN ... CASCADE`; see Status) |
| 9 | has_a base writes routed to the subtype | `0160_dd_functions.sql` (the has_a `record_write_*` generator) |

After each fix:
- `deno task migrate` on Neon, then run 0436, 0490 and 0435
- that item's tests turn green, and no green test turns red
- the 0435 PART 11 has_a update test passes unchanged
- new codes go into `docs/error-contract.md` with the fix that raises them

Fix 1 edits a `.once` file, and migrate does not run a `.once` file again.
Version 0.5.0 (currently built as 0.5.0-beta1) is developed in place
(`RELEASE.md`), as the is_a/has_a work already did.
- Its tests stay red on Neon until the database is rebuilt with
  `deno task retest --confirm` (dropall + migrate + tests).
- That **wipes the Neon test database, including data created there by hand
  in the app**. Ask the user before running it.
- Meanwhile fix 1 is verified on pgdocker PG18 (Path A), which installs
  fresh.

### Step 4: full verification

- Full suite on Neon (after the user's OK to rebuild it) and on pgdocker
  PG18 (Path A).
- `deno task lint-sql` on pgdocker. No new unexpected skips; a new generated
  trigger function gets an `OVERRIDES` entry if it needs one.

### Step 5: docs and build

- `docs/error-contract.md`: 90253-90256, checked against the code.
- `AGENTS.md`: the family checks range (90240-90256), and 90253 next to
  90233.
- The 0435 header points to 0436 for dictionary changes on families.
- `docs/model-state-and-roadmap.md`, and `schema.md` (regenerated).
- `extension/CHANGES.md`, and the build (`deno task extension 0.5.0-beta1`).
- postgrest-mcp `SKILL.md` (and its generated instructions):
  - an `id_column` that cannot change
  - has_a writes that run the subtype's rules
  - a subtype prefix that cannot be reused
  - views built on a family view that block changes (90256)
- `plans/2026-09-27-1909-is-a-has-a.md` lists "`ensure_entities` ordering of
  is_a records" as deferred (`:424`). That item is done here. Record that
  when both plans are closed.

### Step 6

Delete this plan once the work has landed.
