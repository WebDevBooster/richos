#!/bin/bash
# The same four channels at the SHIPPED decode args (MAX_CONTEXT_TOKENS = 0) — the world the guard
# actually lives in, so the change's cost can be priced there and not only in the retired -mc -1 one.
set -euo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33
BIN=/opt/homebrew/bin/whisper-cli
run() {
  local MODEL="$1" CH="$2" TAG="$3"
  local MB="$HOME/Models/Whisper/ggml-${MODEL}.bin"
  local OUT="$SP/results/${TAG}"
  /usr/bin/time -l "$BIN" -m "$MB" -f "$SP/audio/${CH}.wav" -l en -t 4 -mc 0 -oj -np -of "$OUT" \
    > "$OUT.stdout" 2> "$OUT.time"
  echo "=== $TAG done ==="
}
run large-v3-turbo      me     turbo_me_mc0
run large-v3-turbo      others turbo_others_mc0
run large-v3-turbo-q5_0 me     q5_me_mc0
run large-v3-turbo-q5_0 others q5_others_mc0
echo MC0DONE
