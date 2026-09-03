#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/DisplayControl.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE_NAME="DisplayControl-$VERSION-macOS-arm64.zip"

"$ROOT/scripts/make-app.sh" release "$APP"
rm -f "$DIST/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ARCHIVE_NAME"
unzip -tq "$DIST/$ARCHIVE_NAME"
(
  cd "$DIST"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
echo "Release archive: $DIST/$ARCHIVE_NAME"
