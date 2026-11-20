# Error contract

**Status:** draft, 2026-09-08. Every error that can reach a client through
PostgREST follows this contract. The rules come first; the numbers
themselves are the tables at the end of the page.

## Why

A client that wants to show an error in the user's language needs two things
the raw PostgreSQL error does not give it: a stable identity to look a
translation up by, and the values that belong in the sentence, separate from
the sentence. A plain English message has the values baked in
(`Permission denied: dd:write required`), and the SQLSTATE alone lumps
unrelated situations together (42501 alone would cover a missing token, a
wrong audience, a missing permission and a locked system field) and is one
PostgreSQL raises itself for its own reasons (42501 is also a row-level
security refusal). Nothing of that can be localized without parsing English.

## What the client receives

PostgREST returns exactly four fields of a PostgreSQL error and nothing else:

```json
{ "code": "90210", "message": "...", "details": "...", "hint": "..." }
```

`code` is the SQLSTATE. There is no fifth field, so the constraint name, the
column name and the table name that PostgreSQL attaches to its own errors do
not travel; only what fits into these four does.

## Two classes of our own

PostgreSQL's SQLSTATE space is shared. Every standard class is PostgreSQL's,
and class 42 alone holds about thirty of its codes, several of which reach
clients straight from PostgreSQL. We therefore invent no code in a standard
class, reuse two standard codes where REST statuses require them (42501 and
42P01, see "HTTP status") and one, 23514, where the dictionary refuses a field
change in PostgreSQL's own words (see "Constraint names"), and put every
identity of our own in two classes PostgreSQL leaves empty:

- **Class 90 is Semantius.** Every error our own code raises for a client,
  except the 42P01 of the schema reads and the 23514 of a field change, has a
  `90xxx` catalog number, and the number is the identity: one row in the
  catalog, one translation on the client. Most sites raise the number as their
  ERRCODE. The families whose HTTP status carries REST meaning raise a standard
  code instead and carry the number as `hint.code`, see "HTTP status".
- **Class 99 is custom.** Errors a rule author raises, from `throw_error` or
  from a failing validation rule, carry a `99xxx` code minted by that author.
  A validation rule that core itself ships, marked `"source_module":
  "platform"` in `0150_dd_bootstrap.once.sql` or in a core `.jsonc` entity
  definition,
  is not custom: it fails with a class 90 catalog code like every other error
  of ours. The split between the two classes is a naming convention that
  keeps admin-minted numbers clear of the catalog's, not a trust boundary:
  the marker is an ordinary JSON key that a dictionary administrator can
  write, and nothing guards it at runtime, because that administrator already
  writes the rule, its message and its logic.

Both use digits only. PL/pgSQL accepts any five uppercase alphanumerics as an
ERRCODE; a handler catches a whole class with `WHEN SQLSTATE '90000'` or
`WHEN SQLSTATE '99000'`.

### Class 90 layout

Blocks of one hundred, one per domain, so a code says where it comes from:

| Block | Domain |
|---|---|
| 900xx | authentication and JWT claims |
| 901xx | permissions, roles, lockout guards |
| 902xx | data dictionary: entities and fields |
| 903xx | schema and record RPCs |
| 904xx | api keys |
| 905xx | queues and topics |
| 906xx | audit |
| 907xx | modules and slugs |
| 908xx | RACI |
| 909xx | JsonLogic runtime and rule definitions |

A code may be raised from more than one site; every site uses the catalog's
message template verbatim.

The 900xx, 901xx and 903xx blocks are wire-bearing: their refusals travel as
42501 or 42P01 and carry the number in `hint.code`; a number in them that is
no refusal is raised as itself, see "HTTP status". A validation rule raises its
code as the SQLSTATE itself, so a platform rule must not take a number from
those three blocks (the check at save time accepts any `90xxx` code) - it
takes one from a block whose wire is the number, and that is why the
dictionary's own immutability rules are 902xx rather than 901xx.

### Class 99

`99000` to `99999`, chosen by the author of the rule. `99000` is what
`throw_error` raises when no code is given. Two entities can use the same code
for different things, so a client keys class 99 translations by entity and
code, not by code alone; the error carries the entity as `hint.entity`, see
"The generated trigger". A module is a rule author like any other, so the
validation rules and `throw_error` codes of a custom module use class 99.

### HTTP status

PostgREST derives the HTTP status from the SQLSTATE: a handful of standard
codes get a specific status and every code it does not know gets 400. A REST
consumer reads 401, 403 and 404 as "who are you", "you may not" and "no such
thing", and would read 400 as a malformed request, so those three statuses
are kept:

| Family | Wire SQLSTATE | PostgREST status | Identity |
|---|---|---|---|
| 900xx authentication, 901xx permissions | 42501 insufficient_privilege | 401 for an anonymous request, 403 with a token | `hint.code` |
| 903xx unknown entity or table | 42P01 undefined_table | 404 | none: the block has no numbers, and the schema reads raise 42P01 without a hint |
| every other 90xxx code | the number itself | 400 | `code` |
| 99xxx | the number itself | 400 | `code`, scoped by entity |

The first row is about refusals. A number in the 900xx or 901xx blocks that is
not one - an internal invariant failing inside `get_userinfo`, an argument
guard - is raised as itself and answers 400, because 403 would send a client to
re-authenticate over something authentication cannot fix. The **Wire** column of
each row settles which it is.

42501 and 42P01 are the only standard codes we raise for their HTTP status;
the one other standard code our code raises for a client is the 23514 of a
field change, see "Constraint names". Every 42501 we raise for a client
carries a `hint.code` from the 900xx or 901xx block. No 42P01 we raise
carries one: `get_schema`, `get_schemas` and `build_schema_for_table` raise
`Table "<name>" not found in entities` without a hint, and the 903xx block has
no numbers. PostgreSQL raises the same two codes itself, for a row-level
security refusal, a missing grant or a missing relation, and its errors carry
no `hint.code` either. So the `hint.code` tells a 42501 of ours from
PostgreSQL's, and a 42P01 carries none either way.

The 404 is also the existence-hiding answer: `get_schema`, `get_schemas` and
`build_schema_for_table` answer 42P01 both for a table that does not exist and
for one the caller may not see, with exactly the same error, `Table "<name>"
not found in entities`, raised by the same statement, so no field of it, the
context included, says which. The record reads raise no error for either:
`get_record_by_id` returns the same NULL for an entity or record that does not
exist and for one the caller may not read.

PostgREST's own 401 for a missing, expired or invalid token is unaffected: it
rejects those before the database is reached. The mapping is PostgREST's and
can change with its version; re-check it when PostgREST is upgraded.

## The four fields

| Field | Rule |
|---|---|
| SQLSTATE | `99xxx`, a `90xxx` number, or 42501 / 42P01 with the number in `hint.code`, as above. |
| MESSAGE | English template with `${name}` placeholders. Never interpolated on the server, except in the 42P01 of the schema reads, whose message names the table, and in the 23514 of a field change, which copies PostgreSQL's sentence. |
| DETAIL | Optional free-text string with more information. Shown as-is. Absent and empty mean the same thing. |
| HINT | A JSON object of the parameters. Five keys are reserved: `hint`, an optional suggestion template with the same placeholder grammar; `code`, the catalog number when the SQLSTATE is 42501 or 42P01; and `entity`, `rule` and `field`, which the generated validation trigger adds, see "The generated trigger". Required when the message or the hint template contains a placeholder or when `code` is needed; otherwise it may be absent. Absent and empty mean the same thing. |

The suggestion lives inside the JSON because HINT is the only slot left once
the parameters take it, and PostgreSQL's own errors use HINT for exactly that
kind of text; a client applies one rule to both, see "Client rules".

### Parameter values

Every parameter value is a JSON scalar of its native type: a number is a JSON
number, a boolean a JSON boolean, text a JSON string, and an unknown value
`null`. Never an object or an array, and never a number or boolean turned
into a string: `{"min": 3}`, not `{"min": "3"}`. The client formats with ICU,
whose plural and number rules select on the JSON type, so `"3"` would neither
pluralize nor localize. A date or timestamp has no JSON type and travels as
an ISO 8601 string. The reserved keys are strings: `code` is a SQLSTATE, not
a quantity, `hint` is a template, and `entity`, `rule` and `field` are
identifiers.

In PL/pgSQL this means passing the typed value to `jsonb_build_object`,
which maps integer, numeric and boolean to their JSON types by itself, and
never its `::text` or a `format()` result. The tests read the hint as JSON
(`catch_error_hint`), and `0110_test_jsonlogic_ext.sql` asserts the JSON type
of the `throw_error` parameters.

### The raise pattern

A site in a status-bearing family raises the standard code and carries the
catalog number in the hint:

```sql
RAISE EXCEPTION 'Permission denied: ${permission} required'
    USING ERRCODE = 'insufficient_privilege',
          HINT = jsonb_build_object(
              'code',       '90101',
              'hint',       'Ask an administrator to grant ${permission}',
              'permission', p_permission_name
          )::text;
```

which arrives, with HTTP 403, as

```json
{
  "code": "42501",
  "message": "Permission denied: ${permission} required",
  "details": null,
  "hint": "{\"code\": \"90101\", \"hint\": \"Ask an administrator to grant ${permission}\", \"permission\": \"dd:write\"}"
}
```

Every other site raises its number directly and arrives with HTTP 400:

```sql
RAISE EXCEPTION 'Cannot change format of core system field ${field_name}'
    USING ERRCODE = '90219',
          HINT = jsonb_build_object('field_name', OLD.field_name)::text;
```

PostgREST copies the four fields verbatim in both cases; the SQLSTATE only
decides the status.

### Placeholder grammar

A placeholder is `${` followed by a name matching `^[a-z][a-z0-9_]*$` and `}`.
The dollar sign is deliberate. PostgreSQL's own messages contain braces, for
example `invalid input syntax for type integer: "{1,2}"`, and a client fills
native messages as fallbacks with the same routine it uses for ours, so a
bare-brace syntax would misread them. Other braces in a template are literal.
`${` cannot collide with dollar quoting, because a dollar-quote tag has to be
an identifier.

`hint`, `code`, `entity`, `rule` and `field` are reserved and cannot be
parameter names: the last three are merged into the object by the generated
trigger, and a parameter with one of those names would hide the key the
trigger adds, because the merge keeps a key that is already present. Every
placeholder used in the message or in the hint template must be a key of the
JSON object; the reserved keys may be used as placeholders where they are
present.

MESSAGE is RAISE's own format string. A literal percent sign is written `%%`;
a bare `%` makes RAISE fail with "too few parameters" at run time.
The one place where admin-supplied text becomes a message, the generated
validation trigger, passes the text as the argument of a `'%'` format string
instead, so rule authors do not escape anything.

## The catalog

"The numbers" at the end of this page has one row per catalog number with its
wire SQLSTATE (the number itself, 42501 or 42P01), message template, hint
template, parameter names and a one-line description. "Constraint names"
follows it, because a constraint name is the only stable key a PostgreSQL
constraint error carries and a client translating one needs the same list.

Both are maintained by hand, and they are a reference, not a mechanism: they
are where a client's translator reads what a number means, and where the next
person to add an error picks the next free number in the right block. They
live on this page rather than a second one so that the rules and the numbers
cannot drift apart while nobody is looking.

## JsonLogic

### throw_error

```json
{"throw_error": "Order is already shipped"}
{"throw_error": ["Order ${id} is already shipped", "99017", ["id", {"var": "id"}]]}
```

The first form raises `99000`. The second takes the message, the code and the
parameters as a flat list of key, value, key, value. The list is flat because
JsonLogic treats an object with one key as an operator call: `{"id": 3}` would
be evaluated as the operator `id` and fail with "Unrecognized operation". The
values are evaluated, so `{"var": ...}` and any other expression work, and
each keeps the JSON type the evaluation produced, so a numeric column arrives
as a number, see "Parameter values". A code outside class 99, a parameter
with a reserved name, or a value that is an object or an array raises a
909xx error.

### Validation rules

A rule in `entities.validation_rules` is `{"code", "message", "jsonlogic"}`
with an optional `"hint"`. `code` is the SQLSTATE the failure raises: a
99xxx code of the author's choosing, or, when the rule carries
`"source_module": "platform"`, a 90xxx code listed in the catalog, because
those rules are shipped by core and their failures are Semantius errors.
`message` is the MESSAGE; `hint` is the suggestion template placed under the
`hint` key of the JSON hint, next to `entity`, the table name of the entity
the rule belongs to, and `rule`, the rule's code. A rule failure carries no row values: the caller
already holds the row, and copying columns into the hint would be a second
read path around row-level security. A rule that needs parameters in its text
uses `throw_error` inside its logic and names them explicitly. The shape is
checked when a managed entity is saved, or an entity is switched to managed:
a code outside class 99 is rejected then, unless the rule is a platform rule,
whose code must be class 90. That the code is a catalog row is not checked at
save time, because the catalog is a document, not a table.

### The generated trigger

The per-table compute/validate trigger evaluates every rule inside an
exception handler so that a broken rule reports which rule broke, and so
that every class 99 error names the entity that scopes it.

- Class 90 passes through untouched: its identity is the code alone.
- Class 99 carries `entity` (the table name of the entity whose rule was
  evaluating) and `rule` (that rule's code) in the hint object: a failing
  validation rule is raised with them, and a `throw_error` inside a validation
  rule's logic is re-raised with the same SQLSTATE, message and DETAIL and the
  two merged in. A `throw_error` inside a computed field gets `entity` and
  `field` (the computed field name) instead.
- Any other error is re-raised with the original SQLSTATE, message, DETAIL
  and HINT, with `entity` and `rule` (the rule code) or `field` (the computed
  field name) added to the hint object, a hint that was not a JSON object
  being wrapped as `{"hint": text}` first. That path carries both
  PostgreSQL's own errors and our 42501 sites; those keep their `hint.code`
  because the hint object is merged, not replaced.

A write can cascade: a row trigger on one entity writes a second entity
(audit rows, queue events, RACI bookkeeping), whose own compute/validate
trigger may fail. No trigger on the way out adds keys to that error, so
`entity` and `rule` name the innermost entity, the one whose rule actually
failed. `set_record` is not
such a case: it reads a record into the rule's data and writes nothing.

The message is never prefixed, because a prefix is an interpolation. `entity`
is the table identifier, not the label: it is a translation key and must be
stable and language-neutral.

### Runtime errors the evaluator passes through

| Source | SQLSTATE | Note |
|---|---|---|
| `require_permission` | 42501, `hint.code` 901xx | the permission error, as raised by rbac |
| a `select_rule`, or `set_record`, evaluated without claims | 42501, `hint.code` 900xx | `rbac.uid`, called by `jl_request_context` and by `get_record_by_id`; in a computed field or validation rule `$user_id` itself is null instead |
| a `select_rule`, or `set_record`, evaluated for a subject with no enabled `users` row | 42501, `hint.code` 900xx | 90006 from `rbac.ensure_context_initialized`; the client has not called `get_userinfo` yet, or the user is disabled |
| unknown operator | 90910 | `Unrecognized operation: ${op}` |
| `is_match` with a malformed pattern | 2201B | PostgreSQL's own message |
| `/` or `%` with a zero divisor, an arithmetic result of Infinity or NaN, arithmetic over text that carries no number | 90920 | `${operator} has no finite result` |

A comparison never raises on a bad numeric string: `==` and the ordering
operators read a string that carries no number as no number at all, so every
comparison of it with a number is false. Arithmetic over such a string raises
90920. A date operator returns null for a null or empty value, and `to_date`
reads a number as epoch seconds. Any other value that does not have the shape
of an ISO 8601 date or date-time raises 90915; a value of that shape that is
no real date, such as 2026-02-30, raises PostgreSQL's 22008, and one whose
offset is out of range, such as `+99`, raises 22009.

## Errors we do not raise

Foreign key, unique and not-null violations, CHECK constraints on our own
tables, row-level security refusals, the vendored pgmq messages and
PostgREST's own `PGRST` codes carry no JSON hint and English text with values
inside. They localize by SQLSTATE, and where PostgreSQL names the constraint
in the message, by constraint name parsed out of `message`; "Constraint
names" at the end of this page lists the ones that exist. Vendored pgmq text
is upstream text and is never edited.

Two more native errors reach a client from an is_a or has_a entity. An upsert
on its view (`ON CONFLICT`, PostgREST's merge-duplicates and `PUT`) fails with
42P10 when the statement is planned, before any trigger of ours runs; an
entities file imports such records with an insert followed by an update
instead. And PostgreSQL truncates identifiers longer than 63 bytes, which a
generated name can reach; 90273 and 90276 keep the names generated from an
entity or field name (`<entity>_ext_<field>_fkey`, `record_write_<entity>`)
within that limit when an entity or field is created or renamed, or an entity
is switched to managed. 90506 keeps the queue trigger names of a mapping
(`queue_<queue>_<event>_on_<table>`) within 63 bytes when the mapping is
written or moved to another queue and when the mapped table is renamed; a
`queue_` trigger of no current mapping is renamed unchecked.

## Client rules

1. A `hint` that starts with `{` is parsed as a JSON object; if it does not
   parse, it is shown as text. Any other hint is suggestion text, PostgreSQL's own or an install-time error's, and is
   shown as-is, the same way the `hint` key inside the object is.
2. The translation key is `code` when it is class 90 or 99, else `hint.code`
   when present, else the SQLSTATE. Class 99 keys are scoped by
   `hint.entity` when it is present; a `throw_error` evaluated outside a
   trigger, through `evaluate_json_logic` over RPC, carries none and is
   keyed by code alone. A
   code outside classes 90 and 99 with no `hint.code` is PostgreSQL's or
   PostgREST's own error and falls back to a translation of the SQLSTATE
   plus, where present, the constraint name.
3. Fill `${name}` placeholders in the message and hint templates from the
   parsed object. The English templates in the response are the fallbacks when
   no translation exists.
4. HTTP statuses keep their REST meaning: 401 and 403 for authentication and
   permission, 404 for an entity a schema read does not find or may not
   show, 400 for every other refusal.
   Generic middleware may key on them; localization keys on the code.

## Security

Everything in HINT is visible to the caller. A parameter must never carry data
from a row or a column the caller cannot read; `docs/authorization.md` invariant
I1 counts error messages as a read path. Names of things the caller asked for
(the permission, the table, the field) are fine; contents of other rows are
not.

## Exemptions

Errors raised while installing or operating the database are not
client-reachable and keep RAISE's ordinary form and their existing SQLSTATE,
and get no catalog number: the BYPASSRLS check in `0100_rbac_rls.sql`, the
pgmq conflict check in `0310_pgmq.once.sql`, and the preflight and `migrate()`
errors of the extension build in `packages/cli/commands/extension.ts`, most
of which the extension archive's README lists for the operator who hits one,
and the definition errors of `ensure_entities` in `0290_ensure_entities.sql`
(22023 for a malformed `.jsonc` definition, 0A000 for a change that is not
additive), which only a migration reaches.
The administrator lockout guards and the User-role guard in
`0100_rbac_rls.sql` are not exempt: a client reaches them by editing
`user_roles`, `users`, `roles`, `role_permissions` or `permissions`, so they
are 901xx errors like every other refusal.

## The numbers

One row per catalog number. **Wire** is the SQLSTATE the error is raised with:
the number itself for most rows, and 42501 or 42P01 for the families whose
HTTP status carries REST meaning, which carry the number as `hint.code`
instead. **Message** and **Hint** are the templates the server sends, which a
client without a translation shows as they are; **Parameters** are the keys of
the JSON hint that fill their `${name}` placeholders.

### 900xx - authentication and JWT claims

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90001` | `42501` | `Authentication required: No valid JWT claims found` | - | - | No JWT claims reached the database, or they could not be parsed. |
| `90002` | `42501` | `Authentication required: JWT role claim must be authenticated` | - | - | The token's `role` claim is something other than `authenticated` — or it has no `role` claim and no `roles` claim carrying `authenticated` either. |
| `90003` | `42501` | `Authentication required: JWT sub claim is missing` | - | - | The token carries no subject, so there is nobody to be. |
| `90004` | `42501` | `Authentication required: JWT audience claim is missing (expected ${expected})` | - | `expected` | `_settings.jwt_aud` is set and the token has no `aud`. |
| `90005` | `42501` | `Authentication required: JWT audience does not match (expected ${expected}, got ${actual})` | - | `expected`, `actual` | The token was minted for a different audience. |
| `90006` | `42501` | `User not found: ${external_id}. Client must call get_userinfo() on first login to create user record.` | - | `external_id` | The claims are well formed but no enabled `users` row matches: the client has not called `get_userinfo` yet, or the user is disabled. |
| `90007` | `90007` | `external_id cannot be null or empty` | - | - | An argument guard, not a refusal, so it answers 400. |
| `90008` | `90008` | `Failed to create or find user: external_id = ${external_id}` | - | `external_id` | `get_userinfo` upserted the user and got nothing back. |
| `90009` | `42501` | `Authentication required: Microsoft Entra ID token is missing the tid or oid claim` | - | - | The token's `iss` is an Entra issuer, whose user is identified by `entra.<tid>.<oid>`, and one of the two is absent. Falling back to `sub` would create a second identity for the same person. |
| `90011` | `90011` | `Database ${database} must run in UTC with ISO 8601 durations, but this session has time zone ${time_zone} and interval style ${interval_style}. Run ALTER DATABASE ${database} SET timezone = 'UTC' and ALTER DATABASE ${database} SET intervalstyle = 'iso_8601', then reconnect.` | - | `database`, `time_zone`, `interval_style` | `get_userinfo` refuses a session without the database's UTC and ISO 8601 defaults, which a plain logical restore drops. Connections opened before the statements run keep the old values until they reconnect. |
| `90010` | `90010` | `Unexpected error: unable to build user info JSON for user_id = ${user_id}` | - | `user_id` | As 90008, at the end of `get_userinfo`. |
| `90012` | `42501` | `Authentication required: the request context holds no user id` | - | - | `rbac.user_id()` found the cached request context initialized for the caller's subject but without a user id. The context is always written whole, so only a session that writes the `app.*` settings by hand can produce this; it names nobody and is refused like a session without a user. `rbac.user_id_or_null()` answers NULL. |

### 901xx - permissions, roles and lockout guards

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90101` | `42501` | `Permission denied: ${permission} required` | `Ask an administrator to grant ${permission}` | `permission` | `rbac.require_permission`, the refusal every gated call makes. |
| `90102` | `42501` | `Permission denied: one of (${permissions}) required` | - | `permissions` | `rbac.require_any_permission`. The list is one string, not an array: a parameter is a value in a sentence. |
| `90103` | `42501` | `Cannot delete role 1 (User) from user. All users must have the User role.` | - | - | Reachable by editing `user_roles`, so it is a refusal like any other. |
| `90104` | `42501` | `This would leave the system without an enabled Administrator` | `Grant the Administrator role to another enabled user first. A direct connection as a role with BYPASSRLS is exempt from this check.` | - | The lockout guard: a DELETE on `user_roles`, `users` or `roles`, an UPDATE on `user_roles` or an UPDATE of `users.is_disabled` that would leave no enabled holder of role 2. Not checked while the current role (`current_user`) has BYPASSRLS, as the owner has inside SECURITY DEFINER code. |
| `90105` | `42501` | `Permission denied for queue ${queue}` | - | `queue` | A caller without `admin` named a queue that is not registered. A registered queue it may not use answers 90101 with the permission instead, so the answer tells whether a queue name is registered. |
| `90106` | `42501` | `Permission denied: cannot fix the id sequence of ${table}` | - | `table` | `fix_id_sequence` without the entity's `edit_permission`, or on an entity the caller does not see in the catalog, such as an is_a or has_a entity whose base it does not see. A name that is no entity gets the same answer from a caller without `admin`, so the answer does not tell whether the entity exists. |
| `90107` | `42501` | `Permission denied: only an administrator can set the external_id of a user` | `external_id is the identity a session resolves to. Send it unchanged, or leave it out, to save the rest of the record.` | - | A caller without `admin` inserted a user with an `external_id`, or changed the one of an existing user. An unchanged value and an agent inserted without one pass. Not checked while the current role (`current_user`) has BYPASSRLS, as the owner has inside SECURITY DEFINER code such as the sign-in in `get_userinfo`. |
| `90108` | `42501` | `The Administrator role has to keep the admin permission` | `Role 2 granting admin is what makes its holders Administrators. A direct connection as a role with BYPASSRLS is exempt from this check.` | - | The lockout guard for role 2's grant of `admin`: removing or re-pointing the `role_permissions` row of role 2 for `admin`, and deleting or renaming the permission `admin`. Not checked while the current role (`current_user`) has BYPASSRLS, as the owner has inside SECURITY DEFINER code. |

### 902xx - data dictionary: entities and fields

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90201` | `90201` | `catalog_entity_code is write-once: it cannot be changed once set` | - | - | Platform rule on `entities`. A catalog code identifies the row for good once it is set. |
| `90202` | `90202` | `catalog_field_code is write-once: it cannot be changed once set` | - | - | Platform rule on `fields`, as 90201. |
| `90203` | `90203` | `roles.origin is set on INSERT and cannot be changed` | - | - | Platform rule on `roles`. Provenance is decided when the role is created. |
| `90204` | `90204` | `system role slugs cannot be changed after creation` | - | - | Platform rule on `roles`. A system role's slug is referenced by name elsewhere. |
| `90205` | `90205` | `permission_hierarchy.origin is set on INSERT and cannot be changed` | - | - | Platform rule on `permission_hierarchy`, as 90203. |
| `90206` | `90206` | `catalog_role_code is write-once: it cannot be changed once set` | - | - | Platform rule on `roles`, as 90201. |
| `90207` | `90207` | `A bookmark can only be written by an authenticated user` | - | - | Platform rule on `user_bookmarks`. Its computed `user_id` is the writer's `$user_id`, which is null in a session without claims; the rule refuses that insert or update instead of storing a bookmark without an owner. Deletes are exempt. |
| `90210` | `90210` | `Cannot add permission hierarchy: would create a cycle. Permission ${including} cannot be both ancestor and descendant of permission ${included}` | - | `including`, `included` | Permission inclusion has to stay a DAG. |
| `90211` | `90211` | `Cannot add permission hierarchy: maximum depth of 11 levels would be exceeded. Current depth would be ${depth}` | - | `depth` | The depth bound the resolver is written against. |
| `90212` | `90212` | `Referenced table ${table} not found in entities` | - | `table` | A `reference` or `parent` field naming an entity that does not exist. Raised from three sites: when a field is created, when it is pointed at another entity, and when a change has to rebuild its foreign key. A reference that is not changing is not checked again unless a change of its delete mode or format rebuilds its foreign key. |
| `90213` | `90213` | `catalog_entity_aliases is append-only: existing alias elements cannot be removed or rewritten` | - | - | A merge record is history; it only grows. |
| `90214` | `90214` | `ctype is system-managed and cannot be changed on field ${field_name}` | - | `field_name` | Raised for an UPDATE that changes `ctype` while the current role (`current_user`) lacks BYPASSRLS; under such a role an INSERT gets `ctype` set to empty instead. The marker that makes a column a core column. `rollup` and `computed` are ctypes too, derived from a rollup definition (docs/rollup-fields.md) and from the entity's `computed_fields`: set and cleared with the definition or rule and never by hand, and the two markers the core protection below (90217-90220, 90285, 90286) does not apply to. A label column that a rule computes carries `computed_label`, derived the same way, and keeps the label's protection. The label marker follows `entities.label_column` (90270). |
| `90215` | `90215` | `Table ${table} already has a primary key` | - | `table` | One `is_pk` field per entity. The unique index `one_pk_per_table_idx` refuses a second key field with 23505 before the trigger that raises this code runs, so a client gets the 23505. |
| `90217` | `90217` | `Cannot delete core system field ${field_name}. Core fields (ctype id/label/audit/core) cannot be deleted.` | - | `field_name` | A computed label column (ctype `computed_label`) is the label and is protected the same way. A rollup field (ctype `rollup`) and a computed field (ctype `computed`) are not core and are deleted like any other field. |
| `90218` | `90218` | `Cannot rename core system field ${field_name}` | - | `field_name` | The label column is exempt. A rollup field is not core and may be renamed. |
| `90219` | `90219` | `Cannot change format of core system field ${field_name}` | - | `field_name` | A rollup field is not core; its format change goes through 90223 and 90268 instead. |
| `90220` | `90220` | `Cannot change default value of core system field ${field_name}` | - | `field_name` | The label column is exempt; id, audit and core columns are not. A rollup field is not core. |
| `90285` | `90285` | `Cannot change reference_delete_mode of core system field ${field_name}` | - | `field_name` | The foreign key of a core column is written by hand in the migrations, some in a form the dictionary does not generate: the one of `modules.view_permission` is deferred. A changed delete mode would have the dictionary drop that constraint and build the generated form in its place. |
| `90286` | `90286` | `Cannot change reference_table of core system field ${field_name}` | - | `field_name` | As 90285, for the entity the field points at. Renaming `users`, `roles` or `permissions` would re-point the core fields that point at them, so the rename is refused with this code, naming one of those fields. |
| `90221` | `90221` | `Cannot change table_name of a field` | - | - | Except as the cascade of a table rename. |
| `90222` | `90222` | `Cannot change primary key status of existing field` | - | - | |
| `90223` | `90223` | `Cannot change format of field ${field_name} from ${old_format} to ${new_format} because it would require changing the column type from ${old_type} to ${new_type}. Drop and recreate the field instead.` | - | `field_name`, `old_format`, `new_format`, `old_type`, `new_type` | Two sites, one row: the rename guard and the update guard. |
| `90224` | `90224` | `Field name ${field_name} is reserved: names starting with "_" are reserved for generated/system columns (e.g. _label)` | - | `field_name` | The prefix is reserved; the `_label` suffix is not. Not checked while the current role (`current_user`) has BYPASSRLS, as the owner has inside SECURITY DEFINER code. |
| `90225` | `90225` | `label_parent cannot be set on junction entity ${table}` | - | `table` | |
| `90226` | `90226` | `label_parent ${label_parent} is not a field of entity ${table}` | - | `label_parent`, `table` | |
| `90227` | `90227` | `label_parent ${label_parent} on ${table} must name a reference/parent field` | - | `label_parent`, `table` | |
| `90228` | `90228` | `label_parent ${label_parent} must not be self-referential (the identity spine must be acyclic)` | - | `label_parent` | |
| `90229` | `90229` | `label_parent ${label_parent} must not target junction entity ${table}` | - | `label_parent`, `table` | |
| `90230` | `90230` | `label_parent on ${table} via ${label_parent} would create a cycle in the identity spine` | - | `table`, `label_parent` | |
| `90231` | `90231` | `Table ${table} is not an entity` | - | `table` | `fix_id_sequence` on a name no entity has. The answer an administrator gets; everyone else gets 90106. Also `create_entity_policies`, which only dictionary code and migrations call. |
| `90232` | `90232` | `Table ${table} is busy, try again` | `Another transaction is writing to ${table}. Retry when it has finished.` | `table` | `fix_id_sequence` waited 2 s for its table lock. Safe to retry. |
| `90233` | `90233` | `id_type is set when an entity is created and cannot be changed` | - | - | Platform rule on `entities`. Every key and every foreign key pointing at one was built from it. |
| `90234` | `90234` | `id_type ${id_type} is reserved for system tables and cannot be used for entity ${table}` | - | `id_type`, `table` | `computed` describes the system tables whose key is a generated column; the dictionary cannot build one. Raised when a managed entity is created or switched to managed. |
| `90235` | `90235` | `Table ${table} cannot be adopted: its key column ${id_column} is ${actual_type}, but id_type ${id_type} needs ${expected_type}` | `Change the table's key column to ${expected_type}, or declare the entity with the id_type that matches it.` | `table`, `id_column`, `actual_type`, `id_type`, `expected_type` | Registering an entity onto an existing table, or switching `managed` on for one, when the key column does not match `id_type`. `actual_type` is `missing` when there is no key column. |
| `90236` | `90236` | `The key ${column} of ${table} cannot be changed` | - | `column`, `table` | A record key is set once. Writing the unchanged key back passes. Also raised by the generated write routine of an is_a or has_a entity, naming the entity: on any UPDATE that changes the key, whether the statement or a rule changes it, and on the insert of a has_a record whose rules change the key of the base record it attaches to. |
| `90237` | `90237` | `Id ${id} does not carry the prefix ${prefix} of ${table}` | - | `id`, `prefix`, `table` | An insert into a typeid entity that brings its own id with another prefix, a former prefix of the entity included. Also an is_a insert whose id lacks the is_a entity's prefix, a direct insert into an is_a root with a subtype's prefix, and a has_a insert that creates its base record with an id lacking the base's prefix. |
| `90238` | `90238` | `Invalid record id ${id} for entity ${table}` | - | `id`, `table` | `get_record_by_id` (and JsonLogic `set_record` through it) with an id that is not a valid value of the entity's key type. Raised only to a caller who sees the entity in the catalog (a holder of its view or edit permission, on every level of an is_a or has_a entity, or of `admin`); anybody else gets the `NULL` of a missing record. |
| `90239` | `90239` | `Entity ${table} cannot be managed: its id field ${id_column} has format ${actual_format}, but id_type ${id_type} needs ${expected_format}` | `Change the format of the id field to ${expected_format} while the entity is unmanaged, then switch managed on.` | `table`, `id_column`, `actual_format`, `id_type`, `expected_format` | Switching `managed` on for an entity whose id field row (written while it was unmanaged) describes another key type. Switching managed on never rewrites metadata, so the difference is refused, not fixed. |
| `90240` | `90240` | `Entity ${table} cannot be based on ${base}` | `An is_a entity is based on a managed typeid or is_a entity, a has_a entity on a managed typeid entity, and no entity on itself.` | `table`, `base` | Creating an is_a or has_a entity whose `id_refentity` has the wrong key type, is unmanaged, or is the entity itself. |
| `90241` | `90241` | `id_refentity is set when an entity is created and cannot be changed` | - | `table` | The records of an is_a or has_a entity are stored in its base. A rename of the base, which `ON UPDATE CASCADE` carries to `id_refentity`, is the one change it takes. |
| `90242` | `90242` | `label_column, label_column_label and label_parent of ${table} come from its base ${base}` | - | `table`, `base` | An is_a or has_a entity's record is labeled by its root, so `label_column` and `label_column_label` are set from the root and `label_parent` is set empty when the entity is created, and none of the three can be changed on it. |
| `90243` | `90243` | `Field ${field_name} of ${table} collides with ${other}, which shares its records` | - | `field_name`, `table`, `other` | A field name already used by an entity above or below this one in its is_a/has_a chain; the views show the fields of the whole chain side by side. Siblings may repeat a name; the key and the audit fields are each entity's own. |
| `90244` | `90244` | `${relation} stores part of ${table} records; write them through ${table}` | - | `relation`, `table` | A direct write to `<entity>_ext`. Only the entity's write routines write it, so every part and every level's rules are written together. |
| `90245` | `90245` | `id_prefix of an is_a entity is set when it is created` | - | - | Platform rule on `entities`. An is_a record's type is read from the prefix of its id, so the prefix has to mean the same thing for good. |
| `90246` | `90246` | `Attaching ${table} to ${base} record ${id}: ${field} differs from the stored value; change it through ${base}` | - | `table`, `base`, `id`, `field` | An insert into a has_a entity with the id of an existing base record attaches to it and writes no base field; a base value in the insert that is neither the stored one nor the column default, or one a computed field changed, is refused. |
| `90247` | `90247` | `Entity ${table} still has records; delete them first` | - | `table` | Deleting an is_a/has_a entity, or the base of one, while it has records. Their records span several tables, so they are deleted through the entity first. Also refuses a module delete whose cascade reaches such an entity. |
| `90248` | `90248` | `Entity ${table} cannot be deleted while ${dependents} are based on it` | - | `table`, `dependents` | `dependents` is one comma-separated string. A dependent in the module being deleted does not count. |
| `90249` | `90249` | `${feature} is not available for ${id_type} entity ${table}` | - | `feature`, `id_type`, `table` | `feature` is an identifier: `order_column`, `queue_table_events` and `process_gates` on an is_a or has_a entity, `cascade` on a reference or parent field of an is_a entity (an RI cascade would delete one part of a record and leave the rest), `rollup` when the parent or the child of a rollup is an is_a or has_a entity. |
| `90250` | `90250` | `Table name ${relation} is already in use` | - | `relation` | Creating or renaming an is_a or has_a entity whose view name or `<entity>_ext` name is taken by another relation. |
| `90251` | `90251` | `Record ${id} of ${table} still has a ${extension} record; remove it through ${extension} first` | - | `id`, `table`, `extension` | Deleting a has_a base record that an extension is attached to. Deletes never cascade into the parts of a record. |
| `90252` | `90252` | `Entity ${table} cannot become unmanaged while ${dependents} are based on it` | - | `table`, `dependents` | Switching `managed` off on a base; its dependents' views and write routines are built on its table. |
| `90253` | `90253` | `id_column is set when an entity is created and cannot be changed` | - | - | Platform rule on `entities`, for every key type. The key column is created under this name; changing the row would rename no column, so the entity would describe a key that does not exist. Writing the unchanged value back passes. |
| `90254` | `90254` | `Records of ${base} already carry the prefix ${prefix}` | `The prefix names the type of a record. Choose a prefix no record of the family carries.` | `table`, `base`, `prefix` | Creating an is_a entity whose prefix rows of its root still carry: a prefix the root gave up is free among entities, but the root's rows keep it, and the dispatch would hand them to the new subtype, which has no part for them. `base` is the root. |
| `90255` | `90255` | `Record ${id} of ${table} has no part in ${subtype}, the type its id names` | - | `id`, `table`, `subtype` | An update or delete through the root, or through the view of a supertype, of a record whose id names a subtype that holds no part for it. Only a write past the dictionary can leave such a record. A part the caller may not read is not this error: that record is skipped, like any row RLS hides. |
| `90256` | `90256` | `This change drops ${views}, and with them ${dependents}, which the dictionary did not create` | `Drop those objects, make the change, then create them again.` | `views`, `dependents` | Any change that rebuilds an is_a/has_a family (a field of any level added, changed or deleted, a searchable change, a rename, a root prefix change, rules added to or removed from a level) or deletes a family entity (itself, or through a module delete) drops the family's views, and PostgreSQL would drop what is built on them with them. Refused while such an object exists. `views` and `dependents` are comma-separated strings; a dependent is described as `view <name>`, `function <signature>`, `policy <name> on table <name>` and so on. What the dictionary builds on the views itself does not count. A plain entity's delete still drops what is built on its table. |
| `90257` | `90257` | `Field ${field_name} on ${table} cannot be required while its delete mode is clear` | - | `table`, `field_name` | `ON DELETE SET NULL` would make every delete of the referenced record fail on this field. Refused when the combination is set, so a field that already has it stays editable. |
| `90258` | `90258` | `Field ${field_name} on ${table} is required` | - | `table`, `field_name` | A write left a required field missing: `NULL` for `reference`, `date`, `time`, `date-time` and `uuid`, blank or whitespace-only text, an empty enum, JSON `{}`, `[]`, `null` or `""`, an empty `binary`, a `rating` of 0. Raised by the field's required check, so every writer gets it. Explicit `NULL` on a `NOT NULL` column stays PostgreSQL's 23502, because `NOT NULL` runs before any check. |
| `90259` | `90259` | `Field ${field_name} on ${table} cannot be required while rows have no value for it` | - | `table`, `field_name` | Changing a field to required while rows are missing a value, or adding a required field with no usable default, or a parent field whose default is the current user, to a table with rows. |
| `90260` | `90260` | `Entity ${table} cannot be deleted while ${fields} reference it` | `Delete those fields or point them at another entity first.` | `table`, `fields` | `fields` is one comma-separated string of `entity.field`. The delete would drop their foreign keys and leave the columns, values and field rows pointing at nothing, whatever their delete mode, which governs deleting records rather than the entity. A field of the entity itself, or of an entity in the module being deleted, does not count, so a module delete is refused only by a reference from another module. |
| `90261` | `90261` | `Rollup ${field_name} on ${table} has an invalid definition: ${problem}` | - | `table`, `field_name`, `problem` | The shape of `fields.rollup` (docs/rollup-fields.md): an unknown key, a value of the wrong type, a definition on the key, a core field, a computed field or a reference or parent field, or a rollup that is `required`, `searchable` or `unique_value`. `problem` says which. |
| `90262` | `90262` | `Rollup ${field_name} on ${table}: link_field ${link_field} must name a reference or parent field of another entity that points at ${table}` | - | `table`, `field_name`, `link_field` | `link_field` is `<entity>.<field>`; the field must exist, be a `reference` or `parent`, and have `reference_table` = `table`. |
| `90263` | `90263` | `Rollup ${field_name} on ${table}: function ${function} is not one of sum, min, max, avg, count` | - | `table`, `field_name`, `function` | |
| `90264` | `90264` | `Rollup ${field_name} on ${table}: value_field ${value_field} must name a field of ${link_table} that ${function} can aggregate` | - | `table`, `field_name`, `value_field`, `link_table`, `function`, `problem` | `sum` and `avg` take a numeric field; `min` and `max` also a text-typed, `date` or `date-time` field; `count` takes none. `problem` says whether the field is missing, unknown or of the wrong format. |
| `90265` | `90265` | `Rollup ${field_name} on ${table}: the filter cannot be compiled: ${problem}` | - | `table`, `field_name`, `problem` | The filter uses something outside the compiled subset (an operator, a request variable, a path, a column the child does not have or of a type the compiler does not compare, a literal the column cannot be cast from, a number compared with text, a string in an `in` list against a number, an operator object with two keys, an empty `in` list, null in an ordering comparison, arguments a date operator would refuse). `problem` names it. |
| `90266` | `90266` | `Field ${field_name} on ${table} cannot be deleted while rollups ${rollups} depend on it` | - | `table`, `field_name`, `rollups` | `rollups` is one comma-separated string of `entity.field`. Raised for the link field or the value field of another entity's rollup, and for the entity holding them; a rollup whose entity or module is being deleted in the same cascade does not count, as for 90260. |
| `90267` | `90267` | `Rollup ${field_name} on ${table} depends on itself through ${chain}` | - | `table`, `field_name`, `chain` | A value field that is itself a rollup is fine; a chain of such rollups that comes back to the field is not. `chain` is the path, `entity.field -> entity.field`. A chain longer than 32 steps is refused the same way. |
| `90268` | `90268` | `Rollup ${field_name} on ${table}: format ${format} does not fit ${function}; use ${expected_format}` | - | `table`, `field_name`, `format`, `function`, `expected_format`, `value_field` | The field's own format must fit the result: an integer format or `number` for `count`, a numeric one for `sum`, a fractional one (`number`, `float`, `double`) for `avg`, and for `min` and `max` one with the value field's column type. |
| `90269` | `90269` | `Rollup ${field_name} on ${table} aggregates rows of ${link_table} that readers of ${table} may not see; set include_hidden_rows to accept that` | - | `table`, `field_name`, `link_table` | The child has a `select_rule` or another `view_permission` than the parent, so the aggregate would show readers of the parent something about rows their row security hides. Accepted only with `"include_hidden_rows": true` in the definition. Also raised when a change of `select_rule` or `view_permission` on either entity of an existing rollup makes it such a case. |
| `90270` | `90270` | `label_column of ${table} cannot name ${field_name}, which is already a ${ctype} field` | - | `table`, `field_name`, `ctype` | Pointing `entities.label_column` at a field moves the label marker (ctype `label` or `computed_label`) to it and turns the previous label field into an ordinary field. A field carries one marker, so an `id`, `audit`, `core` or `rollup` field cannot become the label. A plain or computed field can. |
| `90271` | `90271` | `Table name ${table} is reserved: a name starting with "_" marks an internal table, which cannot be registered or managed as an entity` | - | `table` | Inserting an entity whose `table_name` starts with `_`, renaming one to such a name, or setting `managed` on one. Internal tables (`_settings`, `_apikeys`) have no permission model, and an entity would give them one. Nobody is exempt. |
| `90272` | `90272` | `Rollup ${field_name} on ${table}: the filter cannot evaluate ${operator} for this record` | - | `table`, `field_name`, `operator`, `cause_code` | Raised on the write of a child record. A date operator in the rollup's filter has no answer for a value the child holds: a date of `infinity`, a year beyond 9999, an amount beyond the integer range, or a sum past the last timestamp. Counting the child in or out would both be a guess, so the write is refused. `cause_code` is the code of the error underneath (90915, 22003, 22008). |
| `90273` | `90273` | `Table name ${table} is ${length} bytes long: the names generated from it fit only up to ${max} bytes` | - | `table`, `length`, `max` | Inserting an entity, renaming one, or setting `managed` on one whose `table_name` is longer than 41 bytes. PostgreSQL cuts an identifier to 63 bytes without an error, and the longest name generated from a table name adds 22, so a longer name would share its policies, trigger functions or rule functions with another. Existing entities are not touched. |
| `90274` | `90274` | `Field ${field_name} on ${table} cannot get its index: the name ${name} is already used by ${used_by}` | - | `table`, `field_name`, `name`, `used_by` | A reference field's index `idx_<table>_<field>` or a `unique_value` field's index `<table>_<field>_unique` carries a name that something else in the schema already has: table `a_b` with field `c` spells the name of table `a` with field `b_c`. `used_by` is the table the existing index is on. Rename the field. Raised whenever the field gets an index: when it is created, when a change rebuilds its foreign key or turns `unique_value` on, and when its entity is switched to managed; and when a rename of the field or of its table would give its index such a name. |
| `90275` | `90275` | `Field ${field_name} cannot be renamed while ${rule} on ${table} names it` | - | `field_name`, `table`, `rule` | A rename rewrites no rule, and a rule that reads the old name would decide on null. `table` is the entity the rule belongs to, which is the field's entity or an is_a or has_a entity below it; `rule` is its place there: `computed_fields[0]`, `validation_rules[2]`, `select_rule`, or `<field>.input_type_rule`. A computed field also names the field it writes. Change the rule, then rename. A field read through the alias of a `set_record` in another entity's rule is not found. |
| `90276` | `90276` | `Field name ${field_name} on ${table} is ${length} bytes long: the names generated from it fit only up to ${max} bytes` | - | `table`, `field_name`, `length`, `max` | Creating a field, or renaming one, whose longest generated name, `<relation>_<field>_not_null`, would exceed 63 bytes; `max` is 53 less the length of the relation name, which is `<entity>_ext` for an is_a or has_a entity. Also renaming a table to a longer name under which a field it has would no longer fit; `field_name` is then the longest such field. A field that exists is otherwise left alone. |
| `90277` | `90277` | `Field ${field_name} is the label_parent of ${table} and has to stay a reference or parent field` | - | `field_name`, `table` | Changing the format of a field away from `reference` or `parent` while its entity names it as `label_parent`. Clear `label_parent` first. |
| `90278` | `90278` | `order_column ${order_column} of ${table} names a column the table already has` | - | `order_column`, `table` | The order column is the dictionary's own: it adds the column and drops it when the entity stops naming it. A name that a field or a core column of the entity carries is refused where it is newly given, on insert and on a change of `order_column`. |
| `90280` | `90280` | `Rollup ${field_name} on ${table}: the function of link_field ${link_field} and the guard of a rollup parent would carry one name` | - | `table`, `field_name`, `link_field` | The maintenance function of a link is `common.rollup_<child>_<link>` and the guard of a parent `common.rollup_guard_<parent>`: a child entity named `guard` with link field `x` spells the guard of an entity named `x`. Rename the child entity or the link field. |
| `90281` | `90281` | `Rollup ${field_name} on ${table}: the function name ${name} is already used by ${used_by}` | `Rename the child entity or the link field.` | `table`, `field_name`, `name`, `used_by` | The maintenance function of a link is `common.rollup_<child>_<link>`. A name longer than 59 characters keeps 42 characters and 8 hex digits of md5, so two long links can spell one name, and a function name of 58 characters, the length of a shortened one, is not shortened and can spell another link's shortened name; building the second would drop the first one's function and triggers. `name` is the function name, `used_by` a rollup field over the other link, as `<table>.<field>`. Rollups over the same link share the function and are not refused. Checked wherever the definition is validated: when the rollup is saved, and when a rename changes the name of its function. |
| `90282` | `90282` | `Field ${field_name} on ${table} is a parent field and cannot use delete mode clear` | `Use restrict or cascade, or make it a reference with clear.` | `table`, `field_name` | A `parent` column is `NOT NULL`, so `ON DELETE SET NULL` would make every delete of a parent record that has children fail (23502). Refused when the field is created with it, and when its delete mode or its format changes to it, so a field that already has it stays editable. |
| `90283` | `90283` | `Default ${default_value} of field ${field_name} on ${table} only applies to a reference or parent field to users` | - | `table`, `field_name`, `default_value` | `CURRENT_USER` or `$user_id` as a default means the signed-in user's id, which only a `reference` or `parent` field to `users` can hold. Refused for `$user_id` on any other field, and for `CURRENT_USER` on a reference or parent field to another entity or on a column that is not TEXT, where PostgreSQL's own `CURRENT_USER` (the role name) does not fit. `CURRENT_USER` on a TEXT column stays allowed and stores the role name. Checked when a field comes to carry the token where it cannot work, so a field that already did stays editable. |
| `90284` | `90284` | `Default ${default_value} of field ${field_name} on ${table} is not a relative day or time a default can hold` | `Write today, tomorrow, yesterday, now, $today or $now on its own; a time field takes only now or $now.` | `table`, `field_name`, `default_value` | A date, date-time or time default that names `today`, `tomorrow`, `yesterday` or `now` other than as the word on its own, such as `tomorrow 09:00`, `$today + 1`, or `today` on a time field. The word on its own becomes an expression that reads the UTC day or clock on every insert. Any other such text would be a literal, which PostgreSQL either refuses or converts once, when the default is set, so every record would get the day the field was saved. Allow-listed expressions such as `now()` are not affected. Checked when a field comes to carry such a default, so a field that already did stays editable. |

### 903xx - schema and record RPCs

Reserved. `get_schema`, `get_schemas` and `build_schema_for_table` answer
42P01 both for a table that does not exist and for one the caller may not see,
and carry no `hint.code`; `get_record_by_id` answers both with NULL. Those
sites are deliberately left as they are, so the block has no rows.

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|

### 904xx - api keys

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90401` | `90401` | `User with id ${user_id} does not exist` | - | `user_id` | Minting or listing keys for a user that is not there. |
| `90402` | `90402` | `API key not found` | - | - | Also the answer to a caller without `admin` who names a key of another user. |

### 905xx - queues and topics

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90501` | `90501` | `Cannot change queue_name after creation` | - | - | The name is the key pgmq stores under. |
| `90502` | `90502` | `Cannot change table_name on a queue table event` | - | - | Except as the cascade of a table rename. |
| `90503` | `90503` | `Parent queue not found for queue_id ${queue_id}` | - | `queue_id` | |
| `90504` | `90504` | `Queue ${queue} is not registered` | - | `queue` | The answer an administrator gets; everyone else gets 90105. |
| `90505` | `90505` | `Queue name ${queue} has to start with a lower-case letter or an underscore, contain only lower-case letters, digits and underscores, and be at most 47 bytes long` | - | `queue` | A queue name has the shape of a table name. pgmq names the tables of a queue after it in lower case and cuts them at 63 bytes, so two names that differ in case only, or in their tail only, would share their tables; and the name goes into the triggers that map a table to the queue and into the statements pgmq builds. |
| `90506` | `90506` | `Queue ${queue} and table ${table} are too long together: the trigger name ${name} would not fit 63 bytes` | - | `queue`, `table`, `name` | Mapping a table to a queue, or moving a mapping to another queue, when a trigger name `queue_<queue>_<event>_on_<table>` would exceed 63 bytes; also renaming a mapped table to a name under which one of its mapping's trigger names would. A `queue_` trigger of no current mapping is renamed without this check and can still be cut. A cut name no longer ends in `_on_<table>`: the rename of the table would leave the trigger under its old name, where the removal of the mapping no longer finds it. |

### 906xx - audit

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90601` | `90601` | `Table ${table} cannot be audited because it has no primary key` | - | `table` | An audit row is keyed by the row it describes. |
| `90602` | `90602` | `Audit log entity ${table} cannot be managed` | `The audit logs are append-only evidence. Managing them would grant the request role INSERT and UPDATE on the log.` | `table` | Switching `managed` on for `audit_record_logs` or `audit_ddl_logs`. The audit logs are append-only evidence; adoption would grant the request role INSERT and UPDATE on the log. |

### 907xx - modules and slugs

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90701` | `90701` | `catalog_module_code is write-once: it cannot be changed once set` | - | - | Platform rule on `modules`, as 90201. |
| `90702` | `90702` | `module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, '-' and '_'` | - | - | Platform rule on `modules`. The slug appears in URLs and permission names. |

### 908xx - RACI

Reserved. A RACI gate does not refuse: a blocking consultation holds a gated
state column at its stored value. A refusal that a RACI operator
(`is_raci_actor`, `has_consultation`) decides comes from a validation rule,
which carries a code of its own, so nothing raises from this block.

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|

### 909xx - JsonLogic runtime and rule definitions

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90900` | `90900` | `computed_fields[${index}] on ${table} is missing required "name"` | - | `index`, `table` | Raised while a managed entity is saved, or an entity is switched to managed, by the trigger builder. A name that is not text counts as missing, and is refused already when the entry is saved new or changed, on any entity. |
| `90901` | `90901` | `computed_fields[${index}] on ${table} is missing required "jsonlogic"` | - | `index`, `table` | As 90900. |
| `90902` | `90902` | `validation_rules[${index}] on ${table} is missing required "code"` | - | `index`, `table` | As 90900. |
| `90903` | `90903` | `validation_rules[${index}] on ${table} is missing required "message"` | - | `index`, `table` | As 90900, for a message that is missing or is not text. |
| `90904` | `90904` | `validation_rules[${index}] on ${table} is missing required "jsonlogic"` | - | `index`, `table` | As 90900. |
| `90905` | `90905` | `validation_rules[${index}] on ${table} must carry a class 99 code, not ${rule_code}` | - | `index`, `table`, `rule_code` | The rule's code is the SQLSTATE its failure raises, so it has to be one. |
| `90906` | `90906` | `validation_rules[${index}] on ${table} is a platform rule, so its code must be a class 90 number, not ${rule_code}` | - | `index`, `table`, `rule_code` | As 90905, for a rule core itself ships. |
| `90907` | `90907` | `computed_fields[${index}] on ${table} names the rollup field ${field_name}` | - | `index`, `table`, `field_name` | A field has one derivation. A computed rule writing a rollup column would run after the rollup guard and overwrite the aggregate; the other direction, a rollup on a computed field, is 90261. |
| `90908` | `90908` | `computed_fields on ${table} cannot be applied to record ${record_id}: ${problem}` | - | `table`, `record_id`, `problem`, `cause_code` | Saving a computed rule applies it to the existing records, and this one cannot take its new value: a validation rule refuses it, the rule itself fails on it, or a constraint does. The whole save is refused, so no record is left half applied. `problem` is the original message and `cause_code` its code, a rule's own 99xxx code for a validation rule. A record whose value does not move is not validated and cannot cause this. |
| `90909` | `90909` | `${rule} on ${table} uses an operation the evaluator does not implement: ${op}` | - | `rule`, `table`, `op` | Raised while the entity or the field is saved. `rule` is the rule's place in the entity: `select_rule`, `validation_rules[0]`, `computed_fields[2]`, or `<field>.input_type_rule` for the rule of a field. The operator can stand anywhere in the rule. The same operator met by the evaluator on a record, in a rule stored past the save, is 90910. |
| `90910` | `90910` | `Unrecognized operation: ${op}` | - | `op` | The rule names an operator the evaluator does not implement. |
| `90911` | `90911` | `throw_error code must be a class 99 number, not ${code_given}` | - | `code_given` | Class 99 is the space reserved for whoever writes the rule. |
| `90912` | `90912` | `throw_error parameter ${name} uses a reserved name` | - | `name` | `hint`, `code`, `entity`, `rule` and `field` belong to the contract. |
| `90913` | `90913` | `throw_error parameter ${name} must be a scalar value, not ${json_type}` | - | `name`, `json_type` | A parameter is a value in a sentence, never a structure. |
| `90914` | `90914` | `throw_error parameters must be a flat list of name and value pairs` | - | - | The list is flat because JsonLogic reads a single-key object as an operator call. |
| `90915` | `90915` | `${operator} needs an ISO 8601 date or date-time, not ${value}` | - | `operator`, `value` | A date operator was given anything else, including text PostgreSQL itself would read as a date, such as `today` or a locale format, because a stored result must not depend on the day a rule ran or on a session setting. |
| `90916` | `90916` | `${operator} cannot use ${unit} on this value` | - | `operator`, `unit` | The unit or part is unknown or missing, or it needs a time of day the value does not have, as `hour` does on a date-only value or a duration with a time part. |
| `90917` | `90917` | `${operator} cannot use the pattern ${pattern}` | - | `operator`, `pattern` | `date_format` takes a fixed list of tokens so that the browser and the server render the same text. A token with a time of day is refused on a date-only value. |
| `90918` | `90918` | `${operator} needs a whole number or an ISO 8601 duration, not ${value}` | - | `operator`, `value` | The amount given to `date_add` is neither. |
| `90919` | `90919` | `${rule} on ${table} must be a single JsonLogic operation: an object with exactly one key` | - | `rule`, `table` | Raised while the entity is saved, for a `select_rule` or a validation rule. The evaluator reads an object with several keys, and every literal, as a value, and a value is truthy, so such a rule would pass every record. `true` and `false` are refused with the rest; a computed field may be a literal. The empty `select_rule` `{}` means no rule. |
| `90920` | `90920` | `${operator} has no finite result` | - | `operator` | `/` or `%` with a zero divisor, or `+`, `-`, `*`, `/`, `%`, `max` or `min` with a result of Infinity or NaN: an operand spelled `Infinity`, number text with an exponent beyond the range, or text that carries no number at all, which JavaScript computes as NaN. Null and the empty string count as 0. JSON has no such number, and answering null would store "no value" where the rule's author made a mistake. The browser evaluator raises in the same cases. |
| `90921` | `90921` | `${rule} on ${table} gives ${op} ${count} arguments, a number it does not take` | - | `rule`, `table`, `path`, `op`, `count`, `min`, `max` | Raised while the entity or the field is saved, for a rule that is new or changed; `rule` as for 90909. `path` is the JSON pointer of the operation's arguments inside the rule, such as `/if/0/>=`. `max` is null when the operator takes any number above `min`. The evaluator ignores an extra argument and reads a missing one as null, so `{">=": [x, 1, 10]}` would drop the 10. |
| `90922` | `90922` | `${rule} on ${table}: ${op} needs ${expected} at ${path}` | - | `rule`, `table`, `path`, `op`, `expected` | As 90921, for a literal argument of the wrong kind. `expected` is one of `var_path`, `number`, `array`, `name`, `permission`, `field`, `entity`, `string`, `raci_letter`, `error_code`, `error_parameters`, `parameter_pairs`, `parameter_name`, `parameter_value`, `duration`, `date_unit`, `date_part`, `date_pattern`. An operation in that place is evaluated when the rule runs and is not checked. |
| `90923` | `90923` | `${rule} on ${table} holds an object with ${key_count} keys, which is a value and not an operation` | - | `rule`, `table`, `path`, `key_count` | As 90921. The evaluator reads such an object as a value, and a value is truthy. It is refused in a computed field too, a constant object included. `path` is `''` when the object is the whole rule; at the top of a `select_rule` or a validation rule the same object is 90919. |
| `90924` | `90924` | `${rule} on ${table} reads ${variable}, which has no value where it is read` | - | `rule`, `table`, `path`, `variable`, `reason`, `op` | As 90921. `reason` is `unknown`, a `$` name other than `$today`, `$now`, `$user_id`, `$old` and `$mode`; `array_element`, a `$` name inside the logic of `map`, `filter`, `reduce`, `all`, `none` or `some`, which is evaluated against each element; or `bound_outside`, a name a `let` or `set_record` outside that operator binds. `op` is that operator, `''` for `unknown`. `variable` is the name before the first dot. |

## Constraint names

A constraint violation is PostgreSQL's error, not ours: the write goes straight
at the table, the row trigger runs before the constraint is evaluated, and
there is no code of ours between the client and the refusal to give it a
number or a JSON hint. What comes back is 23514, 23505 or 23503 with
PostgreSQL's own sentence. A delete that a foreign key with
`ON DELETE RESTRICT` refuses returns 23001 (`restrict_violation`) on
PostgreSQL 18 and 23503 up to PostgreSQL 17: the code depends on the version,
the constraint's name in the sentence does not. That name is the only stable
token in the sentence. The one constraint that does not answer with
PostgreSQL's code and sentence is a required field's check, generated as
`<table>_<field>_assert`, which calls a function that raises 90258 instead of
PostgreSQL's 23514. Our own code also raises 23514, with the sentence
PostgreSQL would give and the name of the generated `<table>_<field>_check`,
when rows do not fit a field's new enum values or default. The table below
lists the names our own tables declare and the names we keep stable, so a
translation keyed on one of them survives a rewrite of the expression behind
it. Names PostgreSQL generates itself (`entities_pkey`, `roles_role_name_key`)
are not listed - they are not ours to keep - except `entities_id_refentity_fkey`,
`fields_table_name_fkey`, `modules_module_slug_key` and
`<entity>_ext_<id_column>_fkey`, which PostgreSQL generates from inline
`REFERENCES` and `UNIQUE` clauses.

| Constraint | Table | Kind | Meaning |
|---|---|---|---|
| `catalog_entity_aliases_is_array` | `entities` | CHECK | `catalog_entity_aliases` must be a JSON array |
| `computed_fields_is_array` | `entities` | CHECK | `computed_fields` must be a JSON array |
| `derived_entity_managed` | `entities` | CHECK | an is_a or has_a entity is managed |
| `entities_id_refentity_fkey` | `entities` | FOREIGN KEY | `id_refentity` must name an entity; an entity cannot be deleted while entities are based on it, and an entities file must list a base before the entities based on it |
| `id_prefix_matches_id_type` | `entities` | CHECK | a typeid or is_a entity has an `id_prefix`, and no other entity has one |
| `id_refentity_matches_id_type` | `entities` | CHECK | an is_a or has_a entity names its base in `id_refentity`, and no other entity names one |
| `plural_matches_table_name` | `entities` | CHECK | `plural` must equal `table_name` |
| `select_rule_is_object` | `entities` | CHECK | `select_rule` must be a JSON object |
| `valid_cube_mode` | `entities` | CHECK | `cube_mode` is `disabled` or `auto` |
| `valid_edit_mode` | `entities` | CHECK | `edit_mode` is `auto`, `sidebar`, `modal` or `page` |
| `valid_entity_type` | `entities` | CHECK | `entity_type` is one of the six classifications |
| `valid_id_prefix` | `entities` | CHECK | `id_prefix` is empty or a TypeID prefix: up to 63 lowercase letters and underscores, starting and ending with a letter |
| `valid_id_type` | `entities` | CHECK | `id_type` is `auto_increment`, `bigint`, `text`, `uuid`, `typeid`, `is_a`, `has_a` or `computed` |
| `valid_id_column` | `entities` | CHECK | `id_column` is a lowercase identifier |
| `valid_label_column` | `entities` | CHECK | `label_column` is a lowercase identifier |
| `valid_label_parent` | `entities` | CHECK | `label_parent` is empty or a lowercase identifier |
| `valid_order_column` | `entities` | CHECK | `order_column` is empty or a lowercase identifier of at most 63 bytes |
| `valid_table_name` | `entities` | CHECK | `table_name` is a lowercase identifier that does not end in `_ext` (reserved for the tables of is_a and has_a entities) |
| `validation_rules_is_array` | `entities` | CHECK | `validation_rules` must be a JSON array |
| `unique_current_id_prefix` | `entities` | UNIQUE (index) | no two entities use the same `id_prefix` at the same time |
| `typeid_format` | domain `common.typeid` | CHECK | a TypeID key, or a column referencing one, holds a well-formed TypeID |
| `<entity>_ext_<id_column>_fkey` | `<entity>_ext` | FOREIGN KEY | the record still has a part stored in `<entity>_ext`; delete it through `<entity>`. This is what a cascade into an is_a root hits for a subtype record |
| `<table>_<field>_check` | `<table>` | CHECK | an enum field holds one of its values; also raised by the dictionary when rows do not fit a change of the values or default |
| `<table>_<field>_fkey` | `<table>` | FOREIGN KEY | a reference or parent field names an existing record; its delete mode decides what deleting that record does |
| `<table>_<field>_unique` | `<table>` | UNIQUE (index) | a `unique_value` field holds no value twice (NULL and, on a TEXT column, the empty string excepted) |
| `fields_table_field_unique` | `fields` | UNIQUE | one row per (`table_name`, `field_name`) |
| `fields_table_name_fkey` | `fields` | FOREIGN KEY | `table_name` must name an entity |
| `reference_requires_table` | `fields` | CHECK | a `reference` or `parent` field must name a `reference_table` |
| `reference_table_requires_reference_format` | `fields` | CHECK | `reference_table` is only allowed on a `reference` or `parent` field |
| `rollup_is_object` | `fields` | CHECK | `rollup` must be a JSON object (its keys are checked by the dictionary, 90261-90269) |
| `valid_ctype` | `fields` | CHECK | `ctype` is empty, `id`, `label`, `audit`, `core`, `rollup`, `computed` or `computed_label` |
| `valid_cube_type` | `fields` | CHECK | `cube_type` is `auto`, `dimension`, `measure` or `disabled` |
| `valid_default_value` | `fields` | CHECK | `default_value` is at most 200 characters and carries no semicolon, control character or SQL comment |
| `valid_field_name` | `fields` | CHECK | `field_name` is a lowercase identifier |
| `valid_format` | `fields` | CHECK | `format` is one of the supported field formats |
| `valid_input_type` | `fields` | CHECK | `input_type` is `default`, `required`, `readonly`, `disabled` or `hidden` |
| `valid_precision` | `fields` | CHECK | `precision` is between 0 and 18 |
| `one_pk_per_table_idx` | `fields` | UNIQUE (index) | one `is_pk` field per entity |
| `valid_reference_delete_mode` | `fields` | CHECK | `reference_delete_mode` is empty, `restrict`, `clear` or `cascade` |
| `valid_width` | `fields` | CHECK | `width` is `default`, `s`, `m` or `w` |
| `modules_module_slug_key` | `modules` | UNIQUE | `module_slug` is unique |
| `modules_view_permission_fkey` | `modules` | FOREIGN KEY | `view_permission` must name a permission |
| `valid_access_scope` | `modules` | CHECK | `access_scope` is `custom`, `basic`, `advanced`, `gated` or `raci` |
| `valid_module_type` | `modules` | CHECK | `module_type` is `domain` or `master` |
| `no_self_reference` | `permission_hierarchy` | CHECK | a permission cannot include itself |
| `valid_permission_hierarchy_origin` | `permission_hierarchy` | CHECK | `origin` is `system`, `model`, `model_master` or `user` |
| `permission_name_shape` | `permissions` | CHECK | `permission_name` is colon-separated lowercase segments |
| `process_gates_process_entity_gate_state_key` | `process_gates` | UNIQUE | one gate per (`process_id`, `entity`, `gate_kind`, `to_state`) |
| `idx_processes_module_key` | `processes` | UNIQUE (index) | a non-empty `process_key` is unique within its module |
| `idx_processes_global_key` | `processes` | UNIQUE (index) | a non-empty `process_key` is unique among the processes without a module |
| `valid_process_key` | `processes` | CHECK | `process_key` is empty or a lowercase identifier |
| `raci_assignments_process_role_raci_key` | `raci_assignments` | UNIQUE | one assignment per (`process_id`, `role_id`, `raci`) |
| `idx_raci_one_accountable` | `raci_assignments` | UNIQUE (index) | at most one accountable assignment per process |
| `raci_events_entity_fkey` | `raci_events` | FOREIGN KEY | `entity` must name an entity; an entity cannot be deleted while events name it (23001 on PostgreSQL 18, 23503 up to 17), and a rename carries its events along |
| `raci_events_target_role_id_fkey` | `raci_events` | FOREIGN KEY | `target_role_id` must name a role; a role cannot be deleted while events name it (23001 on PostgreSQL 18, 23503 up to 17) |
| `valid_role_origin` | `roles` | CHECK | `origin` is `system`, `model`, `model_master` or `user` |
| `valid_role_slug` | `roles` | CHECK | `slug` is empty or lowercase letters, digits and underscores |
| `users_external_id_not_empty` | `users` | CHECK | `external_id` cannot be blank |

