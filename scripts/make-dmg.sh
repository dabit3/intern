#!/bin/sh
# Builds a Release Intern.app and packages it into Intern.dmg
# (app + Applications symlink). Unsigned; recipients right-click → Open once.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: ./Intern.dmg)
set -eu
cd "$(dirname "$0")/.."

OUT="${1:-Intern.dmg}"
DERIVED="build"
APP="$DERIVED/Build/Products/Release/Intern.app"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/launcher-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

xcodebuild -project Intern.xcodeproj -scheme Intern -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build -quiet

test -d "$APP" || { echo "build did not produce $APP" >&2; exit 1; }

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Intern" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
echo "$OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
