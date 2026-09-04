#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source-png> <destination-icns>" >&2
    exit 64
fi

SOURCE_PNG="$1"
DESTINATION_ICNS="$2"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "ERROR: App icon source not found: $SOURCE_PNG" >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keykeeper-icon.XXXXXX")"
ICONSET_DIR="$TEMP_DIR/KeyKeeper.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

render_icon() {
    local size="$1"
    local filename="$2"
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "$DESTINATION_ICNS")"
iconutil -c icns "$ICONSET_DIR" -o "$DESTINATION_ICNS"
