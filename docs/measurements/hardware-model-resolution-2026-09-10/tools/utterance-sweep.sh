#!/bin/bash
#
# Peak memory and wall clock of ONE conversational utterance, per model, at the LIVE path's
# exact argv.
#
# WHY THIS RIG EXISTS AND THE MODEL-CHOICE RIG DID NOT ANSWER IT. Its sibling
# ../whisper-model-choice-2026-09-10/ measures two models at CALL length and at 92 minutes.
# The live path decodes a 3-second utterance and is judged on the pause after the CEO stops
# talking, so neither of its scopes is this one, and it never measured small.en at all — which
# is the model the live path has hardcoded.
#
# The argv below is `stt.rs::decode_args(None)` copied verbatim, plus the `-m`/`-f` that
# function's caller adds around it. If that function changes, this rig is measuring something
# the product no longer runs; the assertion in hardware.rs is what notices.
#
# Usage: tools/utterance-sweep.sh <wav> <outdir>
set -uo pipefail

WAV="${1:?usage: utterance-sweep.sh <wav> <outdir>}"
OUT="${2:?usage: utterance-sweep.sh <wav> <outdir>}"
BIN="${RICHOS_WHISPER_BIN:-/opt/homebrew/bin/whisper-cli}"
mkdir -p "$OUT/raw"

# stt.rs decode_args(None), verbatim.
ARGS=(-l en -t 4 -fa -np -nt -mc 0)

MODELS=(
  "tiny.en:$HOME/.config/open-wispr/models/ggml-tiny.en.bin"
  "base.en:$HOME/.config/open-wispr/models/ggml-base.en.bin"
  "small.en:$HOME/Models/Whisper/ggml-small.en.bin"
  "large-v3-turbo-q5_0:$HOME/Models/Whisper/ggml-large-v3-turbo-q5_0.bin"
  "large-v3-turbo:$HOME/Models/Whisper/ggml-large-v3-turbo.bin"
)

echo "argv, identical on every row: $BIN -m <model> -f <wav> ${ARGS[*]}"
echo "wav: $WAV  sha256 $(shasum -a 256 "$WAV" | awk '{print $1}')"
echo
printf '%-22s %-4s %14s %9s  %s\n' model run "maxRSS B" "wall s" transcript
for entry in "${MODELS[@]}"; do
  id="${entry%%:*}"
  path="${entry#*:}"
  if [ ! -f "$path" ]; then
    printf '%-22s %-4s %14s %9s  %s\n' "$id" "-" "ABSENT" "-" "$path"
    continue
  fi
  for run in 1 2 3; do
    log="$OUT/raw/$id.$run.time"
    txt="$OUT/raw/$id.$run.txt"
    s=$(python3 -c 'import time;print(time.time())')
    /usr/bin/time -l "$BIN" -m "$path" -f "$WAV" "${ARGS[@]}" >"$txt" 2>"$log"
    e=$(python3 -c 'import time;print(time.time())')
    rss=$(grep 'maximum resident set size' "$log" | awk '{print $1}')
    wall=$(python3 -c "print(f'{$e-$s:.3f}')")
    text=$(tr -d '\n' < "$txt" | sed 's/^ *//;s/  */ /g')
    printf '%-22s %-4s %14s %9s  %s\n' "$id" "$run" "$rss" "$wall" "$text"
  done
done
