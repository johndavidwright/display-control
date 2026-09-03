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
echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/DisplayControl"

echo "→ Assembling ${APP}…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGED_APP="$WORK/DisplayControl.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"
cp "$BIN" "$STAGED_APP/Contents/MacOS/DisplayControl"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/DisplayControl-LICENSE.txt"
ditto "$BIN_DIR/Sparkle.framework" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/checkouts/Sparkle/LICENSE" "$STAGED_APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$ROOT/THIRD_PARTY/MonitorControl-LICENSE.txt" "$STAGED_APP/Contents/Resources/MonitorControl-LICENSE.txt"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi

echo "→ Ad-hoc code signing…"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
lipo "$STAGED_APP/Contents/MacOS/DisplayControl" -verify_arch arm64
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"

echo "✓ Built $APP"
echo "  Run:  open \"$APP\"    (look for the sun icon in the menu bar)"
