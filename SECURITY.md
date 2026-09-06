# Security policy

## Reporting a vulnerability

Please report privately, not as a public issue.

Use GitHub's private
[security advisory](https://github.com/semantius/semantius/security/advisories/new)
form. It is the only reporting channel, and it is private until an advisory is
published.

Include enough to reproduce it: the extension version or commit, how the
database is reached (PostgREST, an app server in session mode, a direct
connection), the role and permissions of the caller, and what an attacker
gets. A proof of concept is welcome and never required.

You will get an acknowledgment within three working days and an assessment
within ten. If we disagree that something is a vulnerability, you will get the
reasoning rather than silence.

Please do not test against a database you do not run.

## What is in scope

`pg_semantius`, the PostgreSQL extension in this repository: the migrations
under `apps/_core/migrations`, the generated scripts under `extension/`, and
the tooling that generates and releases them. Anything that lets a caller do
one of these is a vulnerability:

- read or change rows their permissions do not cover, through the generated
  row-level security policies, the public RPC functions, or the queue RPCs;
- hold a permission or the Administrator role they were not granted, or act as
  another subject: the JWT gate `rbac.uid()`, the request context, the
  first-user bootstrap, API keys;
- run SQL or DDL of their choosing through the data dictionary, that is,
  metadata an administrator can edit reaching generated SQL unquoted
  (defaults, validation rules, computed fields, identifiers);
- learn about rows they cannot read, through the audit log or the change
  queue;
- leave privileges wider than documented after an install, upgrade, dump and
  restore, or drop of the extension. `DROP EXTENSION` removes only the
  `semantius` schema and its installer functions; it never touches data,
  policies or grants.

## What is not

These are documented behaviors rather than defects. If you think the reasoning
is wrong, say so, but they will not be treated as vulnerabilities.

- **A restore by a differently named superuser loses the installer's default
  privileges.** The extension's `ALTER DEFAULT PRIVILEGES` entries bind to the
  role that installed it, so restoring a dump as a superuser with a different
  name leaves the four schemas and the event triggers owned by the restorer
  and drops those entries: the request role's data access on future tables in
  `public` and its EXECUTE on future functions in `rbac`.
  `semantius.status()` reports the drift. `pg_restore --no-owner` additionally
  loses `OWNER TO semantius_owner`, so the dictionary's SECURITY DEFINER code
  would run as the restorer. Restore as the same superuser name, without
  `--no-owner`.
- **A function you create by hand in any of the extension's schemas is
  PUBLIC-executable.** PostgreSQL grants EXECUTE to PUBLIC on every new
  function, and the `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS
  FROM PUBLIC` entries do not change that: `pg_default_acl` records only the
  privileges a schema *adds*, so a revoke of the built-in PUBLIC grant is not
  representable there and is dropped. In `rbac` the effect is wider, because the
  surviving `GRANT EXECUTE ... TO semantius_user` in the same entry does apply:
  a function you add there is PUBLIC-executable *and* automatically exposed to
  the request role over RPC. This is a property of any install, restored or not.
  The extension's own functions are revoked explicitly instead, and guard test
  `0060_test_security.sql` fails if one is missed; a function you add needs its
  own `REVOKE`, whether or not it is SECURITY DEFINER.
- **Session mode trusts the application tier.** When an application connects
  as `semantius_authenticator`, switches to the request role and writes the
  JWT claim settings itself, that application is the trust boundary: whoever
  can run SQL as the request role can set any claim, `sub` included. Deploy
  through PostgREST or an app server you control, never hand the request role
  to end users, and set `jwt_aud` in `_settings` so tokens minted for another
  audience are rejected.
- **The transaction-scoped context cache is client-writable, and it stays
  that way.** The `app.*` settings written by
  `rbac.ensure_context_initialized()` are ordinary settings. Behind PostgREST
  or an app server the client never runs SQL, so they are out of reach. In a
  PostgreSQL 18 OAuth bearer session the client does run SQL, and there the
  cache is disabled and permissions are derived on every check. The obvious
  hardening - build the context once per request in a `VOLATILE` entry point
  and leave the readers pure - is **not** what happens, because it needs a
  per-request seam. The primary deployment target is Neon's managed Data API,
  which is Neon's own PostgREST: no code of ours runs per request there and
  there is no `db-pre-request` hook, so every permission check would run
  permanently cold - about 1 ms instead of 0.025 ms, and once per *row*
  wherever the JsonLogic `has_permission` operator appears. The readers keep
  their lazy write instead. Everything they write is transaction-local, so a
  rolled-back request leaves nothing behind; the full contract is in the
  comment above `rbac.uid()`.
- **Bearer mode is experimental.** PostgreSQL 18 OAuth bearer authentication
  with `pg_oidc_validator` is a development configuration, not a deployment
  target. Its status and the remaining hardening are in
  [docs/bearer-mode-status.md](docs/bearer-mode-status.md).
- **The extension installs as superuser, and dictionary code runs as the
  schema owner.** Where the installer is a superuser, every core object is
  owned by `semantius_owner` (NOSUPERUSER, BYPASSRLS) and SECURITY DEFINER
  dictionary code runs with that role's powers; on managed platforms it runs
  as the installing role. An administrator can shape every managed table
  through the dictionary. That is what the `admin` permission means.
- **A table created by hand in `public` is writable by the request role until
  it gets row-level security.** Default privileges grant the request role
  data access on future tables in `public`. Tables created through the data
  dictionary always get their policies; tables created outside it need their
  own.
- **Every principal carries a non-empty `external_id`, and that is its
  identity.** A session is a JWT, and the caller is the `users` row whose
  `external_id` equals the `sub` claim, for users and agents alike; an API key
  resolves to a user id, and the JWT minted from it carries that row's
  `external_id` as `sub`. A user brings theirs from the authentication
  provider and is refused without one. An agent (`is_agent`) saved without one
  gets a generated `agent:<uuid>` from a trigger. The column refuses the empty
  string for both (`users_external_id_not_empty`). Uniqueness is enforced by
  the data dictionary's partial unique index, which excludes `NULL` and `''`;
  with the empty string refused, it is total in effect.
- **An API key is its owner.** A key authenticates as the user it belongs to
  and carries every permission that user holds; there is no per-key scope.
  Keep an administrator's key where you keep the administrator's password.
- **The last enabled Administrator cannot be removed through the API.**
  Dropping the role from the last holder, deleting that user, disabling them, or
  deleting the Administrator role is refused, because every route back in is
  itself gated on `admin` and the first-user election fires only when a user row
  is created. A direct superuser or owner connection is exempt, so an operator
  can still empty the set deliberately; the next principal to log in *for the
  first time* is then elected.
- **pgmq's information functions are callable by the request role.** Queue
  names, metrics and topic bindings are readable. Queue contents are not:
  they are reachable only through the queue RPCs, which require the queue's
  view or manage permission.
- **JsonLogic rules have no recursion or size limit.** A select rule or
  validation rule can be made arbitrarily expensive by the administrator who
  writes it. This is accepted as a residual denial of service by a trusted
  role.
- **Anything requiring superuser, the schema owner, or the database's
  environment.** That is the trust boundary of any extension. Whoever holds
  it already holds what the extension protects.

## Supported versions

The latest minor release of the extension. Fixes go to `main` and a patch
release; older minors are not backported. Releases are tested on PostgreSQL
18.

## Handling

A confirmed vulnerability gets a private advisory, a fix, and a release. The
advisory is published once the fix is available, and credits the reporter
unless they ask otherwise.
