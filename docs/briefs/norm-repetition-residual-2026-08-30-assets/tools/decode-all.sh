#!/bin/bash
# Re-decode the four 92-minute channels at BARE whisper.cpp defaults — byte-for-byte the command
# the 2026-08-29 real-audio measurement used (its tools/run1.sh), so the 72 hand-verified findings
# reproduce. Serialized: one whisper at a time, as that measurement required.
set -euo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33
BIN=/opt/homebrew/bin/whisper-cli
run() {
  local MODEL="$1" CH="$2" TAG="$3"
  local MB="$HOME/Models/Whisper/ggml-${MODEL}.bin"
  local OUT="$SP/results/${TAG}"
  /usr/bin/time -l "$BIN" -m "$MB" -f "$SP/audio/${CH}.wav" -l en -t 4 -otxt -oj -of "$OUT" -np \
    > "$OUT.stdout" 2> "$OUT.time"
  echo "=== $TAG done ==="
}
run large-v3-turbo      me     turbo_me
run large-v3-turbo      others turbo_others
run large-v3-turbo-q5_0 me     q5_me
run large-v3-turbo-q5_0 others q5_others
echo ALLDONE
