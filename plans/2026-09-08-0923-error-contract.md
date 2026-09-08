# Error contract and catalog

The contract itself is `docs/error-contract.md`, numbers and constraint names
included; this file is only the order of work and what proves each step.
Deleted when the last step lands.

## Why

Clients cannot localize our errors: 118 `RAISE EXCEPTION` sites in
`apps/_core/migrations` (31 of them vendored pgmq), about 83 templates outside
pgmq, 60 of them with values interpolated into English text, and the SQLSTATE
as the only identity (44 sites set one, the rest fall to P0001), shared with
PostgreSQL's own errors. The generated compute/validate trigger in
`0180_computed_validation.sql` re-raises every evaluator error as P0001 with a
text prefix, so nothing a rule raises keeps its code. Structured payloads
exist in two places, both in DETAIL (`cache_current` in
`0080_public_functions.sql`, `rule code:` in `0180`), and three errors carry
plain-text HINTs.

## Decisions (user, 2026-09-08)

- Class 90 is ours: every client-reachable error our code raises has a
  `90xxx` catalog number, in blocks of one hundred per domain, and that
  number is the identity. The authentication and permission families raise
  42501 and the unknown-entity codes raise 42P01, carrying the number as
  `hint.code`, so PostgREST keeps answering 401, 403 and 404; every other
  code is raised as itself (HTTP 400). Class 99 is the rule author's:
  `throw_error` and failing validation rules raise `99xxx`. No other
  standard code is ever raised by us.
- `validation_rules[].code` becomes the SQLSTATE of the failure: 99xxx for
  custom rules, which includes every `nwind` rule, and a catalog 90xxx code
  for the platform rules core ships in `0060` and `0200`
  (`"source_module": "platform"`, a naming convention, not a trust boundary).
  Non-matching codes are rejected on save.
- The catalog is hand-written, lives in `docs/error-contract.md` next to the
  rules, and is a reference for whoever writes a translation or the next
  error. No catalog table, no lint, no raise helper.
- The table 404 answer in `0080_public_functions.sql` is intentional and out
  of scope: its two branches keep the messages they have, and `0341` is not
  touched.
- Placeholders are `${name}`, because PostgreSQL's own messages contain braces.

## Order of work

| Row | Step | What | Proof |
|---|---|---|---|
| E2 | 1 | `docs/error-contract.md` | landed |
| E1 | 2 | `0180`: class 90 passes through; every other error keeps its SQLSTATE, message, DETAIL and HINT and gains `entity` plus `rule` or `field` in the hint object, no message prefix | landed: `0320` asserts the message is unprefixed, the keys are added, and a cascaded write names the innermost entity |
| E3 | 3 | the ten domain blocks and the constraint-name table as sections of `docs/error-contract.md` | landed: headings exist, client rows empty, 39 constraints listed |
| E4 | 4 | landed.  `0180`: a failing rule raises `rule.code` (99xxx) with `{"hint", "entity", "rule"}`; the builder validates code shape and placeholder grammar and raises 909xx when they are wrong; the seven platform rules in `0060` and `0200` get catalog 90xxx codes | `0320` and `0425` rewritten with class 99 codes; `0340` asserts the platform rules' codes; an invalid code is rejected on entity save |
| E5 | 5 | landed.  `0210`: `throw_error` three-argument form, default `99000`, code and reserved-name validation; a parameter keeps the jsonb type its expression evaluated to, an object or array value is a 909xx error; `Unrecognized operation` under a 909xx code | `0016` covers every form and asserts `jsonb_typeof` of a number, a boolean and a string parameter |
| E6 | 6 | landed, 0080 excepted.  convert every client-reachable site to its 90xxx code, file by file (0030 including the no-`users`-row 28000 in `rbac.user_id`, 0050, 0060, 0070 where 0140 and 0145 do not replace it, 0080 except the 404 branches, 0110, 0140, 0145, 0150, 0170, 0190, 0210), writing each row into the contract as it lands; `cache_current` moves from DETAIL to HINT; superseded copies untouched | full test run green, with the existing tests updated where a converted message or code breaks them |
| E7 | 7 | landed.  `deno task bundle-sql`; `deno task extension <version>` | bundles and the extension SQL regenerated from the edited migrations |

3 before 6 so a converted site has a row to write into; 4 and 5 before 6 so
the rule and `throw_error` paths are settled before the sites move.

## What is left

- The table 404 answer in `0080_public_functions.sql` is out of scope by
  decision, so its six sites keep 42P01 with no catalog number and the 903xx
  block has no rows. `cache_current` stays in DETAIL for the same reason.
- The wire check below has not been run: it needs the Data API, and the
  pgdocker harness has no HTTP front.
- The extension install path (`pgdocker/pg-ext-retest.sh`) has not been run;
  only the migrate path has.

## Verification

```
deno task retest --confirm
deno task lint-sql --database-url ...
deno task bundle-sql
deno task extension <version>
```

Wire check against the Neon project the CLI tests run on (the `DATABASE_URL`
of `.env.local`), through its Data API, which is PostgREST; the pgdocker
harness has no HTTP front and cannot show a status: a `throw_error` from a
rule returns 400 with a 99xxx `code` and a JSON `hint`; a permission failure
returns 403 (401 without a token) with 42501 and its 901xx `hint.code`; an
expired token still returns PostgREST's own 401.

## Follow-ups, not owned here

- Where translations for admin-defined codes live (client bundle or a
  per-module table).
