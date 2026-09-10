#!/bin/bash
# The DICTATION path's own question: on one short utterance, through small.en, what do -mc and
# --prompt actually do? Three runs each, text and wall clock.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/899d5bee-2ef7-4c2b-8478-3cde1a1aecdf/scratchpad
W=/opt/homebrew/bin/whisper-cli
M=/Users/alex/Models/Whisper/ggml-small.en.bin
SRC=$SP/corpus/2026-08-29T09-00-00Z--meet--call-01-halden-scheduling/me.wav
UTT=$SP/utt.wav
ffmpeg -y -v error -i "$SRC" -ss 0 -t 6 -ac 1 -ar 16000 "$UTT"
PROMPT="Priya Sandoval, Halden Freight, Marla Kestrel, Corvane Systems, Everlock, Ridgeline Analytics, Quilvern Media, Tobias Renner, Nadia Kwok, Brightmoor Dental, Wexford Road, Cannery Street, Tidemark, Northgate, Pallas."
run() {
  local label="$1"; shift
  for i in 1 2 3; do
    local t0=$(python3 -c 'import time;print(int(time.time()*1000))')
    local out
    out=$("$W" -m "$M" -f "$UTT" -l en -t 4 -np -nt "$@" 2>/dev/null | tr -s ' \n' ' ')
    local t1=$(python3 -c 'import time;print(int(time.time()*1000))')
    printf '%-26s run%d  %5d ms  %s\n' "$label" "$i" "$((t1 - t0))" "$out"
  done
}
run "vendor default (-mc -1)"
run "-mc 0" -mc 0
run "-mc 0 + prompt" -mc 0 --prompt "$PROMPT"
run "-mc 64 + prompt" -mc 64 --prompt "$PROMPT"
run "-mc -1 + prompt" --prompt "$PROMPT"
