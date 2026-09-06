#!/usr/bin/env python3
"""Second pass: the same degraded-payload matrix, but rooted at the REAL
governed entity (femcboost) so hooks that need entity-root content
(CEO TODOs, named-persons registry, ceo-ruled corpus, worktree ledger)
are actually able to run instead of standing down for a sandbox reason.

Read-only intent. Uses a distinctive session id so anything written can be
found and removed afterwards.
"""
import json, os, subprocess, sys, time

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
SANDBOX = os.path.dirname(os.path.abspath(__file__))
ENTITY = "/Users/alex/ab/femcboost"

SESSION = "fcsweep00-0000-0000-0000-000000000000"
TRANSCRIPT = os.path.join(SANDBOX, "transcript.jsonl")

sys.path.insert(0, SANDBOX)
from sweep import PRETOOL, STOP, variants  # reuse the same shapes


def reroot(obj):
    d = json.loads(json.dumps(obj))
    d["session_id"] = SESSION
    d["cwd"] = ENTITY
    d["transcript_path"] = TRANSCRIPT
    if d.get("tool_name") == "Write":
        d["tool_input"]["file_path"] = os.path.join(ENTITY, "docs", "sweep-note.md")
    return d


def run(hook, payload, timeout=45):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = ENTITY
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    t0 = time.time()
    try:
        p = subprocess.run(["/bin/bash", os.path.join(HOOKS, hook)],
                           input=payload, capture_output=True, text=True,
                           env=env, cwd=ENTITY, timeout=timeout)
        return {"rc": p.returncode, "out": p.stdout, "err": p.stderr,
                "sec": round(time.time() - t0, 2), "timeout": False}
    except subprocess.TimeoutExpired:
        return {"rc": None, "out": "", "err": "", "sec": round(time.time() - t0, 2),
                "timeout": True}


def main():
    results = []
    jobs = [("PreToolUse", h, m, reroot(c)) for h, m, c in PRETOOL]
    stop_ctrl = {"session_id": SESSION, "transcript_path": TRANSCRIPT, "cwd": ENTITY,
                 "hook_event_name": "Stop", "stop_hook_active": False}
    jobs += [("Stop", h, "(all)", stop_ctrl) for h in STOP]
    for event, hook, matcher, ctrl_obj in jobs:
        row = {"event": event, "hook": hook, "matcher": matcher, "cases": {}}
        for name, payload in variants(ctrl_obj):
            r = run(hook, payload)
            row["cases"][name] = r
            print("%-11s %-34s %-10s rc=%-7s %5.2fs out=%d err=%d" % (
                event, hook, name, "TIMEOUT" if r["timeout"] else r["rc"],
                r["sec"], len(r["out"]), len(r["err"])), flush=True)
        results.append(row)
    with open(os.path.join(SANDBOX, "sweep2-results.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    print("\nwrote sweep2-results.json (%d hooks)" % len(results))


if __name__ == "__main__":
    main()
