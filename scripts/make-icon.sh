#!/bin/bash
# Regenerates Resources/AppIcon.icns — every size inside it — with the app's own renderer.
#   ./scripts/make-icon.sh [orb|halftone|ripple|core]
#
# The art is drawn by `Ponte --icon`, the same code that draws the orb in the HUD, so the icon
# cannot drift from the thing it is an icon of. Each size is rendered *at* that size: the
# renderer grows the dots relative to the sphere as the tile shrinks, which is what keeps a
# 240-dot sphere from turning into a grey smudge at 32 px.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources"
MARK="${1:-orb}"
BIN="$ROOT/.build/release/Ponte"

mkdir -p "$OUT"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

for s in 16 32 64 128 256 512; do
  "$BIN" --icon "$ICONSET/icon_${s}x${s}.png" "$MARK" "$s" >/dev/null
  "$BIN" --icon "$ICONSET/icon_${s}x${s}@2x.png" "$MARK" "$((s * 2))" >/dev/null
done
# a 1024 px render *is* icon_512x512@2x
"$BIN" --icon "$ICONSET/icon_512x512@2x.png" "$MARK" 1024 >/dev/null

iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
"$BIN" --icon "$OUT/icon-preview.png" "$MARK" 320 >/dev/null
echo "wrote $OUT/AppIcon.icns ($MARK, 16–1024 px)"
