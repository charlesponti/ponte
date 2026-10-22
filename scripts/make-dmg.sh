#!/bin/bash
# Builds a DMG you can put on a website: signed with the Developer ID certificate and the hardened
# runtime that notarization requires, then (optionally) notarized and stapled.
#
#   ./scripts/make-dmg.sh                 → dist/Ponte-<version>.dmg, signed, ready to notarize
#   ./scripts/make-dmg.sh --notarize      → also submit to Apple, wait, and staple the ticket
#   ./scripts/make-dmg.sh --install       → also replace /Applications/Ponte.app with this build
#
# Notarization needs a stored credential profile (the password is entered by you, never here):
#
#   xcrun notarytool store-credentials ponte-notary \
#     --apple-id "<your Apple ID>" --team-id 3QHJ2KN8AL --password "<an app-specific password>"
#
# Apple-specific passwords: appleid.apple.com → Sign-In and Security → App-Specific Passwords.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_NAME="Ponte"
DEVID_PROFILE="${PONTE_NOTARY_PROFILE:-ponte-notary}"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"

# MARK: - The identity

DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [ -z "$DEVID" ]; then
  echo "!! no Developer ID Application certificate found."
  echo "!! A DMG signed with a development certificate opens on other Macs only with a"
  echo "!! right-click, and cannot be notarized. Add one in Xcode → Settings → Accounts → Manage"
  echo "!! Certificates (Developer ID Application), or accept that for a personal copy."
  exit 1
fi
echo "==> signing identity: $DEVID"

# MARK: - Build and sign for distribution

APP="$ROOT/dist/$APP_NAME.app"
echo "==> building"
swift build -c release --arch arm64 2>&1 | tail -2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ponte "$APP/Contents/MacOS/Ponte"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The hardened runtime is not optional: notarytool rejects anything without it. --timestamp is what
# makes the signature provable after the certificate expires.
echo "==> signing with the hardened runtime"
codesign --force --options runtime --timestamp \
  --sign "$DEVID" --identifier com.ponti.ponte \
  --entitlements Resources/Ponte.entitlements "$APP" 2>&1 | tail -2
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -1
echo "    authority: $(codesign -dv --verbose=4 "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
echo "    hardened:  $(codesign -dv --verbose=4 "$APP" 2>&1 | grep -c 'flags=.*runtime') (1 means yes)"

# MARK: - The disk image

echo "==> building the disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The volume wears the app's own icon, drawn by the app's own renderer.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  SetFile -a C "$STAGE" 2>/dev/null || true
fi
cat > "$STAGE/Read me first.txt" <<TXT
$APP_NAME $VERSION

Drag $APP_NAME to Applications, then open it from there.

The first time you record, macOS asks for the microphone — allow it.
The first launch downloads the speech model (about 600 MB) so that everything after
that runs on your Mac. Nothing you say is sent anywhere.
TXT

mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "==> wrote $DMG ($(du -h "$DMG" | cut -f1))"

# MARK: - Notarization

if [ "$NOTARIZE" = "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$DEVID_PROFILE" >/dev/null 2>&1; then
    echo "!! no stored credentials for profile '$DEVID_PROFILE'."
    echo "!! run this once, entering the password yourself:"
    echo "!!   xcrun notarytool store-credentials $DEVID_PROFILE --apple-id <id> --team-id 3QHJ2KN8AL --password <app-specific>"
    exit 1
  fi
  echo "==> submitting to Apple (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$DEVID_PROFILE" --wait 2>&1 | tail -6
  echo "==> stapling the ticket to the DMG"
  xcrun stapler staple "$DMG" 2>&1 | tail -2
  xcrun stapler validate "$DMG" 2>&1 | tail -1
fi

# MARK: - What Gatekeeper will say

echo "==> Gatekeeper's verdict on this copy:"
if spctl -a -vvv -t install "$APP" 2>&1 | head -3; then :; fi
echo
if [ "$NOTARIZE" = "1" ]; then
  echo "    Notarized and stapled: it opens on any Mac with a double click."
else
  echo "    Not notarized yet. On another Mac this shows \"Apple could not verify...\", which the"
  echo "    buyer can only get past by right-clicking and choosing Open — so run with --notarize"
  echo "    before you sell it."
fi

if [ "$INSTALL" = "1" ]; then
  echo "==> installing to /Applications"
  osascript -e 'tell application "Ponte" to quit' >/dev/null 2>&1 || true
  pkill -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "    note: this build is signed with a different certificate than the development one, so"
  echo "    macOS may ask for the microphone again."
fi
