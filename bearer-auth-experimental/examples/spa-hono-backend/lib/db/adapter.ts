import type { DbHandle } from "./types";
import type { VerifiedClaims } from "./verify";

export type DbAuthMode = "bearer" | "session";

export interface SessionContext {
  /**
   * The raw access token. In BEARER mode it authenticates the DB connection
   * itself (SASL OAUTHBEARER); the DB validates its signature.
   */
  token: string;
  /**
   * The claims for this request. In SESSION mode these are the APP-VERIFIED
   * claims that get injected into request.jwt.claims (the app is the trust
   * boundary). In BEARER mode they are decoded-but-unverified and used only for
   * display — the DB is authoritative for identity (system_user), so the adapter
   * ignores them.
   */
  claims: VerifiedClaims;
}

export interface DbAdapter {
  readonly mode: DbAuthMode;
  /** One-time startup assertion (session: refuse a superuser/BYPASSRLS connection). */
  init?(): Promise<void>;
  /**
   * Open a connection + BEGIN, (session) SET LOCAL ROLE authenticated + inject
   * claims, run `fn` with the tx Drizzle handle, then COMMIT on success /
   * ROLLBACK on throw, and release. Returns fn's result.
   */
  runInSession<T>(ctx: SessionContext, fn: (db: DbHandle) => Promise<T>): Promise<T>;
  /** Close pools etc. (graceful shutdown / tests). */
  close?(): Promise<void>;
}
