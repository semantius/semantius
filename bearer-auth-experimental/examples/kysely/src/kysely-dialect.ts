// =============================================================================
// kysely-dialect.ts — a Kysely Dialect that authenticates with an OAuth bearer
// token over SASL OAUTHBEARER, instead of the usual user/password.
// =============================================================================
//
// Kysely's stock PostgresDialect runs on node-postgres (`pg`), which only speaks
// SCRAM / MD5 / cleartext — not OAUTHBEARER — and offers no hook to inject a
// pre-minted token. So we keep everything Kysely gives us for PostgreSQL (the
// query compiler, the SQL adapter, schema introspection) and swap in a custom
// Driver whose transport is the hand-rolled OAUTHBEARER client in
// ./pg-oauthbearer. Result: real Kysely query building, OAuth-authenticated
// connections.
//
// DIFFERENCE FROM kysely-raw: this typed example decodes values to real JS types
// so they match the generated Kysely types (see ./types). The transport speaks
// PostgreSQL's TEXT wire format — every value arrives as a string — but the wire
// RowDescription also carries each column's type OID (exposed as `fieldTypes`).
// That's all we need: we run each value through node-postgres' own `pg-types`
// parser keyed by that OID — the exact decoding node-postgres does internally —
// so integers come back as numbers, booleans as booleans, timestamps as Dates,
// jsonb as objects, etc. The kysely-raw dialect skips this and leaves everything
// a string (that example has no types to honor).
//
// This is intentionally minimal (one connection, no pool). See pg-oauthbearer.ts
// for the caveats.
// =============================================================================

import {
  CompiledQuery,
  type DatabaseConnection,
  type DatabaseIntrospector,
  type Dialect,
  type DialectAdapter,
  type Driver,
  type Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type QueryCompiler,
  type QueryResult,
  type TransactionSettings,
} from "kysely";
import { getTypeParser } from "pg-types";
import { PgOAuthConnection, type PgConnectOptions } from "./pg-oauthbearer";

export interface OAuthBearerDialectConfig extends PgConnectOptions {}

/**
 * A Kysely Dialect that connects to PostgreSQL 18 using a pre-minted OAuth
 * access token (SASL OAUTHBEARER). Reuses Kysely's PostgreSQL compiler/adapter/
 * introspector; only the transport is custom.
 */
export class OAuthBearerDialect implements Dialect {
  readonly #config: OAuthBearerDialectConfig;

  constructor(config: OAuthBearerDialectConfig) {
    this.#config = config;
  }

  createDriver(): Driver {
    return new OAuthBearerDriver(this.#config);
  }

  createQueryCompiler(): QueryCompiler {
    return new PostgresQueryCompiler();
  }

  createAdapter(): DialectAdapter {
    return new PostgresAdapter();
  }

  createIntrospector(db: Kysely<unknown>): DatabaseIntrospector {
    return new PostgresIntrospector(db);
  }
}

class OAuthBearerDriver implements Driver {
  readonly #config: OAuthBearerDialectConfig;
  #connection?: OAuthBearerConnection;

  constructor(config: OAuthBearerDialectConfig) {
    this.#config = config;
  }

  async init(): Promise<void> {
    const raw = await PgOAuthConnection.connect(this.#config);
    this.#connection = new OAuthBearerConnection(raw);
  }

  async acquireConnection(): Promise<DatabaseConnection> {
    if (!this.#connection) {
      throw new Error("OAuthBearerDriver.init() has not completed");
    }
    return this.#connection;
  }

  async beginTransaction(
    connection: DatabaseConnection,
    settings: TransactionSettings,
  ): Promise<void> {
    const sql = settings.isolationLevel
      ? `start transaction isolation level ${settings.isolationLevel}`
      : "begin";
    await connection.executeQuery(CompiledQuery.raw(sql));
  }

  async commitTransaction(connection: DatabaseConnection): Promise<void> {
    await connection.executeQuery(CompiledQuery.raw("commit"));
  }

  async rollbackTransaction(connection: DatabaseConnection): Promise<void> {
    await connection.executeQuery(CompiledQuery.raw("rollback"));
  }

  // Single shared connection: nothing to release between queries.
  async releaseConnection(): Promise<void> {}

  async destroy(): Promise<void> {
    await this.#connection?.raw.end();
  }
}

class OAuthBearerConnection implements DatabaseConnection {
  readonly raw: PgOAuthConnection;

  constructor(raw: PgOAuthConnection) {
    this.raw = raw;
  }

  async executeQuery<R>(compiledQuery: CompiledQuery): Promise<QueryResult<R>> {
    const { fields, fieldTypes, rows, command, rowCount } = await this.raw.query(
      compiledQuery.sql,
      compiledQuery.parameters,
    );

    // Decode each TEXT value with node-postgres' parser for its column's type
    // OID, then key the result by column name. NULLs pass through untouched.
    // This is what makes the generated types honest: `id` is 1, not "1".
    const parsers = fieldTypes.map((oid) => getTypeParser(oid));
    const mapped = rows.map((values) => {
      const row: Record<string, unknown> = {};
      for (let i = 0; i < fields.length; i++) {
        const value = values[i];
        row[fields[i]] = value === null ? null : parsers[i](value);
      }
      return row;
    }) as R[];

    // For INSERT/UPDATE/DELETE/MERGE, surface the affected-row count.
    const numAffectedRows = /^(insert|update|delete|merge)\b/i.test(command)
      ? BigInt(rowCount)
      : undefined;

    return { rows: mapped, numAffectedRows };
  }

  // Streaming would need the Execute "max rows" / portal-suspend loop; not
  // implemented in this example.
  // eslint-disable-next-line require-yield
  async *streamQuery<R>(): AsyncIterableIterator<QueryResult<R>> {
    throw new Error(
      "streamQuery is not implemented in the OAuthBearer example dialect",
    );
  }
}
