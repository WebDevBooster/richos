"""Operator-owned CI pauses, shared by reports and gates.

The registry lives outside plugin installations so an update cannot undo a
pause. A pause is scoped to an exact GitHub repository and is never a green
test result. Remove the entry only on an explicit operator instruction.
"""

import json
import os
import re
import subprocess
import sys


def registry_path():
    return os.environ.get("CI_PAUSE_CONFIG", os.path.expanduser("~/.claude/state/ci-pauses.json"))


def registry():
    try:
        with open(registry_path(), encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError:
        return {}
    if not isinstance(data, dict) or not isinstance(data.get("repositories"), dict):
        raise ValueError("Invalid CI pause registry: " + registry_path())
    return data["repositories"]


def slug_for(repository):
    value = os.fspath(repository).strip()
    if os.path.isdir(value):
        try:
            result = subprocess.run(
                ["git", "-C", value, "config", "--get", "remote.origin.url"],
                capture_output=True, text=True, timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired):
            return ""
        if result.returncode:
            return ""
        value = result.stdout.strip()
    match = re.fullmatch(
        r"(?:(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:))?"
        r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?", value,
    )
    return match.group(1).lower() if match else ""


def pause_for(repository):
    records = registry()
    if not records:
        return None
    slug = slug_for(repository)
    for key, record in records.items():
        if key.lower() == slug and isinstance(record, dict) and record.get("paused") is True:
            return dict(record, repo=key)
    return None


def paused_verdict(repository, branch="main"):
    pause = pause_for(repository)
    if not pause:
        return None
    return {"repo": pause["repo"], "branch": branch, "state": "paused",
            "reason": pause["reason"], "source": "operator-pause",
            "read_at": pause.get("since"), "workflows_seen": 0, "red": []}


def session_context():
    lines = []
    for slug, record in registry().items():
        if isinstance(record, dict) and record.get("paused") is True:
            lines.append(
                "CI PAUSED by the operator for %s: %s Do not resume prior CI repair "
                "assignments. Continue product work with targeted local verification."
                % (slug, record["reason"])
            )
    if lines:
        return {"hookSpecificOutput": {"hookEventName": "SessionStart",
                                       "additionalContext": "\n".join(lines)}}
    return None


if __name__ == "__main__":
    if sys.argv[1:] != ["--session-context"]:
        raise SystemExit("usage: ci_pause.py --session-context")
    context = session_context()
    if context:
        print(json.dumps(context))
