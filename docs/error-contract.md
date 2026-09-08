# Error contract

**Status:** draft, 2026-09-08. Every error that can reach a client through
PostgREST follows this contract. The rules come first; the numbers
themselves are the tables at the end of the page.

## Why

A client that wants to show an error in the user's language needs two things
the raw PostgreSQL error does not give it: a stable identity to look a
translation up by, and the values that belong in the sentence, separate from
the sentence. Before this contract every message was an English string with
the values already baked in (`Permission denied: dd:write required`), and the
only identity was the SQLSTATE, which lumps unrelated situations together
(42501 alone covered a missing token, a wrong audience, a missing permission
and a locked system field) and which PostgreSQL raises itself for its own
reasons (42501 is also a row-level security refusal). Nothing could be
localized without parsing English.

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
class, reuse exactly two standard codes where REST statuses require them
(42501 and 42P01, see "HTTP status"), and put every identity of our own in
two classes PostgreSQL leaves empty:

- **Class 90 is Semantius.** Every error our own code raises for a client has
  a `90xxx` catalog number, and the number is the identity: one row in the
  catalog, one translation on the client. Most sites raise the number as their
  ERRCODE. The families whose HTTP status carries REST meaning raise a standard
  code instead and carry the number as `hint.code`, see "HTTP status".
- **Class 99 is custom.** Errors a rule author raises, from `throw_error` or
  from a failing validation rule, carry a `99xxx` code minted by that author.
  A validation rule that core itself ships, marked `"source_module":
  "platform"` in `0060_dd_schema.sql` and `0200_module_slug_validation.sql`,
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

The 900xx, 901xx and 903xx blocks are wire-bearing: their numbers travel as
42501 or 42P01 and appear only in `hint.code`. A validation rule raises its
code as the SQLSTATE itself, so a platform rule can never take a number from
those three blocks - it takes one from a block whose wire is the number, and
that is why the dictionary's own immutability rules are 902xx rather than
901xx.

### Class 99

`99000` to `99999`, chosen by the author of the rule. `99000` is what
`throw_error` raises when no code is given. Two entities can use the same code
for different things, so a client keys class 99 translations by entity and
code, not by code alone; the error carries the entity as `hint.entity`, see
"The generated trigger". A module is a rule author like any other: the
`nwind` sample module is a custom module, and its rules use class 99.

### HTTP status

PostgREST derives the HTTP status from the SQLSTATE: a handful of standard
codes get a specific status and every code it does not know gets 400. A REST
consumer reads 401, 403 and 404 as "who are you", "you may not" and "no such
thing", and would read 400 as a malformed request, so those three statuses
are kept:

| Family | Wire SQLSTATE | PostgREST status | Identity |
|---|---|---|---|
| 900xx authentication, 901xx permissions | 42501 insufficient_privilege | 401 for an anonymous request, 403 with a token | `hint.code` |
| 903xx unknown entity or table | 42P01 undefined_table | 404 | `hint.code` |
| every other 90xxx code | the number itself | 400 | `code` |
| 99xxx | the number itself | 400 | `code`, scoped by entity |

The first row is about refusals. A number in the 900xx or 901xx blocks that is
not one - an internal invariant failing inside `get_userinfo`, an argument
guard - is raised as itself and answers 400, because 403 would send a client to
re-authenticate over something authentication cannot fix. The **Wire** column of
each row settles which it is.

42501 and 42P01 are the only standard codes we ever raise, and only paired
with a `hint.code` from those blocks. PostgreSQL raises the same two codes
itself, for a row-level security refusal, a missing grant or a missing
relation; those carry no `hint.code`, which is how a client tells them apart.

The 404 is also the existence-hiding answer: `get_schema`,
`build_schema_for_table` and the record RPCs answer 42P01 both for a table
that does not exist and for one the caller may not see, so the status alone
never says which.

PostgREST's own 401 for a missing, expired or invalid token is unaffected: it
rejects those before the database is reached. The mapping is PostgREST's and
can change with its version; re-check it when PostgREST is upgraded.

## The four fields

| Field | Rule |
|---|---|
| SQLSTATE | `99xxx`, a `90xxx` number, or 42501 / 42P01 with the number in `hint.code`, as above. |
| MESSAGE | English template with `${name}` placeholders. Never interpolated on the server. |
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
never its `::text` or a `format()` result. The contract test asserts the
JSON type of every parameter it exercises.

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
RAISE EXCEPTION 'Cannot change format of core system field ${field}'
    USING ERRCODE = '90210',
          HINT = jsonb_build_object('field', OLD.field_name)::text;
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
trigger, and a parameter with one of those names would be overwritten. Every
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
checked when the entity is saved: a code outside class 99 is rejected then,
unless the rule is a platform rule, whose code must be class 90. That the
code is a catalog row is not checked at save time, because the catalog is a
document, not a table.

### The generated trigger

The per-table compute/validate trigger evaluates every rule inside an
exception handler so that a broken rule reports which rule broke, and so
that every class 99 error names the entity that scopes it.

- Class 90 passes through untouched: its identity is the code alone.
- Class 99 is re-raised with the same SQLSTATE, message and DETAIL, and with
  `entity` (the table name of the entity whose rule was evaluating) and
  `rule` (that rule's code) merged into the hint object. This covers both a
  failing validation rule and a `throw_error` inside a rule's logic.
- Any other error is re-raised with the original SQLSTATE, message, DETAIL
  and HINT, with `entity` and `rule` (the rule code) or `field` (the computed
  field name) added to the hint object, a hint that was not a JSON object
  being wrapped as `{"hint": text}` first. That path carries both
  PostgreSQL's own errors and our 42501 / 42P01 sites; the latter keep their
  `hint.code` because the hint object is merged, not replaced.

A write can cascade: a row trigger on one entity writes a second entity
(audit rows, queue events, RACI bookkeeping), whose own compute/validate
trigger may fail. Every trigger on the way out merges its keys, and the merge
keeps a key that is already present, so `entity` and `rule` always name the
innermost entity, the one whose rule actually failed. `set_record` is not
such a case: it reads a record into the rule's data and writes nothing.

The message is never prefixed, because a prefix is an interpolation. `entity`
is the table identifier, not the label: it is a translation key and must be
stable and language-neutral.

### Runtime errors the evaluator passes through

| Source | SQLSTATE | Note |
|---|---|---|
| `require_permission` | 42501, `hint.code` 901xx | the permission error, as raised by rbac |
| `$user_id` without claims | 42501, `hint.code` 900xx | `rbac.uid`, called by `jl_request_context` |
| `$user_id` for a subject with no `users` row | 42501, `hint.code` 900xx | `rbac.user_id`; the client has not called `get_userinfo` yet |
| unknown operator | 909xx | `Unrecognized operation: ${op}` |
| `is_match` with a malformed pattern | 2201B | PostgreSQL's own message |
| `%` with a zero divisor | 22012 | PostgreSQL's own message; `/` returns null instead |

Bad numeric or date strings never raise; the coercion swallows the whole 22xxx
class and yields 0.

## Errors we do not raise

Foreign key, unique and not-null violations, CHECK constraints on our own
tables, row-level security refusals, the vendored pgmq messages and
PostgREST's own `PGRST` codes carry no JSON hint and English text with values
inside. They localize by SQLSTATE, and where PostgreSQL names the constraint
in the message, by constraint name parsed out of `message`; "Constraint
names" at the end of this page lists the ones that exist. Vendored pgmq text
is upstream text and is never edited.

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
   permission, 404 for an unknown entity, 400 for every other refusal.
   Generic middleware may key on them; localization keys on the code.

## Security

Everything in HINT is visible to the caller. A parameter must never carry data
from a row or a column the caller cannot read; `docs/authz-spec.md` invariant
I1 counts error messages as a read path. Names of things the caller asked for
(the permission, the table, the field) are fine; contents of other rows are
not.

## Exemptions

Errors raised while installing or operating the database are not
client-reachable and keep RAISE's ordinary form and their existing SQLSTATE,
and get no catalog number: the BYPASSRLS check in `0050_rbac_rls.sql`, the
pgmq conflict check in `0160_pgmq.sql`, and the preflight and `migrate()`
errors of the extension build in `packages/cli/commands/extension.ts`, which
the extension archive's README already lists for the operator who hits one.
The administrator lockout guard and the User-role guard in
`0050_rbac_rls.sql` are not exempt: a client reaches both by editing
`user_roles` or `users`, so they are 901xx errors like every other refusal.

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
| `90002` | `42501` | `Authentication required: JWT role claim must be authenticated` | - | - | The token's `role` claim is something other than `authenticated`. |
| `90003` | `42501` | `Authentication required: JWT sub claim is missing` | - | - | The token carries no subject, so there is nobody to be. |
| `90004` | `42501` | `Authentication required: JWT audience claim is missing (expected ${expected})` | - | `expected` | `_settings.jwt_aud` is set and the token has no `aud`. |
| `90005` | `42501` | `Authentication required: JWT audience does not match (expected ${expected}, got ${actual})` | - | `expected`, `actual` | The token was minted for a different audience. |
| `90006` | `42501` | `User not found: ${external_id}. Client must call get_userinfo() on first login to create user record.` | - | `external_id` | The claims are well formed but no `users` row matches yet. |
| `90007` | `90007` | `external_id cannot be null or empty` | - | - | An argument guard, not a refusal, so it answers 400. |
| `90008` | `90008` | `Failed to create or find user: external_id = ${external_id}` | - | `external_id` | `get_userinfo` upserted the user and got nothing back. |
| `90009` | `90009` | `User not found in users table: user_id = ${user_id}` | - | `user_id` | As 90008, one step later. |
| `90010` | `90010` | `Unexpected error: unable to build user info JSON for user_id = ${user_id}` | - | `user_id` | As 90008, at the end of `get_userinfo`. |

### 901xx - permissions, roles and lockout guards

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90101` | `42501` | `Permission denied: ${permission} required` | `Ask an administrator to grant ${permission}` | `permission` | `rbac.require_permission`, the refusal every gated call makes. |
| `90102` | `42501` | `Permission denied: one of (${permissions}) required` | - | `permissions` | `rbac.require_any_permission`. The list is one string, not an array: a parameter is a value in a sentence. |
| `90103` | `42501` | `Cannot delete role 1 (User) from user. All users must have the User role.` | - | - | Reachable by editing `user_roles`, so it is a refusal like any other. |
| `90104` | `42501` | `This would leave the system without an enabled Administrator` | `Grant the Administrator role to another enabled user first. A direct superuser connection is exempt from this check.` | - | The lockout guard. |
| `90105` | `42501` | `Permission denied for queue ${queue}` | - | `queue` | Hides whether the queue exists from a caller who may not read it. |

### 902xx - data dictionary: entities and fields

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90201` | `90201` | `catalog_entity_code is write-once: it cannot be changed once set` | - | - | Platform rule on `entities`. A catalog code identifies the row for good once it is set. |
| `90202` | `90202` | `catalog_field_code is write-once: it cannot be changed once set` | - | - | Platform rule on `fields`, as 90201. |
| `90203` | `90203` | `roles.origin is set on INSERT and cannot be changed` | - | - | Platform rule on `roles`. Provenance is decided when the role is created. |
| `90204` | `90204` | `system role slugs cannot be changed after creation` | - | - | Platform rule on `roles`. A system role's slug is referenced by name elsewhere. |
| `90205` | `90205` | `permission_hierarchy.origin is set on INSERT and cannot be changed` | - | - | Platform rule on `permission_hierarchy`, as 90203. |
| `90210` | `90210` | `Cannot add permission hierarchy: would create a cycle. Permission ${including} cannot be both ancestor and descendant of permission ${included}` | - | `including`, `included` | Permission inclusion has to stay a DAG. |
| `90211` | `90211` | `Cannot add permission hierarchy: maximum depth of 11 levels would be exceeded. Current depth would be ${depth}` | - | `depth` | The depth bound the resolver is written against. |
| `90212` | `90212` | `Referenced table ${table} not found in entities` | - | `table` | A `reference` or `parent` field naming an entity that does not exist. Raised from three sites. |
| `90213` | `90213` | `catalog_entity_aliases is append-only: existing alias elements cannot be removed or rewritten` | - | - | A merge record is history; it only grows. |
| `90214` | `90214` | `ctype is system-managed and cannot be changed on field ${field_name}` | - | `field_name` | The marker that makes a column a core column. |
| `90215` | `90215` | `Table ${table} already has a primary key` | - | `table` | One `is_pk` field per entity. |
| `90217` | `90217` | `Cannot delete core system field ${field_name}. Core fields (ctype id/label/audit/core) cannot be deleted.` | - | `field_name` | |
| `90218` | `90218` | `Cannot rename core system field ${field_name}` | - | `field_name` | |
| `90219` | `90219` | `Cannot change format of core system field ${field_name}` | - | `field_name` | |
| `90220` | `90220` | `Cannot change default value of core system field ${field_name}` | - | `field_name` | |
| `90221` | `90221` | `Cannot change table_name of a field` | - | - | Except as the cascade of a table rename. |
| `90222` | `90222` | `Cannot change primary key status of existing field` | - | - | |
| `90223` | `90223` | `Cannot change format of field ${field_name} from ${old_format} to ${new_format} because it would require changing the column type from ${old_type} to ${new_type}. Drop and recreate the field instead.` | - | `field_name`, `old_format`, `new_format`, `old_type`, `new_type` | Two sites, one row: the rename guard and the update guard. |
| `90224` | `90224` | `Field name ${field_name} is reserved: names starting with "_" are reserved for generated/system columns (e.g. _label)` | - | `field_name` | The prefix is reserved; the `_label` suffix is not. |
| `90225` | `90225` | `label_parent cannot be set on junction entity ${table}` | - | `table` | |
| `90226` | `90226` | `label_parent ${label_parent} is not a field of entity ${table}` | - | `label_parent`, `table` | |
| `90227` | `90227` | `label_parent ${label_parent} on ${table} must name a reference/parent field` | - | `label_parent`, `table` | |
| `90228` | `90228` | `label_parent ${label_parent} must not be self-referential (the identity spine must be acyclic)` | - | `label_parent` | |
| `90229` | `90229` | `label_parent ${label_parent} must not target junction entity ${table}` | - | `label_parent`, `table` | |
| `90230` | `90230` | `label_parent on ${table} via ${label_parent} would create a cycle in the identity spine` | - | `table`, `label_parent` | |

### 903xx - schema and record RPCs

Reserved. `get_schema`, `build_schema_for_table` and the record RPCs answer
42P01 both for a table that does not exist and for one the caller may not see,
and carry no `hint.code`. Those sites are deliberately left as they are, so the
block has no rows yet.

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|

### 904xx - api keys

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90401` | `90401` | `User with id ${user_id} does not exist` | - | `user_id` | Minting or listing keys for a user that is not there. |
| `90402` | `90402` | `API key not found` | - | - | |

### 905xx - queues and topics

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90501` | `90501` | `Cannot change queue_name after creation` | - | - | The name is the key pgmq stores under. |
| `90502` | `90502` | `Cannot change table_name on a queue table event` | - | - | Except as the cascade of a table rename. |
| `90503` | `90503` | `Parent queue not found for queue_id ${queue_id}` | - | `queue_id` | |
| `90504` | `90504` | `Queue ${queue} is not registered` | - | `queue` | The answer an administrator gets; everyone else gets 90105. |

### 906xx - audit

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90601` | `90601` | `Table ${table} cannot be audited because it has no primary key` | - | `table` | An audit row is keyed by the row it describes. |

### 907xx - modules and slugs

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90701` | `90701` | `catalog_module_code is write-once: it cannot be changed once set` | - | - | Platform rule on `modules`, as 90201. |
| `90702` | `90702` | `module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, '-' and '_'` | - | - | Platform rule on `modules`. The slug appears in URLs and permission names. |

### 908xx - RACI

Reserved. The RACI gates refuse through validation rules, which carry codes of
their own, so nothing raises from this block yet.

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|

### 909xx - JsonLogic runtime and rule definitions

| Code | Wire | Message | Hint | Parameters | Description |
|---|---|---|---|---|---|
| `90900` | `90900` | `computed_fields[${index}] on ${table} is missing required "name"` | - | `index`, `table` | Raised while the entity is saved, by the trigger builder. |
| `90901` | `90901` | `computed_fields[${index}] on ${table} is missing required "jsonlogic"` | - | `index`, `table` | As 90900. |
| `90902` | `90902` | `validation_rules[${index}] on ${table} is missing required "code"` | - | `index`, `table` | As 90900. |
| `90903` | `90903` | `validation_rules[${index}] on ${table} is missing required "message"` | - | `index`, `table` | As 90900. |
| `90904` | `90904` | `validation_rules[${index}] on ${table} is missing required "jsonlogic"` | - | `index`, `table` | As 90900. |
| `90905` | `90905` | `validation_rules[${index}] on ${table} must carry a class 99 code, not ${rule_code}` | - | `index`, `table`, `rule_code` | The rule's code is the SQLSTATE its failure raises, so it has to be one. |
| `90906` | `90906` | `validation_rules[${index}] on ${table} is a platform rule, so its code must be a class 90 number, not ${rule_code}` | - | `index`, `table`, `rule_code` | As 90905, for a rule core itself ships. |
| `90910` | `90910` | `Unrecognized operation: ${op}` | - | `op` | The rule names an operator the evaluator does not implement. |
| `90911` | `90911` | `throw_error code must be a class 99 number, not ${code_given}` | - | `code_given` | Class 99 is the space reserved for whoever writes the rule. |
| `90912` | `90912` | `throw_error parameter ${name} uses a reserved name` | - | `name` | `hint`, `code`, `entity`, `rule` and `field` belong to the contract. |
| `90913` | `90913` | `throw_error parameter ${name} must be a scalar value, not ${json_type}` | - | `name`, `json_type` | A parameter is a value in a sentence, never a structure. |
| `90914` | `90914` | `throw_error parameters must be a flat list of name and value pairs` | - | - | The list is flat because JsonLogic reads a single-key object as an operator call. |

## Constraint names

A constraint violation is PostgreSQL's error, not ours: the write goes straight
at the table, the row trigger runs before the constraint is evaluated, and
there is no code of ours between the client and the refusal to give it a
number or a JSON hint. What comes back is 23514, 23505 or 23503 with
PostgreSQL's own sentence, and the only stable token in that sentence is the
constraint's name. These are the names our own tables declare and the names we
keep stable, so a translation keyed on one of them survives a rewrite of the
expression behind it. Names PostgreSQL generates itself (`users_email_key`,
`entities_pkey`) are not listed - they are not ours to keep.

| Constraint | Table | Kind | Meaning |
|---|---|---|---|
| `catalog_entity_aliases_is_array` | `entities` | CHECK | `catalog_entity_aliases` must be a JSON array |
| `computed_fields_is_array` | `entities` | CHECK | `computed_fields` must be a JSON array |
| `plural_matches_table_name` | `entities` | CHECK | `plural` must equal `table_name` |
| `select_rule_is_object` | `entities` | CHECK | `select_rule` must be a JSON object |
| `valid_cube_mode` | `entities` | CHECK | `cube_mode` is `disabled` or `auto` |
| `valid_edit_mode` | `entities` | CHECK | `edit_mode` is `auto`, `sidebar`, `modal` or `page` |
| `valid_entity_type` | `entities` | CHECK | `entity_type` is one of the six classifications |
| `valid_id_column` | `entities` | CHECK | `id_column` is a lowercase identifier |
| `valid_label_column` | `entities` | CHECK | `label_column` is a lowercase identifier |
| `valid_label_parent` | `entities` | CHECK | `label_parent` is empty or a lowercase identifier |
| `valid_order_column` | `entities` | CHECK | `order_column` is empty or a lowercase identifier |
| `valid_table_name` | `entities` | CHECK | `table_name` is a lowercase identifier |
| `validation_rules_is_array` | `entities` | CHECK | `validation_rules` must be a JSON array |
| `fields_table_field_unique` | `fields` | UNIQUE | one row per (`table_name`, `field_name`) |
| `fields_table_name_fkey` | `fields` | FOREIGN KEY | `table_name` must name an entity |
| `reference_requires_table` | `fields` | CHECK | a `reference` or `parent` field must name a `reference_table` |
| `reference_table_requires_reference_format` | `fields` | CHECK | `reference_table` is only allowed on a `reference` or `parent` field |
| `valid_ctype` | `fields` | CHECK | `ctype` is empty, `id`, `label`, `audit` or `core` |
| `valid_cube_type` | `fields` | CHECK | `cube_type` is `auto`, `dimension`, `measure` or `disabled` |
| `valid_default_value` | `fields` | CHECK | `default_value` is at most 200 characters and carries no semicolon, control character or SQL comment |
| `valid_field_name` | `fields` | CHECK | `field_name` is a lowercase identifier |
| `valid_format` | `fields` | CHECK | `format` is one of the supported field formats |
| `valid_input_type` | `fields` | CHECK | `input_type` is `default`, `required`, `readonly`, `disabled` or `hidden` |
| `valid_precision` | `fields` | CHECK | `precision` is between 0 and 18 |
| `valid_reference_delete_mode` | `fields` | CHECK | `reference_delete_mode` is empty, `restrict`, `clear` or `cascade` |
| `valid_width` | `fields` | CHECK | `width` is `default`, `s`, `m` or `w` |
| `modules_module_slug_key` | `modules` | UNIQUE | `module_slug` is unique |
| `modules_view_permission_fkey` | `modules` | FOREIGN KEY | `view_permission` must name a permission |
| `valid_access_scope` | `modules` | CHECK | `access_scope` is `basic` or `full` |
| `valid_module_type` | `modules` | CHECK | `module_type` is `domain` or `master` |
| `no_self_reference` | `permission_hierarchy` | CHECK | a permission cannot include itself |
| `valid_permission_hierarchy_origin` | `permission_hierarchy` | CHECK | `origin` is `system`, `model`, `model_master` or `user` |
| `permission_name_shape` | `permissions` | CHECK | `permission_name` is colon-separated lowercase segments |
| `process_gates_process_entity_gate_state_key` | `process_gates` | UNIQUE | one gate per (`process_id`, `entity`, `gate_kind`, `to_state`) |
| `valid_process_key` | `processes` | CHECK | `process_key` is empty or a lowercase identifier |
| `raci_assignments_process_role_raci_key` | `raci_assignments` | UNIQUE | one assignment per (`process_id`, `role_id`, `raci`) |
| `valid_role_origin` | `roles` | CHECK | `origin` is `system`, `model`, `model_master` or `user` |
| `valid_role_slug` | `roles` | CHECK | `slug` is empty or lowercase letters, digits and underscores |
| `users_external_id_not_empty` | `users` | CHECK | `external_id` cannot be blank |

