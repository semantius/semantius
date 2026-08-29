# TODO — docker-compose stack (Caddy front door + Dokploy blueprint)

Open items left over from the front-door / blueprint work. Everything else in
that change is implemented and verified (see [README.md](README.md)).

## Blocking a publish

- [ ] **Add `docker-compose/logo.svg`.** `dokploy/meta.json` references `logo.svg`
      and `./dokploy-build.sh` copies it into `dokploy/` when it exists — right now
      it doesn't, so the build prints a MISSING reminder and the gallery card would
      render without a logo. Drop the Semantius SVG in and re-run the build.

- [ ] **Dokploy round-trip test** (needs a Dokploy instance). Import the blueprint
      — fork [Dokploy/templates](https://github.com/Dokploy/templates) as
      `blueprints/semantius/`, or **Create Service → Advanced → Import → Base64** —
      deploy it, and confirm:
      - the `configs:` block survives Dokploy's compose processing (the one
        residual unknown; needs docker compose ≥ 2.23.1 on the server),
      - Traefik routes `${main_domain}` → `caddy`:80,
      - `/`, `/rest/`, `/gateway/rest/`, `/api-docs/` all work at `https://<domain>`,
      - the identity provider works end to end: `/idp` serves the setup page, its
        two embedded `idp-config/*.jsonc` configs arrive with their `${env:…}`
        placeholders intact, `/.well-known/openid-configuration` (and the RFC 8414
        suffix form `/.well-known/oauth-authorization-server/idp`) resolve, and a
        login through the SPA completes.

## Follow-ups

- [ ] **`token.sh` / `api-test.sh` mint from the retired test issuer.** Both call
      `pgdocker/get_user_token.ts`, whose issuer is hardcoded in
      `pgdocker/verify_oauth.ts`, so their tokens no longer verify against the
      bundled idp's JWKS and `api-test.sh` fails against a default stack. Point
      them at the idp instead — the supported headless path is a per-user API key
      exchanged at `GET /idp/api/auth/token` (see the README), which needs a user
      to exist, so it probably wants a small bootstrap helper.

- [ ] **`read_only: true` is dropped from `idp` in the blueprint.** Not a choice:
      docker compose delivers an inline `configs.content` by writing it into the
      container filesystem and refuses outright on a read-only service
      (*"cannot create config … in read-only service: `file` is the sole supported
      option"*). The generator strips it and says so. To get it back, the
      blueprint would have to ship the config as a `file:` config — which means
      files beside the compose, the thing a one-click blueprint exists to avoid.

- [ ] **Clean self-hosted opt-out in the `semantius-app` repo.** The `web` service
      has to pass `VITE_CONTROL_PLANE_URL: " "` — a literal single space — because
      unset *or empty* falls through to the baked cloud default. Make `runtimeEnv`
      honour an explicit empty value (or `none`) in `window.__ENV__`, then replace
      the whitespace hack here and drop the warnings in `docker-compose.yml`,
      `README.md` and `api-test.sh`.

- [ ] **Regeneration drift guard.** `dokploy/` is generated and committed, so it can
      silently go stale when `docker-compose.yml` or `Caddyfile` change. Add a CI
      step that runs `./dokploy-build.sh` and fails if the working tree is dirty.

- [ ] *(optional)* Have `dokploy-build` also emit the Dokploy Base64 import blob, so
      importing into an instance is copy-paste with no manual encoding step.

## Unrelated observation

- [ ] After OIDC login the admin SPA shows **"You don't have access to any
      modules"** for `user1`. Not a routing problem — `/api/modules` returns 200
      through the front door, and `/rpc/get_userinfo` reports a role on module 1.
      Looks like RBAC/data state or an app-side query; worth a look separately.
