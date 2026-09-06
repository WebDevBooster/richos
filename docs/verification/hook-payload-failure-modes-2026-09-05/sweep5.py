#!/usr/bin/env python3
"""Trace probe over every Stop hook, with the real-root Stop payload of
sweep2 as the control, so the Stop half gets the same instrument the
PreToolUse half got.
"""
import json, os, re, subprocess, sys

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
TRANS = os.path.join(S, "trans-violate.jsonl")
SESSION = "p7sweep00-0000-0000-0000-000000000000"
TAIL = "z" * 4000

sys.path.insert(0, S)
from sweep import STOP

CTRL = {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
        "hook_event_name": "Stop", "stop_hook_active": False,
        "prompt_id": "p7",
        "last_assistant_message": "I merged the branch and pushed it. Zach builds it tomorrow. "
                                  "I am not spawning that right now; it goes in with the next land.",
        "_pad": TAIL}


def run(hook, text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    env["PS4"] = "+ "
    p = subprocess.run(["/bin/bash", "-x", os.path.join(HOOKS, hook)],
                       input=text.encode(), capture_output=True, env=env,
                       cwd=FB, timeout=90)
    err = p.stderr.decode("utf-8", "replace")
    trace = [ln for ln in err.splitlines() if ln.startswith("+")]
    return {"rc": p.returncode, "steps": len(trace),
            "out": p.stdout.decode("utf-8", "replace"),
            "err": "\n".join(ln for ln in err.splitlines() if not ln.startswith("+"))}


full = json.dumps(CTRL)
VARIANTS = [("violation", full), ("empty", ""),
            ("truncated", full[: full.index(TAIL) + 500]),
            ("nonjson", "not json\n")]

rows = []
for hook in STOP:
    row = {"hook": hook, "cases": {}}
    for name, text in VARIANTS:
        row["cases"][name] = run(hook, text)
    c = row["cases"]
    print("%-32s ctrl(rc=%s steps=%s out=%d) empty(rc=%s steps=%s out=%d) trunc(rc=%s steps=%s out=%d) nonjson(rc=%s steps=%s out=%d)" % (
        hook,
        c["violation"]["rc"], c["violation"]["steps"], len(c["violation"]["out"]),
        c["empty"]["rc"], c["empty"]["steps"], len(c["empty"]["out"]),
        c["truncated"]["rc"], c["truncated"]["steps"], len(c["truncated"]["out"]),
        c["nonjson"]["rc"], c["nonjson"]["steps"], len(c["nonjson"]["out"])), flush=True)
    rows.append(row)

with open(os.path.join(S, "sweep5-stop.json"), "w") as fh:
    json.dump(rows, fh, indent=1)
print("\nwrote sweep5-stop.json")
