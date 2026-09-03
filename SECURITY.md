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

You will get an acknowledgement within three working days and an assessment
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
  restore, or drop of the extension.

## What is not

These are documented behaviors rather than defects. If you think the reasoning
is wrong, say so, but they will not be treated as vulnerabilities.

- **Session mode trusts the application tier.** When an application connects
  as `semantius_authenticator`, switches to the request role and writes the
  JWT claim settings itself, that application is the trust boundary: whoever
  can run SQL as the request role can set any claim, `sub` included. Deploy
  through PostgREST or an app server you control, never hand the request role
  to end users, and set `jwt_aud` in `_settings` so tokens minted for another
  audience are rejected.
- **The transaction-scoped context cache is client-writable.** The `app.*`
  settings written by `rbac.ensure_context_initialized()` are ordinary
  settings. Behind PostgREST or an app server the client never runs SQL, so
  they are out of reach. In a PostgreSQL 18 OAuth bearer session the client
  does run SQL, and there the cache is disabled and permissions are derived on
  every check.
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
- **An API key is its owner.** A key authenticates as the user it belongs to
  and carries every permission that user holds; there is no per-key scope.
  Keep an administrator's key where you keep the administrator's password.
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
