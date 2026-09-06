#!/usr/bin/env python3
"""Preserve ordinary Bash command failures before output filters can hide them.

PreToolUse changes only the command, preserving all other tool arguments and
permission decisions. No shell parsing, command execution or auto-approval.
Expected failures belong in explicit if/else or || branches. This covers the
calling shell; scripts and explicit failure handling retain their own semantics.
"""
import json
import sys

PREFIX = "set -e -o pipefail\n"


def rewrite(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("tool_name"), str):
        return {"systemMessage": "Shell evidence hook could not read this call (tool identity missing); failure propagation is unverified."}
    if payload["tool_name"] != "Bash":
        return {}
    original = payload.get("tool_input")
    if not isinstance(original, dict) or not isinstance(original.get("command"), str):
        return {"systemMessage": "Shell evidence hook could not read this call (Bash command missing); failure propagation is unverified."}
    command = original["command"]
    if command.startswith(PREFIX):
        return {}
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": dict(original, command=PREFIX + command),
        "additionalContext": "Shell commands use errexit and pipefail: a failed command or pipeline stops this call. "
        "Handle expected nonzero results explicitly with if/else. Keep JSON stdout separate from stderr. "
        "Read saved logs in a separate call; do not turn a failed check into success with a trailing echo or filter."
    }}


if __name__ == "__main__":
    try:
        result = rewrite(json.load(sys.stdin))
    except (ValueError, OSError):
        result = {"systemMessage": "Shell evidence hook could not read this call (invalid payload); failure propagation is unverified."}
    if result:
        print(json.dumps(result))
