#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <built-cli> [target-cli]" >&2
    exit 64
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_CLI="$1"
TARGET_CLI="${2:-/opt/homebrew/bin/keykeeper}"

if [ ! -x "$BUILT_CLI" ]; then
    echo "ERROR: built KeyKeeper CLI is missing or not executable: $BUILT_CLI" >&2
    exit 1
fi

EXPECTED_CLI_VERSION="$("$BUILT_CLI" --version)"
TARGET_DIRECTORY="$(/usr/bin/dirname "$TARGET_CLI")"
if ! INSTALL_TEMP="$(/usr/bin/mktemp "$TARGET_DIRECTORY/.keykeeper.install.XXXXXX")"; then
    echo "ERROR: failed to create an atomic install file in $TARGET_DIRECTORY" >&2
    exit 1
fi
trap '/bin/rm -f "$INSTALL_TEMP"' EXIT

if ! /bin/cp "$BUILT_CLI" "$INSTALL_TEMP" || ! /bin/chmod 755 "$INSTALL_TEMP"; then
    echo "ERROR: failed to prepare KeyKeeper CLI for $TARGET_CLI" >&2
    exit 1
fi
if ! /bin/mv -f "$INSTALL_TEMP" "$TARGET_CLI"; then
    echo "ERROR: failed to atomically install KeyKeeper CLI at $TARGET_CLI" >&2
    exit 1
fi
trap - EXIT

"$PROJECT_DIR/scripts/verify-cli-deploy.sh" \
    "$BUILT_CLI" \
    "$EXPECTED_CLI_VERSION" \
    "$TARGET_CLI"
