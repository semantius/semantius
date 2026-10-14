/**
 * Tests of the kysely generator's column types for the rating, color and icon
 * formats, and of enum entries that carry a description, color and icon.
 *
 *   deno test -A packages/cli/commands/kyselygen_test.ts
 */

import {
  columnType,
  effectiveEnumValues,
  type EnumEntry,
  type FieldRecord,
} from "./kyselygen.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

function field(format: string, extra: Partial<FieldRecord> = {}): FieldRecord {
  return {
    table_name: "items",
    field_name: "f",
    format,
    is_pk: false,
    default_value: "",
    field_order: 1,
    input_type: "default",
    enum_values: null,
    reference_table: "",
    ...extra,
  };
}

Deno.test("kyselygen: rating is a number", () => {
  const type = columnType(field("rating"), new Set(), new Map());
  assert(type === "number", `rating should be number, got ${type}`);
});

Deno.test("kyselygen: color and icon are strings", () => {
  for (const format of ["color", "icon"]) {
    const type = columnType(field(format), new Set(), new Map());
    assert(type === "string", `${format} should be string, got ${type}`);
  }
});

const entries: EnumEntry[] = [
  {
    value: "on_hold",
    label: "On hold",
    description: "Waiting on the customer",
    color: "amber",
    icon: "circle-pause",
  },
  "active",
];

Deno.test("kyselygen: enum entries with description, color and icon yield only their values", () => {
  const values = effectiveEnumValues("required", entries);
  assert(
    JSON.stringify(values) === JSON.stringify(["on_hold", "active"]),
    `expected the values only, got ${JSON.stringify(values)}`,
  );
});

Deno.test("kyselygen: an enum column with description, color and icon is typed by its values", () => {
  const type = columnType(
    field("enum", { input_type: "required", enum_values: entries }),
    new Set(),
    new Map(),
  );
  assert(type === '"on_hold" | "active"', `unexpected enum type: ${type}`);
});
