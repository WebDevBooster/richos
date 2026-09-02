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

# --- ownership ledger: an ADVISORY per-agent finish signal -------------------
# Retained in ~/.claude/state/worktree-ledger.jsonl (scripts/lib/
# worktree-ledger.py) against the agent id and the worktree path the payload
# carries. It is per-agent where the harness lock is per-session, which is
# why it is kept — and it is NOT a termination: an idle teammate can be
# resumed, a completed task is task-grain, and SubagentStop fires every turn.
# The reaper prints these beside its verdict and never decides on them.
# Best-effort; this hook's exit code is unchanged whatever happens here.
_LEDGER_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/worktree-ledger.py"
if [ -f "$_LEDGER_PY" ] && command -v python3 >/dev/null 2>&1; then
  PAYLOAD="$PAYLOAD" LEDGER_PY="$_LEDGER_PY" SIGNAL="TaskCompleted" python3 - <<'PY' 2>/dev/null || true
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("wl", os.environ["LEDGER_PY"])
wl = importlib.util.module_from_spec(spec); spec.loader.exec_module(wl)
try:
    d = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    d = {}
if not isinstance(d, dict) or d.get("hook_event_name") not in ("", None, os.environ["SIGNAL"]):
    raise SystemExit(0)
def first(*keys):
    for k in keys:
        v = d.get(k)
        if v not in (None, ""):
            return str(v)
    return ""
cwd = first("cwd")
agent_id = first("agent_id", "agentId")
if not agent_id and cwd:
    b = os.path.basename(cwd.rstrip("/"))
    if b.startswith("agent-"):
        agent_id = b[len("agent-"):]
rec = {"event": "finished", "signal": os.environ["SIGNAL"], "agent_id": agent_id,
       "teammate": first("teammate_name", "teammateName", "agent_name", "agentName", "name"),
       "session_id": first("session_id"), "worktree": cwd, "task_id": first("task_id", "taskId", "id"),
       "source": "task-completed-handoff.sh"}
if agent_id or cwd or rec["teammate"] or rec["task_id"]:
    wl.append(rec)
PY
fi

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
