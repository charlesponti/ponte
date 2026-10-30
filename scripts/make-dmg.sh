#!/bin/bash
# Builds a DMG you can put on a website: signed with the Developer ID certificate and the hardened
# runtime that notarization requires, then (optionally) notarized and stapled.
#
#   ./scripts/make-dmg.sh                 → dist/Ponte-<version>.dmg, signed, ready to notarize
#   ./scripts/make-dmg.sh --notarize      → also submit to Apple, wait, and staple the ticket
#   ./scripts/make-dmg.sh --install       → also replace /Applications/Ponte.app with this build
#
# Notarization needs a stored credential profile, created once by you and kept in your keychain:
#
#   # either an App Store Connect team key — belongs to the team, no password anywhere
#   xcrun notarytool store-credentials ponte-notary \
#     --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer id>
#
#   # or an Apple ID with an app-specific password (appleid.apple.com → Sign-In and Security)
#   xcrun notarytool store-credentials ponte-notary \
#     --apple-id "<your Apple ID>" --team-id 3QHJ2KN8AL --password "<app-specific>"
#
# Both notarize the *app* and then the *disk image*, and staple each, so the copy a buyer drags to
# /Applications carries its own ticket and does not need Apple to be reachable on first launch.
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

# Resolve to the certificate *hash*, not its name: passing the name to codesign on this machine produces an
# ad-hoc signature (TeamIdentifier=not set) for the nested binaries, which notarytool rejects. The hash works.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}')"
if [ -z "$DEVID" ]; then
  echo "!! no Developer ID Application certificate found."
  echo "!! A DMG signed with a development certificate opens on other Macs only with a"
  echo "!! right-click, and cannot be notarized. Add one in Xcode → Settings → Accounts → Manage"
  echo "!! Certificates (Developer ID Application), or accept that for a personal copy."
  exit 1
fi
TEAM_ID="${PONTE_TEAM_ID:-3QHJ2KN8AL}"
TEAM_ID="${TEAM_ID:-3QHJ2KN8AL}"
echo "==> signing identity: $DEVID"
echo "==> team: $TEAM_ID"

# MARK: - Build and sign for distribution

APP="$ROOT/dist/$APP_NAME.app"
echo "==> building"
swift build -c release --arch arm64 2>&1 | tail -2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ponte "$APP/Contents/MacOS/Ponte"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the version, exactly as build-app.sh does. The template plist carries CFBundleVersion 1, and without this
# every disk image shipped with build 1 — which Sparkle compares against the installed build, so a new release
# looked older than the one already on the Mac and the update never fired.
STAMP_SHORT="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAMP_BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STAMP_SHORT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STAMP_BUILD" "$APP/Contents/Info.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" != "$STAMP_BUILD" ]; then
  echo "!! build number did not stamp: wanted $STAMP_BUILD"; exit 1
fi
echo "    stamped $STAMP_SHORT ($STAMP_BUILD)"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle is the one dynamically linked framework. Everything else in this bundle is static, so without this
# line the app is signed, notarized and stapled — and dies in dyld before it can open. (This is why 1.1.0 shipped
# dead: the build that produced the DMG copied the bundles but not the framework.)
FW_SRC=".build/release/Sparkle.framework"
if [ -d "$FW_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FW_SRC" "$APP/Contents/Frameworks/"
  echo "    + Sparkle.framework"
else
  echo "!! Sparkle.framework missing from .build/release — the app cannot launch"; exit 1
fi
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The hardened runtime is not optional: notarytool rejects anything without it. --timestamp is what
# makes the signature provable after the certificate expires.
# Sparkle is a framework that contains its own helper apps and XPC services. They must be signed first,
# from the inside out, with the hardened runtime and a secure timestamp — otherwise notarytool rejects the
# whole archive with "the binary is not signed with a valid Developer ID certificate", which is what 1.1.0's
# first notarization attempt did. Signing only the outer app is not enough, and --deep is deprecated.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  # Inside-out, and every Mach-O first: signing the .xpc or .app bundle does not reliably cover the binary
  # sitting inside it on this toolchain (the notary kept rejecting Downloader.xpc/.../Downloader and Installer.xpc/.../Installer).
  # Sign each executable, then each bundle, then the framework.
  while IFS= read -r -d '' bin; do
    codesign --force --options runtime --timestamp --sign "$DEVID" "$bin" >/dev/null 2>&1 || true
  done < <(find "$FW" -type f -perm -111 -print0)
  for bundle in "$FW"/Versions/B/Autoupdate.app "$FW"/Versions/B/Updater.app \
                "$FW"/Versions/B/Installer.xpc "$FW"/Versions/B/Downloader.xpc; do
    [ -e "$bundle" ] && codesign --force --options runtime --timestamp --sign "$DEVID" "$bundle" >/dev/null 2>&1 || true
  done
  codesign --force --options runtime --timestamp --sign "$DEVID" "$FW" >/dev/null 2>&1 \
    || { echo "!! signing Sparkle.framework failed"; exit 1; }

  # The binary links @rpath/Sparkle.framework, and SwiftPM's default rpath is @loader_path (Contents/MacOS),
  # which does not contain it. Without this the app is signed and notarized and dies in dyld before it opens.
  # (This is what made the 1.1.0 download fail to launch after every earlier fix landed.)
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Ponte" 2>/dev/null || true
  if ! otool -L "$APP/Contents/MacOS/Ponte" | grep -q "Sparkle.framework"; then
    echo "!! Sparkle is not linked — nothing to fix"; fi
  echo "    signed Sparkle.framework (helpers and framework)"
fi

echo "==> signing with the hardened runtime"
codesign --force --options runtime --timestamp \
  --sign "$DEVID" --identifier com.ponti.ponte \
  --entitlements Resources/Ponte.entitlements "$APP" 2>&1 | tail -2
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -1
echo "    authority: $(codesign -dv --verbose=4 "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
echo "    hardened:  $(codesign -dv --verbose=4 "$APP" 2>&1 | grep -c 'flags=.*runtime') (1 means yes)"
# A release whose requirement is not the team's would invalidate every customer's Accessibility grant
# on the next update — with the toggle still showing on. Never ship one.
./scripts/check-signature.sh "$APP" "$TEAM_ID"

# MARK: - Notarize the app itself

# Order matters. Submitting only the disk image notarizes the app but staples nothing to it, so the copy that
# ends up in /Applications has no ticket of its own and Gatekeeper must reach Apple the first time it launches.
# Stapling is offline insurance, and it has to happen before the app is sealed inside the image.
if [ "$NOTARIZE" = "1" ]; then
  APPZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"
  rm -f "$APPZIP"
  echo "==> notarizing the app (submission 1 of 2)"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APPZIP"
  xcrun notarytool submit "$APPZIP" --keychain-profile "$DEVID_PROFILE" --wait 2>&1 | tail -4
  rm -f "$APPZIP"
  xcrun stapler staple "$APP" 2>&1 | tail -1
fi

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

On its first launch Ponte fetches its speech model (about 600 MB) and warms it up. The menu
bar icon says "Getting the speech model — 43%" while that is happening, and it declines to
start a dictation until it has finished, rather than recording one for you to wait on. After
that everything runs on your Mac. Nothing you say is sent anywhere.
TXT

mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "==> wrote $DMG ($(du -h "$DMG" | cut -f1))"

# The disk image needs a signature of its own, not just its contents. That is what Gatekeeper assesses when a
# buyer double-clicks the download, and an unsigned image is rejected outright however well signed the app
# inside may be: "rejected, source=no usable signature". Found by assessing the DMG rather than the app.
echo "==> signing the disk image"
codesign --force --timestamp --sign "$DEVID" "$DMG" 2>&1 | tail -1
codesign --verify --verbose=2 "$DMG" 2>&1 | tail -1

# MARK: - Notarization

if [ "$NOTARIZE" = "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$DEVID_PROFILE" >/dev/null 2>&1; then
    echo "!! no stored credentials for profile '$DEVID_PROFILE'."
    echo "!! run this once, entering the password yourself:"
    echo "!!   xcrun notarytool store-credentials $DEVID_PROFILE --apple-id <id> --team-id 3QHJ2KN8AL --password <app-specific>"
    exit 1
  fi
  echo "==> notarizing the disk image (submission 2 of 2)"
  xcrun notarytool submit "$DMG" --keychain-profile "$DEVID_PROFILE" --wait 2>&1 | tail -6
  echo "==> stapling the ticket to the DMG"
  xcrun stapler staple "$DMG" 2>&1 | tail -2
  xcrun stapler validate "$DMG" 2>&1 | tail -1
fi

# MARK: - What Gatekeeper will say

echo "==> Gatekeeper's verdict, as a buyer's Mac sees it:"
spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 | head -4
echo "    and the app inside:"
spctl -a -vvv -t install "$APP" 2>&1 | head -3
echo
if [ "$NOTARIZE" = "1" ]; then
  echo "    Notarized and stapled: it opens on any Mac with a double click."
else
  echo "    Not notarized yet. On another Mac this shows \"Apple could not verify...\", and recent"
  echo "    macOS has removed the right-click bypass: the buyer has to find System Settings →"
  echo "    Privacy & Security → Open Anyway, or give up. Run with --notarize before you sell it."
fi

if [ "$INSTALL" = "1" ]; then
  echo "==> installing to /Applications"
  osascript -e 'tell application "Ponte" to quit' >/dev/null 2>&1 || true
  # Insist, and then check. This block used to report success while leaving the previous build in place: the
  # staged app was current, /Applications was not, and every later test silently exercised the old binary.
  # A running process cannot have its executable replaced, so waiting for it to actually go is the point.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null || break; sleep 1; done
  pkill -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null 2>&1 || true
  sleep 1
  pgrep -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null && { pkill -9 -f "Ponte.app/Contents/MacOS/Ponte"; sleep 1; }
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  if ! cmp -s "$APP/Contents/MacOS/$APP_NAME" "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"; then
    echo "!! the installed binary is not the one just built — install failed"
    cmp "$APP/Contents/MacOS/$APP_NAME" "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" | head -2
    exit 1
  fi
  echo "    installed and verified identical to the build"
  open "/Applications/$APP_NAME.app"
  echo "    note: this build is signed with a different certificate than the development one, so"
  echo "    macOS may ask for the microphone again."
fi
