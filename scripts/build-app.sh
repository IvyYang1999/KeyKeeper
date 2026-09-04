#!/bin/bash
set -euo pipefail

# Build a signed KeyKeeper.app and, unless --skip-dmg is passed, its DMG.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="KeyKeeper"
VERSION_FILE="$PROJECT_DIR/VERSION"
APP_BUNDLE="$PROJECT_DIR/dist/dmg/${APP_NAME}.app"
CREATE_DMG=true

if [ "${1:-}" = "--skip-dmg" ]; then
    CREATE_DMG=false
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--skip-dmg]" >&2
    exit 64
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: missing version file: $VERSION_FILE" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: VERSION must use x.y.z format" >&2
    exit 1
fi
DMG_PATH="$PROJECT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME} v${VERSION}"
cd "$PROJECT_DIR"
swift build --disable-keychain -c release
BUILD_DIR="$(swift build --disable-keychain -c release --show-bin-path)"

for binary in KeyKeeperApp keykeeper; do
    if [ ! -f "$BUILD_DIR/$binary" ]; then
        echo "ERROR: missing release binary: $BUILD_DIR/$binary" >&2
        exit 1
    fi
done

SPARKLE_FRAMEWORK_SOURCE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]; then
    echo "ERROR: Sparkle framework not found after build" >&2
    exit 1
fi

echo "==> Creating app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist"

cp "$BUILD_DIR/KeyKeeperApp" "$APP_BUNDLE/Contents/MacOS/KeyKeeperApp"
cp "$BUILD_DIR/keykeeper" "$APP_BUNDLE/Contents/MacOS/keykeeper"
cp "$PROJECT_DIR/Assets/KeyKeeper.icns" "$APP_BUNDLE/Contents/Resources/KeyKeeper.icns"
if [ -f "$PROJECT_DIR/skill/keykeeper.md" ]; then
    cp "$PROJECT_DIR/skill/keykeeper.md" "$APP_BUNDLE/Contents/Resources/keykeeper.md"
fi
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

SIGN_IDENTITY="${KEYKEEPER_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$PROJECT_DIR/.signing-identity" ]; then
    SIGN_IDENTITY="$(<"$PROJECT_DIR/.signing-identity")"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

sign_runtime() {
    local target="$1"
    shift
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - --options runtime "$@" "$target"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@" "$target"
    fi
}

echo "==> Signing nested updater and app (identity: ${SIGN_IDENTITY})"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sign_runtime "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
sign_runtime "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign_runtime "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
sign_runtime "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
sign_runtime "$SPARKLE_FRAMEWORK"
sign_runtime "$APP_BUNDLE/Contents/MacOS/keykeeper"
sign_runtime "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [ "$CREATE_DMG" = true ]; then
    echo "==> Creating DMG"
    ln -sfn /Applications "$PROJECT_DIR/dist/dmg/Applications"
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$PROJECT_DIR/dist/dmg" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
        codesign --verify --verbose=2 "$DMG_PATH"
    fi
fi

echo "==> Build complete"
echo "    App bundle: $APP_BUNDLE"
if [ "$CREATE_DMG" = true ]; then
    echo "    DMG:        $DMG_PATH"
fi
