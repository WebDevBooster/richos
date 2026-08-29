#!/usr/bin/env bash
#
# worker-ended-handoff.sh — SubagentStop hook. LOG-ONLY; never blocks.
#
# The terminal half of the lifecycle stream. Appends one JSON line per observed
# END OF A WORKER RUN to the same durable stream the creation/start hooks write:
#
#   -> <team dir>/worker-events.jsonl   (fallback: ~/.claude/worker-events.jsonl)
#
# Full stream contract + the per-state observability table:
#   docs/worker-lifecycle-events.md
#
# WHY A TERMINAL EVENT IS THE SAFETY HALF, NOT A NICE-TO-HAVE. A start signal
# without a matching end signal is worse than no start signal: every worker
# that ever ran would read as permanently active, and a consumer showing "3
# working" forever would be confidently wrong instead of honestly silent. This
# hook is what makes an active count derivable AT ALL — active is "started,
# with no later terminal event", and this supplies the "later terminal event".
#
# WHAT IT DELIBERATELY DOES NOT CLAIM — READ THIS BEFORE ADDING A STATE. The
# payload says the run stopped. It does NOT say why. There is no success flag,
# no error field, no interrupted flag anywhere in it. So this event is recorded
# as `run_ended` and NOTHING ELSE:
#
#   * it is NOT "completed" — completion is a distinct, authoritative signal
#     that already has its own log (TaskCompleted -> task-events.jsonl). A
#     worker can stop without completing anything.
#   * it is NOT "failed" — the harness gives no failure classification here.
#     Deriving one from the last assistant message would be text-scraping a
#     guess and presenting it as a state.
#   * it is NOT "interrupted" — a shutdown request is an instruction, not an
#     observation; nothing in this payload distinguishes a worker that was
#     stopped from one that simply finished its turn.
#
# `run_ended` is deliberately outside the seven-state UX vocabulary, because it
# is the honest superset of three of them: "this run is over, and the reason is
# not observable here". A consumer may safely stop rendering the worker as
# working; it must not render a reason it was never told.
#
# NOT NECESSARILY THE LAST RUN. A background teammate that stops can be woken
# again by a later message, producing another start/end pair for the same
# agent_id. So `run_ended` means this RUN ended, never "this worker is gone
# forever". Consumers must treat the stream as a sequence, not a set of flags.
#
# ATTRIBUTION IS REQUIRED, NEVER GUESSED. Written ONLY when the payload carries
# an agent_id — an unattributable end could not be paired with any start, and
# an unpaired end either does nothing or, worse, closes out the wrong worker.
#
# NEVER BLOCKS, ALWAYS EXIT 0. Env override for tests: WORKER_EVENTS_TEAMS_DIR.

set -o pipefail

PAYLOAD="$(cat)"

python3 - "$PAYLOAD" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone


def finish():
    sys.exit(0)


try:
    payload = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else {}
except Exception:
    finish()

if not isinstance(payload, dict):
    finish()

if payload.get("hook_event_name") not in ("", None, "SubagentStop"):
    finish()

agent_id = payload.get("agent_id") or ""
if not isinstance(agent_id, str) or not agent_id:
    finish()

session_id = payload.get("session_id") or ""
home = os.path.expanduser("~")
teams_dir = os.environ.get("WORKER_EVENTS_TEAMS_DIR") or os.path.join(home, ".claude", "teams")


def resolve_team_dir():
    if session_id:
        candidate = os.path.join(teams_dir, "session-%s" % session_id[:8])
        if os.path.isdir(candidate):
            return candidate
    try:
        sessions = [
            os.path.join(teams_dir, name)
            for name in os.listdir(teams_dir)
            if name.startswith("session-") and os.path.isdir(os.path.join(teams_dir, name))
        ]
    except Exception:
        sessions = []
    return sessions[0] if len(sessions) == 1 else None


team_dir = resolve_team_dir()
log_path = (
    os.path.join(team_dir, "worker-events.jsonl")
    if team_dir
    else os.path.join(home, ".claude", "worker-events.jsonl")
)


def s(value, limit=200):
    if value in (None, ""):
        return ""
    return str(value)[:limit]


record = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "WorkerRunEnded",
    # NOT one of the seven UX states, and that is the point — see the header.
    # The run is over; the REASON is not observable from this payload.
    "lifecycle_state": "run_ended",
    "source_hook": "SubagentStop",
    "agent_id": agent_id,
    "agent_type": s(payload.get("agent_type")),
    "session_id": session_id,
    "decision": "logged",
}

# Recorded verbatim because the harness sets it, not because it means
# "completed": stop_hook_active only says a Stop hook is already in flight.
if isinstance(payload.get("stop_hook_active"), bool):
    record["stop_hook_active"] = payload["stop_hook_active"]

# A path, never message content — the consumer can read the transcript itself
# under its own privacy rules. This log stays free of model output.
if payload.get("agent_transcript_path"):
    record["agent_transcript_path"] = s(payload.get("agent_transcript_path"), 512)

host_pid = os.environ.get("CLAUDE_PID", "")
if host_pid.isdigit():
    record["host_pid"] = int(host_pid)

try:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
except Exception:
    pass

finish()
PY
