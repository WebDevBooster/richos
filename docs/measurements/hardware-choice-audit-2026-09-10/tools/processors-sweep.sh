#!/usr/bin/env bash
# `--processors` (`-p`) is whisper-cli's audio-level parallelism: it splits the input into N
# chunks and decodes them concurrently. NOTHING in this repository ever passes it, so every
# decode on every machine runs at whisper-cli's own default of 1 -- the same shape of
# unexamined vendor default as the `-mc -1` that cost two weeks.
#
# It is the ONE decode flag whose right value scales with the machine, and it only means
# anything on audio long enough to split, which is the batch/call-transcription path
# (`tools/richos-service/lib/`), never the live one-utterance path.
#
# argv is config.js::whisperArgs() verbatim minus -oj (output shape, not decode cost),
# with -p swept.
set -uo pipefail

WAV="${1:?usage: processors-sweep.sh <wav>}"
MODEL="${2:-$HOME/Models/Whisper/ggml-large-v3-turbo-q5_0.bin}"
BIN=/opt/homebrew/bin/whisper-cli
REPS="${REPS:-3}"

printf 'bin       %s\n' "$BIN"
printf 'bin sha   %s\n' "$(shasum -a 256 "$BIN" | cut -d' ' -f1)"
printf 'model     %s  (DEFAULT_TIER `quantized`, config.js:311)\n' "$MODEL"
printf 'wav       %s (sha256 %s)\n' "$WAV" "$(shasum -a 256 "$WAV" | cut -d' ' -f1)"
printf 'host      %s, %s cores (%sP + %sE), %s B\n' \
  "$(sysctl -n hw.model)" "$(sysctl -n hw.ncpu)" \
  "$(sysctl -n hw.perflevel0.logicalcpu)" "$(sysctl -n hw.perflevel1.logicalcpu)" \
  "$(sysctl -n hw.memsize)"
printf 'reps      %s per cell, MINIMUM reported\n' "$REPS"
printf 'whisper-cli own default for -p is 1 (from --help); nothing in this repo ever sets it\n\n'

printf '%-6s %-10s %-14s %s\n' '-p' 'min_secs' 'peak_rss_B' 'samples'
for p in 1 2 4; do
  samples=() peak=0
  for _ in $(seq 1 "$REPS"); do
    s=$(python3 -c 'import time;print(time.monotonic())')
    rss=$( { /usr/bin/time -l "$BIN" -m "$MODEL" -f "$WAV" \
               -l en -t 4 -p "$p" -mc 0 -np -nt -fa >/dev/null; } 2>&1 \
           | awk '/maximum resident set size/ {print $1}' )
    e=$(python3 -c 'import time;print(time.monotonic())')
    samples+=("$(python3 -c "print(f'{$e-$s:.3f}')")")
    [ -n "${rss:-}" ] && [ "$rss" -gt "$peak" ] && peak="$rss"
  done
  m=$(printf '%s\n' "${samples[@]}" | sort -g | head -1)
  printf '%-6s %-10s %-14s %s\n' "$p" "$m" "$peak" "${samples[*]}"
done
