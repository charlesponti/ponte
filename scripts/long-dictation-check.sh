#!/bin/bash
# Long-dictation check: builds synthetic speech carrying a countable pattern, runs each engine over it, and
# asserts that every run used the engine it asked for.
#
# Why a pattern rather than a nice paragraph: the failure worth catching is text vanishing at a seam.
# Whisper on a 76-second file returned the first ~19 seconds and *then* the closing sentence, dropping
# everything between — 6 of 24 repetitions, 315 characters against Parakeet's 1125. A transcript that reads
# plausibly does not reveal that; counting a repeated phrase does.
#
# Why it checks the engine attribution: an earlier table of these timings carried a "parakeet-v3" row that had
# actually run ultra, because `--engine parakeet-v3` fell back to the default in silence. v3 is a *model*,
# chosen with `--parakeet-model v3`. The CLI now refuses unknown values, and this script checks the engine
# line of every run as well, so a mislabelled row cannot get through twice.
#
#   ./scripts/long-dictation-check.sh [work-dir]
#
# Reuses audio already present in the work directory, so a re-run is quick.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/ponte-long}"
BIN="$ROOT/.build/release/Ponte"
[ -x "$BIN" ] || { echo "build it first: swift build -c release"; exit 1; }

SENTENCE="The quick brown fox jumps over the lazy dog. "
CLOSING="This is the final sentence of the recording."
# Roughly 20 s, 76 s and 6 minutes of speech.
LENGTHS=("20s 6" "76s 24" "6min 120")

mkdir -p "$OUT"

build_audio() {
  local name="$1" reps="$2" text="$OUT/$name.txt"
  if [ ! -f "$OUT/$name.wav" ]; then
    python3 - "$text" "$reps" "$SENTENCE" "$CLOSING" <<'PY'
import sys
path, reps, sentence, closing = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
open(path, "w").write(sentence * reps + closing)
PY
    say -o "$OUT/$name.aiff" -f "$text"
    ffmpeg -hide_banner -loglevel error -y -i "$OUT/$name.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/$name.wav"
    rm -f "$OUT/$name.aiff"
  fi
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$name.wav"
}

# $1 label, $2 audio, $3 reps, $4 expect-engine-substring, then the engine flags
check() {
  local label="$1" audio="$2" reps="$3" expect="$4"; shift 4
  local seconds duration chars kept marker ran rss verdict
  { /usr/bin/time -l "$BIN" --transcribe "$OUT/$audio.wav" "$@" > "$OUT/out-$label.txt" ; } 2> "$OUT/err-$label.txt"
  seconds=$(grep -E "^ *[0-9.]+ real" "$OUT/err-$label.txt" | awk '{print $1}')
  rss=$(grep "maximum resident" "$OUT/err-$label.txt" | awk '{printf "%.0f MB", $1/1048576}')
  duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$audio.wav")
  ran=$(grep -oE "engine=[^)]*" "$OUT/err-$label.txt" | tail -1 | cut -d= -f2-)
  chars=$(wc -c < "$OUT/out-$label.txt" | tr -d ' ')
  kept=$(grep -o fox "$OUT/out-$label.txt" | wc -l | tr -d ' ')
  marker=$(grep -c "final sentence" "$OUT/out-$label.txt" || true)
  verdict="PASS"
  [ "$kept" -eq "$reps" ] || verdict="FAIL: $kept of $reps repetitions"
  [ "$marker" -gt 0 ] || verdict="FAIL: closing marker missing"
  case "$ran" in *"$expect"*) ;; *) verdict="FAIL: asked for $expect, ran $ran" ;; esac
  printf "%-18s %-18s %6.0fs %8ss %6s %-5s %-9s %s\n" \
    "$label" "$ran" "${duration%.*}" "$seconds" "$kept/$reps" \
    "$([ "$marker" -gt 0 ] && echo yes || echo NO)" "$rss" "$verdict"
}

echo "building audio in $OUT (reused if present)"
for row in "${LENGTHS[@]}"; do
  name="${row%% *}"
  reps="${row##* }"
  duration="$(build_audio "$name" "$reps")"
  printf "  %-6s %ss\n" "$name" "${duration%.*}"
done

echo
printf "%-18s %-18s %8s %9s %6s %-5s %-9s %s\n" \
  "run" "engine" "audio" "time" "reps" "tail" "peak RSS" "verdict"
check "ultra-20s" "20s" 6 ultra --engine parakeet --parakeet-model ultra
check "ultra-76s" "76s" 24 ultra --engine parakeet --parakeet-model ultra
check "ultra-6min" "6min" 120 ultra --engine parakeet --parakeet-model ultra
check "v3-76s" "76s" 24 v3 --engine parakeet --parakeet-model v3
check "whisper-76s" "76s" 24 whisper --engine whisper
