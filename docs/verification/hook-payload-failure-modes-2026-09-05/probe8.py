#!/usr/bin/env python3
"""Where exactly does the silent path diverge? Read the trace tail."""
import json, os, subprocess

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
TRANS = os.path.join(S, "trans-violate.jsonl")
HOOK = "notice-ceo-unasked.sh"
BASE = {"session_id": "pr8-0000", "transcript_path": TRANS, "cwd": FB,
        "hook_event_name": "Stop", "stop_hook_active": False}


def trace(text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    env["PS4"] = "+ "
    p = subprocess.run(["/bin/bash", "-x", os.path.join(HOOKS, HOOK)],
                       input=text.encode(), capture_output=True, env=env,
                       cwd=FB, timeout=90)
    err = p.stderr.decode("utf-8", "replace")
    return [ln for ln in err.splitlines() if ln.startswith("+")], len(p.stdout)


for label, obj in [("speaks: full", BASE),
                   ("silent: bad cwd", dict(BASE, cwd="/Users/alex/ab/nowhere-at-all"))]:
    tr, n = trace(json.dumps(obj))
    print("=== %s (stdout=%d, steps=%d) ===" % (label, n, len(tr)))
    for ln in tr[-14:]:
        print("   ", ln[:150])
    print("")
