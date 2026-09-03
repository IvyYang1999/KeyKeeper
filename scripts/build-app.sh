#!/bin/bash
set -euo pipefail

# Build script for KeyKeeper.app bundle and .dmg installer
# Usage: ./scripts/build-app.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="KeyKeeper"
VERSION="0.1.0"
BUNDLE_ID="com.keykeeper.app"
APP_BUNDLE="$PROJECT_DIR/dist/dmg/${APP_NAME}.app"
DMG_PATH="$PROJECT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME} v${VERSION}"
echo "    Project: ${PROJECT_DIR}"

# Step 1: Build release binaries
echo "==> Running swift build -c release..."
cd "$PROJECT_DIR"
swift build -c release

BUILD_DIR="$(swift build -c release --show-bin-path)"
echo "    Build output: ${BUILD_DIR}"

# Verify binaries exist
if [ ! -f "$BUILD_DIR/KeyKeeperApp" ]; then
    echo "ERROR: KeyKeeperApp binary not found at $BUILD_DIR/KeyKeeperApp"
    exit 1
fi
if [ ! -f "$BUILD_DIR/keykeeper" ]; then
    echo "ERROR: keykeeper CLI binary not found at $BUILD_DIR/keykeeper"
    exit 1
fi

# Step 2: Create .app bundle structure
echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 3: Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KeyKeeperApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.keykeeper.app</string>
    <key>CFBundleName</key>
    <string>KeyKeeper</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>KeyKeeper deep links</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>keykeeper</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Step 4: Copy binaries
echo "==> Copying binaries..."
cp "$BUILD_DIR/KeyKeeperApp" "$APP_BUNDLE/Contents/MacOS/KeyKeeperApp"
cp "$BUILD_DIR/keykeeper" "$APP_BUNDLE/Contents/MacOS/keykeeper"

# Step 5: Copy skill file into Resources
echo "==> Copying skill file..."
if [ -f "$PROJECT_DIR/skill/keykeeper.md" ]; then
    cp "$PROJECT_DIR/skill/keykeeper.md" "$APP_BUNDLE/Contents/Resources/keykeeper.md"
else
    echo "WARNING: skill/keykeeper.md not found, skipping"
fi

# Step 6: Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Step 6.5: Code sign the whole bundle.
#
# A STABLE signing identity is what keeps macOS keychain items readable without
# prompts across rebuilds: the item's ACL trusts the identity that created it, and
# ad-hoc signatures mint a new identity on every build (the July 2026 popup storms).
# Identity resolution: $KEYKEEPER_SIGN_IDENTITY, else the .signing-identity file at
# the repo root (gitignored, holds e.g. "Developer ID Application: ..."), else
# ad-hoc "-" so open-source contributors can still build (they get at most one
# prompt per rebuild thanks to the single-item store; a self-made cert fixes even that).
# No entitlements: an ad-hoc signature carrying keychain-access-groups is killed by
# the kernel at launch (exit 137).
SIGN_IDENTITY="${KEYKEEPER_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$PROJECT_DIR/.signing-identity" ]; then
    SIGN_IDENTITY="$(cat "$PROJECT_DIR/.signing-identity")"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing bundle (identity: ${SIGN_IDENTITY})..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

# Step 7: Create .dmg
echo "==> Creating .dmg..."
# Add Applications symlink for drag-to-install
ln -sf /Applications "$PROJECT_DIR/dist/dmg/Applications"

# Remove old dmg if exists
rm -f "$DMG_PATH"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$PROJECT_DIR/dist/dmg" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "==> Build complete!"
echo "    App bundle: $APP_BUNDLE"
echo "    DMG:        $DMG_PATH"
echo ""
echo "    To test: open \"$APP_BUNDLE\""
