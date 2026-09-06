import type { ExtractTablesWithRelations } from "drizzle-orm";
import type { PgDatabase } from "drizzle-orm/pg-core";
import type * as schema from "./schema";

export type Schema = typeof schema;

/**
 * The narrow, adapter-agnostic Drizzle surface the data layer codes against.
 *
 * Both adapters build a Drizzle db over the SAME generated schema, but with
 * different concrete types:
 *   - bearer  -> drizzle-orm/pg-proxy   (PgRemoteDatabase<Schema>)
 *   - session -> a node-postgres tx     (PgTransaction<…, Schema, …>)
 *
 * Both extend PgDatabase<TQueryResultHKT, Schema, …>. We erase ONLY the
 * query-result HKT (the single thing that differs between the drivers) to `any`,
 * so one type unifies them while keeping the full typed query builder and the
 * relational `query` API:
 *
 *   db.select({ … }).from(users)
 *   db.query.users.findMany({ with: { userRolesUser: { with: { role: true } } } })
 *   db.execute(sql`select public.get_userinfo()`)
 *
 * This is why getDb() returns "the narrow common query interface", not "the tx
 * instance" — the data layer must stay adapter-agnostic (plan §2).
 */
export type DbHandle = PgDatabase<any, Schema, ExtractTablesWithRelations<Schema>>;
