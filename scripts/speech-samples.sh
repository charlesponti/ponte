#!/bin/bash
#
# Speech to test the live transcript with, in the shape Ponte records: 16 kHz mono 16-bit WAV.
#
# The words are the Harvard sentences — a public-domain list built for exactly this, intelligible, phonetically
# varied, and dull enough that nobody has to invent something to say. Synthesised by `say` at 170 words a minute,
# which is ordinary dictation pace.
#
#   ./scripts/speech-samples.sh [out-dir]        # default /tmp/ponte-speech
#
# Then, with a release build:
#   .build/release/Ponte --live-file /tmp/ponte-speech/speech-90s.wav
#
set -eu

OUT="${1:-/tmp/ponte-speech}"
mkdir -p "$OUT"

# Harvard sentences, public domain (IEEE recommended practice for speech quality measurements).
read -r -d '' SENTENCES <<'TEXT' || true
The birch canoe slid on the smooth planks.
Glue the sheet to the dark blue background.
It's easy to tell the depth of a well.
These days a chicken leg is a rare dish.
Rice is often served in round bowls.
The juice of lemons makes fine punch.
The box was thrown beside the parked truck.
The hogs were fed chopped corn and garbage.
Four hours of steady work faced us.
A large size in stockings is hard to sell.
The boy was there when the sun rose.
A rod is used to catch pink salmon.
The source of the huge river is the clear spring.
Kick the ball straight and follow through.
Help the woman get back to her feet.
A pot of tea helps to pass the evening.
Smoky fires lack flame and heat.
The soft cushion broke the man's fall.
The salt breeze came across from the sea.
The girl at the booth sold fifty bonds.
TEXT

rate=170
# One long read, then cut the three lengths out of it: the files then hear identical words, which makes them
# comparable. `say` writes AIFF; Ponte records WAV, so convert to the same shape.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '%s\n' "$SENTENCES" > "$tmp/text.txt"
# Repeat the list until it is comfortably longer than 90 s at this rate.
{ for _ in 1 2 3 4; do cat "$tmp/text.txt"; done; } > "$tmp/long.txt"

echo "speaking $(wc -w < "$tmp/long.txt") words at $rate wpm…"
say -v "${VOICE:-Daniel}" -r "$rate" -f "$tmp/long.txt" -o "$tmp/long.aiff"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/long.aiff" "$tmp/long.wav"

for seconds in 10 30 90; do
  out="$OUT/speech-${seconds}s.wav"
  # Take the first N seconds of the same recording, so the three files hear identical words.
  ffmpeg -v error -y -i "$tmp/long.wav" -t "$seconds" -ar 16000 -ac 1 -c:a pcm_s16le "$out"
  printf '  %s  %.1fs  %s KB\n' "$out" \
    "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")" \
    "$(( $(stat -f%z "$out") / 1024 ))"
done
