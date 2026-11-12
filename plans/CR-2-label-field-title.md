# CR 2: Set the label field's title when the entity is created

## Summary

To get the label title you want, pass it in the same call that creates the
entity: `create_entity` / `POST /entities` takes the new column
`label_column_label`, e.g.
`{"table_name": "offers", "label_column": "offer_number", "label_column_label": "Offer #"}`.
The label field is created with that title, so no `update_field` step follows.
`fields.title` stays the source, and `entities.label_column_label` is a copy
kept in step both ways. If the caller leaves it out, the default is the column
in words without the entity's singular or plural (`company_name` on companies
-> "Name", `region_description` on regions -> "Description"); a column ending
in `_number`, `_no`, `_id` or `_code` keeps the entity word ("Offer Number").

## Problem

`create_entity` always titles the label field "Name". A caller cannot pass a
title in the same call, so every entity whose label is not a name needs its
own `update_field` call afterward (`update_field` applies one `data` to every
id it names). For a record identified by a number, "Name" is wrong.

## Seen in

One agent run on tests.semantius.ai (2026-11-12): 3 of the 5 label fields still
read "Name" after the build: `job_applications.application_number`,
`interviews.interview_number` and `offers.offer_number`.

## Why the label field reads "Name" today

When the label column is the record's own name, naming the entity again is
redundant: on companies, `company_name` is titled "Name", just as a phone
field there is "Phone" and not "Company Phone". That reasoning still holds,
and section 2 applies it to every label column: the entity word is dropped,
the rest stays. What fails today is the constant: every label field gets
"Name", whatever its column says.

## Change

### 1. `entities.label_column_label`: the label title, settable on create

- New column `label_column_label TEXT NOT NULL DEFAULT ''` on `entities`. A
  caller passes it in `POST /entities` / `create_entity`, and can change it
  later with `update_entity`.
- **`fields.title` stays the source of truth.** The column is a copy that the
  dictionary keeps equal to the label field's title, in the same way
  `entities.searchable` follows the label field (`update_table_searchable_flag`):
  - Insert: the label field row is created with this title. When the caller
    leaves the column empty, the default from section 2 is filled in BEFORE
    INSERT, so creating an entity adds no extra `entities` UPDATE.
  - Update of the column: it writes `fields.title` of the label row.
  - A title changed on the field (`update_field`, `.jsonc`): it is copied
    back into the column.
  - `label_column` pointed at another column: the copy is reread from the new
    label row.
  - Both directions skip a write when the value is unchanged (`IS DISTINCT
    FROM`). A no-op `entities` UPDATE still fires its whole trigger stack,
    and the round trip must end after one step.
- **Both paths that create the label row** use it: `create_dd_table`
  (`0160_dd_functions.sql`, the core field INSERT) and the managed false ->
  true backfill (`0180_managed_enable.sql`).
- **is_a / has_a:** they have no label row of their own; the label is the
  root's. The column is taken from the root and refused as input when it
  differs, as `label_column` and `label_parent` are (90242). A change on the
  root is carried down the family.
- **`managed: false`:** no label row exists at insert, so the value waits for
  the managed false -> true backfill. `.jsonc` entities of this kind declare
  their label field explicitly anyway.
- **`ensure_entities`** picks the key up automatically. It refuses:
  - an empty `label_column_label`, as it does an empty `singular`;
  - a document whose `label_column_label` differs from its label field's
    `title`. The two would be written back and forth on every apply.

### 2. Better default when the caller gives none

The default never repeats the entity. A leading entity singular or plural is
dropped from the column, and the rest is the title in words
(`snake_to_label`). The only exception is a column ending in `_number`,
`_no`, `_id` or `_code`: it keeps its entity word, because "Number" or "Id"
alone says nothing.

| label column on entity | default title |
|---|---|
| `company_name` on `companies`, `product_name` on `products` | Name |
| `region_description` on `regions` | Description |
| `name`, `label`, `title` | Name, Label, Title |
| `last_name` on `employees`, `company_name` on `customers` (no entity prefix) | Last Name, Company Name |
| `city` on `cities` (nothing left after the prefix) | City |
| `offer_number`, `ticket_no`, `invoice_id`, `product_code` on their entity (exception) | Offer Number, Ticket No, Invoice Id, Product Code |

- **Entity prefix:** the column starts with `<p>_`, where `<p>` is
  `table_name`, `singular`, or `table_name` with `ies` -> `y`, `es` or `s`
  removed. The longest match wins. The plural forms are matched because
  `singular` is derived naively (`addresses` -> `addresse`) or supplied as
  free text.
- **No other special cases:** junctions and computed labels get "Label" like
  any `label` column.
- The rule lives in one function, built on `snake_to_label`. Both creation
  paths reach it through the BEFORE INSERT default.

### 2b. Default `singular_label` comes from the entity, not the label column

`set_entity_defaults` derives an omitted `singular_label` from `label_column`.
That gives the entity `offers`, labeled by `offer_number`, the singular label
"Offer Number". The same field-versus-entity confusion, on the entity side.

- Derive it from `singular` instead (`offers` -> "Offer"). A naively derived
  singular can still be wrong (`addresses` -> "Addresse"), but callers usually
  pass `singular_label`.
- With that, nothing in `set_entity_defaults` depends on the inherited
  `label_column`: an is_a / has_a entity gets its title from
  `check_entity_family`, and `set_entity_defaults` skips it. The comment that
  ordered the two triggers is removed.

### 3. Migration layout

0.5.0 is still developed in place (RELEASE.md: the highest version is
mutable), so the column goes into the existing bootstrap files. No new
`.once` file is needed:
- **`0130_dd_schema.once.sql`:** the column in `CREATE TABLE entities`.
- **`0150_dd_bootstrap.once.sql`:** its `fields` row, with a `field_order`
  that matches the column's physical position.
- **The default and the copy triggers** go beside their siblings: the default
  in `set_entity_defaults` (0220), the copy from `fields` next to
  `update_table_searchable_flag` (0160).

The column exists before any entity is created, so `create_dd_table` and the
managed-enable backfill read `NEW.label_column_label` directly, and no
existing entity needs a backfill.

A database that already ran these `.once` files never runs them again. That
covers tests.semantius.ai and local dev databases. There the column is
missing, and every entity create fails until the database is reinstalled
(`dropall --confirm`, then `migrate`). See decision C.

### 4. Comments

Short, and only what the code cannot say: the redundancy reason and the
`_number` / `_no` / `_id` / `_code` exception at the default function, the
`IS DISTINCT FROM` reason at the copy triggers. No references to documents,
no history. The stale headers of `0220_entity_insert_defaults.sql` and
`apps/test/tests/0430_test_entity_defaults.sql` both say the title is seeded
from `singular_label`. Rewrite them to describe the code.

### 5. Shipped entities

Every database is installed fresh (section 3), so fresh and upgraded
databases can't diverge. The shipped `_core` and nwind label fields simply
get the section 2 default. These 13 change from today's "Name":

| entity.field | module | section 2 default |
|---|---|---|
| `queue_table_events.event_name` | core | Event Name |
| `webhook_receivers.label` | core | Label |
| `webhook_receiver_logs.label` | core | Label |
| `dashboards.label` | core | Label |
| `user_bookmarks.title` | core | Title |
| `customers.company_name` | nwind | Company Name |
| `suppliers.company_name` | nwind | Company Name |
| `shippers.company_name` | nwind | Company Name |
| `regions.region_description` | nwind | Description |
| `territories.territory_description` | nwind | Description |
| `orders.label` | nwind | Label |
| `order_details.label` | nwind | Label |
| `employee_territories.label` | nwind | Label |

The shipped `.jsonc` files follow the convention, so none of the 13 gets an
override.

Explicit label titles already in the `.jsonc` files must match the
convention too. All do except one:
- `raci_events.record_id` (`0350_raci.jsonc`) sets "Record", and the
  convention gives "Record Id". Its explicit `title` is removed.
- These already equal the default and stay: `processes.name`,
  `raci_assignments.name`, `process_gates.name`, `employees.last_name`,
  `audit_record_logs.table_name`, `audit_ddl_logs.command_tag`.

For the remaining shipped label fields, section 2 gives "Name", as today:
`queues.queue_name`, `categories.category_name`, `products.product_name`.

### 6. Texts that say "always Name"

- `C:\dev\postgrest-mcp\src\tools\schemas\entitySchema.ts:12`: add
  `label_column_label` with its description, and correct the
  `singular_label` text, which says it is derived from `label_column`. Also `SKILL.md:147` and
  `generated/instructions.ts:148`, then re-vendor into semantius-cli.
- use-semantius is not changed.

## Not affected

- The default only fills an empty `label_column_label` on insert. It never
  rewrites a title.
- Renaming the label column keeps the title.
- The title stays writable through `update_field` and through `update_entity`.
- Junctions do have a label row. It follows the same rules.

## Acceptance criteria

1. `create_entity` with `label_column: "offer_number"` and
   `label_column_label: "Offer #"` gives `read_field` title "Offer #" in one
   call, and `read_entity` shows the same value.
2. Without `label_column_label`:
   - `offer_number` on `offers` -> "Offer Number"
   - `company_name` on `companies` -> "Name"
   - `region_description` on `regions` -> "Description"
   - `company_name` on `customers` -> "Company Name"
   - `name`, `label`, `title` -> "Name", "Label", "Title"
   - `city` on `cities` -> "City"
   - an omitted `singular_label` on `offers` -> "Offer"
3. `update_field` on the label title changes `entities.label_column_label`.
   `update_entity` on `label_column_label` changes `fields.title`.
4. An is_a / has_a entity shows its root's value and refuses a different one.
5. A fresh install passes the full test sequence, and `schema.md` shows the
   section 5 titles.

## Tests

- **`0430_test_entity_defaults.sql`:**
  - Unit tests of the default function, one per row of the section 2 table,
    including the naive-singular cases.
  - Create with an explicit `label_column_label`.
  - The existing lines 59-63 and 78 move to the new defaults. Lines 38 and 58
    move to the `singular_label` derived from `singular` (section 2b).
  - Update `plan(23)`.
- **Copy rules:**
  - field -> entity
  - entity -> field
  - unchanged value: no write
  - `label_column` repointed
  - label column renamed: the title stays
- **`0440_test_managed_flag.sql`:** managed false -> true uses the column,
  or the default when it is empty.
- **Family:** inherited from the root, a different value refused, a change on
  the root carried down.
- **`ensure_entities`:** a label field `title` in a document wins, and the
  copy follows. No test pins this today.

## Build

`deno task extension 0.5.0-beta1` (the build and `versions.json`) and
`deno task docgen` (`schema.md`), committed with the migrations. Then the full
sequence from AGENTS.md: `connect`, `dropall --confirm`,
`migrate --apps _core,nwind,test --verbose`, `test`.

## Decisions open

- **C.** Reinstall tests.semantius.ai and the local dev databases when this
  lands? Without a reinstall, entity creation fails there (section 3).

## After it ships

postgrest-mcp is deployed after the database has the column, and semantius-cli
re-vendors it with `bun run sync-mcp-tools` from postgrest-mcp's committed
HEAD. use-semantius is not changed.
