# Error contract and catalog

The contract itself is `docs/error-contract.md`; this file is only the order
of work and what proves each step. Deleted when the last step lands. Draft:
nothing below is approved for implementation yet.

## Why

Clients cannot localize our errors: 120 `RAISE EXCEPTION` sites in
`apps/_core/migrations` (32 of them vendored pgmq), about 83 templates outside
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
- `validation_rules[].code` becomes the 99xxx SQLSTATE of the failure.
  Non-matching codes are rejected on save.
- The catalog is the hand-written `docs/error-catalog.md` plus a lint that
  fails the build on drift. No catalog table, no raise helper.
- Placeholders are `${name}`, because PostgreSQL's own messages contain braces.

## Order of work

| Row | Step | What | Proof |
|---|---|---|---|
| E2 | 1 | `docs/error-contract.md` | file exists; every later step cites it |
| E1 | 2 | `0180`: pass classes 90 and 99 through; preserve SQLSTATE/DETAIL/HINT of PostgreSQL's own errors and put the rule name into the hint object, no message prefix | pgTAP: throw_error inside a rule arrives with its code and hint; `0320` asserts the hint key |
| E3 | 3 | `packages/cli/commands/lint_errors.ts` + `deno task lint-errors` + `docs/error-catalog.md` skeleton (domain blocks, install rows, constraint names) | lint fails on a synthetic violation, passes on the tree, runs in CI next to `deno task lint` |
| E4 | 4 | `0180`: rule failure raises `rule.code` (99xxx) with `{"hint": ...}`; builder validates code shape and placeholder grammar; builder errors get 909xx codes | `0320` and `0425` rewritten with class 99 codes; invalid code rejected on entity save |
| E5 | 5 | `0210`: `throw_error` three-argument form, default `99000`, code and reserved-name validation; `Unrecognized operation` under a 909xx code | `0016` covers every form |
| E6 | 6 | convert every client-reachable site domain by domain (0030, 0050, 0060, 0080, 0110, 0140, 0145, 0150, 0170, 0190, 0200, 0210, 0270, 0284) to its 90xxx code; `cache_current` moves from DETAIL to HINT; superseded copies untouched | `lint-errors` clean with only the install-time exemptions; full test run green |
| E7 | 7 | `apps/test/tests/0460_test_error_contract.sql` | behavioral checks of shape, wrapper pass-through, throw_error forms |
| E8 | 8 | `deno task bundle-sql`; extension README Errors table equals the install rows; `docs/test-coverage.md` if required | bundles regenerated; README table matches |

Steps 1 and 2 have no dependency on each other; 3 before 6 so the conversion
is checked as it lands; 4 and 5 after 3 for the same reason.

## Verification

```
deno task lint-errors
deno task test
deno task retest --confirm
deno task lint-sql --database-url ...
deno task bundle-sql
deno task extension <version>
```

Wire check through the docker harness with PostgREST: a `throw_error` from a
rule returns 400 with a 99xxx `code` and a JSON `hint`; a permission failure
returns 403 (401 without a token) with 42501 and its 901xx `hint.code`; a
missing entity returns 404 with its 903xx `hint.code`; an expired token still
returns PostgREST's own 401.

## Follow-ups, not owned here

- Translation-key scoping for class 99 codes, which are minted per entity.
- Where translations for admin-defined codes live (client bundle or a
  per-module table).
