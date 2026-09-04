#!/bin/bash
set -euo pipefail

# Publish the already-prepared immutable candidate. External changes require an
# explicit version argument so an accidental invocation fails closed.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
TAG="v$VERSION"
DMG="$PROJECT_DIR/dist/KeyKeeper-$VERSION.dmg"
NOTES="$PROJECT_DIR/release-notes/$VERSION.md"
APPCAST="$PROJECT_DIR/appcast.xml"

if [ "${1:-}" != "--confirm-version" ] || [ "${2:-}" != "$VERSION" ] || [ "$#" -ne 2 ]; then
    echo "Usage: $0 --confirm-version $VERSION" >&2
    exit 64
fi
if [ "$(git -C "$PROJECT_DIR" branch --show-current)" != "main" ]; then
    echo "ERROR: updates must be published from main" >&2
    exit 1
fi

CHANGES="$(git -C "$PROJECT_DIR" status --porcelain)"
if [ "$CHANGES" != "?? appcast.xml" ] && [ "$CHANGES" != " M appcast.xml" ]; then
    echo "ERROR: appcast.xml must be the only uncommitted file" >&2
    exit 1
fi
for required in "$DMG" "$NOTES" "$APPCAST"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing release artifact: $required" >&2
        exit 1
    fi
done
if git -C "$PROJECT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag already exists: $TAG" >&2
    exit 1
fi
if gh release view "$TAG" --repo IvyYang1999/KeyKeeper >/dev/null 2>&1; then
    echo "ERROR: GitHub release already exists: $TAG" >&2
    exit 1
fi

git -C "$PROJECT_DIR" tag -a "$TAG" -m "KeyKeeper $VERSION"
git -C "$PROJECT_DIR" push origin "$TAG"
gh release create "$TAG" "$DMG" \
    --repo IvyYang1999/KeyKeeper \
    --title "KeyKeeper $VERSION" \
    --notes-file "$NOTES" \
    --latest

git -C "$PROJECT_DIR" add appcast.xml
git -C "$PROJECT_DIR" commit -m "发布：更新 appcast 至 $VERSION"
echo "Published KeyKeeper $VERSION and activated its signed update feed"
