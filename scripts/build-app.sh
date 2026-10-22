#!/bin/bash
# Builds VoiceNote.app (release, arm64) and ad-hoc signs it.
#   ./scripts/build-app.sh            → build into ./dist
#   ./scripts/build-app.sh --install  → also copy to /Applications and launch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/VoiceNote.app"

echo "==> swift build (release)"
swift build -c release --arch arm64 2>&1 | tail -5

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceNote "$APP/Contents/MacOS/VoiceNote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Resource bundles (FluidAudio ships CoreML/tokenizer resources) must travel with
# the binary, or the CoreML models fail to load at runtime.
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  echo "    + $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Sign with a *stable* identity. An ad-hoc signature (--sign -) has a designated
# requirement of `cdhash H"…"`, which changes on every rebuild — macOS then cannot
# match the user's existing TCC grants (microphone, accessibility) and re-prompts
# every single build. Signing with a certificate keys the requirement to the cert
# and bundle id instead, so grants survive rebuilds.
SIGN_ID="${VOICENOTE_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$SIGN_ID" ]; then
  echo "==> signing as: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" --identifier com.ponti.voicenote "$APP" >/dev/null 2>&1 \
    || { echo "codesign failed with '$SIGN_ID'"; exit 1; }
else
  echo "!! no code-signing identity found — ad-hoc signing."
  echo "!! TCC grants (microphone, accessibility) will NOT survive rebuilds."
  codesign --force --sign - --identifier com.ponti.voicenote "$APP" >/dev/null 2>&1 \
    || { echo "codesign failed"; exit 1; }
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
echo "    requirement: $(codesign -d -r- "$APP" 2>&1 | grep '^# designated' | sed 's/# designated => //')"

echo "==> built $APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> installing to /Applications"
  # quit a running copy first so the bundle swap is clean
  osascript -e 'tell application "VoiceNote" to quit' >/dev/null 2>&1 || true
  pkill -f "VoiceNote.app/Contents/MacOS/VoiceNote" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/VoiceNote.app"
  cp -R "$APP" "/Applications/VoiceNote.app"
  open "/Applications/VoiceNote.app"
  echo "==> launched /Applications/VoiceNote.app"
fi
