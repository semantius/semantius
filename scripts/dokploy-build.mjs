#!/usr/bin/env node
/**
 * Dokploy blueprint builder — generates `docker-compose/dokploy/` from the
 * local-dev stack in `docker-compose/`.
 *
 * Sources (hand-maintained):
 *   docker-compose/docker-compose.yml   the ONE complete local stack
 *   docker-compose/Caddyfile            the front-door routes (bind-mounted locally)
 *
 * Output (GENERATED — committed, never hand-edited):
 *   docker-compose/dokploy/docker-compose.yml   deployment variant
 *   docker-compose/dokploy/template.toml        Dokploy variables/env/domains
 *   docker-compose/dokploy/meta.json            gallery metadata
 *
 * The transform, per the Dokploy blueprint rules (github.com/Dokploy/templates):
 *   - drop every `ports:`      — Dokploy/Traefik routes by service name, not host ports
 *   - drop every `container_name:` — names must not collide across deployments
 *   - no custom networks       — Dokploy attaches its own
 *   - no bind mounts           — the Caddyfile is embedded via a top-level
 *                                `configs:` entry with inline `content:`, so the
 *                                template needs `mounts = []` and the stack stays
 *                                a single self-contained file
 *
 * Comments in the source compose are preserved (yaml Document round-trip).
 *
 * Usage (from docker-compose/, the folder it builds):
 *   ./dokploy-build.sh          (Windows: dokploy-build.cmd)
 *
 * or directly, from anywhere:
 *   node scripts/dokploy-build.mjs
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { isMap, isSeq, parseDocument, Scalar, YAMLMap } from "yaml";

// Paths are resolved relative to THIS file, so the task works from any cwd.
const SRC_DIR = new URL("../docker-compose/", import.meta.url);
const OUT_DIR = new URL("dokploy/", SRC_DIR);
const src = (name) => new URL(name, SRC_DIR);
const out = (name) => new URL(name, OUT_DIR);

/** Blueprint id — the folder name it gets in a Dokploy templates repo. */
const BLUEPRINT_ID = "semantius";

// ---------------------------------------------------------------------------
// The generated compose header. Replaces the local-dev header, which documents
// host ports and the bind-mounted Caddyfile — neither of which exists here.
// ---------------------------------------------------------------------------
const GENERATED_HEADER = ` GENERATED FILE — DO NOT EDIT.
 Built from ../docker-compose.yml + ../Caddyfile by \`./dokploy-build.sh\`
 (scripts/dokploy-build.mjs). Change those, then regenerate.

 The Dokploy blueprint variant of the semantius-rest stack. Same services as the
 local-dev compose, minus everything a one-click deployment must not carry:
 host \`ports:\` (Dokploy's Traefik routes to the \`caddy\` service by name — see
 template.toml's [[config.domains]]), \`container_name:\` (would collide across
 deployments) and bind mounts (the Caddyfile is embedded in the top-level
 \`configs:\` block below, so \`mounts = []\` in the template).

 Requires docker compose >= 2.23.1 on the target server (inline configs.content).`;

// ---------------------------------------------------------------------------
// template.toml — static: no mounts, so nothing here depends on the compose.
// Keep the env list in sync with the compose's variables.
// ---------------------------------------------------------------------------
const TEMPLATE_TOML = `# Dokploy template for the Semantius PostgREST stack.
# Variables are generated per deployment; env is written to the stack's .env.

[variables]
main_domain = "\${domain}"
postgres_password = "\${password:32}"
authenticator_password = "\${password:32}"

[config]
# No bind mounts: the Caddyfile ships inside docker-compose.yml (configs.content).
mounts = []
env = [
  # OIDC issuer — the ONLY settings a real deployment must change. The defaults
  # point at a public THROWAWAY test issuer so the one-click deploy works out of
  # the box; swap both for your own IdP before using this for anything real.
  "VITE_OAUTH_CONFIG=https://oidc-test.semanti.us/.well-known/openid-configuration",
  "VITE_OAUTH_CLIENT_ID=public-client",
  "POSTGRES_PASSWORD=\${postgres_password}",
  "SEMANTIUS_AUTHENTICATOR_PASSWORD=\${authenticator_password}",
  "POSTGRES_DB=semantius",
  "SEMANTIUS_DB_VERSION=latest",
  "SEMANTIUS_APP_VERSION=latest",
  # Public front door, including the /api prefix that caddy strips.
  "PUBLIC_API_URL=https://\${main_domain}/api",
  # Load the Northwind demo module on first init so the deploy has data to show.
  # Remove this line for an empty database.
  "NWIND=TRUE",
]

# Traefik routes the domain to the caddy front door; caddy fans out to the SPA,
# PostgREST (/api/*) and Scalar (/api-docs/*).
[[config.domains]]
serviceName = "caddy"
port = 80
host = "\${main_domain}"
`;

// ---------------------------------------------------------------------------
// meta.json — the gallery card (per-blueprint shape from Dokploy/templates).
// ---------------------------------------------------------------------------
const META_JSON = {
  id: BLUEPRINT_ID,
  name: "Semantius",
  version: "1.0.0",
  description:
    "Semantic data-model platform: PostgreSQL 18 with the pg_semantius extension, " +
    "a PostgREST HTTP API with OpenAPI docs, and the admin SPA — behind one Caddy " +
    "front door. Auth is OIDC bearer tokens verified against your issuer's JWKS; " +
    "the defaults point at a public test issuer, so set VITE_OAUTH_CONFIG and " +
    "VITE_OAUTH_CLIENT_ID to your own IdP before using this for anything real.",
  logo: "logo.svg",
  links: {
    github: "https://github.com/semantius/semantius",
    website: "https://semantius.com",
    docs: "https://github.com/semantius/semantius/tree/main/docker-compose",
  },
  tags: ["database", "api", "postgres", "postgrest", "low-code"],
};

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------
function fail(msg) {
  console.error(`\ndokploy-build FAILED — ${msg}\n`);
  process.exit(1);
}

/** Read a text file with CRLF normalised away. */
function readText(path) {
  return readFileSync(path, "utf8").replace(/\r\n/g, "\n");
}

/** Write LF-only UTF-8. */
function writeText(path, text) {
  writeFileSync(path, text.replace(/\r\n/g, "\n"));
}

const composeSrc = readText(src("docker-compose.yml"));
const caddySrc = readText(src("Caddyfile"));

const doc = parseDocument(composeSrc);
if (doc.errors.length) fail(`source compose has YAML errors: ${doc.errors[0].message}`);

// --- header ----------------------------------------------------------------
// The local header sits as a `commentBefore` on the `services:` key; swap it for
// the generated one and hoist a banner above `name:` too.
doc.commentBefore = GENERATED_HEADER;
const servicesPair = doc.contents.items.find(
  (p) => String(p.key.value) === "services",
);
if (!servicesPair) fail("no `services:` block in the source compose");
servicesPair.key.commentBefore = undefined;

const services = servicesPair.value;
if (!isMap(services)) fail("`services:` is not a mapping");

// --- per-service: strip host ports + container names ------------------------
let strippedPorts = 0;
let strippedNames = 0;
for (const pair of services.items) {
  const svc = pair.value;
  if (!isMap(svc)) continue;
  if (svc.has("ports")) {
    svc.delete("ports");
    strippedPorts++;
  }
  if (svc.has("container_name")) {
    svc.delete("container_name");
    strippedNames++;
  }
}

// --- caddy: bind mount -> compose config ------------------------------------
const caddy = services.get("caddy");
if (!isMap(caddy)) fail("no `caddy` service in the source compose");

const caddyVolumes = caddy.get("volumes");
if (!isSeq(caddyVolumes)) fail("`caddy` has no `volumes:` list");
const before = caddyVolumes.items.length;
caddyVolumes.items = caddyVolumes.items.filter((item) => {
  const v = item.value;
  return !(typeof v === "string" && v.includes("/etc/caddy/Caddyfile"));
});
if (caddyVolumes.items.length === before) {
  fail("`caddy` has no ./Caddyfile bind mount to replace — did the compose change?");
}
// The comment that introduced the bind mount describes local-dev editing; it is
// wrong here, and the yaml round-trip re-anchors it onto whatever item follows.
caddyVolumes.commentBefore = undefined;
const firstVolume = caddyVolumes.items[0];
if (firstVolume?.commentBefore?.includes("Caddyfile")) firstVolume.commentBefore = undefined;

const configRef = doc.createNode([
  { source: "caddyfile", target: "/etc/caddy/Caddyfile" },
]);
caddy.set(doc.createNode("configs"), configRef);
const caddyConfigsPair = caddy.items.find(
  (p) => String(p.key.value) === "configs",
);
if (caddyConfigsPair) {
  caddyConfigsPair.key.commentBefore =
    " The Caddyfile, embedded at the bottom of this file (no bind mounts in a\n" +
    " blueprint). Edit ../Caddyfile and regenerate — never this copy.";
}

// --- top-level configs: the Caddyfile, inline -------------------------------
// `$` must be escaped as `$$`: compose interpolates `${...}` inside `content:`,
// and `{$SITE_ADDRESS::80}` has to reach Caddy verbatim as its own env placeholder.
const caddyContent = caddySrc.endsWith("\n") ? caddySrc : `${caddySrc}\n`;
const escaped = caddyContent.replaceAll("$", "$$$$");

const contentScalar = new Scalar(escaped);
contentScalar.type = Scalar.BLOCK_LITERAL;

const caddyfileEntry = new YAMLMap();
caddyfileEntry.set(doc.createNode("content"), contentScalar);
const configsMap = new YAMLMap();
configsMap.set(doc.createNode("caddyfile"), caddyfileEntry);
doc.set(doc.createNode("configs"), configsMap);

const configsPair = doc.contents.items.find(
  (p) => String(p.key.value) === "configs",
);
if (configsPair) {
  configsPair.key.commentBefore =
    " The front-door routes, copied verbatim from ../Caddyfile at build time.\n" +
    " `$` is escaped as `$$` so compose leaves Caddy's own {$SITE_ADDRESS::80}\n" +
    " placeholder alone (it resolves from the caddy service's environment).\n" +
    " Needs docker compose >= 2.23.1 (inline `content:` support).";
}

// lineWidth 0: never fold long lines. Folding is valid YAML and round-trips, but
// a `${VAR}` split across two lines is alarming to read in a published template.
const outCompose = doc.toString({ lineWidth: 0 });

// ---------------------------------------------------------------------------
// Validate the OUTPUT — a blueprint that breaks these rules fails in Dokploy in
// ways that are tedious to debug, so fail here instead.
// ---------------------------------------------------------------------------
const problems = [];

const outDoc = parseDocument(outCompose);
if (outDoc.errors.length) {
  problems.push(`generated compose does not parse: ${outDoc.errors[0].message}`);
}
const outAny = outDoc.toJS();
const outServices = outAny?.services ?? {};

if (!Object.keys(outServices).length) problems.push("generated compose has no services");

for (const [name, svc] of Object.entries(outServices)) {
  if (svc.ports) problems.push(`service \`${name}\` still has ports:`);
  if (svc.container_name) problems.push(`service \`${name}\` still has container_name:`);
  if (svc.networks) problems.push(`service \`${name}\` declares networks: (Dokploy attaches its own)`);
  for (const v of svc.volumes ?? []) {
    const s = typeof v === "string" ? v : JSON.stringify(v);
    if (/^\s*[.\/~]/.test(s) || (typeof v === "object" && v && v.type === "bind")) {
      problems.push(`service \`${name}\` still has a bind mount: ${s}`);
    }
  }
}
if (outAny?.networks) problems.push("generated compose declares top-level networks:");

const embedded = outAny?.configs?.caddyfile?.content;
if (!embedded) {
  problems.push("configs.caddyfile.content is missing or empty");
} else if (embedded.replaceAll("$$", "$") !== caddyContent) {
  problems.push("configs.caddyfile.content does not round-trip back to ../Caddyfile");
}

// Every `${VAR:?...}` (required, no default) must be supplied by the template env.
const templateEnv = new Set(
  [...TEMPLATE_TOML.matchAll(/^\s*"([A-Za-z_][A-Za-z0-9_]*)=/gm)].map((m) => m[1]),
);
const required = new Set(
  [...outCompose.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*):\?/g)].map((m) => m[1]),
);
for (const v of required) {
  if (!templateEnv.has(v)) {
    problems.push(`compose requires \${${v}:?...} but template.toml's env does not set it`);
  }
}

// Every [[config.domains]] must point at a service that exists, on a port it serves.
for (const block of TEMPLATE_TOML.split("[[config.domains]]").slice(1)) {
  const svcName = block.match(/serviceName\s*=\s*"([^"]+)"/)?.[1];
  if (!svcName) problems.push("a [[config.domains]] block has no serviceName");
  else if (!outServices[svcName]) {
    problems.push(`[[config.domains]] serviceName "${svcName}" is not a service in the compose`);
  }
}

if (problems.length) {
  fail(`blueprint validation:\n  - ${problems.join("\n  - ")}`);
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------
mkdirSync(OUT_DIR, { recursive: true });
writeText(out("docker-compose.yml"), outCompose);
writeText(out("template.toml"), TEMPLATE_TOML);
writeText(out("meta.json"), `${JSON.stringify(META_JSON, null, 2)}\n`);

// The gallery card wants a logo next to meta.json. Copy one if the repo has it;
// otherwise say so — the blueprint still deploys, it just renders without a logo.
let logoNote = `  logo.svg          MISSING — drop the Semantius SVG at docker-compose/logo.svg`;
try {
  const logo = readFileSync(src("logo.svg"), "utf8");
  writeFileSync(out("logo.svg"), logo, "utf8");
  logoNote = "  logo.svg";
} catch {
  // no logo in the repo yet
}

console.log(`Wrote docker-compose/dokploy/ (stripped ${strippedPorts} ports:, ${strippedNames} container_name:)`);
console.log(`  docker-compose.yml`);
console.log(`  template.toml`);
console.log(`  meta.json`);
console.log(logoNote);
console.log("");
console.log("Publish it as a Dokploy one-click template either way:");
console.log(`  - fork github.com/Dokploy/templates and copy this folder to blueprints/${BLUEPRINT_ID}/`);
console.log("  - or in any instance: Create Service > Advanced > Import > Base64 of these files");
