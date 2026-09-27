#!/usr/bin/env python3
"""Preserve ordinary Bash command failures before output filters can hide them.

PreToolUse changes only the command, preserving all other tool arguments and
permission decisions. No shell parsing, command execution or auto-approval.
Expected failures belong in explicit if/else or || branches. This covers the
calling shell; scripts and explicit failure handling retain their own semantics.
"""
import json
import os
import sys

PREFIX = "set -e -o pipefail\n"


def ownership(payload):
    """A subagent's call also records who owns it, so a pause can hold it (scripts/lib/agent_hold.py).

    This hook is the only Bash rewriter, so the capture lives here: two rewriting
    hooks would race for the one updated command. Any failure leaves the command
    exactly as it was without capture; the pause then cannot hold this call.
    """
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
        import agent_hold
        return agent_hold.capture(payload)
    except Exception:
        return ""


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
        "updatedInput": dict(original, command=PREFIX + ownership(payload) + command),
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
