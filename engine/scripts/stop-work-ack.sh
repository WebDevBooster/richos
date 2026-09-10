#!/usr/bin/env bash
#
# stop-work-ack.sh — WRITE DOWN, BEFORE YOU DESTROY IT, WHAT YOU ARE DESTROYING.
#
# The escape hatch for guard-stop-live-work.sh, and the only one. Run it, then
# make the TaskStop call:
#
#   <engine>/scripts/stop-work-ack.sh \
#       --task <task-id-or-name> \
#       --destroying "<what is lost if this dies now>" \
#       --why "<why it cannot wait for the agent to finish and commit>"
#
# ===========================================================================
# WHY THIS IS A COMMAND AND NOT A MARKER LINE
# ===========================================================================
# Every other ack in this engine rides inside the tool call it excuses:
# `model-ceiling-ack:` in the Agent prompt, `resume-ack:` in the SendMessage
# body, `main-checkout-run:` in the spawn prompt. TaskStop cannot do that.
# Measured 2026-09-10 across all 100 real TaskStop calls on this machine: the
# entire tool_input is {"task_id": "..."} — one key, no free text, 100 of 100.
# And a PreToolUse hook cannot fall back to reading the turn's prose either,
# because the assistant record carrying it is written AFTER the hook returns
# (measured the same day with a live probe session).
#
# So there is nowhere to put a marker. The ack has to exist on disk before the
# call, which makes it a command. That is more friction than a marker line, and
# on this tool alone the extra friction is the correct direction: everything
# else an ack excuses is recoverable, and an unfinished agent's uncommitted
# work is not.
#
# ===========================================================================
# WHAT MAKES IT AN ACK RATHER THAN PAPERWORK
# ===========================================================================
#   ONE TARGET.   It names a single task id. Today's incident killed two
#                 teammates 2.7 seconds apart; a blanket ack would have waved
#                 both through on one sentence.
#   IT EXPIRES.   15 minutes. An ack banked yesterday is not a decision taken
#                 today.
#   IT IS SPENT.  Consumed on first use. One ack, one destruction.
#   IT SAYS SOMETHING. Both fields have a floor. A BARE MARKER EXEMPTS NOTHING.
#
# ===========================================================================
# BEFORE YOU RUN THIS, THE CHEAPER TRUTH
# ===========================================================================
# A subagent cannot be paused. It can only be STOPPED, and stopping it throws
# away everything it has not committed. So when the reason is budget, the
# action that costs nothing is TO STOP DISPATCHING — not to destroy what is
# already running. Work in flight has already been paid for; killing it
# refunds nothing and forfeits the result.
#
# On 2026-09-10 that difference was the whole story. `zach-opus-dor1` lost
# almost nothing because it had committed as it went. `echo-opus-hw2` lost
# everything, because it had not.
#
# Exit codes: 0 written · 2 usage / refused

set -eo pipefail

TAG="(<engine>/scripts/stop-work-ack.sh)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s\n' "$*" >&2; }

usage() {
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

TASK=""; DESTROYING=""; WHY=""; ENTITY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --task|--task-id) TASK="${2:-}"; shift 2 ;;
        --destroying)     DESTROYING="${2:-}"; shift 2 ;;
        --why)            WHY="${2:-}"; shift 2 ;;
        --entity)         ENTITY="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) err "unknown argument: $1  $TAG"; usage; exit 2 ;;
    esac
done

if [ -z "$TASK" ]; then
    err "REFUSED: --task is required. An ack that names no target is not an ack. $TAG"
    exit 2
fi

# The floors. Deliberately stated as sentences rather than counts in the error,
# because the failure this prevents is not "too short" — it is "said nothing".
if [ "${#DESTROYING}" -lt 20 ]; then
    err "REFUSED: --destroying must say what is actually lost if $TASK dies now"
    err "         (uncommitted work? a whole session? nothing, because it has"
    err "          committed as it went?). A bare marker exempts nothing. $TAG"
    exit 2
fi
if [ "${#WHY}" -lt 20 ]; then
    err "REFUSED: --why must say why this cannot wait for the agent to finish"
    err "         and commit. If the reason is budget, the answer is to stop"
    err "         DISPATCHING — a running agent is already paid for. $TAG"
    exit 2
fi

# --- ROOT RESOLUTION -------------------------------------------------------
_RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
if [ -n "$ENTITY" ]; then
    ENTITY_ROOT="$ENTITY"
elif [ -f "$_RR_LIB" ]; then
    # shellcheck source=lib/resolve-roots.sh
    . "$_RR_LIB"
    ENTITY_ROOT="${RICHOS_ENTITY_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
else
    ENTITY_ROOT="${RICHOS_ENTITY_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
fi

if [ ! -d "$ENTITY_ROOT" ]; then
    err "REFUSED: entity root does not exist: $ENTITY_ROOT  $TAG"
    exit 2
fi

STATE_DIR="$ENTITY_ROOT/.claude/state"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/stop-work-acks.jsonl"

command -v python3 >/dev/null 2>&1 || {
    err "REFUSED: python3 is required to write a well-formed ack. $TAG"; exit 2; }

ACK_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:16])')"

TASK="$TASK" DESTROYING="$DESTROYING" WHY="$WHY" ACK_ID="$ACK_ID" \
SESSION_ID="${CLAUDE_SESSION_ID:-}" LOG="$LOG" python3 - <<'PY'
import json, os, time
rec = {
    "id": os.environ["ACK_ID"],
    "task_id": os.environ["TASK"],
    "destroying": os.environ["DESTROYING"],
    "why": os.environ["WHY"],
    "epoch": time.time(),
    "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "session_id": os.environ.get("SESSION_ID") or "",
    "consumed": False,
}
with open(os.environ["LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

cat >&2 <<EOF
stop-work-ack recorded for: $TASK
  destroying: $DESTROYING
  why:        $WHY
  ledger:     $LOG
  valid for:  15 minutes, this target only, spent on first use

Last check before you make the call: a running agent cannot be paused, only
destroyed. If what you actually want is to spend less, stop DISPATCHING.
$TAG
EOF
