#!/bin/sh
# Builds a Release Intern.app and packages it into Intern.dmg
# (app + Applications symlink). Unsigned; recipients right-click → Open once.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: ./Intern.dmg)
set -eu
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: scripts/make-dmg.sh [output.dmg]' \
    'RELEASE_VERSION (default: 0.1.2), RELEASE_BUILD (default: 3)' \
    'SIGNING_IDENTITY: Developer ID Application identity, or - for a local ad-hoc build.' \
    'NOTARY_PROFILE: notarytool Keychain profile. Requires SIGNING_IDENTITY.' \
    'Without NOTARY_PROFILE, the build is not notarized. Existing outputs are never replaced.'
  exit 0
fi
[ "$#" -le 1 ] || fail 'Usage: scripts/make-dmg.sh [output.dmg]'
OUT="${1:-Intern.dmg}"
case "$OUT" in
  /*.dmg) ;;
  *.dmg) OUT="$PWD/$OUT" ;;
  *) fail 'Output must have a .dmg extension.' ;;
esac
[ -d "$(dirname "$OUT")" ] || fail 'Output directory does not exist.'
for FILE in "$OUT" "$OUT.sha256"; do
  [ ! -e "$FILE" ] && [ ! -L "$FILE" ] || fail "Output already exists: $FILE"
done

VERSION="${RELEASE_VERSION:-0.1.2}"
BUILD_NUMBER="${RELEASE_BUILD:-3}"
IDENTITY="${SIGNING_IDENTITY:--}"
PROFILE="${NOTARY_PROFILE:-}"
awk -v version="$VERSION" 'BEGIN {exit(version ~ /^[0-9]+[.][0-9]+[.][0-9]+$/ ? 0 : 1)}' \
  || fail 'RELEASE_VERSION must contain three numbers, such as 0.1.0.'
awk -v build="$BUILD_NUMBER" 'BEGIN {exit(build ~ /^[1-9][0-9]*$/ ? 0 : 1)}' \
  || fail 'RELEASE_BUILD must be a positive integer without leading zeros.'
[ -z "$PROFILE" ] || [ "$IDENTITY" != - ] || fail 'Set SIGNING_IDENTITY to a Developer ID Application identity before notarizing.'

DERIVED="$PWD/build"
mkdir -p "$DERIVED"
WORK="$(mktemp -d "$DERIVED/dmg.XXXXXX")"
STAGE="$WORK/stage"
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT" -quiet || return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$STAGE/.background" "$MOUNT"

xcodebuild -project Intern.xcodeproj -scheme Intern -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=YES MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build -quiet

APP="$DERIVED/Build/Products/Release/Intern.app"
[ -d "$APP" ] || fail "Build did not produce $APP"
if [ "$IDENTITY" = - ]; then
  codesign --force --sign - --options runtime --timestamp=none --entitlements Resources/Intern.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements Resources/Intern.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
for ARCH in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/Intern" -verify_arch "$ARCH"
done
ditto "$APP" "$STAGE/Intern.app"
APP="$STAGE/Intern.app"

if [ -n "$PROFILE" ]; then
  ditto -c -k --keepParent "$APP" "$WORK/Intern.zip"
  xcrun notarytool submit "$WORK/Intern.zip" --keychain-profile "$PROFILE" --wait --timeout 30m
  xcrun stapler staple "$APP"
fi

ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') + 32768 ))
hdiutil create -volname Intern -fs HFS+ -size "${SIZE_KB}k" -srcfolder "$STAGE" -format UDRW -quiet "$WORK/layout.dmg"
hdiutil attach "$WORK/layout.dmg" -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
MOUNTED=1
osascript scripts/layout-dmg.applescript "$MOUNT"
[ -s "$MOUNT/.DS_Store" ] || fail 'Finder did not save the installer layout.'
cp Resources/Intern.icns "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
sync
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
hdiutil convert "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/Intern.dmg" -quiet

if [ "$IDENTITY" != - ]; then
  codesign --sign "$IDENTITY" --timestamp "$WORK/Intern.dmg"
fi
if [ -n "$PROFILE" ]; then
  xcrun notarytool submit "$WORK/Intern.dmg" --keychain-profile "$PROFILE" --wait --timeout 30m
  xcrun stapler staple "$WORK/Intern.dmg"
  REQUIRE_NOTARIZATION=1 sh scripts/verify-dmg.sh "$WORK/Intern.dmg"
else
  sh scripts/verify-dmg.sh "$WORK/Intern.dmg"
  printf '%s\n' 'This build is not notarized. Do not describe it as an Apple-notarized release.' >&2
fi

ln "$WORK/Intern.dmg" "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")") > "$WORK/checksum"
ln "$WORK/checksum" "$OUT.sha256"
printf '%s\n' "$OUT" "$OUT.sha256"
