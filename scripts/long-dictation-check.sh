#!/bin/bash
# Long-dictation check: builds two kinds of synthetic speech, runs each engine over them, and asserts that
# every run used the engine it asked for.
#
# TWO MATERIALS, because they ask different questions.
#
#   * REPETITION — one sentence repeated N times plus a closing marker. Counting a repeated phrase is what makes
#     a dropped or duplicated region visible, since a truncated transcript reads perfectly plausibly. This is a
#     stress test, not a typical dictation.
#   * PROSE — forty distinct sentences plus a unique closing marker. This is the realistic case, and the only
#     one that can fairly be used to judge an engine, because repetitive audio is a known weakness of Whisper's
#     decoder rather than a property of long audio. A first version of this script had only repetition material
#     and libelled whisper with it: 6 of 24 repetitions, filed as a bug about long takes. On six minutes of
#     prose whisper keeps the whole thing, ending included.
#
# WHY IT CHECKS ENGINE ATTRIBUTION: an earlier table of these timings carried a "parakeet-v3" row that had
# actually run ultra, because `--engine parakeet-v3` fell back to the default in silence. v3 is a *model*,
# chosen with `--parakeet-model v3`. The CLI now refuses unknown flags entirely, and this script checks the
# engine line of every run as well, so a mislabelled row cannot get through twice.
#
# ONE ENGINE: whisper.cpp was removed, along with the `--engine` flag and the model downloader that fetched
# its weights. It needed a separate Homebrew install, which made the Engine menu a support ticket on a machine
# without one. The engine column below stays as a check — it is what caught the mislabelled row.
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

# Forty distinct sentences: varied enough that no decoder can lean on repetition. About eighty seconds of speech.
VARIED=(
  "The harbour at dawn holds a dozen small boats and one very tired dog."
  "She wrote the address on the back of a receipt and put it in her coat."
  "Rain arrived late that afternoon and stayed for the better part of a week."
  "Nobody could explain why the lift stopped on the fourth floor every Tuesday."
  "He kept a list of every book he had abandoned and the page he stopped at."
  "The bakery on the corner sells out of rye bread before nine in the morning."
  "A grey cat watched the pigeons from the wall and did not move for an hour."
  "They painted the kitchen twice because the first colour dried too green."
  "The train was twelve minutes late, which is unusual for that particular line."
  "My grandmother measured everything by eye and was almost never wrong."
  "The office moved to a smaller building and somehow the meetings got longer."
  "A single lamp was left burning in the window of the house on the hill."
  "He learned to fix bicycles because the nearest shop was an hour away."
  "The concert ended early when the power failed during the second movement."
  "Every summer the field behind the school filled with flowers nobody planted."
  "She answered the letter three months later and apologised for the delay."
  "The bridge was closed for repairs, so we took the long road past the lake."
  "There is a shop in the old quarter that still sells nothing but buttons."
  "The dog learned to open the gate and the family learned to fix it."
  "He read the whole manual twice and then ignored most of what it said."
  "A thin layer of frost covered the car and the windscreen took forever."
  "The market opens at six, and by seven the best of the fish is gone."
  "They argued about the colour of the door for a fortnight and chose blue."
  "A small fire in the chimney kept the whole downstairs pleasantly warm."
  "The letter arrived on a Thursday and changed the shape of the whole year."
  "She kept the tickets in a tin, which is why they survived the move."
  "The path through the woods is shorter in winter when the nettles die back."
  "He could name every tree on the street and most of the birds as well."
  "The clock in the hall is five minutes fast and has been for a decade."
  "A neighbour lent us a ladder and never once asked for it back."
  "The recipe calls for butter, but oil works and nobody has complained yet."
  "They planted a hedge along the boundary and argued about its height."
  "The ferry runs twice a day in summer and once a day for the rest of it."
  "She taught herself to swim at forty and now goes every morning."
  "The piano is out of tune in a way that makes one particular chord lovely."
  "A boy on a bicycle delivered the message and waited for an answer."
  "The roof leaked in one place for years until someone finally climbed up."
  "He kept bees for a decade and was stung perhaps four times in total."
  "The library extended its hours and the quiet evening crowd doubled."
  "They found the missing key in the pocket of a coat nobody had worn."
)

mkdir -p "$OUT"

build_text() {
  python3 - "$OUT/$1.source.txt" "$2" "$3" "$SENTENCE" "$CLOSING" "${VARIED[@]}" <<'PY'
import sys
path, kind, reps, sentence, closing = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
varied = sys.argv[6:]
body = sentence * reps if kind == "repetition" else " ".join(varied)
with open(path, "w") as f:
    f.write(body + " " + closing)
PY
}

duration_of() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"; }

speak() {
  say -o "$OUT/$1.aiff" -f "$OUT/$1.source.txt"
  ffmpeg -hide_banner -loglevel error -y -i "$OUT/$1.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/$1.wav"
  rm -f "$OUT/$1.aiff"
}

build_audio() {
  local name="$1" kind="$2" reps="$3" duration words estimate
  # The text is written every time, because it is the spec the rows are judged against — and it is named
  # .source.txt so that nothing the engines write can collide with it. Both parts of that lesson were learned
  # the hard way: a stray prose.wav from a manual experiment got measured against forty sentences it did not
  # contain, and the app's whisper path deleted the source text it found beside the audio.
  build_text "$name" "$kind" "$reps"
  if [ ! -f "$OUT/$name.wav" ]; then
    speak "$name"
  else
    # An audio file that does not match its text is worse than no audio file, so check before trusting it.
    duration=$(duration_of "$OUT/$name.wav")
    words=$(wc -w < "$OUT/$name.source.txt" | tr -d ' ')
    estimate=$(( words * 60 / 165 ))
    if [ "${duration%.*}" -lt $(( estimate * 6 / 10 )) ] || [ "${duration%.*}" -gt $(( estimate * 17 / 10 )) ]; then
      echo "  $name: audio is ${duration%.*}s but the text is $words words (~${estimate}s) — rebuilding" >&2
      speak "$name"
    fi
  fi
  duration=$(duration_of "$OUT/$name.wav")
  printf "%s" "${duration%.*}"
}

# $1 label, $2 audio, $3 expected repetitions or the word "words", $4 expect-engine-substring, then engine flags
check() {
  local label="$1" audio="$2" expected="$3" expect="$4"; shift 4
  local seconds duration ran rss kept marker verdict source_words out="$OUT/out-$label.txt"
  [ -f "$OUT/$audio.source.txt" ] || { echo "  $label: missing $audio.source.txt — delete $OUT/$audio.wav so it rebuilds"; return 1; }
  { /usr/bin/time -l "$BIN" --transcribe "$OUT/$audio.wav" "$@" > "$out" ; } 2> "$OUT/err-$label.txt"
  seconds=$(grep -E "^ *[0-9.]+ real" "$OUT/err-$label.txt" | awk '{print $1}')
  rss=$(grep "maximum resident" "$OUT/err-$label.txt" | awk '{printf "%.0f MB", $1/1048576}')
  duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT/$audio.wav")
  ran=$(grep -oE "engine=[^)]*" "$OUT/err-$label.txt" | tail -1 | cut -d= -f2-)
  verdict="PASS"
  if [ "$expected" = "words" ]; then
    kept=$(wc -w < "$out" | tr -d ' ')
    source_words=$(wc -w < "$OUT/$audio.source.txt" | tr -d ' ')
    [ "$kept" -ge $(( source_words * 3 / 4 )) ] || verdict="FAIL: only $kept words of ~$source_words"
    [ "$kept" -le $(( source_words * 3 / 2 )) ] || verdict="FAIL: $kept words from ~$source_words (duplicated?)"
    expected="${source_words}w"
  else
    kept=$(grep -o fox "$out" | wc -l | tr -d ' ')
    [ "$kept" -eq "$expected" ] || verdict="FAIL: $kept of $expected repetitions"
  fi
  marker=$(grep -c "final sentence" "$out" || true)
  [ "$marker" -gt 0 ] || verdict="FAIL: closing marker missing"
  case "$ran" in *"$expect"*) ;; *) verdict="FAIL: asked for $expect, ran $ran" ;; esac
  printf "%-15s %-30s %5ss %7ss %9s %-5s %-9s %s\n" \
    "$label" "$ran" "${duration%.*}" "$seconds" "$kept/$expected" \
    "$([ "$marker" -gt 0 ] && echo yes || echo NO)" "$rss" "$verdict"
}

echo "building audio in $OUT (reused if present)"
for row in "${LENGTHS[@]}"; do
  name="${row%% *}"; reps="${row##* }"
  printf "  repetition %-5s %ss\n" "$name" "$(build_audio "$name" repetition "$reps")"
done
printf "  prose      %-5s %ss\n" "prose" "$(build_audio prose prose 0)"

echo
echo "REPETITION material: a stress test for losing text at a seam, not a typical dictation."
printf "%-15s %-30s %6s %8s %10s %-5s %-9s %s\n" "run" "engine" "audio" "time" "kept" "tail" "peak RSS" "verdict"
check "ultra-20s" "20s" 6 ultra --parakeet-model ultra
check "ultra-76s" "76s" 24 ultra --parakeet-model ultra
check "ultra-6min" "6min" 120 ultra --parakeet-model ultra
check "v3-76s" "76s" 24 v3 --parakeet-model v3

echo
echo "PROSE material: forty distinct sentences, judged by word count. This is the case that resembles use."
printf "%-15s %-30s %6s %8s %10s %-5s %-9s %s\n" "run" "engine" "audio" "time" "words" "tail" "peak RSS" "verdict"
check "ultra-prose" "prose" words ultra --parakeet-model ultra

echo
echo "Read the repetition rows for text going missing at a seam, and the prose row for whether a long take is"
echo "transcribed whole. Both materials are kept even though there is now one engine: they measure different"
echo "failure modes, and a future engine — or a model swap — should be judged on both."
