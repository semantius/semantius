#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd "$SCRIPT_DIR/../apps/web" && pwd)"
rm -f "$SCRIPT_DIR/../.preview-url.md"

cd "$WEB_DIR"

# 1. Build (Astro → apps/web/dist)
pnpm run build:netlify

# 2. Resolve absolute publish dir.
#    netlify-cli v23 resolves a relative --dir against the git root (not the
#    netlify.toml directory), which breaks in monorepos. Passing an absolute
#    path sidesteps the auto-detection entirely.
DIST_DIR="$WEB_DIR/dist"
if [[ ! -d "$DIST_DIR" ]]; then
  echo "❌ Build output not found at $DIST_DIR" >&2
  exit 1
fi

# Under Git Bash/MSYS, $WEB_DIR is POSIX (e.g. /c/dev/...). netlify-cli is a
# Windows Node binary and resolves '/c/...' to 'C:\c\...'. Convert to a native
# Windows path before passing it to the CLI.
DIST_DIR_NATIVE="$DIST_DIR"
if command -v cygpath >/dev/null 2>&1; then
  DIST_DIR_NATIVE="$(cygpath -w "$DIST_DIR")"
fi

# 3. Deploy. --no-build prevents netlify-cli from auto-running 'netlify build'
#    on top of the Astro build we just produced.
DEPLOY_ARGS=(deploy --prod --no-build --dir="$DIST_DIR_NATIVE")
[[ -n "$NETLIFY_SITE_ID" ]]   && DEPLOY_ARGS+=(--site="$NETLIFY_SITE_ID")
[[ -n "$NETLIFY_AUTH_TOKEN" ]] && DEPLOY_ARGS+=(--auth="$NETLIFY_AUTH_TOKEN")

echo "🚀 [PRODUCTION] Deploying to Netlify"
DEPLOY_OUTPUT=$(netlify "${DEPLOY_ARGS[@]}" 2>&1 | tee /dev/stderr)

# 4. Extract the live URL from netlify-cli output ("Website URL:" line).
DEPLOY_URL=$(echo "$DEPLOY_OUTPUT" \
  | grep -Eo 'https://[^[:space:]]+' \
  | grep -E 'netlify\.app|\.com|\.io' \
  | tail -n 1)

if [[ -z "$DEPLOY_URL" ]]; then
  echo "⚠️  Could not extract deploy URL from netlify output" >&2
else
  echo ""
  echo "Deploy URL: $DEPLOY_URL"
  printf "# Deploy URL\n\n%s\n" "$DEPLOY_URL" > "$SCRIPT_DIR/../.preview-url.md"
  "$SCRIPT_DIR/message.sh" "Netlify production deploy: $DEPLOY_URL"
fi
