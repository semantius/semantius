#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read
/**
 * Traces the get_userinfo() hot path through pg_stat_xact_user_functions,
 * which is visible immediately rather than waiting on the once-per-second
 * flush pg_stat_user_functions depends on - the only way to see one
 * request's function-call counts precisely. track_functions is
 * superuser-only, so this connects as the postgres superuser directly rather
 * than going through PostgREST or the session-mode authenticator.
 *
 * Each scenario gets its own fresh connection, not only its own transaction:
 * a backend does not zero pg_stat_xact_user_functions when one transaction
 * commits and the next begins, so counts from an earlier transaction on the
 * same connection keep showing up in a later one, and a shared connection
 * would make every scenario after the first read as cumulative. Three
 * PostgREST-shaped transactions, each `SET LOCAL ROLE authenticated` plus
 * injected claims the way a real request arrives:
 *
 *   1. public.get_userinfo() called twice - cold, then a repeat in the same
 *      transaction - plus the users row's xmin/ctid/last_seen and the
 *      audit_record_logs row count for that user, before and after.
 *   2. a single cold permission check (SELECT count(*) FROM fields) as the
 *      first statement of a fresh transaction, to see what one check costs
 *      with no warm context to reuse.
 *   3. an UPDATE of every row of an audited nwind table, context warmed by a
 *      permission check first (as a real request's earlier checks already
 *      would have done), to see the per-row cost across a whole statement.
 *      Rolled back, so the data change never persists.
 *
 * Requires _core, nwind and test deployed (the same stack the pgTAP suite
 * runs against) and the pgdocker test issuer reachable (mintToken).
 *
 *   deno run --allow-net --allow-env --allow-read measure_hot_path.ts \
 *     [--host 127.0.0.1] [--port 5432] [--db appdb] [--user-id user3] [--client-id test-client]
 */
import { Client } from "https://deno.land/x/postgres@v0.17.0/mod.ts";
import { parseFlags } from "./verify_oauth.ts";
import { claimsFor } from "./session_helpers.ts";

/** Every function this plan's steps touch, schema-qualified to disambiguate. */
const FUNCTIONS_OF_INTEREST = [
  "rbac.uid",
  "rbac.upsert_user_from_jwt",
  "rbac.get_user_permissions",
  "rbac.get_user_permissions_by_id",
  "rbac.get_user_by_external_id",
  "rbac.ensure_context_initialized",
  "rbac.user_id",
  "rbac.user_id_or_null",
  "rbac.has_permission",
  "rbac.has_any_permission",
  "rbac.is_bearer_session",
  "public.jl_request_context",
  "public.get_userinfo",
  "public.get_user_modules",
  "audit.insert_update_delete_trigger",
  "audit.insert_trigger",
  "audit.delete_trigger",
  "audit.truncate_trigger",
  "audit.current_user_id",
  "audit.primary_key_columns",
  "audit.to_record_id",
  "audit.extract_record_pk",
  "common.update_updated_at_column",
];

interface FnStat {
  name: string;
  calls: number;
  totalTime: number;
}

/** Resolve the postgres superuser password: $POSTGRES_PASSWORD, then pgdocker/.env, then the dev default. */
async function resolvePostgresPassword(): Promise<string> {
  const fromEnv = Deno.env.get("POSTGRES_PASSWORD");
  if (fromEnv) return fromEnv;
  try {
    const envText = await Deno.readTextFile(new URL("./.env", import.meta.url));
    for (const line of envText.split(/\r?\n/)) {
      const m = line.match(/^\s*POSTGRES_PASSWORD\s*=\s*(.*?)\s*$/);
      if (m) return m[1].replace(/^["']|["']$/g, "");
    }
  } catch {
    // No readable .env - fall through to the dev default.
  }
  return "postgres";
}

/** Snapshot pg_stat_xact_user_functions, filtered and sorted by total_time descending. */
async function functionStats(client: Client): Promise<FnStat[]> {
  const r = await client.queryObject<
    { name: string; calls: string; total_time: string }
  >(
    `SELECT schemaname || '.' || funcname AS name, calls::text, total_time::text
       FROM pg_stat_xact_user_functions
      WHERE schemaname || '.' || funcname = ANY($1)
      ORDER BY total_time DESC`,
    [FUNCTIONS_OF_INTEREST],
  );
  return r.rows.map((row) => ({
    name: row.name,
    calls: Number(row.calls),
    totalTime: Number(row.total_time),
  }));
}

function printStats(label: string, stats: FnStat[]) {
  console.log(`\n-- ${label} --`);
  if (stats.length === 0) {
    console.log("  (no tracked calls)");
    return;
  }
  for (const s of stats) {
    console.log(
      `  ${s.name.padEnd(34)} calls=${s.calls}  total_time=${s.totalTime.toFixed(3)}ms`,
    );
  }
}

async function setRequestContext(client: Client, claims: unknown) {
  await client.queryArray("SET LOCAL track_functions = 'all'");
  // queryArray, not queryObject: three set_config() calls in one SELECT would
  // otherwise collide on the column name every call gets by default.
  await client.queryArray({
    text:
      "SELECT set_config('search_path', 'public', true), " +
      "set_config('role', 'authenticated', true), " +
      "set_config('request.jwt.claims', $1, true)",
    args: [JSON.stringify(claims)],
  });
}

/**
 * pg_stat_xact_user_functions is transaction-local within a backend, but a
 * backend does not zero it out when one transaction ends and the next
 * begins - counts from an earlier, already-committed transaction on the same
 * connection keep showing up in a later one. A fresh connection per scenario
 * is what actually gets a pristine counter, confirmed against PostgreSQL 18
 * (a COMMIT followed by a fresh BEGIN on the same session still reported the
 * prior transaction's calls).
 */
async function withFreshConnection<T>(
  opts: { host: string; port: number; db: string; password: string },
  fn: (client: Client) => Promise<T>,
): Promise<T> {
  const client = new Client({
    user: "postgres",
    password: opts.password,
    database: opts.db,
    hostname: opts.host,
    port: opts.port,
    tls: { enabled: false },
  });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  const userId = a["user-id"] ?? "user3";
  const clientId = a["client-id"] ?? "test-client";
  const password = await resolvePostgresPassword();
  const connOpts = { host, port, db, password };

  console.log(`target: postgres (superuser) at ${host}:${port}/${db}`);

  try {
    const claims = await claimsFor(userId, clientId);

    // ---- Scenario 1: get_userinfo(), cold then repeat -----------------------
    await withFreshConnection(connOpts, async (client) => {
      await client.queryArray("BEGIN");
      try {
        await setRequestContext(client, claims);

        const before = await client.queryObject<
          { xmin: string; ctid: string; last_seen: string | null }
        >(
          `SELECT xmin::text, ctid::text, last_seen::text FROM users WHERE external_id = $1`,
          [userId],
        );
        const auditBefore = await client.queryObject<{ n: string }>(
          `SELECT count(*)::text AS n FROM audit_record_logs WHERE table_name = 'users'`,
        );

        await client.queryArray("SELECT public.get_userinfo()"); // cold
        const cold = await functionStats(client);

        await client.queryArray("SELECT public.get_userinfo()"); // repeat
        const cumulative = await functionStats(client);
        // Still cumulative since BEGIN within this one transaction, so the
        // repeat call's own cost is the delta against the cold snapshot.
        const repeat = cumulative
          .map((r) => {
            const c = cold.find((x) => x.name === r.name);
            return {
              name: r.name,
              calls: r.calls - (c?.calls ?? 0),
              totalTime: r.totalTime - (c?.totalTime ?? 0),
            };
          })
          .filter((r) => r.calls > 0)
          .sort((x, y) => y.totalTime - x.totalTime);

        const after = await client.queryObject<
          { xmin: string; ctid: string; last_seen: string | null }
        >(
          `SELECT xmin::text, ctid::text, last_seen::text FROM users WHERE external_id = $1`,
          [userId],
        );
        const auditAfter = await client.queryObject<{ n: string }>(
          `SELECT count(*)::text AS n FROM audit_record_logs WHERE table_name = 'users'`,
        );

        console.log(`\n=== Scenario 1: get_userinfo() for ${userId}, cold then repeat ===`);
        console.log(
          `users row: xmin ${before.rows[0]?.xmin} -> ${after.rows[0]?.xmin}` +
            `  ctid ${before.rows[0]?.ctid} -> ${after.rows[0]?.ctid}`,
        );
        console.log(`users.last_seen: ${before.rows[0]?.last_seen} -> ${after.rows[0]?.last_seen}`);
        console.log(
          `audit_record_logs rows for users: ${auditBefore.rows[0]?.n} -> ${auditAfter.rows[0]?.n}`,
        );
        printStats("cold get_userinfo() (cumulative since BEGIN)", cold);
        printStats("repeat get_userinfo() (delta over the cold call)", repeat);

        await client.queryArray("COMMIT");
      } catch (e) {
        await client.queryArray("ROLLBACK").catch(() => {});
        throw e;
      }
    });

    // ---- Scenario 2: one cold permission check, nothing warmed first --------
    await withFreshConnection(connOpts, async (client) => {
      await client.queryArray("BEGIN");
      try {
        await setRequestContext(client, claims);
        await client.queryArray("SELECT count(*) FROM fields");
        const stats = await functionStats(client);
        console.log(`\n=== Scenario 2: cold SELECT count(*) FROM fields for ${userId} ===`);
        printStats("first statement of a fresh connection and transaction", stats);
        await client.queryArray("COMMIT");
      } catch (e) {
        await client.queryArray("ROLLBACK").catch(() => {});
        throw e;
      }
    });

    // ---- Scenario 3: a per-row cost on an audited bulk UPDATE, warm ----------
    await withFreshConnection(connOpts, async (client) => {
      await client.queryArray("BEGIN");
      try {
        await setRequestContext(client, claims);
        // Warm the context first, as a real request's earlier checks already
        // would have by the time it reaches a bulk write.
        await client.queryArray("SELECT rbac.has_permission('admin')");

        const rowCount = await client.queryObject<{ n: string }>(
          `SELECT count(*)::text AS n FROM products`,
        );
        // A real change, not a no-op: the audited-no-op skip returns before
        // resolving the acting user at all, which would measure nothing.
        await client.queryArray("UPDATE products SET unit_price = unit_price + 1");
        const stats = await functionStats(client);

        console.log(
          `\n=== Scenario 3: audited UPDATE of ${rowCount.rows[0]?.n} rows (products), warm context ===`,
        );
        printStats("UPDATE products SET unit_price = unit_price + 1", stats);

        await client.queryArray("ROLLBACK"); // never persist the price bump
      } catch (e) {
        await client.queryArray("ROLLBACK").catch(() => {});
        throw e;
      }
    });

    return 0;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/rbac\.uid|get_userinfo|schema "rbac"|does not exist/i.test(msg)) {
      console.log(`SKIP: _core/nwind not fully deployed: ${msg}`);
      return 2;
    }
    throw e;
  }
}

if (import.meta.main) Deno.exit(await main());
