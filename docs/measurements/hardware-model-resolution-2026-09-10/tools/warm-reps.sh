#!/bin/bash
#
# Steady-state repetition for the two models the LIVE decision turns on.
#
# The three-run sweep beside this includes a cold page cache in run 1, and the live path's
# question is not "what does the first utterance of the day cost" — a conversation is dozens of
# utterances and the CEO judges the pause after every one of them. Eight warm reps is what
# separates "q5_0 is near the ceiling" from "q5_0 is over it", and the answer turned out not to
# be close, which is only knowable by running it.
#
# Usage: tools/warm-reps.sh <wav>
set -uo pipefail

WAV="${1:?usage: warm-reps.sh <wav>}"
BIN="${RICHOS_WHISPER_BIN:-/opt/homebrew/bin/whisper-cli}"
ARGS=(-l en -t 4 -fa -np -nt -mc 0)

echo "argv, identical on every row: $BIN -m <model> -f <wav> ${ARGS[*]}"
echo "8 warm reps, wall seconds"
echo
for id in small.en large-v3-turbo-q5_0; do
  case "$id" in
    small.en) path="$HOME/Models/Whisper/ggml-small.en.bin" ;;
    *) path="$HOME/Models/Whisper/ggml-large-v3-turbo-q5_0.bin" ;;
  esac
  printf '%-22s' "$id"
  times=()
  for _ in 1 2 3 4 5 6 7 8; do
    s=$(python3 -c 'import time;print(time.time())')
    "$BIN" -m "$path" -f "$WAV" "${ARGS[@]}" >/dev/null 2>&1
    e=$(python3 -c 'import time;print(time.time())')
    t=$(python3 -c "print(f'{$e-$s:.3f}')")
    times+=("$t")
    printf ' %s' "$t"
  done
  printf '   median %s\n' "$(python3 -c "
import statistics
print(f'{statistics.median([${times[0]},${times[1]},${times[2]},${times[3]},${times[4]},${times[5]},${times[6]},${times[7]}]):.3f}')")"
done
