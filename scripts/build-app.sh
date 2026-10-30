#!/bin/bash
# Builds Ponte.app (release, arm64) and ad-hoc signs it.
#   ./scripts/build-app.sh            → build into ./dist
#   ./scripts/build-app.sh --install  → also copy to /Applications and launch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/Ponte.app"

echo "==> swift build (release)"
swift build -c release --arch arm64 2>&1 | tail -5

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ponte "$APP/Contents/MacOS/Ponte"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# One source of truth for the version. `CFBundleShortVersionString` is the release tag's number; `CFBundleVersion`
# is the commit count, which only ever goes up — an updater compares that integer, and a version that goes backwards
# makes an update look like a downgrade and get refused. Hand-editing the plist is how 0.1.0 shipped under a v1.0.0
# tag, and why this is stamped rather than typed.
# `PONTE_VERSION` and `PONTE_BUILD` exist so a *test* release can be built without touching VERSION or making a
# commit: that is how the updater gets exercised locally, with a newer build to find and install.
SHORT_VERSION="${PONTE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_VERSION="${PONTE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
STAMPED_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAMPED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ "$STAMPED_SHORT" != "$SHORT_VERSION" ] || [ "$STAMPED_BUILD" != "$BUILD_VERSION" ]; then
  echo "!! version stamping failed: wanted $SHORT_VERSION ($BUILD_VERSION), bundle has $STAMPED_SHORT ($STAMPED_BUILD)"
  exit 1
fi
echo "    version $STAMPED_SHORT ($STAMPED_BUILD)"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Resource bundles (FluidAudio ships CoreML/tokenizer resources) must travel with
# the binary, or the CoreML models fail to load at runtime.
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  echo "    + $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Sparkle travels inside the bundle. Everything nested has to be signed from the inside out — its helper apps and
# XPC services first, then the framework, then the app — because signing a bundle that contains unsigned code fails.
# `--deep` would do that in one pass and is deprecated for signing for exactly the reason it looks convenient.
FW_SRC=".build/release/Sparkle.framework"
if [ -d "$FW_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FW_SRC" "$APP/Contents/Frameworks/"
  echo "    + Sparkle.framework"
else
  echo "!! Sparkle.framework missing from .build/out/Products/Release — the updater would not run"
  exit 1
fi
# The binary links @rpath/Sparkle.framework; without this the app fails to launch outside the build directory.
if ! otool -l "$APP/Contents/MacOS/Ponte" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Ponte"
  echo "    + rpath @executable_path/../Frameworks"
fi

# Sign with a *stable* identity. An ad-hoc signature (--sign -) has a designated
# requirement of `cdhash H"…"`, which changes on every rebuild — macOS then cannot
# match the user's existing TCC grants (microphone, accessibility) and re-prompts
# every single build. Signing with a certificate keys the requirement to the cert
# and bundle id instead, so grants survive rebuilds.
# Developer ID first, deliberately. The development and distribution certificates carry different
# designated requirements (the development one adds …100.6.2.12), so alternating between them clears
# every TCC grant Ponte holds each time it flips — and System Settings goes on showing the toggle as
# on. One identity, every build.
SIGN_ID="${PONTE_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$SIGN_ID" ]; then
  echo "==> signing as: $SIGN_ID"
  # Inside out: Sparkle's own helpers, then the framework, then the app that contains them.
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$FW" ]; then
    for item in "$FW"/Versions/B/Autoupdate "$FW"/Versions/B/Updater.app \
                "$FW"/Versions/B/Autoupdate.app "$FW"/Versions/B/Installer.xpc \
                "$FW"/Versions/B/Downloader.xpc; do
      [ -e "$item" ] && codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$item" >/dev/null 2>&1 || true
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$FW" >/dev/null 2>&1 \
      || { echo "!! signing Sparkle.framework failed"; exit 1; }
    echo "    signed Sparkle.framework"
  fi
  codesign --force --sign "$SIGN_ID" --identifier com.ponti.ponte "$APP" >/dev/null 2>&1 \
    || { echo "codesign failed with '$SIGN_ID'"; exit 1; }
else
  echo "!! no code-signing identity found — ad-hoc signing."
  echo "!! TCC grants (microphone, accessibility) will NOT survive rebuilds."
  codesign --force --sign - --identifier com.ponti.ponte "$APP" >/dev/null 2>&1 \
    || { echo "codesign failed"; exit 1; }
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
if ! ./scripts/check-signature.sh "$APP"; then
  echo "!! For a local build that is only a nuisance. Before shipping, sign with the identity you"
  echo "!! always use: PONTE_SIGN_ID=\"Developer ID Application: … (TEAMID)\" ./scripts/build-app.sh"
fi

echo "==> built $APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> installing to /Applications"
  # Quit a running copy first, and *wait* for it. A process cannot have its executable replaced, and `open` on an
  # app that is still running just activates the old instance — which is how a twelve-hour-old build was being
  # tested while every script reported success.
  osascript -e 'tell application "Ponte" to quit' >/dev/null 2>&1 || true
  pkill -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    pgrep -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "Ponte.app/Contents/MacOS/Ponte" >/dev/null 2>&1 || true
  sleep 1

  rm -rf "/Applications/Ponte.app"
  cp -R "$APP" "/Applications/Ponte.app"

  # Verify rather than assume: the installed binary must be byte-identical to the one just built.
  built_sum=$(shasum -a 256 "$APP/Contents/MacOS/Ponte" | awk '{print $1}')
  installed_sum=$(shasum -a 256 "/Applications/Ponte.app/Contents/MacOS/Ponte" | awk '{print $1}')
  if [ "$built_sum" != "$installed_sum" ]; then
    echo "!! the installed binary is not the one just built — install failed"
    echo "   built:     $built_sum"
    echo "   installed: $installed_sum"
    exit 1
  fi
  echo "    installed and verified identical to the build ($(echo "$built_sum" | cut -c1-12))"

  open "/Applications/Ponte.app"
  echo "==> launched /Applications/Ponte.app"
fi
