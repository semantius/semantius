#!/usr/bin/env node
/**
 * Dokploy blueprint builder — generates `docker-compose/dokploy/` from the
 * local-dev stack in `docker-compose/`.
 *
 * Sources (hand-maintained):
 *   docker-compose/docker-compose.yml   the ONE complete local stack
 *   docker-compose/Caddyfile            the front-door routes (bind-mounted locally)
 *   docker-compose/idp-config/*.jsonc   the identity provider's configuration
 *                                       (bind-mounted locally; every .jsonc in
 *                                       the folder is picked up)
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
 *   - no bind mounts           — every bind-mounted file is embedded instead, as a
 *                                top-level `configs:` entry with inline `content:`,
 *                                so the template needs `mounts = []` and the stack
 *                                stays a single self-contained file
 *   - no `read_only:` on a service that gains such a config — compose delivers an
 *                                inline `content:` config by WRITING it into the
 *                                container filesystem, and refuses outright on a
 *                                read-only one ("cannot create config … in
 *                                read-only service"). Nothing else about the
 *                                service changes.
 *
 * Comments in the source compose are preserved (yaml Document round-trip).
 *
 * Usage (from docker-compose/, the folder it builds):
 *   ./dokploy-build.sh          (Windows: dokploy-build.cmd)
 *
 * or directly, from anywhere:
 *   node scripts/dokploy-build.mjs
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
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
// host ports and the bind-mounted config files — neither of which exists here.
// ---------------------------------------------------------------------------
const GENERATED_HEADER = ` GENERATED FILE — DO NOT EDIT.
 Built from ../docker-compose.yml + ../Caddyfile + ../idp-config/*.jsonc by
 \`./dokploy-build.sh\` (scripts/dokploy-build.mjs). Change those, then regenerate.

 The Dokploy blueprint variant of the semantius-rest stack. Same services as the
 local-dev compose, minus everything a one-click deployment must not carry:
 host \`ports:\` (Dokploy's Traefik routes to the \`caddy\` service by name — see
 template.toml's [[config.domains]]), \`container_name:\` (would collide across
 deployments) and bind mounts (the Caddyfile and the identity provider's
 configuration are embedded in the top-level \`configs:\` block below, so
 \`mounts = []\` in the template).

 One further difference, forced rather than chosen: a service carrying an inline
 \`content:\` config cannot also be \`read_only\`, because compose delivers such a
 config by writing it into the container filesystem. \`read_only\` is therefore
 dropped from those services here — cap_drop, no-new-privileges and the tmpfs
 are not.

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
# Signs the identity provider's sessions and encrypts its JWT signing keys at
# rest. Generated once per deployment and never rotated casually: changing it
# logs every user out and makes the stored signing keys undecryptable.
idp_secret = "\${password:64}"

[config]
# No bind mounts: the Caddyfile and the idp's config files ship inside
# docker-compose.yml (configs.content).
mounts = []
env = [
  # The stack brings its OWN issuer — the \`idp\` service, mounted at /idp on the
  # front door — so a one-click deploy has a complete auth story with nothing to
  # register anywhere. On first visit, https://\${main_domain}/idp serves a setup
  # page: whoever completes it becomes the first administrator.
  #
  # The SPA discovers it at the origin root (caddy routes /.well-known/* there),
  # and \`public-client\` is the SPA registered in idp-config/oauth_clients.jsonc.
  "VITE_OAUTH_CONFIG=https://\${main_domain}/.well-known/openid-configuration",
  "VITE_OAUTH_CLIENT_ID=public-client",
  # The keys PostgREST validates tokens against: the idp, IN-NETWORK. Explicit
  # rather than derived from discovery, because the jwks_uri the idp advertises
  # carries its public URL, which the jwks-fetch container cannot resolve.
  "JWKS_URL=http://idp:3000/idp/.well-known/jwks.json",
  "IDP_SECRET=\${idp_secret}",
  # The issuer, and the origin the SPA's redirect URIs are built from. Both must
  # be the public front door — every URL the idp emits derives from them.
  "IDP_BASE_URL=https://\${main_domain}/idp",
  "PUBLIC_WEB_ORIGIN=https://\${main_domain}",
  "POSTGRES_PASSWORD=\${postgres_password}",
  "SEMANTIUS_AUTHENTICATOR_PASSWORD=\${authenticator_password}",
  "POSTGRES_DB=semantius",
  "SEMANTIUS_DB_VERSION=latest",
  "SEMANTIUS_APP_VERSION=latest",
  "SEMANTIUS_IDP_VERSION=latest",
  # Public front door, including the /api prefix that caddy strips.
  "PUBLIC_API_URL=https://\${main_domain}/api",
  # Load the Northwind demo module on first init so the deploy has data to show.
  # Remove this line for an empty database.
  "NWIND=TRUE",
]

# Traefik routes the domain to the caddy front door; caddy fans out to the SPA,
# PostgREST (/api/*), Scalar (/api-docs/*) and the identity provider (/idp/* plus
# the discovery documents at /.well-known/*).
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
    "front door. Auth is self-contained: a bundled OIDC/OAuth identity provider at " +
    "/idp issues the bearer tokens and publishes the JWKS PostgREST validates them " +
    "against, so the first visit to /idp creates the first administrator and nothing " +
    "external has to be registered. Point VITE_OAUTH_CONFIG, VITE_OAUTH_CLIENT_ID " +
    "and JWKS_URL elsewhere to use your own issuer instead.",
  logo: "logo.svg",
  links: {
    github: "https://github.com/semantius/semantius",
    website: "https://semantius.com",
    docs: "https://github.com/semantius/semantius/tree/main/docker-compose",
  },
  tags: ["database", "api", "postgres", "postgrest", "oidc", "low-code"],
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

// ---------------------------------------------------------------------------
// What gets embedded. One group per service that bind-mounts configuration
// locally: the mount is dropped, each file becomes a top-level `configs:` entry,
// and the service gets a `configs:` list pointing at the same paths the mount
// used to provide.
//
// The idp's files are DISCOVERED rather than listed, so adding e.g. a
// roles.jsonc to docker-compose/idp-config/ needs no change here.
// ---------------------------------------------------------------------------
const idpConfigFiles = readdirSync(src("idp-config/"))
  .filter((f) => f.endsWith(".jsonc"))
  .sort()
  .map((f) => ({
    // Compose config names: the file's stem, prefixed so it cannot collide with
    // another service's. `config.jsonc` -> `idp_config`.
    name: `idp_${f.replace(/\.jsonc$/, "").replace(/[^A-Za-z0-9]+/g, "_")}`,
    source: `idp-config/${f}`,
    target: `/config/${f}`,
  }));

if (!idpConfigFiles.length) fail("no *.jsonc files in docker-compose/idp-config/");

const EMBED_GROUPS = [
  {
    service: "caddy",
    // The bind mount this replaces.
    isMount: (v) => v.includes("/etc/caddy/Caddyfile"),
    files: [{ name: "caddyfile", source: "Caddyfile", target: "/etc/caddy/Caddyfile" }],
    comment:
      " The Caddyfile, embedded at the bottom of this file (no bind mounts in a\n" +
      " blueprint). Edit ../Caddyfile and regenerate — never this copy.",
  },
  {
    service: "idp",
    isMount: (v) => v.includes(":/config"),
    files: idpConfigFiles,
    comment:
      " The identity provider's configuration, embedded at the bottom of this file\n" +
      " (no bind mounts in a blueprint). Edit ../idp-config/*.jsonc and regenerate\n" +
      " — never these copies. Restarting the service applies a change.",
  },
];

// Read every source file up front, so a typo in a path fails before anything is
// written and the round-trip check below has the exact bytes to compare against.
for (const group of EMBED_GROUPS) {
  for (const file of group.files) {
    const text = readText(src(file.source));
    file.content = text.endsWith("\n") ? text : `${text}\n`;
  }
}

const composeSrc = readText(src("docker-compose.yml"));

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
let strippedReadOnly = 0;
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

// --- bind mounts -> compose configs -----------------------------------------
const configsMap = new YAMLMap();

for (const group of EMBED_GROUPS) {
  const svc = services.get(group.service);
  if (!isMap(svc)) fail(`no \`${group.service}\` service in the source compose`);

  const volumes = svc.get("volumes");
  if (!isSeq(volumes)) fail(`\`${group.service}\` has no \`volumes:\` list`);
  const before = volumes.items.length;
  volumes.items = volumes.items.filter((item) => {
    const v = item.value;
    return !(typeof v === "string" && group.isMount(v));
  });
  if (volumes.items.length === before) {
    fail(
      `\`${group.service}\` has no config bind mount to replace — did the compose change?`,
    );
  }
  if (volumes.items.length === 0) {
    // Nothing left to mount; an empty `volumes:` is noise at best.
    svc.delete("volumes");
  } else {
    // The comment that introduced the bind mount describes local-dev editing; it
    // is wrong here, and the yaml round-trip re-anchors it onto whatever item
    // follows.
    volumes.commentBefore = undefined;
    const first = volumes.items[0];
    if (first?.commentBefore?.includes("Caddyfile")) first.commentBefore = undefined;
  }

  // The service-level reference: `configs: [{source, target}, …]`.
  svc.set(
    doc.createNode("configs"),
    doc.createNode(group.files.map((f) => ({ source: f.name, target: f.target }))),
  );
  // An inline `content:` config is WRITTEN INTO the container filesystem, so it
  // cannot be delivered to a read-only one — compose fails the container outright
  // ("cannot create config … in read-only service: \`file\` is the sole supported
  // option"). A `file:` config would bind-mount and leave read_only intact, but a
  // blueprint has no files beside it to point at. So the config wins and read_only
  // goes, here only; the rest of the service's hardening is untouched.
  let comment = group.comment;
  if (svc.has("read_only")) {
    svc.delete("read_only");
    strippedReadOnly++;
    comment +=
      "\n\n An inline config is written into the container filesystem, so this service\n" +
      " cannot also be `read_only` — it is dropped in this generated variant and\n" +
      " nowhere else. cap_drop, no-new-privileges and the tmpfs are unchanged.";
  }

  const configsPair = svc.items.find((p) => String(p.key.value) === "configs");
  if (configsPair) configsPair.key.commentBefore = comment;

  // The top-level entry, one per file.
  for (const file of group.files) {
    // `$` must be escaped as `$$`: compose interpolates `${...}` inside
    // `content:`, and both Caddy's `{$SITE_ADDRESS::80}` and the idp's
    // `${env:...}` placeholders have to reach their reader verbatim.
    const contentScalar = new Scalar(file.content.replaceAll("$", "$$$$"));
    contentScalar.type = Scalar.BLOCK_LITERAL;
    const entry = new YAMLMap();
    entry.set(doc.createNode("content"), contentScalar);
    configsMap.set(doc.createNode(file.name), entry);
  }
}

doc.set(doc.createNode("configs"), configsMap);

const topConfigsPair = doc.contents.items.find(
  (p) => String(p.key.value) === "configs",
);
if (topConfigsPair) {
  topConfigsPair.key.commentBefore =
    " The bind-mounted files, copied verbatim from ../Caddyfile and\n" +
    " ../idp-config/*.jsonc at build time. `$` is escaped as `$$` so compose\n" +
    " leaves Caddy's own {$SITE_ADDRESS::80} and the idp's ${env:...} placeholders\n" +
    " alone — each is resolved by its own reader, from that service's environment.\n" +
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
  // Compose refuses to create such a container at all — catch it here, not there.
  if (svc.configs?.length && svc.read_only) {
    problems.push(`service \`${name}\` is read_only but carries an inline config`);
  }
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

// Every embedded file must be present, referenced by its service, and round-trip
// back to its source byte for byte once the `$$` escaping is undone.
for (const group of EMBED_GROUPS) {
  const refs = outServices[group.service]?.configs ?? [];
  for (const file of group.files) {
    const embedded = outAny?.configs?.[file.name]?.content;
    if (!embedded) {
      problems.push(`configs.${file.name}.content is missing or empty`);
    } else if (embedded.replaceAll("$$", "$") !== file.content) {
      problems.push(`configs.${file.name}.content does not round-trip back to ../${file.source}`);
    }
    if (!refs.some((r) => r?.source === file.name && r?.target === file.target)) {
      problems.push(
        `service \`${group.service}\` does not mount config \`${file.name}\` at ${file.target}`,
      );
    }
  }
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

const embeddedNames = EMBED_GROUPS.flatMap((g) => g.files.map((f) => f.source));
console.log(
  `Wrote docker-compose/dokploy/ (stripped ${strippedPorts} ports:, ${strippedNames} container_name:, ${strippedReadOnly} read_only:)`,
);
console.log(`  docker-compose.yml    embeds ${embeddedNames.join(", ")}`);
console.log(`  template.toml`);
console.log(`  meta.json`);
console.log(logoNote);
console.log("");
console.log("Publish it as a Dokploy one-click template either way:");
console.log(`  - fork github.com/Dokploy/templates and copy this folder to blueprints/${BLUEPRINT_ID}/`);
console.log("  - or in any instance: Create Service > Advanced > Import > Base64 of these files");
