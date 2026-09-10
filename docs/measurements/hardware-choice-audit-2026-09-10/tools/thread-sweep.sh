#!/usr/bin/env bash
# Does `-t 4` cost anything on a machine where the decode is NOT Metal-bound?
#
# `stt.rs::decode_args` and `config.js::whisperArgs` both pin `-t 4` with the reason
# "the decode is Metal-bound; 8 threads measured byte-identical at the same wall clock".
# That reason is a property of Apple Silicon, measured on one Apple Silicon machine.
# `-ng` (no GPU) is the honest local proxy for a host with no usable Metal device --
# an Intel Mac, or an Apple Silicon Mac whose Metal backend failed to load.
#
# argv is decode_args(None) verbatim plus -m/-f, with -t swept.
set -uo pipefail

WAV="${1:?usage: thread-sweep.sh <wav>}"
MODEL="${2:-$HOME/Models/Whisper/ggml-small.en.bin}"
BIN=/opt/homebrew/bin/whisper-cli
REPS="${REPS:-3}"

printf 'bin       %s\n' "$BIN"
printf 'bin sha   %s\n' "$(shasum -a 256 "$BIN" | cut -d' ' -f1)"
printf 'model     %s\n' "$MODEL"
printf 'wav       %s (sha256 %s)\n' "$WAV" "$(shasum -a 256 "$WAV" | cut -d' ' -f1)"
printf 'host      %s, %s cores (%sP + %sE), %s B\n' \
  "$(sysctl -n hw.model)" "$(sysctl -n hw.ncpu)" \
  "$(sysctl -n hw.perflevel0.logicalcpu)" "$(sysctl -n hw.perflevel1.logicalcpu)" \
  "$(sysctl -n hw.memsize)"
printf 'reps      %s per cell, MINIMUM reported (a busy machine can only make a sample slower)\n' "$REPS"
printf 'whisper-cli own default for -t is 4 (from --help)\n\n'

run_one() {
  # $1 = threads, $2 = "gpu"|"nogpu"
  local t="$1" mode="$2" extra=() s e
  [ "$mode" = nogpu ] && extra=(-ng)
  s=$(python3 -c 'import time;print(time.monotonic())')
  "$BIN" -m "$MODEL" -f "$WAV" -l en -t "$t" -fa -np -nt -mc 0 "${extra[@]+"${extra[@]}"}" >/dev/null 2>&1
  e=$(python3 -c 'import time;print(time.monotonic())')
  python3 -c "print(f'{$e-$s:.3f}')"
}

for mode in gpu nogpu; do
  printf '== %s ==\n' "$mode"
  printf '%-8s %-10s %s\n' 'threads' 'min_secs' 'samples'
  for t in 1 2 4 6 8 10; do
    samples=()
    for _ in $(seq 1 "$REPS"); do samples+=("$(run_one "$t" "$mode")"); done
    m=$(printf '%s\n' "${samples[@]}" | sort -g | head -1)
    printf '%-8s %-10s %s\n' "$t" "$m" "${samples[*]}"
  done
  printf '\n'
done
