#!/bin/sh
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail 'Usage: sh scripts/verify-dmg.sh path/to/Intern.dmg'
[ -f "$1" ] || fail "DMG not found: $1"
case "$1" in
  /*) DMG="$1" ;;
  *) DMG="$PWD/$1" ;;
esac

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/intern-verify.XXXXXX")"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT" -quiet || return
  fi
  rmdir "$MOUNT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil verify "$DMG"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
MOUNTED=1
APP="$MOUNT/Intern.app"
PLIST="$APP/Contents/Info.plist"
[ -d "$APP" ] || fail 'Intern.app is missing from the DMG.'
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || fail 'The Applications shortcut is invalid.'
[ -s "$MOUNT/.DS_Store" ] || fail 'The Finder layout is missing.'
[ -s "$MOUNT/.background/background.tiff" ] || fail 'The installer background is missing.'
[ -s "$MOUNT/.VolumeIcon.icns" ] || fail 'The volume icon is missing.'
[ -s "$APP/Contents/Resources/Intern.icns" ] || fail 'The app icon is missing.'
[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" = com.devin.typesafe.jev-launcher ] || fail 'Unexpected bundle identifier.'
[ "$(plutil -extract CFBundleIconFile raw "$PLIST")" = Intern ] || fail 'The app icon is not configured.'
[ "$(plutil -extract LSMinimumSystemVersion raw "$PLIST")" = 14.0 ] || fail 'Unexpected minimum macOS version.'
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail 'The app version is missing.'
for ARCH in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/Intern" -verify_arch "$ARCH"
done
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "${REQUIRE_NOTARIZATION:-0}" = 1 ]; then
  codesign --verify --strict --verbose=2 "$DMG"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

printf 'Verified Intern %s (%s): universal macOS app, icons, installer layout and signature.\n' "$VERSION" "$BUILD"
