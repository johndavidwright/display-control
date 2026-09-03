#!/bin/bash
# Build DisplayControl and wrap it in a double-clickable menu-bar .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="${2:-$ROOT/DisplayControl.app}"
case "$APP" in
  /*.app) ;;
  *) echo "Destination must be an absolute path ending in .app" >&2; exit 2 ;;
esac
BUNDLE_ID="com.jdw.DisplayControl"
VERSION="0.2.5"

echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DisplayControl"

echo "→ Assembling ${APP}…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGED_APP="$WORK/DisplayControl.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/DisplayControl"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>DisplayControl</string>
  <key>CFBundleDisplayName</key>     <string>Display Control</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>DisplayControl</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "→ Ad-hoc code signing…"
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"

echo "✓ Built $APP"
echo "  Run:  open \"$APP\"    (look for the sun icon in the menu bar)"
