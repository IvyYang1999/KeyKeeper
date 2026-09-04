#!/bin/bash
set -euo pipefail

# Prepare a signed appcast locally. This script never tags, pushes, or publishes.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
TAG="v$VERSION"
DMG="$PROJECT_DIR/dist/KeyKeeper-$VERSION.dmg"
NOTES="$PROJECT_DIR/release-notes/$VERSION.md"
SPARKLE_TOOLS="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"

if [ "$(git -C "$PROJECT_DIR" branch --show-current)" != "main" ]; then
    echo "ERROR: updates must be prepared from main" >&2
    exit 1
fi
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "ERROR: commit and verify the release candidate before preparing an update" >&2
    exit 1
fi
if [ ! -f "$NOTES" ]; then
    echo "ERROR: missing release notes: $NOTES" >&2
    exit 1
fi

"$PROJECT_DIR/scripts/build-app.sh"

NOTARY_CREDENTIAL_ID="${KEYKEEPER_NOTARY_CREDENTIAL_ID:-app专用密码-swob}"
keykeeper run -c "$NOTARY_CREDENTIAL_ID" -- \
    "$PROJECT_DIR/scripts/notarize-update.sh" "$DMG"

UPDATE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/keykeeper-update.XXXXXX")"
cleanup() {
    rm -rf "$UPDATE_DIRECTORY"
}
trap cleanup EXIT

cp "$DMG" "$UPDATE_DIRECTORY/"
cp "$NOTES" "$UPDATE_DIRECTORY/KeyKeeper-$VERSION.md"
if [ -f "$PROJECT_DIR/appcast.xml" ]; then
    cp "$PROJECT_DIR/appcast.xml" "$UPDATE_DIRECTORY/appcast.xml"
fi

"$SPARKLE_TOOLS/generate_appcast" \
    --account com.keykeeper.app \
    --download-url-prefix "https://github.com/IvyYang1999/KeyKeeper/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --link "https://github.com/IvyYang1999/KeyKeeper" \
    -o appcast.xml \
    "$UPDATE_DIRECTORY"

EXPECTED_URL="https://github.com/IvyYang1999/KeyKeeper/releases/download/$TAG/KeyKeeper-$VERSION.dmg"
if ! grep -Fq "$EXPECTED_URL" "$UPDATE_DIRECTORY/appcast.xml"; then
    echo "ERROR: generated appcast does not point to the release asset" >&2
    exit 1
fi
if ! grep -Fq 'sparkle:edSignature=' "$UPDATE_DIRECTORY/appcast.xml"; then
    echo "ERROR: generated appcast does not sign the update archive" >&2
    exit 1
fi
if ! grep -Fq 'sparkle:signature=' "$UPDATE_DIRECTORY/appcast.xml"; then
    echo "ERROR: generated appcast itself is not signed" >&2
    exit 1
fi

cp "$UPDATE_DIRECTORY/appcast.xml" "$PROJECT_DIR/appcast.xml"
echo "Prepared signed appcast for KeyKeeper $VERSION"
echo "Review appcast.xml, then run: ./scripts/publish-update.sh --confirm-version $VERSION"
