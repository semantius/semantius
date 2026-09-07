#!/bin/bash
# Install script for the pg_semantius CLI
# Usage: curl -fsSL https://raw.githubusercontent.com/semantius/semantius/main/install.sh | bash
#
# Set PG_SEMANTIUS_VERSION to install a specific release instead of the latest:
#   curl -fsSL .../install.sh | PG_SEMANTIUS_VERSION=0.5.0 bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Cleanup on exit
TMP_FILE=""
TMP_CHECKSUM=""
cleanup() {
    if [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ]; then
        rm -f "$TMP_FILE"
    fi
    if [ -n "$TMP_CHECKSUM" ] && [ -f "$TMP_CHECKSUM" ]; then
        rm -f "$TMP_CHECKSUM"
    fi
}
trap cleanup EXIT

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
    linux)
        case "$ARCH" in
            x86_64) BINARY="pg_semantius-linux-x64" ;;
            aarch64|arm64) BINARY="pg_semantius-linux-arm64" ;;
            *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
        esac
        ;;
    darwin)
        case "$ARCH" in
            arm64) BINARY="pg_semantius-darwin-arm64" ;;
            # There is no macOS x64 build. Saying so is the whole point: an
            # Intel Mac that silently downloaded the arm64 binary would fail
            # later with an exec format error nobody can act on.
            x86_64)
                echo -e "${RED}No macOS x64 build is published; pg_semantius is built for Apple Silicon only.${NC}"
                echo "Run it from a checkout instead: https://github.com/semantius/semantius"
                exit 1 ;;
            *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
        esac
        ;;
    *)
        echo -e "${RED}Unsupported OS: $OS${NC}"
        echo "On Windows, use install.ps1:"
        echo "  irm https://raw.githubusercontent.com/semantius/semantius/main/install.ps1 | iex"
        exit 1
        ;;
esac

# Installation directory - prefer ~/.local/bin (no sudo needed)
if [ -z "${INSTALL_DIR:-}" ]; then
    if [ -w "/usr/local/bin" ]; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="$HOME/.local/bin"
    fi
fi

GITHUB_REPO="semantius/semantius"

# A specific version is fetched from its own tag; without one, from the moving
# `latest` pointer. A draft release never moves `latest`, which is what keeps
# the previous release installable while a new one is still uploading.
if [ -n "${PG_SEMANTIUS_VERSION:-}" ]; then
    RELEASE_PATH="releases/download/v${PG_SEMANTIUS_VERSION#v}"
else
    RELEASE_PATH="releases/latest/download"
fi

# Print banner
echo ""
echo -e "${BOLD}Installing pg_semantius${NC}"
echo ""
echo -e "  ${BOLD}Platform${NC}:  $OS/$ARCH"
echo -e "  ${BOLD}Binary${NC}:    $BINARY"
echo -e "  ${BOLD}Location${NC}:  $INSTALL_DIR/pg_semantius"
echo ""

# Check for existing installation
if command -v pg_semantius &> /dev/null; then
    EXISTING_VERSION=$(pg_semantius --version 2>/dev/null || echo "unknown")
    echo -e "${YELLOW}Note: Updating existing installation ($EXISTING_VERSION)${NC}"
    echo ""
fi

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/$RELEASE_PATH/$BINARY"
CHECKSUM_URL="https://github.com/$GITHUB_REPO/$RELEASE_PATH/checksums.txt"

# Download binary
echo -e "${BLUE}Downloading...${NC}"
TMP_FILE=$(mktemp)
if ! curl -fsSL "$DOWNLOAD_URL" -o "$TMP_FILE"; then
    echo -e "${RED}Failed to download binary. Check if releases exist at:${NC}"
    echo "  https://github.com/$GITHUB_REPO/releases"
    exit 1
fi

# Verify checksum (if available)
TMP_CHECKSUM=$(mktemp)
if curl -fsSL "$CHECKSUM_URL" -o "$TMP_CHECKSUM" 2>/dev/null; then
    # Anchored on the whole line: checksums.txt holds bare names, and an
    # unanchored grep for "pg_semantius-linux-x64" also matches nothing else
    # today but would silently pick the wrong row the day a longer name is
    # added.
    EXPECTED_CHECKSUM=$(awk -v b="$BINARY" '$2 == b || $2 == "*" b {print $1}' "$TMP_CHECKSUM")
    if [ -n "$EXPECTED_CHECKSUM" ]; then
        echo -e "${BLUE}Verifying checksum...${NC}"
        # Calculate actual checksum
        if command -v sha256sum &> /dev/null; then
            ACTUAL_CHECKSUM=$(sha256sum "$TMP_FILE" | awk '{print $1}')
        elif command -v shasum &> /dev/null; then
            ACTUAL_CHECKSUM=$(shasum -a 256 "$TMP_FILE" | awk '{print $1}')
        else
            echo -e "${YELLOW}Warning: Could not verify checksum (no sha256sum/shasum found)${NC}"
            ACTUAL_CHECKSUM=""
        fi

        if [ -n "$ACTUAL_CHECKSUM" ]; then
            if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
                echo -e "${RED}Checksum verification failed!${NC}"
                echo "Expected: $EXPECTED_CHECKSUM"
                echo "Actual: $ACTUAL_CHECKSUM"
                exit 1
            fi
            echo -e "${GREEN}✓${NC} Checksum verified"
        fi
    fi
fi

# Make executable
chmod +x "$TMP_FILE"

# Create install directory if needed
if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${BLUE}Creating $INSTALL_DIR...${NC}"
    mkdir -p "$INSTALL_DIR"
fi

# Install
echo -e "${BLUE}Installing...${NC}"
if [ -w "$INSTALL_DIR" ]; then
    mv "$TMP_FILE" "$INSTALL_DIR/pg_semantius"
else
    echo -e "${YELLOW}Requires sudo to install to $INSTALL_DIR${NC}"
    sudo mv "$TMP_FILE" "$INSTALL_DIR/pg_semantius"
fi
TMP_FILE=""  # Clear so cleanup doesn't try to delete

# Success message
echo ""
echo -e "${GREEN}✓ pg_semantius installed successfully!${NC}"
echo ""

# Check if in PATH and show version
if command -v pg_semantius &> /dev/null; then
    pg_semantius --version
else
    # Not in PATH - show setup instructions
    echo -e "${YELLOW}Add pg_semantius to your PATH:${NC}"
    echo ""

    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        bash)
            echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
            echo "  source ~/.bashrc"
            ;;
        zsh)
            echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
            echo "  source ~/.zshrc"
            ;;
        fish)
            echo "  fish_add_path ~/.local/bin"
            ;;
        *)
            echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac
    echo ""
fi

echo "Get started:"
echo "  pg_semantius --help"
echo "  pg_semantius migrate --apps _core --database-url postgresql://user:pass@host:5432/db"
echo ""
