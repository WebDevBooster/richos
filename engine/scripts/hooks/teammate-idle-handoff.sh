#!/usr/bin/env bash
#
# teammate-idle-handoff.sh — TeammateIdle hook. LOG-ONLY; never blocks.
#
# The teammate->lead idle-notification mailbox is lossy. This hook fires
# deterministically on EVERY teammate idle and appends one JSON line to a
# durable session-scoped log the orchestrator reads:
#
#   ~/.claude/teams/session-<first8-of-session-id>/idle-events.jsonl
#   (fallback: ~/.claude/teammate-idle-events.jsonl)
#
# It is one of TWO guaranteed completion signals (the companion
# task-completed-handoff.sh writes task-events.jsonl). Together with
# ground-truth reads (git log on the teammate's branch) they make the mailbox
# non-load-bearing for handoff detection.
#
# Extra (non-blocking) annotation: if the payload's cwd is a git checkout,
# the record carries `uncommitted_changes` (count of dirty paths) — the
# orchestrator can spot idle-with-uncommitted-work from the log without this
# hook ever blocking anyone.
#
# Fail-open everywhere: any parse/IO error exits 0. Env override for tests:
# TEAMMATE_IDLE_TEAMS_DIR.

set -o pipefail

PAYLOAD="$(cat)"

# Cheap, best-effort dirty-count for the teammate's cwd. Computed in bash
# (not python) so the python block below stays dependency-free.
CWD="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("cwd",""))' 2>/dev/null || true)"
UNCOMMITTED=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        UNCOMMITTED="$(git -C "$CWD" status --porcelain 2>/dev/null | grep -c . || true)"
    fi
fi

UNCOMMITTED="$UNCOMMITTED" python3 - "$PAYLOAD" <<'PY'
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

if payload.get("hook_event_name") not in ("", None, "TeammateIdle"):
    finish()

def first(*keys):
    for k in keys:
        v = payload.get(k)
        if v:
            return v
    return ""

session_id = payload.get("session_id") or ""
home = os.path.expanduser("~")
teams_dir = os.environ.get("TEAMMATE_IDLE_TEAMS_DIR") or os.path.join(home, ".claude", "teams")

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
log_path = os.path.join(team_dir, "idle-events.jsonl") if team_dir else os.path.join(home, ".claude", "teammate-idle-events.jsonl")

record = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "TeammateIdle",
    "session_id": session_id,
    # The payload historically carries no teammate name; extract defensively
    # in case the harness adds one under any spelling.
    "teammate": first("teammate_name", "teammateName", "agent_name", "agentName", "name"),
    "agent_id": first("agent_id", "agentId"),
    "transcript_path": payload.get("transcript_path") or "",
    "cwd": payload.get("cwd") or "",
    "decision": "logged",
}

uncommitted = os.environ.get("UNCOMMITTED", "")
if uncommitted != "":
    try:
        record["uncommitted_changes"] = int(uncommitted)
    except ValueError:
        pass

try:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
except Exception:
    pass

finish()
PY
