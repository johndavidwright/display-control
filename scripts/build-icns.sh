#!/bin/bash
# Regenerate Resources/AppIcon.icns from the CoreGraphics icon renderer.
# See scripts/generate-icon.swift for why this doesn't rasterize the SVG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Rendering 1024×1024 master…"
swift "$ROOT/scripts/generate-icon.swift" "$WORK/AppIcon_1024.png"

echo "→ Building iconset…"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for entry in \
  "16:icon_16x16.png" "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  size="${entry%%:*}"
  name="${entry##*:}"
  sips -z "$size" "$size" "$WORK/AppIcon_1024.png" --out "$ICONSET/$name" >/dev/null 2>&1
done

echo "→ Compiling .icns…"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "✓ Wrote Resources/AppIcon.icns — rebuild the app with scripts/make-app.sh to pick it up."
