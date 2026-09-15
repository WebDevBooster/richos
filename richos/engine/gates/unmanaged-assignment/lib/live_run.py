#!/usr/bin/env python3
"""live_run.py — give the orchestrator ONE assignment, say nothing else, and record what it did.

NO NUDGES, AND THE HARNESS CAN PROVE IT
=======================================
The CEO's specification is "then send no nudges", and a harness that merely intends to stay
quiet is not evidence. This runner sends exactly one string: the contents of ASSIGNMENT.md.
On a restart it sends that IDENTICAL string again and nothing else — a restart is the worker
coming back to the same assignment, not the operator adding information. `meta.json` records
every prompt sent, and `nudges_sent` counts the prompts whose text differs from the first. It
is 0 by construction, and the judge refuses to score a record where it is not.

WHICH SURFACE THIS DEMONSTRATES — READ THIS BEFORE QUOTING A RESULT
==================================================================
A headless `claude --print` session, in a sandbox working directory, with `--setting-sources
""` so the operator's own hooks, plugins and project settings are not in the picture, and with
whatever `--doctrine` file the caller names appended to the system prompt (default: NONE).

That is deliberately the surface RichOS actually ships: `echo-opus-sn1` measured that the
Claude Code process RichOS drives loads no CLAUDE.md, and the default here matches it. Running
with `--doctrine <file>` measures a doctrine-carrying Rich instead, and `meta.json` records
which, so no result can be quoted without its surface.

WHAT THIS SURFACE IS NOT. The 2026-09-08 incident happened in an interactive Claude Code
session driven by a person, over 124 real commits, with a live team of subagents and the real
femcboost record. This is a scale model of that: one workspace, five conditions, minutes
rather than a day, no subagents. A PASS here is evidence that the SHAPE of the failure is
gone; it is not evidence that the incident cannot recur at the incident's scale. The desktop
controller is a third surface again and cannot govern a Claude Code session at all today, so
nothing in this gate speaks for it.

COST AND DURATION are measured per run and written into meta.json, so the header of this gate
never has to carry a number that goes stale.
"""

import json
import os
import shutil
import subprocess
import sys
import time


def _stream(cmd, cwd, transcript, deadline=None):
    """Run claude, tee the stream-json to `transcript`, return (session_id, killed, lines)."""
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    session_id = None
    lines = 0
    killed = False
    with open(transcript, "a") as handle:
        for line in proc.stdout:
            handle.write(line)
            handle.flush()
            lines += 1
            if session_id is None:
                try:
                    event = json.loads(line)
                    session_id = event.get("session_id") or session_id
                except (ValueError, AttributeError):
                    pass
            if deadline and time.time() > deadline:
                # A worker that DISAPPEARS, not one that is asked to stop. SIGKILL, because
                # the interrupted-worker condition is about a process that never got to write
                # a handoff, and a graceful shutdown would write one.
                proc.kill()
                killed = True
                break
    proc.wait()
    return session_id, killed, lines, proc.returncode


def run(
    workspace,
    record_dir,
    model="opus",
    doctrine=None,
    max_turns=140,
    restart_after=None,
):
    os.makedirs(record_dir, exist_ok=True)
    transcript = os.path.join(record_dir, "transcript.jsonl")
    open(transcript, "w").close()

    with open(os.path.join(workspace, "ASSIGNMENT.md")) as handle:
        assignment = handle.read()
    prompt = assignment + (
        "\n\nYour working directory is this workspace. Everything you need is in it. "
        "Begin.\n"
    )

    base = [
        "claude",
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        "bypassPermissions",
        "--setting-sources",
        "",
        "--max-turns",
        str(max_turns),
        "--model",
        model,
    ]
    if doctrine:
        base += ["--append-system-prompt-file", os.path.abspath(doctrine)]

    prompts_sent = [prompt]
    started = time.time()
    deadline = started + restart_after if restart_after else None
    session_id, killed, _lines, rc = _stream(base, workspace, transcript, deadline)
    restarts = 0

    if killed and session_id:
        # THE RESTART CASE. Same assignment, character for character. No explanation of what
        # happened, no summary of what it had done, no new instruction — because the thing
        # under test is whether it recovers its own state from the workspace.
        restarts = 1
        resume = list(base)
        resume[1:2] = ["--resume", session_id, "-p"]
        prompts_sent.append(prompt)
        _sid2, _k2, _l2, rc = _stream(resume, workspace, transcript, None)

    duration = time.time() - started

    cost = 0.0
    result_text = None
    with open(transcript) as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "result":
                cost += float(event.get("total_cost_usd") or 0.0)
                result_text = event.get("result")

    meta = {
        "surface": "headless claude --print, sandbox cwd, --setting-sources '' (no operator "
        "hooks/plugins/project settings)",
        "doctrine": os.path.abspath(doctrine) if doctrine else None,
        "model": model,
        "session_id": session_id,
        "restarts": restarts,
        "prompts_sent": len(prompts_sent),
        "nudges_sent": sum(1 for p in prompts_sent if p != prompts_sent[0]),
        "duration_s": round(duration, 1),
        "cost_usd": round(cost, 4),
        "exit_code": rc,
        "final_text_tail": (result_text or "")[-1500:],
    }
    with open(os.path.join(record_dir, "meta.json"), "w") as handle:
        json.dump(meta, handle, indent=2)
    return meta


if __name__ == "__main__":
    args = sys.argv[1:]
    ws, rec = args[0], args[1]
    kwargs = {}
    for flag, key, cast in (
        ("--model", "model", str),
        ("--doctrine", "doctrine", str),
        ("--max-turns", "max_turns", int),
        ("--restart-after", "restart_after", float),
    ):
        if flag in args:
            kwargs[key] = cast(args[args.index(flag) + 1])
    print(json.dumps(run(ws, rec, **kwargs), indent=2))
