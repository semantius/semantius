// =============================================================================
// drizzle-proxy.ts — wire Drizzle to the OAUTHBEARER transport via `pg-proxy`.
// =============================================================================
//
// Drizzle's own PostgreSQL drivers (node-postgres, postgres.js, …) can't speak
// SASL OAUTHBEARER and offer no hook to inject a pre-minted token. But Drizzle
// ships a driver-agnostic escape hatch: `drizzle-orm/pg-proxy`. You hand it ONE
// async callback `(sql, params, method) => ({ rows })` and Drizzle does the rest
// (query building, schema typing, the relational query API).
//
// Our transport already returns rows as arrays of TEXT column values in result
// order — exactly the shape pg-proxy expects. Drizzle then maps those values to
// JS types using the generated schema, so a `db.select(...)` comes back typed.
//
// Typing the results: the transport delivers values in PostgreSQL's TEXT wire
// format (strings), but it also exposes the type OID of every column (from the
// wire RowDescription). That's all we need to produce real JS types. We run each
// value through node-postgres' own `pg-types` parser keyed by that OID — the
// exact decoding node-postgres does internally — so integers come back as
// numbers, booleans as booleans, timestamps as Dates, jsonb as objects, etc.
// Those are precisely the shapes Drizzle's column mappers expect, so a typed
// `db.select()` returns correctly-typed values, not strings.
// =============================================================================

import { drizzle } from "drizzle-orm/pg-proxy";
import { getTypeParser } from "pg-types";
import { PgOAuthConnection } from "./pg-oauthbearer";
import * as schema from "./schema";

/** Build a Drizzle db (with the full relational schema) over an open transport. */
export function createDb(conn: PgOAuthConnection) {
  return drizzle(
    async (sql, params) => {
      const result = await conn.query(sql, params);
      // Decode each TEXT value with the parser for its column's type OID. NULLs
      // pass through untouched. pg-proxy wants `{ rows }` as arrays of column
      // values in result order — which is what we return.
      const parsers = result.fieldTypes.map((oid: number) => getTypeParser(oid));
      const rows = result.rows.map((row: (string | null)[]) =>
        row.map((value: string | null, i: number) =>
          value === null ? null : parsers[i](value)
        )
      );
      return { rows };
    },
    { schema },
  );
}
