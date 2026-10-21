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

# Stable ad-hoc signature so macOS remembers the microphone grant between builds.
codesign --force --sign - --identifier com.ponti.voicenote "$APP" >/dev/null 2>&1 \
  || { echo "codesign failed"; exit 1; }
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

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
