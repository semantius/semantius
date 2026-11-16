# postgrest-mcp: the skill text describes the backend as it was

`src/SKILL.md` in `C:\dev\postgrest-mcp` tells agents how the Semantius
backend behaves. The backend (`c:\dev\semantius`, pg_semantius 0.5.0) changed,
and several passages are now false or incomplete. Bring them in line.

- `src/SKILL.md` is the source. `src/generated/instructions.ts` is generated
  from it by `scripts/generate-instructions.js`: regenerate it, do not edit it.
- The authority for what is true is `c:\dev\semantius\extension\CHANGES.md`,
  section `## 0.5.0`, and `c:\dev\semantius\docs\error-contract.md` for every
  error code. Read both before writing.
- Leave the changes uncommitted: the maintainer reviews and commits them.

Line numbers are those of `src/SKILL.md` at `2d9db52`.

## False today

| Lines | The text says | True now |
|---|---|---|
| 184, 733-750 | Only `reference`, `date` and `date-time` allow NULL; `uuid`, `time`, `duration` and `binary` have no default and are NOT NULL | Nullable: `reference`, `date`, `time`, `date-time`, `uuid` (`is_nullable()`). `duration` defaults to 0 seconds, `binary` to empty bytes, both NOT NULL. A required `uuid` refuses a missing value with `90258` |
| 318 | A rename does not rewrite the rules, so a renamed field loses the `computed` marker | A field that a rule names cannot be renamed (`90275`). Renaming a field onto a name a rule writes still gives it the marker |
| 843-854 | `precision` only sets the scale | A changed `precision` alters the column: lowering it rounds the stored values, and any change of scale rewrites the table under an exclusive lock. A rollup over the field keeps its own precision until the rollup is saved again. This belongs in the medium-risk list (660-668) |
| 918 | Deleting a permission is refused only by a foreign key | The permission `admin` can be neither deleted nor renamed (`90104`) |

## Incomplete

- **Renames (145, 670).** A field rename is refused while a rule names the
  field (`90275`): the `computed_fields`, `validation_rules` and `select_rule`
  of the entity, the `input_type_rule` of its fields, and the same rules of
  every `is_a` or `has_a` entity below it. A rename whose new index name
  another table's index carries is refused (`90274`). A table rename rewrites
  the entity argument of `set_record` in other rules, and nothing else.
- **Last Administrator (920-923).** Besides deleting the role, the user or the
  assignment, `90104` also refuses: an update of the last Administrator's
  `user_roles` row to another role or user, and removing or re-pointing the
  `role_permissions` row that grants `admin` to role 2.
- **Users and API keys (922, 931).** Only a holder of `admin` sets or changes
  `external_id` (42501, `hint.code` `90107`), so a `user:manage` holder can
  create agents but not people. The API key of a disabled user does not
  validate. `delete_api_key` answers `90402` for another user's key unless the
  caller holds `admin`.
- **Rules (483-510).** A rule that names an unknown operator is refused when
  it is saved (`90909`), an `input_type_rule` included. A `select_rule` or a
  validation rule has to be one operation (`90919`).
- **Rollup filter (460).** `===` and `!==` between a column and a literal of
  another JSON type are refused (`90265`). Text is ordered by code point. A
  number is compared with a `number` column as written, not rounded.
- **`order_column` (161).** It must not name a column the table already has
  (`90278`).
- **Format change (710).** A field that its entity names as `label_parent`
  cannot leave `reference` or `parent` (`90277`).
- **JsonLogic.** Arithmetic over text that carries no number raises `90920`;
  null and `""` count as 0.

## Missing from "Common Errors" (940-952) and "Naming rules" (954)

| Code | Meaning | Do |
|---|---|---|
| `90271` | A table name starts with `_` | Choose another name |
| `90273` | A table name is longer than 41 bytes | Shorten it |
| `90274` | The field's index name is another table's | Rename the field |
| `90275` | A field a rule names cannot be renamed | Change the rule first |
| `90276` | Table name + field name + 10 bytes exceeds 63 | Shorten the field name |
| `90277` | A `label_parent` field must stay a reference | Clear `label_parent` first |
| `90278` | `order_column` names an existing column | Name a new column |
| `90280` | A rollup function and a rollup guard would share a name | Rename the child entity or the link field |
| `90909` / `90919` | A rule names an unknown operator / is not one operation | Fix the rule |
| `90505` | A queue name is not lower case, or over 47 bytes | Use a lower-case name |

The naming rules line should gain the two table name rules (`_`, 41 bytes)
and the field name length rule.
