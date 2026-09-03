#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE_NAME="DisplayControl-$VERSION-macOS-arm64.zip"
GENERATOR="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
DOWNLOAD_PREFIX="https://github.com/johndavidwright/display-control/releases/download/v$VERSION/"

if [ ! -f "$DIST/$ARCHIVE_NAME" ]; then
  echo "Run scripts/package-release.sh before generating the appcast." >&2
  exit 1
fi
if [ ! -x "$GENERATOR" ]; then
  swift package --package-path "$ROOT" resolve
fi

# Only include this release; don't accidentally advertise test or stale bundles.
INPUT="$(mktemp -d "$DIST/appcast-input.XXXXXX")"
trap 'rm -rf "$INPUT"' EXIT
cp "$DIST/$ARCHIVE_NAME" "$INPUT/$ARCHIVE_NAME"
cp "$ROOT/RELEASE_NOTES.md" "$INPUT/${ARCHIVE_NAME%.zip}.md"
ARGS=(--download-url-prefix "$DOWNLOAD_PREFIX" --embed-release-notes --maximum-deltas 0 -o "$DIST/appcast.xml" "$INPUT")

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATOR" --ed-key-file - "${ARGS[@]}"
else
  "$GENERATOR" --account com.jdw.DisplayControl "${ARGS[@]}"
fi
test -s "$DIST/appcast.xml"
xmllint --noout "$DIST/appcast.xml"
echo "Signed appcast: $DIST/appcast.xml"
