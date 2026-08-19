// Run a SQL file against a database, all-or-nothing (BEGIN/COMMIT, ROLLBACK on error).
// Usage:
//   deno run --allow-read --allow-env --allow-net scripts/run-sql.ts <sql-file> [DATABASE_URL]
// If DATABASE_URL is omitted, it is read from the DATABASE_URL env var.
//
// Example (fix one broken tenant):
//   DATABASE_URL='postgresql://user:pass@host/db?sslmode=require' \
//     deno run --allow-read --allow-env --allow-net scripts/run-sql.ts label_fix.sql
import { Client } from "https://deno.land/x/postgres@v0.17.0/mod.ts";

const file = Deno.args[0];
const url = Deno.args[1] ?? Deno.env.get("DATABASE_URL");
if (!file || !url) {
  console.error("usage: run-sql.ts <sql-file> [DATABASE_URL]");
  Deno.exit(2);
}

const sql = await Deno.readTextFile(file);
const client = new Client(url);
await client.connect();
try {
  await client.queryArray("BEGIN");
  const res = await client.queryArray(sql); // simple-query protocol: runs all statements
  await client.queryArray("COMMIT");
  // label_fix.sql ends with SELECT v0_label_fix(); surface its returned count when present.
  const last = Array.isArray(res.rows) ? res.rows.at(-1) : undefined;
  console.log(`✅ applied ${file}`, last ? `→ ${JSON.stringify(last)}` : "");
} catch (e) {
  await client.queryArray("ROLLBACK").catch(() => {});
  console.error(`❌ failed, rolled back:`, e instanceof Error ? e.message : e);
  Deno.exit(1);
} finally {
  await client.end();
}
