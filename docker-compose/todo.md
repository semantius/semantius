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
      - `/`, `/api/`, `/api-docs/` all work at `https://<domain>`.

## Follow-ups

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
