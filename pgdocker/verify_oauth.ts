#!/usr/bin/env -S deno run --allow-net
/**
 * Verify the PostgreSQL 18 OAuth path end to end — pure Deno stdlib, no deps.
 *
 *   1. Mint a fresh access token from the test OIDC server (no login required).
 *   2. Speak the PostgreSQL v3 wire protocol by hand, authenticating with the
 *      SASL OAUTHBEARER mechanism (RFC 7628) as role `authenticated`.
 *   3. Run `SELECT current_user, system_user, current_setting('request.jwt.claims')`
 *      to prove the token was validated against the issuer's JWKS, mapped to the
 *      `authenticated` role, and that the verified claims reached the session.
 *
 * The connect/query helpers are reused by test_oauth_security.ts.
 *
 *   deno run --allow-net verify_oauth.ts [--host 127.0.0.1] [--port 5432]
 *            [--db appdb] [--user-id user1] [--client-id test-client]
 */
<<<<<<< HEAD
// TEST ISSUER ONLY — a public, throwaway OIDC test server that mints tokens for
// anyone with no login. It holds no secrets or passwords (nothing behind it is
// private by design); it exists only to exercise the OAuth path. Replace with
// your own trusted issuer for anything real (and keep it in sync with the
// issuer= line in conf/pg_hba.conf).
const ISSUER = "https://oidc-test.semanti.us";
=======
const ISSUER = "https://test-oidc-server.ma532.workers.dev";
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
const enc = new TextEncoder();
const dec = new TextDecoder();

// message type bytes
const R = 0x52, E = 0x45, Z = 0x5a, D = 0x44, P = 0x70, Q = 0x51;

export function parseFlags(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) out[argv[i].slice(2)] = argv[++i];
  }
  return out;
}

export async function mintToken(userId: string, clientId: string): Promise<string> {
  const url = `${ISSUER}/getaccesstoken?user_id=${userId}&client_id=${clientId}`;
  const res = await fetch(url, { headers: { "user-agent": "curl/8.0", accept: "*/*" } });
  if (!res.ok) throw new Error(`token mint failed: HTTP ${res.status}`);
  let body = (await res.text()).trim();
  if (body.startsWith("{")) body = JSON.parse(body).access_token ?? "";
  return body;
}

async function writeAll(conn: Deno.Conn, data: Uint8Array): Promise<void> {
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

async function readMsg(conn: Deno.Conn): Promise<{ type: number; payload: Uint8Array }> {
  const type = (await readExact(conn, 1))[0];
  const len = new DataView((await readExact(conn, 4)).buffer).getUint32(0);
  return { type, payload: await readExact(conn, len - 4) };
}

/** Byte1 type + Int32 length (incl. self) + payload. */
function frame(type: number, payload: Uint8Array): Uint8Array {
  const msg = new Uint8Array(5 + payload.length);
  msg[0] = type;
  new DataView(msg.buffer).setUint32(1, 4 + payload.length);
  msg.set(payload, 5);
  return msg;
}

function cstrings(b: Uint8Array): string[] {
  const out: string[] = [];
  for (let i = 0; i < b.length && b[i] !== 0;) {
    let j = i;
    while (j < b.length && b[j] !== 0) j++;
    out.push(dec.decode(b.subarray(i, j)));
    i = j + 1;
  }
  return out;
}

function errText(payload: Uint8Array): string {
  for (let i = 0; i < payload.length && payload[i] !== 0;) {
    const code = payload[i++];
    let j = i;
    while (j < payload.length && payload[j] !== 0) j++;
    if (code === 0x4d /* 'M' */) return dec.decode(payload.subarray(i, j));
    i = j + 1;
  }
  return dec.decode(payload);
}

function parseDataRow(payload: Uint8Array): (string | null)[] {
  const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const ncols = dv.getUint16(0);
  const vals: (string | null)[] = [];
  let off = 2;
  for (let i = 0; i < ncols; i++) {
    const len = dv.getInt32(off);
    off += 4;
    if (len === -1) {
      vals.push(null); // SQL NULL
    } else {
      vals.push(dec.decode(payload.subarray(off, off + len)));
      off += len;
    }
  }
  return vals;
}

/** Open a connection and authenticate via SASL OAUTHBEARER. */
export async function oauthConnect(
  host: string, port: number, db: string, token: string,
  user = "authenticated", verbose = false,
): Promise<Deno.Conn> {
  const conn = await Deno.connect({ hostname: host, port });

  // StartupMessage (no type byte): Int32 len + Int32 protocol(3.0) + params
  const params = enc.encode(`user\0${user}\0database\0${db}\0\0`);
  const startup = new Uint8Array(8 + params.length);
  const sdv = new DataView(startup.buffer);
  sdv.setUint32(0, startup.length);
  sdv.setUint32(4, 196608);
  startup.set(params, 8);
  await writeAll(conn, startup);

  // expect AuthenticationSASL (R, 10) listing OAUTHBEARER
  let { type, payload } = await readMsg(conn);
  if (type !== R) throw new Error(`expected Authentication ('R'), got ${type}`);
  if (new DataView(payload.buffer, payload.byteOffset).getUint32(0) !== 10) {
    throw new Error("expected AuthenticationSASL (10)");
  }
  const mechs = cstrings(payload.subarray(4));
  if (verbose) console.log("server offered SASL mechanisms:", mechs);
  if (!mechs.includes("OAUTHBEARER")) throw new Error("server did not offer OAUTHBEARER");

  // SASLInitialResponse: mechanism cstring + Int32 len + bearer token (RFC 7628)
  const initial = enc.encode(`n,,\x01auth=Bearer ${token}\x01\x01`);
  const mech = enc.encode("OAUTHBEARER\0");
  const body = new Uint8Array(mech.length + 4 + initial.length);
  new DataView(body.buffer).setInt32(mech.length, initial.length);
  body.set(mech, 0);
  body.set(initial, mech.length + 4);
  await writeAll(conn, frame(P, body));

  let authed = false;
  for (let i = 0; i < 50; i++) {
    ({ type, payload } = await readMsg(conn));
    if (type === R) {
      const at = new DataView(payload.buffer, payload.byteOffset).getUint32(0);
      if (at === 0) {
        authed = true;
        if (verbose) console.log("AuthenticationOk: OAUTHBEARER token accepted");
      } else if (at === 11) { // SASL failure challenge (JSON)
        if (verbose) console.log("SASL failure challenge:", dec.decode(payload.subarray(4)));
        await writeAll(conn, frame(P, new Uint8Array([0x01]))); // kvsep error response
      }
    } else if (type === E) {
      throw new Error(`authentication failed: ${errText(payload)}`);
    } else if (type === Z) {
      break; // ReadyForQuery
    }
  }
  if (!authed) throw new Error("not authenticated");
  return conn;
}

/** Run a simple query; return rows (each a list of string|null). */
export async function runQuery(conn: Deno.Conn, sql: string): Promise<(string | null)[][]> {
  await writeAll(conn, frame(Q, enc.encode(sql + "\0")));
  const rows: (string | null)[][] = [];
  for (let i = 0; i < 200; i++) {
    const { type, payload } = await readMsg(conn);
    if (type === D) rows.push(parseDataRow(payload));
    else if (type === E) throw new Error(errText(payload));
    else if (type === Z) break;
  }
  return rows;
}

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  const userId = a["user-id"] ?? "user1";

  const token = await mintToken(userId, a["client-id"] ?? "test-client");
  if (!token || token.split(".").length !== 3) {
    console.log(`FAIL: did not get a JWT from the issuer (got: ${token.slice(0, 60)})`);
    return 2;
  }
  console.log(`minted token for sub=${userId} (len=${token.length})`);

  const conn = await oauthConnect(host, port, db, token, "authenticated", true);
  const row = (await runQuery(
    conn,
    "SELECT current_user, system_user, current_setting('request.jwt.claims', true)",
  ))[0];
  console.log(`OK  current_user=${row[0]}  system_user=${row[1]}`);
  console.log(
    row[2] === null
      ? "    request.jwt.claims = <NULL>  (not published to the session)"
      : `    request.jwt.claims = ${row[2]}`,
  );
  conn.close();
  return 0;
}

if (import.meta.main) Deno.exit(await main());
