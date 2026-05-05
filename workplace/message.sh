#!/bin/bash
# Message script
# Sends a message to a Slack or Slack-compatible webhook (e.g. Discord)
if [ -z "$1" ]; then
    echo "Usage: $0 <message>"
    exit 1
fi

MESSAGE="$1"
HOSTNAME=$(uname -n)

# Load NOTIFY_WEBHOOK_URL via dotenvx if not already set
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$NOTIFY_WEBHOOK_URL" ] && command -v dotenvx &>/dev/null && [ -f "$SCRIPT_DIR/../.env" ]; then
    NOTIFY_WEBHOOK_URL=$(dotenvx get NOTIFY_WEBHOOK_URL --env-file "$SCRIPT_DIR/../.env" 2>/dev/null)
fi

if [ -z "$NOTIFY_WEBHOOK_URL" ]; then
    echo "Info: NOTIFY_WEBHOOK_URL is not set. Skipping notification."
    exit 0
fi
WEBHOOK_URL="$NOTIFY_WEBHOOK_URL"

# Get git repo and branch if inside a git repo
GIT_REPO=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$GIT_REPO" ] && [ -n "$GIT_BRANCH" ]; then
    GIT_INFO=" [$GIT_REPO:$GIT_BRANCH]"
else
    GIT_INFO=""
fi

# Send message using Slack-compatible webhook format
curl -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"[$HOSTNAME]$GIT_INFO $MESSAGE\"}" \
    --silent --show-error --output /dev/null

if [ $? -ne 0 ]; then
    echo "Failed to send message"
    exit 1
fi
