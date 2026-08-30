# docker-compose — source-testing tools for the self-hosted stack

**The self-hosting stack moved to
[github.com/semantius/semantius-self-hosted](https://github.com/semantius/semantius-self-hosted).**
That repo holds the compose file, the Caddyfile, the identity provider's
configuration, the Dokploy blueprint, the management scripts (`create`, `up`,
`start`, `stop`, `status`, `destroy`, `jwks-refresh`, `dokploy-build`) and the
full self-hosting manual. Everything there runs published images — no checkout of
this repo required.

What stays here are the tools that test **this repo's source** against that stack,
and so cannot live in a repo that has no source:

| Script | Does |
|---|---|
| `test` | full pgTAP suite on a from-scratch stack: regenerate the extension, build the DB image from `../extension`, `create` the stack on it, `migrate --apps nwind,test`, run the suite. **DESTRUCTIVE** — wipes the stack's data volume |
| `token` | mint a JWT for a test user via `../pgdocker/get_user_token.ts` |
| `api-test` | HTTP/auth smoke test of a running stack (front door, `/rest/`, `/api-docs/`, token-authenticated calls) |

All three need a checkout of `semantius-self-hosted`. They look for it as a
sibling of this repo (`../../semantius-self-hosted`) and take a `SELF_HOSTED_DIR`
environment variable to override that:

```bash
git clone https://github.com/semantius/semantius-self-hosted ../../semantius-self-hosted
./test.sh                    # or: SELF_HOSTED_DIR=/path/to/stack ./test.sh
```

`test` builds the image itself (via [`../docker-postgres/build.sh`](../docker-postgres/README.md),
tagging `ghcr.io/semantius/postgres:latest`) and then calls the stack's
`create.sh -y --no-pull`, so the freshly built image is what actually runs — a
plain `create` would pull `:latest` from GHCR straight over it. Pass `--pull` (or
a version tag) to test the published image instead.

> ⚠️ `token` and `api-test` still mint from the **retired public test issuer**
> hardcoded in `pgdocker/verify_oauth.ts`, so their tokens no longer verify
> against the stack's bundled identity provider. For scripted access to a stock
> stack, use a per-user API key against `/gateway/rest` — see
> [the self-hosting README](https://github.com/semantius/semantius-self-hosted#minting-a-token-without-a-browser).
