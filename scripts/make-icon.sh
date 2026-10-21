#!/bin/bash
# Regenerates Resources/AppIcon.icns from scratch with ImageMagick.
# Explicit intermediate files keep ImageMagick's composite order unambiguous.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources"
mkdir -p "$OUT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

S=1024

# 1. gradient background
magick -size ${S}x${S} "gradient:#4f6bff-#a855f7" "$TMP/bg.png"

# 2. rounded-square mask (≈ macOS corner radius)
magick -size ${S}x${S} xc:none -fill white \
  -draw "roundrectangle 0,0 $((S-1)),$((S-1)) 232,232" "$TMP/mask.png"

# 3. background clipped to the mask
magick "$TMP/bg.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/base.png"

# 4. white microphone glyph on transparency:
#    capsule body, cradle arc hugging its lower half, stem, foot
magick -size ${S}x${S} xc:none \
  -fill white -stroke none \
  -draw "roundrectangle 438,190 586,550 74,74" \
  -fill none -stroke white -strokewidth 50 \
  -draw "arc 344,352 680,688 180,360" \
  -draw "line 512,688 512,790" \
  -draw "line 404,790 620,790" \
  "$TMP/mic.png"

# 5. glyph over background
magick "$TMP/base.png" "$TMP/mic.png" -composite "$TMP/icon-${S}.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$TMP/icon-${S}.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon-${S}.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$TMP/icon-${S}.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
magick "$TMP/icon-${S}.png" -resize 320x320 "$OUT/icon-preview.png"
echo "wrote $OUT/AppIcon.icns"
