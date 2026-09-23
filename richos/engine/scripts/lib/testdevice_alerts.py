"""Persist collector failures even when the collector itself cannot import."""
import json
import os
import tempfile
import time


def record_failure(message, command="Restore the test-device collector and rerun scratch-reaper.sh --apply"):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.environ.get("TEST_DEVICE_FAILURES_STATE") or os.path.join(base, "state/test-device-failures.json")
    try:
        with open(path) as handle:
            rows = json.load(handle)
        if not isinstance(rows, dict):
            raise ValueError("failure state is not an object")
    except FileNotFoundError:
        rows = {}
    except (OSError, ValueError) as exc:
        rows = {}
        message = "%s; previous failure state unreadable: %s" % (message, exc)
    key = "collector:incomplete"
    previous = rows.get(key) or {}
    if not isinstance(previous, dict):
        previous = {}
    try:
        attempts = int(previous.get("attempts", 0)) + 1
    except (TypeError, ValueError):
        attempts = 1
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    rows[key] = {"kind": "collector", "id": "incomplete", "name": "test-device collector",
                 "verdict": "collection incomplete", "why": str(message), "command": command,
                 "first": previous.get("first", stamp), "last": stamp,
                 "attempts": attempts}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".device-alert-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(rows, handle, indent=1, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return rows
