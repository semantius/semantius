/**
 * kyselygen command implementation
 *
 * Generates Kysely type definitions from the Semantius catalog (modules ->
 * entities -> fields). Emits ONE TypeScript file per module (named by
 * module_slug) holding the per-table interfaces, plus an index.ts that declares
 * the `DB` interface Kysely is parameterized with (`new Kysely<DB>(…)`).
 *
 * Unlike Drizzle, Kysely is purely type-driven: there are no runtime table
 * objects, just interfaces. Each table becomes an `export interface <Table>`
 * keyed by the *physical* column names (snake_case — Kysely's default, matching
 * the DB and the raw-SQL example), and index.ts maps each physical table name to
 * its interface.
 *
 * The type mapping mirrors public.format_to_data_type() / public.is_nullable()
 * (apps/_core/migrations/0070_dd_functions.sql) AND the runtime value decoding
 * the example does via node-postgres' `pg-types` (keyed by column type OID). So
 * the generated types match what a query actually returns: integers are numbers,
 * timestamps are Dates, bigint/numeric come back as strings, jsonb as objects.
 *
 * Columns the database fills (auto-increment PKs, created_at/updated_at, any
 * field with a default) are wrapped in Kysely's `Generated<T>` so they are
 * optional on insert. `enum` fields become a literal-union type ('a' | 'b' | …),
 * matching the DB's TEXT + CHECK (not a native PG enum) — with '' included for
 * non-required enums, mirroring public.effective_enum_values().
 *
 *   deno task kyselygen                                  # -> ./kysely/schema
 *   deno task kyselygen --output examples/kysely/src/schema
 */

import { Client } from "@postgres";
import { join } from "@std/path";

interface ModuleRecord {
  id: number;
  module_name: string;
  module_slug: string;
}

interface EntityRecord {
  table_name: string;
  module_id: number | null;
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

/** Mirror of the DB module_slug trigger: lowercase, non-alnum -> _, trimmed. */
function sanitizeSlug(s: string): string {
  const r = s.toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
  return r || "module";
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
 * and should be wrapped in Kysely's `Generated<T>`. Mirrors the cases drizzlegen
 * emits a default for: auto-increment (serial/bigserial) PKs, the timestamp
 * bookkeeping columns, and any field carrying a catalog default_value.
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
  Timestamp: "type Timestamp = ColumnType<Date, Date | string, Date | string>;",
  Numeric: "type Numeric = ColumnType<string, number | string, number | string>;",
  Int8:
    "type Int8 = ColumnType<string, bigint | number | string, bigint | number | string>;",
};

/** The five mutually-referencing aliases emitted when any jsonb column is present. */
const JSON_DEFS = [
  "type JsonArray = JsonValue[];",
  "type JsonObject = { [K in string]?: JsonValue };",
  "type JsonPrimitive = boolean | number | string | null;",
  "type JsonValue = JsonArray | JsonObject | JsonPrimitive;",
  "type Json = JsonValue;",
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
  outputDir: string,
): Promise<void> {
  console.log(`Generating Kysely types into ${outputDir} ...`);

  const client = new Client(databaseUrl);

  try {
    await client.connect();
    console.log("Connected to database");

    const modules = (await client.queryObject<ModuleRecord>(
      "SELECT id, module_name, module_slug FROM modules ORDER BY id",
    )).rows;
    const entities = (await client.queryObject<EntityRecord>(
      "SELECT table_name, module_id FROM entities ORDER BY table_name",
    )).rows;
    const fields = (await client.queryObject<FieldRecord>(
      "SELECT table_name, field_name, format, is_pk, default_value, field_order, input_type, enum_values FROM fields ORDER BY table_name, field_order",
    )).rows;

    console.log(
      `Found ${modules.length} module(s), ${entities.length} entit(y/ies), ${fields.length} field(s)`,
    );

    // --- lookup maps ---------------------------------------------------------
    const slugByModuleId = new Map<number, string>();
    for (const m of modules) {
      const slug = m.module_slug && m.module_slug.trim() !== ""
        ? m.module_slug
        : sanitizeSlug(m.module_name) || `module_${m.id}`;
      slugByModuleId.set(m.id, slug);
    }

    const tableToSlug = new Map<string, string>();
    for (const e of entities) {
      const slug = (e.module_id != null && slugByModuleId.has(e.module_id))
        ? slugByModuleId.get(e.module_id)!
        : "unassigned";
      tableToSlug.set(e.table_name, slug);
    }

    const fieldsByTable = new Map<string, FieldRecord[]>();
    for (const f of fields) {
      if (!fieldsByTable.has(f.table_name)) fieldsByTable.set(f.table_name, []);
      fieldsByTable.get(f.table_name)!.push(f);
    }

    // --- group tables by file (module slug) ----------------------------------
    const tablesBySlug = new Map<string, string[]>();
    for (const e of entities) {
      const slug = tableToSlug.get(e.table_name)!;
      if (!tablesBySlug.has(slug)) tablesBySlug.set(slug, []);
      tablesBySlug.get(slug)!.push(e.table_name);
    }

    await Deno.mkdir(outputDir, { recursive: true });

    const slugs = [...tablesBySlug.keys()].sort();
    for (const slug of slugs) {
      const tables = tablesBySlug.get(slug)!.sort();
      const content = renderModuleFile(tables, fieldsByTable);
      const path = join(outputDir, `${slug}.ts`);
      await Deno.writeTextFile(path, content);
      console.log(`  wrote ${path} (${tables.length} table(s))`);
    }

    // index.ts — re-exports every interface and declares the `DB` interface.
    const allTables = entities.map((e) => e.table_name).sort();
    const indexPath = join(outputDir, "index.ts");
    await Deno.writeTextFile(indexPath, renderIndex(slugs, tablesBySlug, allTables));
    console.log(`  wrote ${indexPath}`);

    console.log(
      `Kysely types generated: ${slugs.length} module file(s) + index.ts`,
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

/** Render one module file: imports + helper aliases + per-table interfaces. */
function renderModuleFile(
  tables: string[],
  fieldsByTable: Map<string, FieldRecord[]>,
): string {
  const used = new Set<Alias>();
  let needGenerated = false;

  const interfaceBlocks: string[] = [];
  for (const table of tables) {
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

  const lines: string[] = [];
  lines.push("// AUTO-GENERATED by `deno task kyselygen`. Do not edit by hand.");
  lines.push("");

  // Imports from kysely: ColumnType backs the Timestamp/Numeric/Int8 aliases;
  // Generated wraps DB-supplied columns.
  const needColumnType = used.has("Timestamp") || used.has("Numeric") ||
    used.has("Int8");
  const kyselyImports = [
    needColumnType ? "ColumnType" : "",
    needGenerated ? "Generated" : "",
  ].filter(Boolean);
  if (kyselyImports.length) {
    lines.push(`import type { ${kyselyImports.join(", ")} } from "kysely";`);
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
  return lines.join("\n");
}

/** Render index.ts: re-export every interface + declare the `DB` interface. */
function renderIndex(
  slugs: string[],
  tablesBySlug: Map<string, string[]>,
  allTables: string[],
): string {
  const lines: string[] = [];
  lines.push("// AUTO-GENERATED by `deno task kyselygen`. Do not edit by hand.");
  lines.push("");

  // Re-export every table interface so consumers can `import type { Users }`.
  for (const slug of slugs) lines.push(`export type * from "./${slug}";`);
  lines.push("");

  // Import the interfaces this file references in the DB map below.
  for (const slug of slugs) {
    const names = tablesBySlug.get(slug)!.slice().sort().map(pascalCase);
    lines.push(
      `import type {\n${names.map((n) => `  ${n},`).join("\n")}\n} from "./${slug}";`,
    );
  }
  lines.push("");

  // The `DB` interface: physical table name -> its interface.
  lines.push("export interface DB {");
  for (const table of allTables) {
    lines.push(`  ${key(table)}: ${pascalCase(table)};`);
  }
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}
