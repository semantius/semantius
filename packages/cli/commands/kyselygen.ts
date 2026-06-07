/**
 * kyselygen command implementation
 *
 * Generates Kysely type definitions from the Semantius catalog (modules ->
 * entities -> fields) as a SINGLE TypeScript file, following the layout of the
 * standard `kysely-codegen` tool: the helper aliases that are needed, one
 * `export interface <Table>` per table keyed by the *physical* column names
 * (snake_case — Kysely's default, matching the DB and the raw-SQL example), and
 * a final `export interface DB` mapping each physical table name to its
 * interface — the type Kysely is parameterized with (`new Kysely<DB>(…)`).
 *
 * Kysely is purely type-driven: there are no runtime table objects, only types.
 *
 * The type mapping mirrors public.format_to_data_type() / public.is_nullable()
 * (apps/_core/migrations/0070_dd_functions.sql) AND the runtime value decoding
 * the example does via node-postgres' `pg-types` (keyed by column type OID). So
 * the generated types match what a query actually returns: integers are numbers,
 * timestamps are Dates, bigint/numeric come back as strings, jsonb as objects.
 *
 * Columns the database fills (auto-increment PKs, created_at/updated_at, any
 * field with a default) are wrapped in `Generated<T>` so they are optional on
 * insert. `enum` fields become a literal-union type ('a' | 'b' | …), matching
 * the DB's TEXT + CHECK (not a native PG enum) — with '' included for
 * non-required enums, mirroring public.effective_enum_values().
 *
 *   deno task kyselygen                                # -> ./kysely/types.ts
 *   deno task kyselygen --output examples/kysely/src/types.ts
 */

import { Client } from "@postgres";
import { dirname } from "@std/path";

interface ModuleRecord {
  id: number;
}

interface EntityRecord {
  table_name: string;
}

interface FieldRecord {
  table_name: string;
  field_name: string;
  format: string;
  is_pk: boolean;
  default_value: string;
  field_order: number;
  input_type: string;
  enum_values: string[] | null;
}

// ---- identifier / string helpers -------------------------------------------

/** snake_case -> camelCase (e.g. user_roles -> userRoles, created_at -> createdAt). */
function camelCase(s: string): string {
  return s.replace(/_+([a-z0-9])/g, (_, c: string) => c.toUpperCase())
    .replace(/^_+/, "");
}

/** Capitalize the first character. */
function upperFirst(s: string): string {
  return s.length ? s[0].toUpperCase() + s.slice(1) : s;
}

/** snake_case -> PascalCase, the interface name for a table (user_roles -> UserRoles). */
function pascalCase(s: string): string {
  return upperFirst(camelCase(s));
}

/** Quote an object key only if it isn't a bare JS identifier. */
function key(name: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) ? name : JSON.stringify(name);
}

/** Mirror of public.is_nullable(format). */
function isNullable(format: string): boolean {
  return format === "reference" || format === "date" || format === "date-time";
}

/**
 * Mirror of public.effective_enum_values(): the set a TEXT enum column can hold.
 * Non-required enums also accept '' (the implicit empty default), so we add it
 * to keep the generated literal union in sync with the DB CHECK constraint.
 */
function effectiveEnumValues(
  inputType: string,
  values: string[] | null,
): string[] | null {
  if (!values || values.length === 0) return values;
  if (inputType !== "required" && !values.includes("")) return [...values, ""];
  return values;
}

/**
 * True when the database supplies the value, so the column is optional on insert
 * and should be wrapped in Kysely's `Generated<T>`: auto-increment (SERIAL /
 * BIGSERIAL) PKs, the created_at/updated_at bookkeeping columns, and any field
 * carrying a catalog default_value.
 */
function isGenerated(field: FieldRecord): boolean {
  const f = field.format;
  if (field.is_pk && (f === "int32" || f === "integer" || f === "int64")) {
    return true; // SERIAL / BIGSERIAL
  }
  if (field.field_name === "created_at" || field.field_name === "updated_at") {
    return true; // DEFAULT now()
  }
  return (field.default_value ?? "") !== "";
}

// ---- column type mapping ----------------------------------------------------

/** Helper type aliases this generator may emit; only the used ones are written. */
type Alias = "Timestamp" | "Numeric" | "Int8" | "Json";

const ALIAS_DEFS: Record<Exclude<Alias, "Json">, string> = {
  Timestamp:
    "export type Timestamp = ColumnType<Date, Date | string, Date | string>;",
  Numeric:
    "export type Numeric = ColumnType<string, number | string, number | string>;",
  Int8:
    "export type Int8 = ColumnType<string, bigint | number | string, bigint | number | string>;",
};

/** The five mutually-referencing aliases emitted when any jsonb column is present. */
const JSON_DEFS = [
  "export type JsonArray = JsonValue[];",
  "export type JsonObject = { [K in string]?: JsonValue };",
  "export type JsonPrimitive = boolean | number | string | null;",
  "export type JsonValue = JsonArray | JsonObject | JsonPrimitive;",
  "export type Json = JsonValue;",
].join("\n");

/**
 * The Kysely column type for a field. Records any helper aliases it needs into
 * `used`, applies nullability (mirror of is_nullable), and wraps DB-supplied
 * columns in Generated<…>.
 */
function columnType(field: FieldRecord, used: Set<Alias>): string {
  let base: string;
  switch (field.format) {
    case "int32":
    case "integer":
    case "reference":
    case "parent":
    case "float":
    case "double":
      base = "number";
      break;
    case "int64":
      used.add("Int8");
      base = "Int8";
      break;
    case "number":
      used.add("Numeric");
      base = "Numeric";
      break;
    case "uuid":
    case "time":
    case "duration":
      base = "string";
      break;
    case "binary":
    case "byte":
      base = "Buffer"; // pg-types decodes bytea -> Buffer (global, from @types/node)
      break;
    case "date":
    case "date-time":
      used.add("Timestamp");
      base = "Timestamp";
      break;
    case "boolean":
      base = "boolean";
      break;
    case "json":
    case "object":
    case "array":
      used.add("Json");
      base = "Json";
      break;
    case "enum": {
      const vals = effectiveEnumValues(field.input_type, field.enum_values);
      base = vals && vals.length
        ? vals.map((v) => JSON.stringify(v)).join(" | ")
        : "string";
      break;
    }
    default: // text and every other string-like format
      base = "string";
  }

  if (!field.is_pk && isNullable(field.format)) base = `${base} | null`;
  if (isGenerated(field)) base = `Generated<${base}>`;
  return base;
}

export async function kyselygenCommand(
  databaseUrl: string,
  outputFile: string,
): Promise<void> {
  console.log(`Generating Kysely types into ${outputFile} ...`);

  const client = new Client(databaseUrl);

  try {
    await client.connect();
    console.log("Connected to database");

    const modules = (await client.queryObject<ModuleRecord>(
      "SELECT id FROM modules ORDER BY id",
    )).rows;
    const entities = (await client.queryObject<EntityRecord>(
      "SELECT table_name FROM entities ORDER BY table_name",
    )).rows;
    const fields = (await client.queryObject<FieldRecord>(
      "SELECT table_name, field_name, format, is_pk, default_value, field_order, input_type, enum_values FROM fields ORDER BY table_name, field_order",
    )).rows;

    console.log(
      `Found ${modules.length} module(s), ${entities.length} entit(y/ies), ${fields.length} field(s)`,
    );

    // --- index fields by table ----------------------------------------------
    const fieldsByTable = new Map<string, FieldRecord[]>();
    for (const f of fields) {
      if (!fieldsByTable.has(f.table_name)) fieldsByTable.set(f.table_name, []);
      fieldsByTable.get(f.table_name)!.push(f);
    }

    // Single file, kysely-codegen style: helper aliases, every table interface,
    // then the `DB` map. Tables (and the DB keys) are sorted by physical name.
    const allTables = entities.map((e) => e.table_name).sort();
    const content = renderFile(allTables, fieldsByTable);

    const dir = dirname(outputFile);
    if (dir && dir !== ".") await Deno.mkdir(dir, { recursive: true });
    await Deno.writeTextFile(outputFile, content);

    console.log(
      `Kysely types generated: ${allTables.length} table(s) -> ${outputFile}`,
    );
  } catch (error) {
    console.error(
      "Failed to generate Kysely types:",
      error instanceof Error ? error.message : String(error),
    );
    Deno.exit(1);
  } finally {
    try {
      await client.end();
      console.log("Database connection closed");
    } catch (_closeError) {
      console.warn("Warning: Could not close connection properly");
    }
  }
}

/**
 * Render the single types file (kysely-codegen layout): the used helper aliases,
 * one `export interface <Table>` per table, then the `export interface DB` map.
 */
function renderFile(
  allTables: string[],
  fieldsByTable: Map<string, FieldRecord[]>,
): string {
  const used = new Set<Alias>();
  let needGenerated = false;

  const interfaceBlocks: string[] = [];
  for (const table of allTables) {
    const fieldList = fieldsByTable.get(table) ?? [];
    const colLines: string[] = [];
    for (const field of fieldList) {
      if (isGenerated(field)) needGenerated = true;
      colLines.push(`  ${key(field.field_name)}: ${columnType(field, used)};`);
    }
    interfaceBlocks.push(
      `export interface ${pascalCase(table)} {\n${colLines.join("\n")}\n}`,
    );
  }

  const dbLines: string[] = ["export interface DB {"];
  for (const table of allTables) {
    dbLines.push(`  ${key(table)}: ${pascalCase(table)};`);
  }
  dbLines.push("}");

  const lines: string[] = [];
  lines.push("// AUTO-GENERATED by `deno task kyselygen`. Do not edit by hand.");
  lines.push("");

  // ColumnType backs the Timestamp/Numeric/Int8 aliases and the Generated helper.
  const needColumnType = needGenerated || used.has("Timestamp") ||
    used.has("Numeric") || used.has("Int8");
  if (needColumnType) {
    lines.push(`import type { ColumnType } from "kysely";`);
    lines.push("");
  }

  // Generated<T>: kysely-codegen's conditional form, which unwraps an already-
  // ColumnType argument (e.g. Generated<Timestamp>) instead of nesting one.
  if (needGenerated) {
    lines.push(
      "export type Generated<T> = T extends ColumnType<infer S, infer I, infer U>\n" +
        "  ? ColumnType<S, I | undefined, U>\n" +
        "  : ColumnType<T, T | undefined, T>;",
    );
    lines.push("");
  }

  // Helper aliases (only the used ones), ColumnType-backed first, then Json set.
  const aliasLines: string[] = [];
  for (const a of ["Timestamp", "Numeric", "Int8"] as const) {
    if (used.has(a)) aliasLines.push(ALIAS_DEFS[a]);
  }
  if (used.has("Json")) aliasLines.push(JSON_DEFS);
  if (aliasLines.length) {
    lines.push(aliasLines.join("\n"));
    lines.push("");
  }

  lines.push(interfaceBlocks.join("\n\n"));
  lines.push("");
  lines.push(dbLines.join("\n"));
  lines.push("");
  return lines.join("\n");
}
