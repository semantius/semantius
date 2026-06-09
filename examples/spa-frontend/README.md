# React SPA sample — browser OAuth (PKCE) → Hono API

A browser **React + Vite SPA** that runs the **OAuth authorization-code + PKCE** flow
(no client secret) in the browser via **`react-oauth2-code-pkce`**, and calls the
standalone [`examples/spa-hono-backend`](../spa-hono-backend) Hono API with
`Authorization: Bearer`. It has **no database dependency whatsoever** — no Drizzle,
no node-postgres, no DB types. It defines its own minimal API DTOs (`src/types.ts`).

This is the decoupled SPA half of the sample pair. The server-rendered BFF
counterpart is [`examples/nextjs`](../nextjs); the resource server it talks to is
[`examples/spa-hono-backend`](../spa-hono-backend), which is where the DB / RLS /
trust-model documentation lives.

---

## Quick start

```bash
# 1. Start the API first (see ../spa-hono-backend/README.md)
cd ../spa-hono-backend && npm install && cp .env.example .env && npm run dev   # :8788

# 2. Start the SPA
cd ../spa-frontend
npm install
cp .env.example .env        # all values are PUBLIC (no secret in a PKCE client)
npm run dev                 # http://localhost:3000
```

Open <http://localhost:3000>, click **Log in**, sign in at the issuer (e.g.
`user1` / `password123`), and you land on `/users` (RLS read) with a write demo.
**The session survives a reload (F5)** — tokens are persisted (see below).

> **Port 3000 is required** — the issuer's redirect allow-list contains
> `http://localhost:3000/oauth2_callback` (Vite's default 5173 is **not**
> allow-listed). `strictPort` is set so dev fails loudly rather than moving to 3001.
> Only one of {this SPA, the Next sample} can hold `:3000` at a time → run them
> separately.

---

## Environment (all public)

```env
VITE_OAUTH_ISSUER=https://oidc-test.semanti.us              # informational
VITE_OAUTH_CLIENT_ID=public-client                          # PUBLIC client, no secret
VITE_OAUTH_AUTHORIZATION_ENDPOINT=https://oidc-test.semanti.us/authorize
VITE_OAUTH_TOKEN_ENDPOINT=https://oidc-test.semanti.us/token
VITE_OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback   # must be issuer-allow-listed
VITE_API_BASE_URL=http://localhost:8788                     # the Hono API (NOT 8787)
```

`VITE_` vars are inlined into the browser bundle — there are **no secrets** (a public
OAuth client authenticates with PKCE, not a secret). `react-oauth2-code-pkce` takes
**explicit** `authorization`/`token` endpoints (it does no OIDC discovery — which
also sidesteps the issuer omitting `code_challenge_methods_supported`: the library
always sends PKCE **S256**).

---

## How it works

```
src/
  main.tsx              <AuthProvider> wraps an InnerApp that feeds live auth into <RouterProvider>
  router.tsx            TanStack Router route tree: root layout (nav) + /, /users, /oauth2_callback;
                        /users is auth-GUARDED via beforeLoad; /oauth2_callback handles the redirect
  auth/AuthContext.tsx  wraps react-oauth2-code-pkce's <AuthProvider> + exposes a small
                        app-shaped useAuth() (status / claims / token / login / logout)
  api/client.ts         useApi(): fetch wrapper — attaches Authorization: Bearer <token>
  pages/Home.tsx        sign-in status + Log in; probes the API's GET / to show its DB_AUTH_MODE
  pages/Users.tsx       GET /me (provision) + GET /users (RLS read) + PUT /me/display-name (write)
  types.ts              local API DTOs (NO DB import — keeps the SPA free of DB deps)
```

**Routing & authenticated routes (TanStack Router).** The router runs *inside* the
`react-oauth2-code-pkce` provider; `main.tsx` injects the live `useAuth()` value into
the router's typed `context`. The protected `/users` route uses **`beforeLoad`** to
**remember the attempted destination and redirect to `/`** when auth is
`unauthenticated` (a rehydrating/refreshing token — `loading` — is allowed through so
a reload isn't bounced mid-refresh). Because the guard reads the router context, it
re-evaluates whenever auth changes.

**Deep-link → sign in → return to where you were headed.** A normal `?redirect=…`
search param **can't** carry the destination here: login is a full-page redirect to
the external IdP and back to the fixed `/oauth2_callback`, so anything on the login
route is gone by the time you're authenticated. So the guard stashes the attempted
href in **`sessionStorage`** (survives the IdP round-trip) and the callback restores
it **exactly** — query/hash included — via `router.history.replace()`. If login was
started with no specific destination (e.g. from Home), it falls back to a single named
default (`DEFAULT_AUTHED_ROUTE = '/users'`). No hardcoded return.

**The flow:** `Log in` → the library builds the authorize URL (PKCE **S256**) and
redirects → issuer Sign In → redirect to `/oauth2_callback?code=…` → the library
validates state, exchanges the code (**no secret**), stores the tokens, clears the URL
→ the `/oauth2_callback` route reacts to the now-authenticated state and returns you to
the remembered destination (or the default). The library **refreshes the access token
proactively** before expiry.

The SPA is **mode-agnostic**: it never knows whether the API runs in `bearer` or
`session` mode — it just sends a bearer token. (Home shows the backend's mode for
illustration, read from the API's public `GET /`.)

---

## Token storage & the security tradeoff (read this)

`react-oauth2-code-pkce` persists tokens (access + refresh + id) in **`localStorage`**
(keys prefixed `ROCP_`), so **the session survives a reload / browser restart** and
401s are rare (the access token is refreshed proactively). Use `storage: 'session'`
in `src/auth/AuthContext.tsx` to scope it to the tab instead.

This is the deliberate, honest tradeoff for a **decoupled** SPA:

- **XSS is the threat, and token custody doesn't prevent it.** If an attacker runs
  script in your origin, they *are* your client — they call your API with whatever
  the browser attaches and act as the user. An httpOnly cookie (the BFF model)
  wouldn't stop that in-session abuse; it only hides the token from `document.cookie`.
- **What storage actually governs is persistence *beyond* the XSS window** — i.e. a
  stolen long-lived **refresh** token usable later / elsewhere. We bound that with
  **refresh-token rotation** (issuer-side reuse detection revokes the family) + a
  **short access-token TTL**. A short access token is low-value to exfiltrate.
- **The real defense is preventing XSS** — strict CSP / Trusted Types, no
  `innerHTML`, dependency hygiene — not hiding the token behind a server.
- **Why not a BFF (httpOnly cookie)?** It's more XSS-robust (no portable credential
  ever exists), but it **re-couples** the SPA to a stateful companion server and
  re-introduces cookies/CSRF — which defeats the point of a *decoupled* SPA + stateless
  bearer API, and would just duplicate the [`examples/nextjs`](../nextjs) BFF model.
  If you need that posture, use that sample.

---

## Required token claims

The API/DB enforce a claims contract (`role=authenticated`, `sub`, `iss`, `aud`,
`exp`/`iat`, plus `email`/`name`). Full table and trust model:
[`../spa-hono-backend/README.md`](../spa-hono-backend/README.md#required-token-claims).
**The issuer must mint `role=authenticated`** (the test issuer does; Auth0/Clerk need
a custom claim).

---

## Build

```bash
npm run typecheck    # tsc --noEmit
npm run build        # tsc --noEmit && vite build
```

---

## Validation status

Verified end-to-end in a real Chrome browser (via agent-browser) against the local
pgdocker stack: Log in → issuer Sign In → `/oauth2_callback` PKCE exchange (S256) →
`/users` RLS read → `user:manage` write succeeds as the admin/first user → **reload
(F5) keeps you signed in** (tokens rehydrated from `localStorage`) → Sign out clears
them. The backend's `bearer`/`session` modes are independent of this SPA (it just
sends a bearer token); both are verified in
[`../spa-hono-backend/README.md`](../spa-hono-backend/README.md#validation-status).
