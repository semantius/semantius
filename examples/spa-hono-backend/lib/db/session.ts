// =============================================================================
// session.ts — the request-scoped session store.
//
// withSession(ctx, fn) opens ONE request-scoped transaction via the active
// adapter, places the tx Drizzle handle in AsyncLocalStorage, runs fn, then
// commits/rolls back/releases. getDb() reads the ambient handle, so the data
// layer (lib/dal/*) never threads a connection — and stays adapter-agnostic
// because getDb() returns the narrow DbHandle, not a concrete driver type.
//
// `export const runtime = 'nodejs'` is required on every route/page that reaches
// this (AsyncLocalStorage + the TCP/transport drivers are not Edge-compatible).
// =============================================================================

import { AsyncLocalStorage } from "node:async_hooks";
import { createBearerAdapter } from "./adapters/bearer";
import { createSessionAdapter } from "./adapters/session";
import type { DbAdapter, DbAuthMode, SessionContext } from "./adapter";
import type { DbHandle } from "./types";

interface Store {
  db: DbHandle;
}

const als = new AsyncLocalStorage<Store>();

let adapter: DbAdapter | null = null;

/** Resolve (and memoize) the active adapter from DB_AUTH_MODE. */
export function getAdapter(): DbAdapter {
  if (adapter) return adapter;
  const mode = (process.env.DB_AUTH_MODE ?? "bearer") as DbAuthMode;
  if (mode === "bearer") {
    adapter = createBearerAdapter();
  } else if (mode === "session") {
    adapter = createSessionAdapter();
  } else {
    throw new Error(`Invalid DB_AUTH_MODE=${String(mode)} (expected 'bearer' | 'session')`);
  }
  return adapter;
}

/**
 * Run `fn` inside one request-scoped transaction with the tx Drizzle handle
 * available via getDb(). The adapter handles BEGIN, (session) SET LOCAL ROLE +
 * claim injection, COMMIT/ROLLBACK, and release.
 */
export function withSession<T>(ctx: SessionContext, fn: () => Promise<T>): Promise<T> {
  return getAdapter().runInSession(ctx, (db) => als.run({ db }, fn));
}

/** The ambient request-scoped Drizzle handle. Throws if called outside withSession. */
export function getDb(): DbHandle {
  const store = als.getStore();
  if (!store) {
    throw new Error("getDb() was called outside of a withSession() scope");
  }
  return store.db;
}
