#!/usr/bin/env bash
# check-pgxn-meta.sh  -  validate a PGXN distribution manifest.
#
#   ./scripts/check-pgxn-meta.sh extension/META.json
#   ./scripts/check-pgxn-meta.sh /tmp/dist/pg_semantius-0.5.0/META.json
#
# Two layers, both of which used to live inline in the release workflow:
#
#   1. `pgxn_meta validate` against the PGXN spec, when it is installed. It ships
#      as a RUBY gem (pgxn_utils), not a PyPI package, so it is frequently absent
#      and its absence is a warning, never a failure.
#   2. Explicit assertions for the four specific defects open item B10 named, none
#      of which a generic spec validation catches: a git:// repository URL, a
#      maintainer with no email, a missing release_status, and a missing
#      CHANGES.md. These always run.
#
# The CHANGES.md check looks NEXT TO the manifest, not at a fixed repo path, so
# the same script validates the build in extension/ and the unpacked archive that
# is about to go to PGXN - which is the copy that actually matters, since that is
# what PGXN ingests.
set -euo pipefail

META="${1:-}"
[ -n "$META" ] || { echo "usage: check-pgxn-meta.sh <path-to-META.json>" >&2; exit 1; }
[ -f "$META" ] || { echo "check-pgxn-meta: $META not found" >&2; exit 1; }

if command -v pgxn_meta >/dev/null 2>&1; then
  pgxn_meta validate "$META"
else
  echo "check-pgxn-meta: pgxn_meta unavailable (gem install pgxn_utils) - running the B10 checks only" >&2
fi

python3 - "$META" <<'PY'
import json, os, sys

path = sys.argv[1]
m = json.load(open(path))
errors = []

for k in ("name", "version", "abstract", "maintainer", "license",
          "provides", "meta-spec"):
    if k not in m:
        errors.append(f"missing required key: {k}")

url = m.get("resources", {}).get("repository", {}).get("url", "")
if url.startswith("git://"):
    errors.append(f"repository url still uses git://: {url}")

if not any("@" in str(x) for x in m.get("maintainer", [])):
    errors.append(f"no maintainer carries an email: {m.get('maintainer')}")

if "release_status" not in m:
    errors.append("release_status is not set")
elif m["release_status"] not in ("stable", "testing", "unstable"):
    errors.append(f"invalid release_status: {m['release_status']}")

changes = os.path.join(os.path.dirname(os.path.abspath(path)), "CHANGES.md")
if not os.path.exists(changes):
    errors.append(f"CHANGES.md is missing next to the manifest ({changes})")

# The install script the manifest promises must exist beside it. In the archive
# this is the whole point; in extension/ it catches a manifest left behind by a
# generation that did not finish.
prov = m.get("provides", {}).get(m.get("name", ""), {})
if isinstance(prov, dict) and prov.get("file"):
    f = os.path.join(os.path.dirname(os.path.abspath(path)), prov["file"])
    if not os.path.exists(f):
        errors.append(f"provides.file does not exist: {prov['file']}")

if errors:
    sys.exit("META.json failed the B10 checks:\n  - " + "\n  - ".join(errors))

print(f"META.json passes: version={m['version']}, url={url}, "
      f"release_status={m['release_status']}, maintainer={m['maintainer']}")
PY
