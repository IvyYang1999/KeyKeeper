#!/bin/bash
# Recompile the macOS 26 app icon from Assets/AppIcon.icon (Icon Composer format).
# Needs full Xcode (actool). The output is committed, so building the app only needs
# the command line tools.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
xcrun actool "$PROJECT_DIR/Assets/AppIcon.icon" --compile "$OUT" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$OUT/partial.plist" >/dev/null
cp "$OUT/Assets.car" "$PROJECT_DIR/Assets/Compiled/Assets.car"
rm -rf "$OUT"
echo "Updated Assets/Compiled/Assets.car"
