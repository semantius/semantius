# Error contract

**Status:** draft, 2026-09-08. Every error that can reach a client through
PostgREST follows this contract. `docs/error-catalog.md` is the list of the
errors themselves; this file is the rules the list and the code obey.
`deno task lint-errors` enforces both.

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
  "platform"` in `0060_dd_schema.sql`, is not custom: it fails with a class 90
  catalog code like every other error of ours.

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
| 900xx authentication, 901xx permissions | 42501 insufficient_privilege | 401 without a valid token, 403 with one | `hint.code` |
| 903xx unknown entity or table | 42P01 undefined_table | 404 | `hint.code` |
| every other 90xxx code | the number itself | 400 | `code` |
| 99xxx | the number itself | 400 | `code`, scoped by entity |

42501 and 42P01 are the only standard codes we ever raise, and only paired
with a `hint.code` from those blocks. PostgreSQL raises the same two codes
itself, for a row-level security refusal, a missing grant or a missing
relation; those carry no `hint.code`, which is how a client tells them apart.

The 404 is also the existence-hiding answer: `get_schema`,
`build_schema_for_table` and the record RPCs raise the same 903xx code, with
the same message and the same hint, for a table that does not exist and for
one the caller may not see, so the response never says which. The two
branches are separate sites of one catalog row, and the catalog row is what
keeps them identical.

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
an ISO 8601 string. The two reserved keys are strings: `code` is a SQLSTATE,
not a quantity, and `hint` is a template.

In PL/pgSQL this means passing the typed value to `jsonb_build_object`,
which maps integer, numeric and boolean to their JSON types by itself, and
never its `::text` or a `format()` result. The lint fails a site that casts a
parameter value to text, and the contract test asserts the JSON type of every
parameter it exercises.

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
a bare `%` makes RAISE fail with "too few parameters" and is a lint failure.
The one place where admin-supplied text becomes a message, the generated
validation trigger, passes the text as the argument of a `'%'` format string
instead, so rule authors do not escape anything.

## The catalog

`docs/error-catalog.md` has one row per catalog number with its wire SQLSTATE
(the number itself, 42501 or 42P01), message template, hint template,
parameter names, reach and a one-line description. Reach is
`client` for errors that follow this contract and `install` for the exempt
errors listed below, which the page still lists with their existing SQLSTATE
so an operator can find them. The page also lists the named constraints of
our tables, because a constraint name is the only stable key a PostgreSQL
constraint error carries.

The page is maintained by hand. `deno task lint-errors` reads it and every
migration and fails when a client-reachable RAISE has neither a class 90 code
nor 42501 / 42P01 paired with the `hint.code` the page assigns to that
SQLSTATE, carries a `code` key although its ERRCODE is already the number,
uses a message other than the catalog's template for that code, uses a
placeholder that is not a parameter, uses `hint` or `code` as a parameter,
casts a parameter value to text, contains a bare `%`, or raises a code the
page does not list; when a `client`
row is never raised; and when a listed constraint name is declared by no
migration.

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
unless the rule is a platform rule, whose code must be class 90. The lint
checks that every platform rule's code is a catalog row; the save-time check
cannot, because the catalog is a document, not a table.

### The generated trigger

The per-table compute/validate trigger evaluates every rule inside an
exception handler so that a broken rule reports which rule broke, and so
that every class 99 error names the entity that scopes it.

- Class 90 passes through untouched: its identity is the code alone.
- Class 99 is re-raised with the same SQLSTATE, message and DETAIL, and with
  `entity` (the table name of the entity whose rule was evaluating) and
  `rule` (that rule's code) merged into the hint object. This covers both a
  failing validation rule and a `throw_error` inside a rule's logic. In a
  nested write, where a rule on one entity calls `set_record` on another,
  the inner trigger stamps the error first and the outer one leaves class 99
  alone, so `entity` always names the entity whose rule failed.
- Any other error is re-raised with the original SQLSTATE, message, DETAIL
  and HINT, with `entity` and `rule` (the rule code) or `field` (the computed
  field name) added to the hint object, a hint that was not a JSON object
  being wrapped as `{"hint": text}` first. That path carries both
  PostgreSQL's own errors and our 42501 / 42P01 sites; the latter keep their
  `hint.code` because the hint object is merged, not replaced.

The message is never prefixed, because a prefix is an interpolation. `entity`
is the table identifier, not the label: it is a translation key and must be
stable and language-neutral.

### Runtime errors the evaluator passes through

| Source | SQLSTATE | Note |
|---|---|---|
| `require_permission` | 42501, `hint.code` 901xx | the permission error, as raised by rbac |
| `$user_id`, `$today`, `$now` without claims | 42501, `hint.code` 900xx | from `jl_request_context` |
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
in the message, by constraint name parsed out of `message`; the catalog page
lists the names that exist. Vendored pgmq text is upstream text and is never
edited.

## Client rules

1. A `hint` that starts with `{` is parsed as a JSON object. Any other hint
   is suggestion text, PostgreSQL's own or an install-time error's, and is
   shown as-is, the same way the `hint` key inside the object is.
2. The translation key is `code` when it is class 90 or 99, else `hint.code`
   when present, else the SQLSTATE. Class 99 keys are scoped by
   `hint.entity`, which the trigger always supplies. A
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
not. The existence of a table the caller may not see is also data the caller
cannot read: the missing-table and hidden-table branches of a 903xx site must
raise byte-identical message, hint and detail, see "HTTP status".

## Exemptions

Errors raised while installing or operating the database are not
client-reachable and keep RAISE's ordinary form and their existing SQLSTATE,
listed in the catalog with reach `install`: the BYPASSRLS check in
`0050_rbac_rls.sql`, the pgmq conflict check in `0160_pgmq.sql`, and the
preflight and `migrate()` errors of the extension build in
`packages/cli/commands/extension.ts`, whose README "Errors" table must list
the same rows. The administrator lockout guard and the User-role guard in
`0050_rbac_rls.sql` are not exempt: a client reaches both by editing
`user_roles` or `users`, so they are 901xx errors like every other refusal.
