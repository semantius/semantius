# Data model: state and roadmap

**Status:** 2026-09-27.

This page is a data-modelling audit of platforms for internal systems: Semantius,
Salesforce Platform, ServiceNow, Directus and SmartSuite. It does three things:
- describes where the Semantius data model stands, including the `is_a` and `has_a`
  key types;
- compares it with the other four platforms;
- lists the gaps that still separate it from the most comprehensive of them, in the
  order in which to close them.

## Where the model stands

**Implemented:**

- **Tables and keys.** Every entity has a single-column key. The key types are
  `auto_increment`, `bigint`, `text`, `uuid` and `typeid`, and `is_a` and `has_a`
  below. A plain entity is one PostgreSQL table.
- **Relationships.**
  - `reference`: the referenced record has its own lifecycle; delete is restrict or clear.
  - `parent`: composition; delete cascades.
  - Many-to-many relationships go through junction entities.
- **Enforced by the database:**
  - foreign keys and CHECK constraints;
  - row-level security per entity: view and edit permission, plus an optional
    JsonLogic `select_rule`;
  - computed fields and validation rules in JsonLogic.

  All of these run inside PostgreSQL, so no API client can bypass them.
- **The model is data.** Entities and fields drive:
  - the DDL;
  - the PostgREST API;
  - `get_schema`;
  - the generated UI.

  Agents build and change models through the MCP server.

**`is_a` and `has_a`:**

- **`is_a`:** subtypes that share the root's key (class-table inheritance), and can be nested.
  - Every record is exactly one type, named by its TypeID prefix: an email of
    `activities` > `emails` has an `eml_` id.
  - A write through any level is carried down to the record's own type, so every
    level's rules and permissions apply.
- **`has_a`:** optional 0..1 extensions of a `typeid` base that share its key, such as
  the customer and supplier roles of a business partner. Removing an extension
  detaches it; the base record stays.
- **Storage:** the entity name is a `security_invoker` view over the base chain and a
  physical `<entity>_ext` table.

## Comparison

**Legend:** ✓ supported, ~ partly or by convention, ✗ not supported, – not applicable.

| Data-model capability | Semantius | Salesforce | ServiceNow | Directus | SmartSuite |
|---|---|---|---|---|---|
| Integrity enforced in the database (foreign keys, constraints) | ✓ PostgreSQL | ✓ proprietary | ~ enforced by the application | ✓ native SQL | ~ |
| Inheritance (is_a) | ✓ normalized, rules per level | ✗ record types only | ✓ table extension, usually one wide base table with a class column | ✗ | ✗ |
| 1:1 role extensions (has_a) | ✓ | ~ person accounts only | ✗ | ~ one-to-one through a unique reference | ✗ |
| Row-level permissions | ✓ RLS in the database, cannot be bypassed | ✓ application level | ✓ application level | ✓ application level | ~ |
| Field-level permissions | ✗ | ✓ | ✓ | ✓ | ~ |
| Roll-up fields, rules across several records | ✗ | ✓ roll-up summary | ~ business rules | ~ flows | ✓ |
| References to any table | ~ within one is_a tree only | ~ standard fields only (WhoId, WhatId) | ✓ document ID | ✓ many-to-any | ✗ |
| Per-subtype overrides of inherited fields | ✗ | – | ✓ dictionary overrides | – | – |
| Human-readable numbers (INC0010001) | ✗ TypeID only | ✓ auto number | ✓ | ✗ | ✓ |

### Verdict

**Cleanest: yes.**

Semantius is the only one of the five that combines three things:
- a normalized relational model;
- integrity and row-level security enforced by the database itself;
- real inheritance and role extensions.

The others each have only part of this:
- ServiceNow comes closest on inheritance, but stores a hierarchy as one wide table
  and enforces integrity in the application.
- Salesforce has no inheritance for custom objects.
- Directus is clean SQL without inheritance.
- SmartSuite does not enforce referential integrity.

On top of that, the model is data that agents build through MCP, and no rule can be
bypassed through the API.

**Most comprehensive: not yet.** The capabilities marked ✗ above are what a migration
from these platforms would miss first. The roadmap below closes them.

## Roadmap

In the order in which to close the gaps:

1. **Field-level permissions.** Applications built on Salesforce and ServiceNow rely
   heavily on hiding or protecting individual fields. Today Semantius grants access per
   entity and per row only.
2. **Roll-up fields and rules across several records.** Examples: header totals summed
   from line items, or a journal entry whose lines must balance. Today, computed fields
   and validation rules see one record at a time.
3. **References to any entity.** A reference whose target can be a record of several
   unrelated entities, as with ServiceNow's document ID or Directus' many-to-any. Used
   for "regarding" links and document flow. With `is_a` this works only inside one
   inheritance tree.
4. **Human-readable numbers per entity**, such as INC0010001 or RE-2026-0001, alongside
   the TypeID key.
5. **Composite uniqueness,** such as customer plus company code. Today it needs a
   computed helper field with `unique_value`.
6. **Per-subtype overrides of inherited fields,** such as a different default, or a
   field required only for emails.

With `is_a`, `has_a` and these six items, Semantius would have both the most
comprehensive and the cleanest data model of the five platforms.
