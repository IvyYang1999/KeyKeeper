#!/bin/bash
set -euo pipefail

# Prepare a signed appcast locally. This script never tags, pushes, or publishes.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
TAG="v$VERSION"
DMG="$PROJECT_DIR/dist/KeyKeeper-$VERSION.dmg"
NOTES="$PROJECT_DIR/release-notes/$VERSION.md"
SPARKLE_TOOLS="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"

if [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" != "$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)" ]; then
    echo "ERROR: updates must be prepared from the exact committed main candidate" >&2
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
if [ -f "$PROJECT_DIR/dist/KeyKeeper-$VERSION.update.json" ]; then
    echo "ERROR: a verified candidate already exists; resume publish-update.sh, do not rebuild it" >&2
    exit 1
fi
if git -C "$PROJECT_DIR" rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "ERROR: version $VERSION is already tagged; use a new version, never rebuild the release" >&2
    exit 1
fi
SOURCE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

: "${KEYKEEPER_PROVISION_PROFILE:?Set the Developer ID provisioning profile path}"
: "${KEYKEEPER_SIGN_IDENTITY:?Set the matching Developer ID certificate SHA-1}"
mkdir -p "$PROJECT_DIR/dist"
python3 -B "$PROJECT_DIR/scripts/build-identity-candidate.py" \
    --profile "$KEYKEEPER_PROVISION_PROFILE" --identity "$KEYKEEPER_SIGN_IDENTITY" \
    --output-parent "$PROJECT_DIR/dist" --release

# One credential carries all three: APPLE_ID and APPLE_TEAM_ID as plain fields, the
# app-specific password as a secret. `keykeeper run` injects the plain ones without asking.
NOTARY_CREDENTIAL_ID="${KEYKEEPER_NOTARY_CREDENTIAL_ID:-apple-notary}"
keykeeper run -c "$NOTARY_CREDENTIAL_ID" \
    --reason "公证本次发布的 KeyKeeper $VERSION 安装包（notarytool submit + staple）" \
    -- "$PROJECT_DIR/scripts/notarize-update.sh" "$DMG"

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

SIGNING_CREDENTIAL_ID="${KEYKEEPER_SPARKLE_CREDENTIAL_ID:-keykeeper-sparkle-signing}"
keykeeper run -c "$SIGNING_CREDENTIAL_ID" \
    --reason "验证更新签名私钥的公钥身份，再签署本次发布的更新源" \
    -- /usr/bin/python3 "$PROJECT_DIR/scripts/sparkle-key.py" \
    --plist "$PROJECT_DIR/dist/dmg/KeyKeeper.app/Contents/Info.plist" \
    --sign "$SPARKLE_TOOLS/generate_appcast" -- \
    --download-url-prefix "https://github.com/IvyYang1999/KeyKeeper/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --link "https://github.com/IvyYang1999/KeyKeeper" \
    -o "$UPDATE_DIRECTORY/appcast.xml" \
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
# Sparkle 2 signs the feed itself as a trailing comment, not as an attribute.
if ! grep -Fq 'sparkle-signatures:' "$UPDATE_DIRECTORY/appcast.xml"; then
    echo "ERROR: generated appcast itself is not signed" >&2
    exit 1
fi
if ! grep -Fq 'edSignature:' "$UPDATE_DIRECTORY/appcast.xml"; then
    echo "ERROR: generated appcast carries no feed signature" >&2
    exit 1
fi

cp "$UPDATE_DIRECTORY/appcast.xml" "$PROJECT_DIR/appcast.xml"
if [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" != "$SOURCE_COMMIT" ]; then
    echo "ERROR: source changed during preparation; no release receipt recorded" >&2
    exit 1
fi
# Re-check both signatures with the App's public key and bind these exact artifacts to HEAD.
/usr/bin/python3 -B "$PROJECT_DIR/scripts/publish-update.py" --record-candidate
echo "Prepared signed appcast for KeyKeeper $VERSION"
echo "Review appcast.xml, then run: ./scripts/publish-update.sh --confirm-version $VERSION"
