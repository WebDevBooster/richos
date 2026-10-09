#!/usr/bin/env bash
# deliver-review-verdict.sh: matcherless PreToolUse. A second-review verdict on a
# running teammate's work reaches that teammate once, at its next tool call, as
# additionalContext (CEO §113; richos-hq plan 2026-10-09 §2.5, slice 3). Never
# blocks: every outcome is exit 0. The logic: scripts/lib/review_delivery.py.
# UNEVALUATED-PAYLOAD-EXEMPT: payload-independent — it never blocks or approves, so a payload it cannot read delivers nothing and the call goes ahead, which is what it should do.
set -uo pipefail
INPUT="$(cat)"
# The lead's own call carries no agent_id: nothing to deliver, no interpreter.
case "$INPUT" in *'"agent_id"'*) ;; *) exit 0 ;; esac
LEDGER="${SECOND_REVIEW_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state}/reviews.jsonl"
[ -f "$LEDGER" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$SCRIPT_DIR/../lib/review_delivery.py" ] || exit 0
printf '%s' "$INPUT" | python3 -B "$SCRIPT_DIR/../lib/review_delivery.py"
exit 0
