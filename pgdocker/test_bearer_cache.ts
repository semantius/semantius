#!/usr/bin/env -S deno run --allow-net
/**
 * Hostile-client check of the permission cache over a REAL PostgreSQL 18
 * OAUTHBEARER session (release review S2).
 *
 * A bearer client runs SQL directly as the request role, and the app.* context
 * settings written by rbac.ensure_context_initialized() are ordinary GUCs the
 * client can overwrite. Core therefore bypasses that cache in bearer sessions
 * (rbac.is_bearer_session()) and re-derives the context on every call. This
 * script proves it from the outside:
 *
 *   1. Authenticate via OAUTHBEARER as a NON-admin subject (default: user1).
 *   2. Forge the whole cache at session level: context_initialized = true,
 *      user_permissions = 'admin,user:manage', current_user_id = 1003.
 *   3. Assert has_permission('admin') is still false, user_id() is still the
 *      real id, the admin-only `roles` table stays empty, require_permission
 *      raises 42501, whoami reports the cache as disabled, and the one-time
 *      WARNING was emitted exactly once for the session.
 *
 * Exit 0 = secure. Exit 1 = a check failed. Requires `_core` and the test
 * identities deployed in the target database.
 *
 *   deno run --allow-net test_bearer_cache.ts [--host 127.0.0.1] [--port 5432]
 *            [--db appdb] [--user-id user1] [--client-id test-client]
 */
import { mintToken, oauthConnect, parseFlags } from "./verify_oauth.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

async function writeAll(conn: Deno.Conn, data: Uint8Array) {
  for (let off = 0; off < data.length;) off += await conn.write(data.subarray(off));
}
async function readExact(conn: Deno.Conn, n: number): Promise<Uint8Array> {
  const buf = new Uint8Array(n);
  for (let off = 0; off < n;) {
    const r = await conn.read(buf.subarray(off));
    if (r === null) throw new Error("server closed the connection");
    off += r;
  }
  return buf;
}
async function readMsg(conn: Deno.Conn) {
  const type = (await readExact(conn, 1))[0];
  const len = new DataView((await readExact(conn, 4)).buffer).getUint32(0);
  return { type, payload: await readExact(conn, len - 4) };
}
/** ErrorResponse / NoticeResponse fields keyed by their one-letter code. */
function fields(payload: Uint8Array): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < payload.length && payload[i] !== 0;) {
    const code = String.fromCharCode(payload[i++]);
    let j = i;
    while (j < payload.length && payload[j] !== 0) j++;
    out[code] = dec.decode(payload.subarray(i, j));
    i = j + 1;
  }
  return out;
}
function parseDataRow(payload: Uint8Array): (string | null)[] {
  const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const n = dv.getUint16(0);
  const vals: (string | null)[] = [];
  let off = 2;
  for (let i = 0; i < n; i++) {
    const len = dv.getInt32(off);
    off += 4;
    if (len === -1) vals.push(null);
    else {
      vals.push(dec.decode(payload.subarray(off, off + len)));
      off += len;
    }
  }
  return vals;
}
/** Simple query that also collects NoticeResponse messages (the WARNING). */
async function query(conn: Deno.Conn, sql: string) {
  const body = enc.encode(sql + "\0");
  const msg = new Uint8Array(5 + body.length);
  msg[0] = 0x51; // 'Q'
  new DataView(msg.buffer).setUint32(1, 4 + body.length);
  msg.set(body, 5);
  await writeAll(conn, msg);
  const rows: (string | null)[][] = [];
  const notices: string[] = [];
  for (let i = 0; i < 500; i++) {
    const { type, payload } = await readMsg(conn);
    if (type === 0x44) rows.push(parseDataRow(payload)); // 'D' DataRow
    else if (type === 0x4e) { // 'N' NoticeResponse
      const f = fields(payload);
      notices.push(`${f.S}: ${f.M}`);
    } else if (type === 0x45) { // 'E' ErrorResponse
      const f = fields(payload);
      throw new Error(`${f.C} ${f.M}`);
    } else if (type === 0x5a) break; // 'Z' ReadyForQuery
  }
  return { rows, notices };
}

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  const userId = a["user-id"] ?? "user1"; // user1 = plain "User" role, not admin
  const token = await mintToken(userId, a["client-id"] ?? "test-client");
  const conn = await oauthConnect(host, port, db, token, "authenticated", false);
  console.log(`authenticated via OAUTHBEARER as ${userId}`);

  let fails = 0;
  const notices: string[] = [];
  const check = (name: string, ok: boolean, detail: string) => {
    console.log(`${ok ? "ok  " : "FAIL"} ${name}  [${detail}]`);
    if (!ok) fails++;
  };
  const q = async (sql: string) => {
    const r = await query(conn, sql);
    notices.push(...r.notices);
    return r.rows;
  };

  let id: (string | null)[];
  try {
    id = (await q("SELECT rbac.uid(), system_user"))[0];
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/rbac\.uid|schema "rbac"|does not exist/.test(msg)) {
      console.log(`SKIP: _core not deployed (rbac.uid() unavailable): ${msg}`);
      conn.close();
      return 2;
    }
    throw e;
  }
  check("identity pinned by system_user", id[0] === userId && id[1] === `oauth:${userId}`, `uid=${id[0]} system_user=${id[1]}`);

  const who = (await q("SELECT value FROM rbac.whoami() WHERE context_type = 'status' AND key = 'permission_cache'"))[0]?.[0];
  check("whoami reports the cache as disabled", who === "disabled (bearer session)", `${who}`);

  const before = (await q("SELECT rbac.has_permission('admin'), rbac.user_id()"))[0];
  check("baseline: subject is not admin", before[0] === "f", `has_permission(admin)=${before[0]} user_id=${before[1]}`);
  const realId = before[1];

  // ATTACK: forge the whole cache at session level so it survives across statements.
  await q(
    "SELECT set_config('app.context_initialized', 'true', false), " +
      "set_config('app.user_permissions', 'admin,user:manage', false), " +
      "set_config('app.current_user_id', '1003', false), " +
      "set_config('app.current_external_id', 'user3', false)",
  );
  console.log("ATTACK: client overwrote app.context_initialized / user_permissions / current_user_id");

  const after = (await q("SELECT rbac.has_permission('admin'), rbac.user_id(), current_setting('app.user_permissions', true)"))[0];
  check("forged app.user_permissions does not grant admin", after[0] === "f", `has_permission(admin)=${after[0]}`);
  check("forged app.current_user_id does not change user_id", after[1] === realId, `user_id=${after[1]} (real ${realId})`);
  check("the rebuild overwrote the forged permission list", after[2] !== "admin,user:manage", `app.user_permissions=${after[2]}`);

  const roles = (await q("SELECT count(*) FROM roles"))[0][0];
  check("admin-only table stays empty", roles === "0", `roles visible=${roles}`);

  let req = "no error";
  try {
    await q("SELECT rbac.require_permission('admin')");
  } catch (e) {
    req = e instanceof Error ? e.message : String(e);
  }
  check("require_permission(admin) raises 42501", req.startsWith("42501"), req);

  const warnings = notices.filter((n) => n.includes("permission cache is disabled"));
  check("one-time WARNING emitted exactly once per session", warnings.length === 1, `count=${warnings.length}`);
  if (warnings[0]) console.log(`    ${warnings[0]}`);

  conn.close();
  console.log(
    fails === 0
      ? "\nSECURE: the forged cache was ignored; bearer sessions re-derive the context on every check."
      : `\nVULNERABLE: ${fails} check(s) failed.`,
  );
  return fails === 0 ? 0 : 1;
}

if (import.meta.main) Deno.exit(await main());
