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


def a_worker_this_lease_already_dispatched(active, payload):
    """Is this tool call a BACKGROUND WORKER's, under a standing grant that survives the
    turn that dispatched it?

    **THE DEFECT THIS ANSWERS, measured on 2026-09-18 and quoted from the worker's own last
    words** (`engine-state/evidence/<session>/callbacks.jsonl`, row 21 of a
    `work_lease_roundtrip` run): *"Unable to complete or report via tools - the host's
    PreToolUse hook is blocking all tool actions this turn, including SubagentHandback
    itself, with: 'RichOS desktop engine: This app turn is stopped or is supplying context.
    New actions are unavailable.'"*

    `actions_allowed` is the TURN's grant, opened and closed by `NativeCognition::prompt`.
    A background worker outlives the turn that dispatched it BY DESIGN — `mega-lander/app.py`
    stamps `run_in_background: true` on every payload, the provider answers
    `{"status":"async_launched"}`, and the turn ends with the worker just getting started.
    So the worker did all of its work in the window where the flag was false and had every
    single call refused, produced nothing, and was then disposed of as landed (an agent that
    produced nothing IS landed, worktree-spec point 7) with its worktree deleted.

    **What authorizes the worker instead is its RECEIPT, and those checks are all still
    ahead of it in `handle`:** `guard-sealed-worktree.sh` refuses a run the platform has
    already ended, `validate_shell_target` refuses a Git command whose target it cannot
    read, and `app.py`'s `worker_context` refuses any `agent_id` that does not join exactly
    one live receipt of this session and this binding, refuses the CEO-scoped `mcp__richos_*`
    tools outright, and fences every write inside the registered target worktree. Nothing is
    waved through here; a different, narrower gate answers for a worker than for the lease.

    **A stop still stops it.** The flag is written true in one place (`bind_work_assignment`'s
    standing §5.4 grant) and cleared by `ecs::revoke` — the CEO's stop, the end of the
    assignment, a crash-recovery sweep — and a stop also kills the process group the worker
    lives in. Absent means false, so an older app, a conversation lease, or a scope written
    by anything else refuses a worker exactly as before.
    """
    return bool(payload.get("agent_id")) and active.get("background_work_allowed") is True


def handle(payload):
    root = Path(os.environ["RICHOS_APP_STATE"])
    coordination = Path(os.environ["RICHOS_ENTITY_ROOT"])
    if not root.is_absolute() or not coordination.is_absolute():
        raise ValueError("desktop roots must be explicit and absolute")
    event = payload.get("hook_event_name")
    if event == "PreToolUse" and payload.get("tool_name") == "SendMessage":
        pause_protocol = load("richos_pause_protocol", ENGINE / "scripts/lib/pause_protocol.py")
        pause_protocol.validate_payload(payload)
    if event == "PreToolUse":
        active = scope()
        if active.get("actions_allowed") is not True \
                and not a_worker_this_lease_already_dispatched(active, payload):
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
        # WHICH GUARDS JUDGE A DISPATCH THE APP MAKES — read from
        # spawn-guard-audience.declaration, never typed here.
        #
        # This list was two hand-written paths until 2026-09-18:
        # guard-worktree-isolation.sh and guard-brief-scope.sh. Nothing said why
        # those two, nothing connected them to the identical list in
        # `EngineProfile::prepare`'s spawn-preflight.json, and the second of them
        # is an operator-session guard — it judges a dispatch against a
        # design-round specification recorded in the DEVELOPMENT project, with an
        # escape line only an operator can write. It was silent on a user's own
        # repository only because a user's repository happens to carry no such
        # record. Rich's ruling (CEO §57) is that the app is judged only by
        # guards whose reason protects the user's own work, so it is off this
        # list and the classification is the source of what is on it.
        #
        # guard-sealed-worktree.sh is user-work and is deliberately NOT repeated
        # here: it ran above, for every tool, exactly as its matcherless
        # registration says it should.
        audience = load("richos_spawn_guard_audience", ENGINE / "scripts/lib/spawn-guard-audience.py")
        for guard in audience.user_work_ids():
            if guard == "guard-sealed-worktree.sh":
                continue
            run(["/bin/bash", str(ENGINE / "scripts/hooks" / guard)], payload)
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
