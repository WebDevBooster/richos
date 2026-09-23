#!/usr/bin/env python3
"""Exit 0 only when the lead cannot act and a Stop guard must stand down.

The workspace gate owns the once-per-session explanation. Other Stop guards
must not demand commands which the tool barrier refuses. Worker events never
inherit the lead exemption. No user prose or acknowledgement marker is read.
"""
import importlib.util
import json
from pathlib import Path
import sys


def recovery(payload):
    if not isinstance(payload, dict) or payload.get("agent_id"):
        return False
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not sid:
        return False
    path = Path(__file__).resolve().parents[2] / "mega-lander/workspaces.py"
    spec = importlib.util.spec_from_file_location("recovery_workspaces", path)
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)
    rec = ws.load_session(sid)
    return bool(rec and ws.forbidden_now(sid, rec))


if __name__ == "__main__":
    try:
        allowed = recovery(json.load(sys.stdin))
    except (OSError, ValueError, TypeError, ImportError):
        allowed = False
    sys.exit(0 if allowed else 1)
