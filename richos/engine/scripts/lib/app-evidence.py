#!/usr/bin/env python3
"""Project native hook callbacks into the transcript shape engine guards read.

The app owns the raw conversation ledger. These private files are a disposable
guard-evidence projection, not conversation history or organizational memory.
No callback is inferred from an attempted action. In particular, PreToolUse does
not establish execution and SubagentStop does not establish successful work.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def project(payload, instruction=None):
    """Preserve actual prompt/tool identities and separate worker sidechains."""
    record = {
        "promptId": payload.get("prompt_id"),
        "cwd": payload.get("cwd"),
        "isSidechain": bool(payload.get("agent_id")),
        "agentId": payload.get("agent_id"),
        "evidenceSource": "richos-native-hook-v1",
    }
    event = payload.get("hook_event_name")
    if event == "UserPromptSubmit":
        # Runtime input can also be hidden priming or quoted context. Only the
        # app ledger can attest that a given message is a user instruction.
        record.update(type="user", promptSource="runtime",
                      message={"content": payload.get("prompt", "")})
        if (not payload.get("agent_id") and isinstance(instruction, dict)
                and isinstance(payload.get("prompt"), str)
                and instruction.get("sha256") == hashlib.sha256(payload["prompt"].encode()).hexdigest()
                and str(instruction.get("ledger_ref", "")).startswith("ledger:")):
            record.update(promptSource="sdk", origin={"kind":"human"},
                          ledgerReference=instruction["ledger_ref"],
                          evidenceSource="richos-ledger-attested-hook-v1")
    elif event == "PreToolUse":
        if not payload.get("tool_use_id") or not payload.get("tool_name"):
            raise ValueError("Tool callback has no tool identity")
        record.update(type="assistant", message={"content": [{
            "type": "tool_use", "id": payload["tool_use_id"],
            "name": payload["tool_name"], "input": payload.get("tool_input", {}),
        }]})
    elif event in ("PostToolUse", "PostToolUseFailure"):
        if not payload.get("tool_use_id"):
            raise ValueError("Tool result has no tool identity")
        response = payload.get("tool_response", payload.get("error", ""))
        # Native transcript tool_result content is a string or content blocks,
        # whereas hook tool_response may be an object. Preserve its structure.
        if not isinstance(response, (str, list)):
            response = json.dumps(response, ensure_ascii=False)
        record.update(type="user", message={"content": [{
            "type": "tool_result", "tool_use_id": payload["tool_use_id"],
            "content": response, "is_error": event == "PostToolUseFailure",
        }]})
    else:
        return None
    if not record["promptId"]:
        raise ValueError("Callback has no prompt identity; refusing session-wide evidence")
    return record


def append(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as stream:
        stream.write(json.dumps(value, ensure_ascii=False) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def capture(payload, state_root, instruction=None):
    session = payload.get("session_id", "")
    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", session):
        raise ValueError("Invalid native session identity")
    root = Path(state_root)
    if not root.is_absolute():
        raise ValueError("Evidence root must be explicit and absolute")
    folder = root / session
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    if folder.is_symlink():
        raise ValueError("Session evidence directory cannot be a symlink")
    transcript = folder / "guard-transcript.jsonl"
    lock_fd = os.open(folder / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = project(payload, instruction)
        append(folder / "callbacks.jsonl", {"schema": 1, "callback": payload})
        if record is not None:
            append(transcript, record)
        # SessionStart/Stop may arrive without a tool event. An empty projection
        # is valid; a missing or unwritable projection is an explicit failure.
        fd = os.open(transcript, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    return {**payload, "transcript_path": str(transcript)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        payload = capture(json.load(sys.stdin), args.state_root)
        command = args.command
        if command[:1] == ["--"]:
            command = command[1:]
        if command:
            return subprocess.run(command, input=json.dumps(payload), text=True).returncode
        print(json.dumps(payload))
        return 0
    except (OSError, ValueError) as error:
        print(f"RichOS guard evidence unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
