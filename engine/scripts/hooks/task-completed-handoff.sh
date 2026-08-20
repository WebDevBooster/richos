#!/usr/bin/env bash
#
# task-completed-handoff.sh — TaskCompleted hook. LOG-ONLY; never blocks.
#
# Appends one JSON line per task completion to the session team directory
# (task-events.jsonl) — durable coordination state for the orchestrator, one
# of the two guaranteed completion signals in the durable-handoff model
# (companion: teammate-idle-handoff.sh -> idle-events.jsonl). A completed task
# is pruned from the queryable task store, so this append-only log + the commit
# are the durable completion record.
#
# Fail-open everywhere: any parse/IO error exits 0. Env override for tests:
# TASK_COMPLETED_TEAMS_DIR.

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

if payload.get("hook_event_name") not in ("", None, "TaskCompleted"):
    finish()

session_id = payload.get("session_id") or ""
home = os.path.expanduser("~")
teams_dir = os.environ.get("TASK_COMPLETED_TEAMS_DIR") or os.path.join(home, ".claude", "teams")

def resolve_team_dir():
    team_name = payload.get("team_name") or ""
    if isinstance(team_name, str) and team_name.startswith("session-"):
        candidate = os.path.join(teams_dir, team_name)
        if os.path.isdir(candidate):
            return candidate
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

def first(*keys):
    for key in keys:
        value = payload.get(key)
        if value not in (None, ""):
            return value
    return ""

team_dir = resolve_team_dir()
log_path = os.path.join(team_dir, "task-events.jsonl") if team_dir else os.path.join(home, ".claude", "teammate-task-events.jsonl")

record = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "TaskCompleted",
    "task_id": first("task_id", "taskId", "id"),
    "task_subject": first("task_subject", "task_title", "subject", "title"),
    "teammate": first("teammate_name", "agent_type", "agentType", "owner", "agent_id", "agentId"),
    "session_id": session_id,
    "decision": "logged"
}

try:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
except Exception:
    pass

finish()
PY
