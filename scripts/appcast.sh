#!/bin/bash
# Builds appcast.xml — the file the app's updater reads — from the built app.
#
# The DMG is for first downloads; the updater installs from a zip of the app bundle. Each archive is signed with the
# EdDSA key Sparkle keeps in the login keychain, and the appcast carries those signatures, so a feed that is
# tampered with cannot deliver an app that will be installed.
#
#   ./scripts/appcast.sh                     → writes ./appcast.xml (served by Pages from the repo root)
#   DOWNLOAD_PREFIX=https://… ./scripts/appcast.sh
#
# Run it after `make-dmg.sh --notarize`, and attach the zip it makes beside the DMG on the release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${PONTE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${PONTE_BUILD:-$(git rev-list --count HEAD)}"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-https://github.com/charlesponti/ponte/releases/download/v$VERSION/}"
TOOLS="${SPARKLE_TOOLS:-$HOME/.cache/ponte/sparkle-tools}"

if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  echo "==> fetching Sparkle tools (2.10.0) into $TOOLS"
  mkdir -p "$TOOLS"
  curl -sL --fail --max-time 120 -o "$TOOLS/tools.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz"
  tar -xf "$TOOLS/tools.tar.xz" -C "$TOOLS"
  rm -f "$TOOLS/tools.tar.xz"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

APP="dist/Ponte.app"
[ -d "$APP" ] || { echo "!! no $APP — run ./scripts/build-app.sh first"; exit 1; }
ZIP="$STAGE/Ponte-$VERSION.zip"
echo "==> packing $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
"$TOOLS/bin/sign_update" "$ZIP" > "$STAGE/signature.txt"
echo "    signed: $(cat "$STAGE/signature.txt" | head -1)"

echo "==> writing appcast for $VERSION ($BUILD)"
"$TOOLS/bin/generate_appcast" "$STAGE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://charlesponti.github.io/ponte/" \
  --embed-release-notes 2>/dev/null || \
  "$TOOLS/bin/generate_appcast" "$STAGE" --download-url-prefix "$DOWNLOAD_PREFIX"

cp "$STAGE/appcast.xml" "$ROOT/appcast.xml"
cp "$ZIP" "$ROOT/dist/Ponte-$VERSION.zip"
echo "==> wrote appcast.xml and dist/Ponte-$VERSION.zip"
echo "    attach dist/Ponte-$VERSION.zip to the release, commit appcast.xml"
