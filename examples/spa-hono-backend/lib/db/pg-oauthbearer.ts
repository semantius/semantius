// VENDORED from examples/transport/src/pg-oauthbearer.ts — the canonical copy.
// This file is dependency-free; to update, re-copy it from there (or depend on
// @semantius/pg-oauthbearer via "file:../transport" instead of vendoring).
//
// =============================================================================
// pg-oauthbearer.ts — a tiny PostgreSQL client that authenticates with a
// pre-minted OAuth bearer token over SASL OAUTHBEARER (RFC 7628).
// =============================================================================
//
// WHY THIS EXISTS
// ---------------
// PostgreSQL 18 added native OAuth via the SASL `OAUTHBEARER` mechanism. The
// Semantius self-host stack uses it: the `authenticated` role is `oauth`-only in
// pg_hba.conf, so a client connecting as `authenticated` MUST present its bearer
// token inside the SASL handshake — there is NO "JWT in the connection string"
// and NO password field for it.
//
// No Node Postgres driver (node-postgres / postgres.js) speaks OAUTHBEARER yet,
// and none exposes a hook to inject a pre-minted token. libpq itself only does
// the *interactive* device flow (the client fetches its own token) — it cannot
// inject a token you already hold. So this module speaks just enough of the
// PostgreSQL v3 wire protocol, by hand, to:
//
//   1. open a TCP socket and send the StartupMessage as role `authenticated`,
//   2. authenticate with SASL OAUTHBEARER, presenting a bearer token,
//   3. run parameterized queries via the extended-query protocol
//      (Parse / Bind / Describe / Execute / Sync) and return the rows.
//
// It is a direct Node port of pgdocker/verify_oauth.ts (which uses the *simple*
// query protocol with no parameters); the extended-query path here is what lets
// a query builder send `$1, $2, …` parameters.
//
// SCOPE / CAVEATS (this is an example, not a production driver):
//   - one connection, not a pool (queries are serialized on the wire);
//   - all parameters and all results use the TEXT wire format — values come back
//     as strings (or null). Callers/ORMs map them to JS types.
//   - no TLS here (the local pgdocker stack uses plain `host`); for any non-local
//     deployment use `hostssl` and wrap the socket in tls.connect().
// =============================================================================

import * as net from "node:net";

export interface PgConnectOptions {
  host: string;
  port: number;
  database: string;
  /** PostgreSQL role to connect as. Defaults to `authenticated`. */
  user?: string;
  /** A pre-minted OAuth 2.0 access token (JWT) for the OAUTHBEARER handshake. */
  token: string;
}

export interface RawQueryResult {
  /** Column names, in result order (from the RowDescription message). */
  fields: string[];
  /**
   * PostgreSQL type OID per column, in result order (from RowDescription).
   * Values themselves still come back as TEXT (see `rows`); callers that want
   * JS-typed values can feed each value through a parser keyed by its OID
   * (e.g. node-postgres' `pg-types` `getTypeParser(oid)`).
   */
  fieldTypes: number[];
  /** One array of TEXT-format column values (or null) per row, in column order. */
  rows: (string | null)[][];
  /** The CommandComplete tag, e.g. "SELECT 5" or "INSERT 0 1". */
  command: string;
  /** Affected/returned row count parsed from the command tag. */
  rowCount: number;
}

// ---- PostgreSQL v3 message type bytes ---------------------------------------
// Backend (server -> client). Some bytes overlap with frontend types below; the
// direction (read vs write) disambiguates, so there is no ambiguity in practice.
const B_AUTH = 0x52; // 'R' Authentication*
const B_ERROR = 0x45; // 'E' ErrorResponse
const B_READY = 0x5a; // 'Z' ReadyForQuery
const B_ROW_DESC = 0x54; // 'T' RowDescription
const B_DATA_ROW = 0x44; // 'D' DataRow
const B_CMD_DONE = 0x43; // 'C' CommandComplete
const B_PARSE_OK = 0x31; // '1' ParseComplete
const B_BIND_OK = 0x32; // '2' BindComplete
// (ParameterStatus 'S', BackendKeyData 'K', NoticeResponse 'N', NoData 'n',
//  EmptyQueryResponse 'I' are all simply ignored below.)

// Frontend (client -> server) message type bytes.
const F_SASL = 0x70; // 'p' SASLInitialResponse / SASLResponse / PasswordMessage
const F_PARSE = 0x50; // 'P' Parse
const F_BIND = 0x42; // 'B' Bind
const F_DESCRIBE = 0x44; // 'D' Describe
const F_EXECUTE = 0x45; // 'E' Execute
const F_SYNC = 0x53; // 'S' Sync
const F_TERMINATE = 0x58; // 'X' Terminate

interface BackendMessage {
  type: number;
  payload: Buffer;
}

export class PgOAuthConnection {
  readonly #socket: net.Socket;
  readonly #user: string;

  // Incremental backend-message reader.
  #buffer: Buffer = Buffer.alloc(0);
  #queued: BackendMessage[] = [];
  #waiter: ((msg: BackendMessage) => void) | null = null;
  #waiterReject: ((err: Error) => void) | null = null;
  #failure: Error | null = null;

  // Serializes queries onto the single connection so overlapping callers cannot
  // interleave their messages on the wire.
  #chain: Promise<unknown> = Promise.resolve();

  private constructor(socket: net.Socket, user: string) {
    this.#socket = socket;
    this.#user = user;
    socket.setNoDelay(true);
    socket.on("data", (chunk) => this.#onData(chunk));
    socket.on("error", (err) => this.#onFailure(err));
    socket.on("close", () =>
      this.#onFailure(new Error("connection closed by server")),
    );
  }

  /** Open a socket, authenticate via SASL OAUTHBEARER, and return a ready connection. */
  static connect(opts: PgConnectOptions): Promise<PgOAuthConnection> {
    return new Promise((resolve, reject) => {
      const socket = net.connect({ host: opts.host, port: opts.port });
      const onConnectError = (err: Error) => reject(err);
      socket.once("error", onConnectError);
      socket.once("connect", () => {
        socket.removeListener("error", onConnectError);
        const conn = new PgOAuthConnection(socket, opts.user ?? "authenticated");
        conn
          .#handshake(opts.database, opts.token)
          .then(() => resolve(conn))
          .catch((err) => {
            socket.destroy();
            reject(err);
          });
      });
    });
  }

  /**
   * Run a query through the extended-query protocol and return the raw rows.
   * `params` are sent in TEXT format; results come back in TEXT format.
   */
  query(sql: string, params: readonly unknown[] = []): Promise<RawQueryResult> {
    const run = () => this.#runQuery(sql, params);
    const result = this.#chain.then(run, run);
    // Keep the chain alive regardless of this query's outcome.
    this.#chain = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** Send Terminate and close the socket. */
  async end(): Promise<void> {
    try {
      this.#socket.write(frame(F_TERMINATE, Buffer.alloc(0)));
    } catch {
      // socket may already be gone; nothing to do.
    }
    this.#socket.destroy();
  }

  // ---- handshake -----------------------------------------------------------

  async #handshake(database: string, token: string): Promise<void> {
    // StartupMessage has no type byte: Int32 length + Int32 protocol(3.0) + params.
    const params = Buffer.from(
      `user\0${this.#user}\0database\0${database}\0\0`,
      "utf8",
    );
    const startup = Buffer.allocUnsafe(8 + params.length);
    startup.writeUInt32BE(8 + params.length, 0);
    startup.writeUInt32BE(196608, 4); // protocol version 3.0
    params.copy(startup, 8);
    this.#socket.write(startup);

    // Expect AuthenticationSASL (type 'R', auth code 10) advertising OAUTHBEARER.
    const sasl = await this.#readMessage();
    if (sasl.type !== B_AUTH) {
      throw new Error(`expected Authentication ('R'), got '${ascii(sasl.type)}'`);
    }
    if (sasl.payload.readUInt32BE(0) !== 10) {
      throw new Error("server did not request SASL authentication (need PG18 OAuth)");
    }
    const mechs = parseCStrings(sasl.payload.subarray(4));
    if (!mechs.includes("OAUTHBEARER")) {
      throw new Error(
        `server did not offer OAUTHBEARER (offered: ${mechs.join(", ") || "none"})`,
      );
    }

    // SASLInitialResponse: mechanism cstring + Int32 length + the RFC 7628 payload.
    const initial = Buffer.from(`n,,\x01auth=Bearer ${token}\x01\x01`, "utf8");
    const mechName = Buffer.from("OAUTHBEARER\0", "utf8");
    const body = Buffer.allocUnsafe(mechName.length + 4 + initial.length);
    mechName.copy(body, 0);
    body.writeInt32BE(initial.length, mechName.length);
    initial.copy(body, mechName.length + 4);
    this.#socket.write(frame(F_SASL, body));

    // Read until ReadyForQuery; accept AuthenticationOk, answer a SASL failure
    // challenge with the kvsep error response (matching verify_oauth.ts).
    let authenticated = false;
    for (;;) {
      const msg = await this.#readMessage();
      if (msg.type === B_AUTH) {
        const code = msg.payload.readUInt32BE(0);
        if (code === 0) authenticated = true; // AuthenticationOk
        else if (code === 11) this.#socket.write(frame(F_SASL, Buffer.from([0x01])));
      } else if (msg.type === B_ERROR) {
        throw new Error(`authentication failed: ${parseError(msg.payload)}`);
      } else if (msg.type === B_READY) {
        break;
      }
      // ParameterStatus / BackendKeyData / NoticeResponse: ignore.
    }
    if (!authenticated) {
      throw new Error("authentication failed: no AuthenticationOk from server");
    }
  }

  // ---- extended query ------------------------------------------------------

  async #runQuery(sql: string, params: readonly unknown[]): Promise<RawQueryResult> {
    const encoded = params.map(encodeParam);

    // Parse: unnamed statement, query text, 0 declared parameter types.
    const parse = Buffer.concat([cstr(""), cstr(sql), int16(0)]);

    // Bind: unnamed portal + unnamed statement, all-text params, all-text results.
    const bindParts: Buffer[] = [
      cstr(""), // portal
      cstr(""), // statement
      int16(0), // 0 parameter format codes => every parameter is TEXT
      int16(encoded.length),
    ];
    for (const value of encoded) {
      bindParts.push(value === null ? int32(-1) : Buffer.concat([int32(value.length), value]));
    }
    bindParts.push(int16(0)); // 0 result format codes => every column is TEXT
    const bind = Buffer.concat(bindParts);

    // Describe the portal (yields a RowDescription), Execute all rows, Sync.
    const describe = Buffer.concat([Buffer.from("P", "ascii"), cstr("")]);
    const execute = Buffer.concat([cstr(""), int32(0)]); // 0 = no row limit

    this.#socket.write(frame(F_PARSE, parse));
    this.#socket.write(frame(F_BIND, bind));
    this.#socket.write(frame(F_DESCRIBE, describe));
    this.#socket.write(frame(F_EXECUTE, execute));
    this.#socket.write(frame(F_SYNC, Buffer.alloc(0)));

    let fields: string[] = [];
    let fieldTypes: number[] = [];
    const rows: (string | null)[][] = [];
    let command = "";
    let pendingError: string | null = null;

    for (;;) {
      const msg = await this.#readMessage();
      switch (msg.type) {
        case B_ROW_DESC: {
          const desc = parseRowDescription(msg.payload);
          fields = desc.names;
          fieldTypes = desc.oids;
          break;
        }
        case B_DATA_ROW:
          rows.push(parseDataRow(msg.payload));
          break;
        case B_CMD_DONE:
          command = cstringAt(msg.payload, 0);
          break;
        case B_ERROR:
          // Record it, but keep reading until ReadyForQuery so the connection
          // stays in sync and remains reusable.
          pendingError = parseError(msg.payload);
          break;
        case B_READY:
          if (pendingError) throw new Error(pendingError);
          return { fields, fieldTypes, rows, command, rowCount: parseRowCount(command) };
        // ParseComplete / BindComplete / NoData / others: ignore.
        case B_PARSE_OK:
        case B_BIND_OK:
        default:
          break;
      }
    }
  }

  // ---- socket message reader ----------------------------------------------

  #onData(chunk: Buffer): void {
    this.#buffer = this.#buffer.length ? Buffer.concat([this.#buffer, chunk]) : chunk;
    // Every backend message is: Byte1 type + Int32 length(incl. self) + payload.
    while (this.#buffer.length >= 5) {
      const length = this.#buffer.readUInt32BE(1);
      if (this.#buffer.length < 1 + length) break;
      const message: BackendMessage = {
        type: this.#buffer[0],
        payload: this.#buffer.subarray(5, 1 + length),
      };
      this.#buffer = this.#buffer.subarray(1 + length);
      this.#deliver(message);
    }
  }

  #deliver(message: BackendMessage): void {
    if (this.#waiter) {
      const resolve = this.#waiter;
      this.#waiter = null;
      this.#waiterReject = null;
      resolve(message);
    } else {
      this.#queued.push(message);
    }
  }

  #onFailure(err: Error): void {
    this.#failure = err;
    if (this.#waiterReject) {
      const reject = this.#waiterReject;
      this.#waiter = null;
      this.#waiterReject = null;
      reject(err);
    }
  }

  #readMessage(): Promise<BackendMessage> {
    const queued = this.#queued.shift();
    if (queued) return Promise.resolve(queued);
    if (this.#failure) return Promise.reject(this.#failure);
    return new Promise((resolve, reject) => {
      this.#waiter = resolve;
      this.#waiterReject = reject;
    });
  }
}

// ---- wire helpers -----------------------------------------------------------

/** Byte1 type + Int32 length (incl. self) + payload. */
function frame(type: number, payload: Buffer): Buffer {
  const msg = Buffer.allocUnsafe(5 + payload.length);
  msg[0] = type;
  msg.writeUInt32BE(4 + payload.length, 1);
  payload.copy(msg, 5);
  return msg;
}

function int16(n: number): Buffer {
  const b = Buffer.allocUnsafe(2);
  b.writeUInt16BE(n & 0xffff, 0);
  return b;
}

function int32(n: number): Buffer {
  const b = Buffer.allocUnsafe(4);
  b.writeInt32BE(n, 0);
  return b;
}

function cstr(s: string): Buffer {
  return Buffer.concat([Buffer.from(s, "utf8"), Buffer.from([0])]);
}

/** Serialize a JS parameter to its PostgreSQL TEXT representation (or null). */
function encodeParam(value: unknown): Buffer | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") return Buffer.from(value, "utf8");
  if (typeof value === "number" || typeof value === "bigint") {
    return Buffer.from(String(value), "utf8");
  }
  if (typeof value === "boolean") return Buffer.from(value ? "true" : "false", "utf8");
  if (value instanceof Date) return Buffer.from(value.toISOString(), "utf8");
  // Arrays / objects: send as JSON text (fine for json/jsonb columns).
  return Buffer.from(JSON.stringify(value), "utf8");
}

/** Read a NUL-terminated string starting at `offset`. */
function cstringAt(buf: Buffer, offset: number): string {
  const end = buf.indexOf(0, offset);
  return buf.toString("utf8", offset, end === -1 ? buf.length : end);
}

/** Split a buffer of consecutive NUL-terminated strings into an array. */
function parseCStrings(buf: Buffer): string[] {
  const out: string[] = [];
  let offset = 0;
  while (offset < buf.length && buf[offset] !== 0) {
    const end = buf.indexOf(0, offset);
    const stop = end === -1 ? buf.length : end;
    out.push(buf.toString("utf8", offset, stop));
    offset = stop + 1;
  }
  return out;
}

function parseRowDescription(payload: Buffer): { names: string[]; oids: number[] } {
  const count = payload.readUInt16BE(0);
  const names: string[] = [];
  const oids: number[] = [];
  let offset = 2;
  for (let i = 0; i < count; i++) {
    const end = payload.indexOf(0, offset);
    names.push(payload.toString("utf8", offset, end));
    // name + NUL, then 18 fixed bytes: tableOID(4) col(2) typeOID(4) typeLen(2)
    // typeMod(4) format(2). The type OID sits 6 bytes in (after tableOID+col).
    const fieldStart = end + 1;
    oids.push(payload.readUInt32BE(fieldStart + 6));
    offset = fieldStart + 18;
  }
  return { names, oids };
}

function parseDataRow(payload: Buffer): (string | null)[] {
  const count = payload.readUInt16BE(0);
  const values: (string | null)[] = [];
  let offset = 2;
  for (let i = 0; i < count; i++) {
    const length = payload.readInt32BE(offset);
    offset += 4;
    if (length === -1) {
      values.push(null);
    } else {
      values.push(payload.toString("utf8", offset, offset + length));
      offset += length;
    }
  }
  return values;
}

/** Extract the human-readable message ('M' field) from an ErrorResponse. */
function parseError(payload: Buffer): string {
  let offset = 0;
  while (offset < payload.length && payload[offset] !== 0) {
    const code = payload[offset];
    offset += 1;
    const end = payload.indexOf(0, offset);
    const stop = end === -1 ? payload.length : end;
    const value = payload.toString("utf8", offset, stop);
    if (code === 0x4d /* 'M' */) return value;
    offset = stop + 1;
  }
  return "database error";
}

/** "SELECT 5" -> 5, "INSERT 0 3" -> 3, "BEGIN" -> 0. */
function parseRowCount(command: string): number {
  const match = command.match(/(\d+)\s*$/);
  return match ? Number(match[1]) : 0;
}

function ascii(byte: number): string {
  return byte >= 0x20 && byte < 0x7f ? String.fromCharCode(byte) : `0x${byte.toString(16)}`;
}
