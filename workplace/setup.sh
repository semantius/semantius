#!/bin/bash

# Current script version
VERSION="003"

# Setup workplace script
# This script configures the environment and dependencies after checkout

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to send messages (wrapper around message.sh)
send_message() {
    local message="$1"
    "$SCRIPT_DIR/message.sh" "$message" 2>/dev/null || true
}

# Error handler function
error_handler() {
    local exit_code=$?
    local line_number=$1
    local error_message="workplace setup failed at line $line_number with exit code $exit_code"
    echo "$error_message"
    send_message "$error_message"
    exit $exit_code
}

# Set up error trap
trap 'error_handler ${LINENO}' ERR
set -e


# Path to the version file
VERSION_FILE=".workplace-version"

# Send start message with environment variables
echo "Starting workplace setup..."

# Read current workplace version, default to 000 if not exists
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
else
    CURRENT_VERSION="000"
fi

echo "Current workplace version: $CURRENT_VERSION"
echo "Script version: $VERSION"

# Stop if workplace version is >= script version
if [ "$CURRENT_VERSION" -ge "$VERSION" ]; then
    echo "Workplace is up to date (version $CURRENT_VERSION). Skipping setup."
    send_message "workplace setup finished - version $VERSION"
    exit 0
fi

echo "Updating workplace from $CURRENT_VERSION to $VERSION..."

# Install global dependencies
echo "Installing agent-browser globally..."
npm install -g agent-browser

echo "Installing dotenvx globally..."
npm install -g @dotenvx/dotenvx

echo "Installing cloudflare wrangler globally..."
npm install -g wrangler

echo "Installing Playwright browsers..."
npx --yes playwright install --with-deps chromium

# Fix: agent-browser bundles its own playwright-core which may expect a different
# chromium-headless-shell revision than the one installed by the global playwright.
#
# Only applied in Claude's remote cloud sandbox (CLAUDECODE=1 + CLAUDE_CODE_REMOTE=true)
# where outbound downloads are restricted, so playwright cannot auto-fetch the missing
# revision at runtime. We create symlinks from the installed revision to the path
# agent-browser's playwright-core expects.
#
# In devcontainer / GitHub Copilot sandboxes the download succeeds at runtime, so
# this function is never called there.
fix_agent_browser_claude_sandbox() {
    local AGBR_PW_DIR
    AGBR_PW_DIR="$(npm root -g)/agent-browser/node_modules/playwright-core"

    if [ ! -d "$AGBR_PW_DIR" ]; then
        echo "  agent-browser playwright-core not found, skipping chromium fix."
        return 0
    fi

    # Read the chromium-headless-shell revision required by agent-browser's playwright-core
    local REQUIRED_REV
    REQUIRED_REV=$(node -e "
        try {
            const b = require('$AGBR_PW_DIR/browsers.json');
            const c = b.browsers.find(x => x.name === 'chromium-headless-shell');
            console.log(c ? c.revision : '');
        } catch(e) { console.log(''); }
    " 2>/dev/null)

    if [ -z "$REQUIRED_REV" ]; then
        echo "  Could not determine required chromium-headless-shell revision, skipping fix."
        return 0
    fi

    local PW_CACHE="/root/.cache/ms-playwright"

    echo "  agent-browser needs chromium-headless-shell rev $REQUIRED_REV, not found."

    # Find the highest installed headless-shell revision (installed by the global playwright)
    local INSTALLED_DIR
    INSTALLED_DIR=$(find "$PW_CACHE" -maxdepth 1 -name "chromium_headless_shell-*" -type d 2>/dev/null \
        | sort -V | tail -1)

    if [ -z "$INSTALLED_DIR" ]; then
        echo "  No installed chromium_headless_shell found, cannot create compatibility symlinks."
        return 1
    fi

    # Older playwright stored the binary in chrome-linux/headless_shell;
    # newer stores it in chrome-headless-shell-linux64/chrome-headless-shell.
    # Try both locations.
    local SRC_DIR SRC_BIN
    if [ -f "$INSTALLED_DIR/chrome-linux/headless_shell" ]; then
        SRC_DIR="$INSTALLED_DIR/chrome-linux"
        SRC_BIN="headless_shell"
    elif [ -f "$INSTALLED_DIR/chrome-headless-shell-linux64/chrome-headless-shell" ]; then
        SRC_DIR="$INSTALLED_DIR/chrome-headless-shell-linux64"
        SRC_BIN="chrome-headless-shell"
    else
        echo "  Could not locate headless shell binary in $INSTALLED_DIR, skipping fix."
        return 1
    fi

    local INSTALLED_REV
    INSTALLED_REV=$(basename "$INSTALLED_DIR" | sed 's/chromium_headless_shell-//')
    echo "  Creating compatibility symlinks: rev $INSTALLED_REV -> rev $REQUIRED_REV"

    local DEST_DIR="$PW_CACHE/chromium_headless_shell-${REQUIRED_REV}/chrome-headless-shell-linux64"
    mkdir -p "$DEST_DIR"

    # Symlink every file; rename the binary to the name playwright-core expects
    for f in "$SRC_DIR"/*; do
        local fname
        fname=$(basename "$f")
        if [ "$fname" = "$SRC_BIN" ]; then
            ln -sf "$f" "$DEST_DIR/chrome-headless-shell"
        else
            ln -sf "$f" "$DEST_DIR/$fname"
        fi
    done

    # Create the INSTALLATION_COMPLETE marker so playwright treats this as a
    # valid installation and does not attempt to delete or re-download it.
    touch "$PW_CACHE/chromium_headless_shell-${REQUIRED_REV}/INSTALLATION_COMPLETE"

    echo "  Compatibility symlinks created (rev $INSTALLED_REV -> rev $REQUIRED_REV)."
}

# Only apply the fix when running in Claude's remote sandbox AND the agent-browser
# setup (playwright install above) did not install the revision that agent-browser
# expects. Outside the Claude sandbox, playwright can download the missing revision
# at runtime, so no fix is needed.
if [ "${CLAUDECODE:-}" = "1" ] && [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    _AGBR_PW_DIR="$(npm root -g)/agent-browser/node_modules/playwright-core"
    _REQUIRED_REV=""
    if [ -d "$_AGBR_PW_DIR" ]; then
        _REQUIRED_REV=$(node -e "
            try {
                const b = require('$_AGBR_PW_DIR/browsers.json');
                const c = b.browsers.find(x => x.name === 'chromium-headless-shell');
                console.log(c ? c.revision : '');
            } catch(e) { console.log(''); }
        " 2>/dev/null)
    fi
    _EXPECTED_BIN="/root/.cache/ms-playwright/chromium_headless_shell-${_REQUIRED_REV}/chrome-headless-shell-linux64/chrome-headless-shell"
    if [ -n "$_REQUIRED_REV" ] && [ ! -f "$_EXPECTED_BIN" ] && [ ! -L "$_EXPECTED_BIN" ]; then
        echo "Detected Claude remote sandbox and agent-browser chromium fix is needed — applying compatibility fix..."
        fix_agent_browser_claude_sandbox
    fi
fi

echo "Installing project dependencies with pnpm..."
pnpm install --frozen-lockfile

# Save the new version
echo "$VERSION" > "$VERSION_FILE"
echo "Workplace updated to version $VERSION"

# Send success message
send_message "workplace setup finished - version $VERSION"
