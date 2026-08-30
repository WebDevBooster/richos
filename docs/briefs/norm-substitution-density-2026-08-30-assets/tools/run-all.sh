#!/bin/bash
# Every 92-minute decode this measurement needs, serialized so the wall clocks are comparable.
#   ship  = the SHIPPING configuration, verbatim from lib/config.js#whisperArgs(): -l en -t 4 -mc 0 -oj -np
#           plus -ojf (token offsets; proven to change no decode parameter on this corpus).
#   bare  = -mc -1, whisper.cpp's own carried context — the PRE-2026-08-29 decode, kept as the
#           artifact the substitution collapse actually lives in.
set -uo pipefail
SP="$1"
TURBO="$HOME/Models/Whisper/ggml-large-v3-turbo.bin"
Q5="$HOME/Models/Whisper/ggml-large-v3-turbo-q5_0.bin"
mkdir -p "$SP/results/ship" "$SP/results/bare" "$SP/results/q5bare"
for CH in me others; do
  /usr/bin/time -l whisper-cli -m "$TURBO" -f "$SP/audio/$CH.wav" \
    -l en -t 4 -mc 0 -oj -ojf -np -of "$SP/results/ship/$CH" \
    > "$SP/results/ship/$CH.stdout" 2> "$SP/results/ship/$CH.time"
  echo "ship $CH done"
done
for CH in me others; do
  /usr/bin/time -l whisper-cli -m "$TURBO" -f "$SP/audio/$CH.wav" \
    -l en -t 4 -mc -1 -oj -ojf -np -of "$SP/results/bare/$CH" \
    > "$SP/results/bare/$CH.stdout" 2> "$SP/results/bare/$CH.time"
  echo "bare $CH done"
done
/usr/bin/time -l whisper-cli -m "$Q5" -f "$SP/audio/me.wav" \
  -l en -t 4 -mc -1 -oj -ojf -np -of "$SP/results/q5bare/me" \
  > "$SP/results/q5bare/me.stdout" 2> "$SP/results/q5bare/me.time"
echo "q5bare me done"
echo ALL-DONE
