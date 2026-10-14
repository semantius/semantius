/**
 * Tests of the drizzle generator's column mapping for the rating, color and
 * icon formats, and of enum entries that carry a description, color and icon.
 *
 *   deno test -A packages/cli/commands/drizzlegen_test.ts
 */

import {
  baseBuilder,
  defaultModifier,
  effectiveEnumValues,
  type EnumEntry,
  type FieldRecord,
} from "./drizzlegen.ts";

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
    precision: 2,
    reference_table: "",
    reference_delete_mode: "",
    ...extra,
  };
}

Deno.test("drizzlegen: rating is an integer column", () => {
  const { fn } = baseBuilder(field("rating"), new Map());
  assert(fn === "integer", `rating should build integer, got ${fn}`);
});

Deno.test("drizzlegen: a rating default is a number", () => {
  const modifier = defaultModifier(field("rating", { default_value: "3" }));
  assert(modifier === ".default(3)", `unexpected rating default: ${modifier}`);
});

Deno.test("drizzlegen: color and icon are text columns", () => {
  for (const format of ["color", "icon"]) {
    const { fn } = baseBuilder(field(format), new Map());
    assert(fn === "text", `${format} should build text, got ${fn}`);
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

Deno.test("drizzlegen: enum entries with description, color and icon yield only their values", () => {
  const values = effectiveEnumValues("required", entries);
  assert(
    JSON.stringify(values) === JSON.stringify(["on_hold", "active"]),
    `expected the values only, got ${JSON.stringify(values)}`,
  );
});

Deno.test("drizzlegen: an enum column with description, color and icon is typed by its values", () => {
  const { args } = baseBuilder(
    field("enum", { input_type: "required", enum_values: entries }),
    new Map(),
  );
  assert(
    args === '"f", { enum: ["on_hold", "active"] }',
    `unexpected enum args: ${args}`,
  );
});
