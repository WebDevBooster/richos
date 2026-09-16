#!/usr/bin/env python3
"""Single desktop hook registration; canonical components retain their decisions.

The host supplies all roots and the active scope. There is no terminal-settings
fallback. Provider callbacks are evidence, not proof of assignment completion.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ENGINE = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(command, payload):
    result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True, timeout=20)
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    if result.returncode:
        raise RuntimeError(f"Required engine control failed or refused (exit {result.returncode})")


def scope():
    path = Path(os.environ["RICHOS_APP_SCOPE"])
    if not path.is_absolute() or path.stat().st_size > 16384:
        raise ValueError("invalid desktop action scope")
    value = json.loads(path.read_text())
    if value.get("version") != 1:
        raise ValueError("unsupported desktop action scope")
    return value


def handle(payload):
    root = Path(os.environ["RICHOS_APP_STATE"])
    coordination = Path(os.environ["RICHOS_ENTITY_ROOT"])
    if not root.is_absolute() or not coordination.is_absolute():
        raise ValueError("desktop roots must be explicit and absolute")
    event = payload.get("hook_event_name")
    if event == "PreToolUse":
        active = scope()
        if active.get("actions_allowed") is not True:
            raise ValueError("This app turn is stopped or is supplying context. New actions are unavailable.")
    evidence = load("richos_app_evidence", ENGINE / "scripts/lib/app-evidence.py")
    instruction = None
    if event == "UserPromptSubmit":
        active = scope()
        if active.get("actions_allowed") is True and active.get("binding", {}).get("session_id") == payload.get("session_id"):
            instruction = active.get("user_instruction")
    payload = evidence.capture(payload, root / "evidence", instruction)
    ws = [sys.executable, str(ENGINE / "mega-lander/workspaces.py"), "--entity", str(coordination)]
    work = load("richos_desktop_work", ENGINE / "mega-lander/app.py")
    if event == "PreToolUse":
        run(["/bin/bash", str(ENGINE / "scripts/hooks/guard-sealed-worktree.sh")], payload)
        work.validate_shell_target(payload)
        context = work.worker_context(active, payload)
        if context: print(json.dumps(context))
    if event == "PreToolUse" and payload.get("tool_name") == "Agent":
        work.dispatch_intent(active, payload)
        # Both decisions come from the existing canonical implementation.
        run(["/bin/bash", str(ENGINE / "scripts/hooks/guard-worktree-isolation.sh")], payload)
        run(["/bin/bash", str(ENGINE / "scripts/hooks/guard-brief-scope.sh")], payload)
    if event in ("SessionStart", "SubagentStart", "SubagentStop", "PostToolUse", "SessionEnd"):
        run(ws + ["hook"], payload)
    if event == "PostToolUse" and payload.get("tool_name") == "Agent":
        run(["/bin/bash", str(ENGINE / "scripts/hooks/detect-nonnative-worktree.sh")], payload)
    if event in ("SubagentStart", "SubagentStop", "PostToolUse", "PostToolUseFailure"):
        work.observe(scope(), payload)
    if event == "Stop":
        # Context-only priming is host machinery, not a new assignment or promise.
        # The same host grant controls mutation tools and the visible-turn analyzer.
        active = scope()
        if active.get("actions_allowed") is True:
            run([sys.executable, str(ENGINE / "ass-kicker/guard-stated-actions.py")], payload)


if __name__ == "__main__":
    try:
        handle(json.load(sys.stdin))
    except Exception as error:
        print(f"RichOS desktop engine: {error}", file=sys.stderr)
        raise SystemExit(2)
