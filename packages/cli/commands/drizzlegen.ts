/**
 * drizzlegen command implementation
 *
 * Generates a Drizzle ORM schema from the Semantius catalog (modules -> entities
 * -> fields). Emits ONE TypeScript file per module (named by module_slug) plus an
 * index.ts barrel, covering every entity defined in the catalog. Foreign-key
 * fields (format 'reference' / 'parent') become Drizzle .references() and
 * relations() so the relational query API and Drizzle Studio's relationship view
 * both work.
 *
 * The type mapping mirrors public.format_to_data_type() and public.is_nullable()
 * from apps/_core/migrations/0070_dd_functions.sql, so the generated schema
 * matches the physical tables the catalog produces. `enum` fields become
 * text(col, { enum: [...] }) — a TEXT column typed as a literal union, matching
 * the DB's TEXT + CHECK (not a native PG enum type).
 *
 *   deno task drizzlegen                                    # -> ./drizzle/schema
 *   deno task drizzlegen --output examples/drizzle/src/schema
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
  id_column: string;
  description: string;
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
  precision: number;
  reference_table: string;
  reference_delete_mode: string;
}

/** A resolved foreign key edge: source.fkField -> target(targetIdColumn). */
interface Fk {
  src: string;
  fkField: string;
  target: string;
  format: "reference" | "parent";
  deleteMode: string;
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

/** Strip a trailing `_id` (FK suffix) so user_id -> user, role_id -> role. */
function stripIdSuffix(s: string): string {
  return s.replace(/_id$/, "");
}

/** Mirror of the DB module_slug trigger: lowercase, non-alnum -> _, trimmed. */
function sanitizeSlug(s: string): string {
  const r = s.toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
  return r || "module";
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

// ---- column type mapping (mirror of format_to_data_type) --------------------

/** The Drizzle pg-core builder function + its argument list for a field. */
function baseBuilder(field: FieldRecord): { fn: string; args: string } {
  const name = JSON.stringify(field.field_name);
  const f = field.format;

  // Auto-increment primary keys: managed tables use SERIAL (see create_dd_table).
  if (field.is_pk && (f === "int32" || f === "integer")) {
    return { fn: "serial", args: name };
  }
  if (field.is_pk && f === "int64") {
    return { fn: "bigserial", args: `${name}, { mode: "number" }` };
  }

  switch (f) {
    case "int32":
    case "integer":
    case "reference":
    case "parent":
      return { fn: "integer", args: name };
    case "int64":
      return { fn: "bigint", args: `${name}, { mode: "number" }` };
    case "float":
      return { fn: "real", args: name };
    case "double":
      return { fn: "doublePrecision", args: name };
    case "number":
      return {
        fn: "numeric",
        args: `${name}, { precision: 18, scale: ${field.precision ?? 2} }`,
      };
    case "uuid":
      return { fn: "uuid", args: name };
    case "binary":
    case "byte":
      return { fn: "bytea", args: name };
    case "date":
      return { fn: "date", args: name };
    case "time":
      return { fn: "time", args: name };
    case "date-time":
      return { fn: "timestamp", args: `${name}, { withTimezone: true }` };
    case "duration":
      return { fn: "interval", args: name };
    case "boolean":
      return { fn: "boolean", args: name };
    case "json":
    case "object":
    case "array":
      return { fn: "jsonb", args: name };
    case "enum": {
      // Physically a TEXT column (+ CHECK in the DB); the { enum } option types
      // it as a literal union ('a' | 'b' | …) without a native PG enum type.
      const vals = effectiveEnumValues(field.input_type, field.enum_values);
      if (vals && vals.length) {
        const list = vals.map((v) => JSON.stringify(v)).join(", ");
        return { fn: "text", args: `${name}, { enum: [${list}] }` };
      }
      return { fn: "text", args: name };
    }
    // text and every other string-like format -> TEXT.
    default:
      return { fn: "text", args: name };
  }
}

/** Best-effort default modifier, kept conservative to stay type-safe. */
function defaultModifier(field: FieldRecord): string {
  if (field.is_pk) return "";
  if (field.format === "reference" || field.format === "parent") return "";

  if (field.field_name === "created_at" || field.field_name === "updated_at") {
    return ".defaultNow()";
  }
  const v = field.default_value ?? "";
  if (v === "") return "";

  switch (field.format) {
    case "boolean":
      if (v === "true" || v === "false") return `.default(${v})`;
      return "";
    case "int32":
    case "int64":
    case "integer":
    case "float":
    case "double":
      return /^-?\d+(\.\d+)?$/.test(v) ? `.default(${Number(v)})` : "";
    case "number":
      return /^-?\d+(\.\d+)?$/.test(v) ? `.default(${JSON.stringify(v)})` : "";
    case "date":
    case "time":
    case "date-time":
    case "json":
    case "object":
    case "array":
      return ""; // skip non-trivial defaults
    default:
      return `.default(${JSON.stringify(v)})`; // text-like
  }
}

export async function drizzlegenCommand(
  databaseUrl: string,
  outputDir: string,
): Promise<void> {
  console.log(`Generating Drizzle schema into ${outputDir} ...`);

  const client = new Client(databaseUrl);

  try {
    await client.connect();
    console.log("Connected to database");

    const modules = (await client.queryObject<ModuleRecord>(
      "SELECT id, module_name, module_slug FROM modules ORDER BY id",
    )).rows;
    const entities = (await client.queryObject<EntityRecord>(
      "SELECT table_name, module_id, id_column, description FROM entities ORDER BY table_name",
    )).rows;
    const fields = (await client.queryObject<FieldRecord>(
      "SELECT table_name, field_name, format, is_pk, default_value, field_order, input_type, enum_values, precision, reference_table, reference_delete_mode FROM fields ORDER BY table_name, field_order",
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
    const tableToIdCol = new Map<string, string>();
    const tableToVar = new Map<string, string>();
    for (const e of entities) {
      const slug = (e.module_id != null && slugByModuleId.has(e.module_id))
        ? slugByModuleId.get(e.module_id)!
        : "unassigned";
      tableToSlug.set(e.table_name, slug);
      tableToIdCol.set(e.table_name, e.id_column);
      tableToVar.set(e.table_name, camelCase(e.table_name));
    }

    const fieldsByTable = new Map<string, FieldRecord[]>();
    for (const f of fields) {
      if (!fieldsByTable.has(f.table_name)) fieldsByTable.set(f.table_name, []);
      fieldsByTable.get(f.table_name)!.push(f);
    }

    // --- resolve foreign keys (skip dangling targets) ------------------------
    const fks: Fk[] = [];
    for (const f of fields) {
      if (
        (f.format === "reference" || f.format === "parent") &&
        f.reference_table && tableToVar.has(f.reference_table) &&
        tableToVar.has(f.table_name)
      ) {
        fks.push({
          src: f.table_name,
          fkField: f.field_name,
          target: f.reference_table,
          format: f.format,
          deleteMode: f.reference_delete_mode,
        });
      }
    }

    // --- relation field naming (deterministic, collision-disambiguated) ------
    // one-side: on the source table, named after the FK (user_id -> user).
    const oneName = new Map<string, string>(); // key: `${src}.${fkField}`
    const usedOne = new Map<string, Set<string>>(); // per src table
    for (const fk of fks) {
      const used = usedOne.get(fk.src) ?? new Set<string>();
      let name = camelCase(stripIdSuffix(fk.fkField));
      if (used.has(name)) name = camelCase(fk.fkField);
      while (used.has(name)) name = name + "Ref";
      used.add(name);
      usedOne.set(fk.src, used);
      oneName.set(`${fk.src}.${fk.fkField}`, name);
    }

    // many-side: on the target table, named after the source table; only the
    // colliding ones (same target reached by multiple FKs with the same base)
    // get an fk-derived suffix.
    const manyName = new Map<string, string>(); // key: `${src}.${fkField}`
    const baseCount = new Map<string, number>(); // `${target}|${camel(src)}`
    for (const fk of fks) {
      const k = `${fk.target}|${camelCase(fk.src)}`;
      baseCount.set(k, (baseCount.get(k) ?? 0) + 1);
    }
    const usedMany = new Map<string, Set<string>>(); // per target table
    for (const fk of fks) {
      const used = usedMany.get(fk.target) ?? new Set<string>();
      const base = camelCase(fk.src);
      let name = base;
      if ((baseCount.get(`${fk.target}|${base}`) ?? 0) > 1) {
        name = base + upperFirst(camelCase(stripIdSuffix(fk.fkField)));
      }
      while (used.has(name)) name = name + "Ref";
      used.add(name);
      usedMany.set(fk.target, used);
      manyName.set(`${fk.src}.${fk.fkField}`, name);
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
      const content = renderModuleFile(slug, tables, {
        tableToSlug,
        tableToIdCol,
        tableToVar,
        fieldsByTable,
        fks,
        oneName,
        manyName,
      });
      const path = join(outputDir, `${slug}.ts`);
      await Deno.writeTextFile(path, content);
      console.log(`  wrote ${path} (${tables.length} table(s))`);
    }

    // index.ts barrel
    const indexBody =
      "// AUTO-GENERATED by `deno task drizzlegen`. Do not edit by hand.\n\n" +
      slugs.map((s) => `export * from "./${s}";`).join("\n") + "\n";
    const indexPath = join(outputDir, "index.ts");
    await Deno.writeTextFile(indexPath, indexBody);
    console.log(`  wrote ${indexPath}`);

    console.log(
      `Drizzle schema generated: ${slugs.length} module file(s) + index.ts`,
    );
  } catch (error) {
    console.error(
      "Failed to generate Drizzle schema:",
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

interface RenderCtx {
  tableToSlug: Map<string, string>;
  tableToIdCol: Map<string, string>;
  tableToVar: Map<string, string>;
  fieldsByTable: Map<string, FieldRecord[]>;
  fks: Fk[];
  oneName: Map<string, string>;
  manyName: Map<string, string>;
}

/** Render one module file: imports + pgTable definitions + relations(). */
function renderModuleFile(
  slug: string,
  tables: string[],
  ctx: RenderCtx,
): string {
  const pgCore = new Set<string>(["pgTable"]);
  let needRelations = false;
  let needBytea = false;
  let needAnyPgColumn = false;
  // external table var -> set, grouped by the file (slug) it lives in
  const externalImports = new Map<string, Set<string>>();

  const addExternal = (table: string) => {
    const targetSlug = ctx.tableToSlug.get(table)!;
    if (targetSlug === slug) return;
    if (!externalImports.has(targetSlug)) {
      externalImports.set(targetSlug, new Set());
    }
    externalImports.get(targetSlug)!.add(ctx.tableToVar.get(table)!);
  };

  const tableBlocks: string[] = [];
  const relationBlocks: string[] = [];

  for (const table of tables) {
    const varName = ctx.tableToVar.get(table)!;
    const fieldList = ctx.fieldsByTable.get(table) ?? [];

    // --- columns ---
    const colLines: string[] = [];
    for (const field of fieldList) {
      const prop = camelCase(field.field_name);
      const { fn, args } = baseBuilder(field);
      pgCore.add(fn);
      if (fn === "bytea") needBytea = true;

      let expr = `${fn}(${args})`;
      if (field.is_pk) expr += ".primaryKey()";

      // Foreign key as an inline .references() thunk. The `: AnyPgColumn` return
      // annotation is required so circular references (e.g. modules <-> permissions
      // <-> roles) don't trip TS inference ("implicitly has type any"); it is
      // Drizzle's documented workaround and harmless for acyclic references.
      if (
        (field.format === "reference" || field.format === "parent") &&
        field.reference_table && ctx.tableToVar.has(field.reference_table)
      ) {
        const targetVar = ctx.tableToVar.get(field.reference_table)!;
        const targetIdProp = camelCase(
          ctx.tableToIdCol.get(field.reference_table)!,
        );
        addExternal(field.reference_table);
        needAnyPgColumn = true;
        const onDelete = field.format === "parent"
          ? "cascade"
          : field.reference_delete_mode === "clear"
          ? "set null"
          : field.reference_delete_mode === "cascade"
          ? "cascade"
          : ""; // restrict / empty -> PG default, omit options
        const opts = onDelete ? `, { onDelete: "${onDelete}" }` : "";
        expr +=
          `.references((): AnyPgColumn => ${targetVar}.${targetIdProp}${opts})`;
      }

      if (!field.is_pk && !isNullable(field.format)) expr += ".notNull()";
      expr += defaultModifier(field);

      colLines.push(`  ${prop}: ${expr},`);
    }

    tableBlocks.push(
      `export const ${varName} = pgTable(${JSON.stringify(table)}, {\n${
        colLines.join("\n")
      }\n});`,
    );

    // --- relations (one-side from this table's FKs, many-side into it) ---
    const ones = ctx.fks.filter((fk) => fk.src === table);
    const manys = ctx.fks.filter((fk) => fk.target === table);
    if (ones.length === 0 && manys.length === 0) continue;
    needRelations = true;

    const helpers = [
      ones.length ? "one" : "",
      manys.length ? "many" : "",
    ].filter(Boolean).join(", ");

    const relLines: string[] = [];
    for (const fk of ones) {
      const targetVar = ctx.tableToVar.get(fk.target)!;
      const targetIdProp = camelCase(ctx.tableToIdCol.get(fk.target)!);
      const fkProp = camelCase(fk.fkField);
      const name = ctx.oneName.get(`${fk.src}.${fk.fkField}`)!;
      addExternal(fk.target);
      relLines.push(
        `  ${name}: one(${targetVar}, { fields: [${varName}.${fkProp}], references: [${targetVar}.${targetIdProp}], relationName: ${
          JSON.stringify(`${fk.src}_${fk.fkField}`)
        } }),`,
      );
    }
    for (const fk of manys) {
      const srcVar = ctx.tableToVar.get(fk.src)!;
      const name = ctx.manyName.get(`${fk.src}.${fk.fkField}`)!;
      addExternal(fk.src);
      relLines.push(
        `  ${name}: many(${srcVar}, { relationName: ${
          JSON.stringify(`${fk.src}_${fk.fkField}`)
        } }),`,
      );
    }

    relationBlocks.push(
      `export const ${varName}Relations = relations(${varName}, ({ ${helpers} }) => ({\n${
        relLines.join("\n")
      }\n}));`,
    );
  }

  // --- assemble imports ---
  const lines: string[] = [];
  lines.push(
    "// AUTO-GENERATED by `deno task drizzlegen`. Do not edit by hand.",
  );
  lines.push("");
  const pgCoreImports = [...pgCore].sort().join(", ");
  lines.push(`import { ${pgCoreImports} } from "drizzle-orm/pg-core";`);
  if (needAnyPgColumn) {
    lines.push(`import type { AnyPgColumn } from "drizzle-orm/pg-core";`);
  }
  if (needRelations) lines.push(`import { relations } from "drizzle-orm";`);
  for (const targetSlug of [...externalImports.keys()].sort()) {
    const vars = [...externalImports.get(targetSlug)!].sort().join(", ");
    lines.push(`import { ${vars} } from "./${targetSlug}";`);
  }
  lines.push("");

  if (needBytea) {
    lines.push(
      `const bytea = customType<{ data: Uint8Array; driverData: Uint8Array }>({ dataType() { return "bytea"; } });`,
    );
    lines.push("");
  }

  lines.push(tableBlocks.join("\n\n"));
  if (relationBlocks.length) {
    lines.push("");
    lines.push(relationBlocks.join("\n\n"));
  }
  lines.push("");

  return lines.join("\n");
}
