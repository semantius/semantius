# Semantius Platform Update — Entity-level Computed Fields & Validation Rules

**Status:** Proposed
**Scope:** Let every entity in a Semantius module carry its own per-record derivation and validation logic, expressed as JsonLogic, evaluated by the platform on every write.

---

## 1. Motivation

Today, derived values (e.g. RICE scores) and record-level invariants (e.g. "release_id only allowed once a feature is committed") are documented in semantic-model markdown but not enforced anywhere. Callers and seed scripts re-implement the same rules — inconsistently, and silently drifting from the spec.

This update lets a semantic model carry that logic alongside its fields. The platform applies it on every write. No service-side code per model.

## 2. Desired outcome

Every entity exposes two new optional properties:

| Property           | Type    | Default | Purpose                                                                                  |
|--------------------|---------|---------|------------------------------------------------------------------------------------------|
| `computed_fields`  | `array` | `[]`    | Ordered list of fields whose values are derived from the same record via JsonLogic.       |
| `validation_rules` | `array` | `[]`    | Ordered list of record-level invariants that must hold for a write to succeed.            |

Both are part of the entity definition. They are read, written, and audited the same way as `label_column`, `module_id`, etc. They are returned by `read_entity` and can be set on `create_entity` / `update_entity`.

## 3. `computed_fields` element shape

```json
{
  "name":        "rice_score",
  "jsonlogic":   { /* JsonLogic expression */ },
  "description": "Optional human note"
}
```

- `name` (string, required) — must reference an existing scalar field on the same entity. The computed result is written into this field.
- `jsonlogic` (object, required) — evaluated against the record being written.
- `description` (string, optional) — human note for future readers and agents.

### Sample value (real, complete array)

```json
[
  {
    "name": "rice_score",
    "description": "(reach × impact × confidence) / effort, null when effort is missing or 0.",
    "jsonlogic": {
      "if": [
        { "and": [
          { "!=": [{ "var": "effort_score" }, null] },
          { ">":  [{ "var": "effort_score" }, 0] }
        ]},
        { "/": [
          { "*": [
            { "var": "reach_score" },
            { "var": "impact_score" },
            { "var": "confidence_score" }
          ]},
          { "var": "effort_score" }
        ]},
        null
      ]
    }
  }
]
```

## 4. `validation_rules` element shape

```json
{
  "code":        "effort_must_be_positive",
  "message":     "Default user-facing message.",
  "jsonlogic":   { /* JsonLogic expression */ },
  "description": "Optional human note"
}
```

- `code` (string, required) — snake_case, unique within the entity. Stable identifier for UI / i18n binding.
- `message` (string, required) — default English text returned to the caller on failure.
- `jsonlogic` (object, required) — must evaluate truthy for the record to be valid.
- `description` (string, optional) — human note explaining *why* this rule exists.

### Sample value (real, complete array)

```json
[
  {
    "code": "release_only_when_committed",
    "message": "A release can only be assigned once the feature is planned, in_progress, or shipped.",
    "description": "Mirrors §3.2 of the product_roadmap semantic model.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "release_id" }, null] },
        { "in": [
          { "var": "feature_status" },
          ["planned", "in_progress", "shipped"]
        ]}
      ]
    }
  }
]
```

## 5. Evaluation semantics

On every `INSERT` and `UPDATE` against an entity:

1. **Compute pass.** Iterate `computed_fields` in array order. For each entry, evaluate `jsonlogic` against the merged record (caller payload + previously-computed values from earlier entries). Write the result into the field named by `name`. If the expression throws or yields `undefined`, set the field to `null`. Any caller-supplied value for a computed field is silently overwritten.
2. **Validate pass.** Iterate `validation_rules` in array order. For each entry, evaluate `jsonlogic` against the post-compute record. A rule passes when the result is truthy.
3. **Aggregation.** Collect *all* failing rules (do not short-circuit). If any failed, the write is rejected and the platform returns a structured error of the form:
   ```json
   { "errors": [ { "code": "…", "message": "…" }, … ] }
   ```
4. Compute and validate run inside the same transaction as the write — either the record lands with all derivations applied and all rules passing, or nothing changes.

## 6. Reserved variables

JsonLogic expressions may read these injected variables via `{"var": "$name"}`:

| Var        | Type        | Meaning                                                  |
|------------|-------------|----------------------------------------------------------|
| `$today`   | `date`      | Server date at evaluation time.                          |
| `$now`     | `date-time` | Server timestamp at evaluation time.                     |
| `$user_id` | `uuid`      | Authenticated user performing the write (null = system). |

No other ambient state. Cross-row lookups, aggregates, and FK traversal are out of scope — those belong in cube and views.

## 7. Deploy-time guarantees

When `create_entity` / `update_entity` accepts these properties, the platform must:

- Confirm both values are arrays (objects of any other shape are rejected).
- Confirm every `computed_fields[].name` resolves to an existing field on the entity.
- Confirm every `validation_rules[].code` is unique within the entity.
- Parse every `jsonlogic` expression and reject the request if any is malformed.

Deploys fail fast with an error that points at the offending entry index, so authoring agents can correct in place.

## 8. MCP / CLI surface

`create_entity` and `update_entity` accept two new optional parameters with the shapes above:

- `computed_fields: array<{ name, jsonlogic, description? }>`
- `validation_rules: array<{ code, message, jsonlogic, description? }>`

Both default to `[]`. `read_entity` returns them as-is. No other tool surface changes.

## 9. Out of scope (deferred)

- Per-field computed expressions (kept entity-level for now).
- Cross-entity / aggregate validation.
- Per-locale messages — `message` stays a single string; i18n binds via `code`.
- Conditional rule activation (e.g. "only run on insert"). Can add `when: "insert"|"update"|"both"` later if real cases appear.
