#!/usr/bin/env python3
"""Stop hooks, re-run correctly.

The first attempt ran all four variants under ONE session id. The shared
stop-hook-notice library suppresses a repeat of an identical state for the
same session, so the later variants were silenced by the earlier ones rather
than by their own payload -- a negative result that would have passed for the
wrong reason. This run gives every variant its own session id AND removes any
notice-state file the run creates, so each variant is a first run.
"""
import glob, json, os, subprocess

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
NOTICES = os.path.join(FB, ".claude", "state", "stop-hook-notices")
TRANS = os.path.join(S, "trans-violate.jsonl")
TAIL = "z" * 4000

import sys
sys.path.insert(0, S)
from sweep import STOP

TEXT = ("I merged the branch and pushed it. Zach builds it tomorrow. "
        "I am not spawning that right now; it goes in with the next land.")


def ctrl(sid):
    return {"session_id": sid, "transcript_path": TRANS, "cwd": FB,
            "hook_event_name": "Stop", "stop_hook_active": False,
            "prompt_id": "p8", "last_assistant_message": TEXT, "_pad": TAIL}


def run(hook, text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    before = set(glob.glob(os.path.join(NOTICES, "*")))
    p = subprocess.run(["/bin/bash", os.path.join(HOOKS, hook)], input=text,
                       capture_output=True, text=True, env=env, cwd=FB, timeout=90)
    for f in set(glob.glob(os.path.join(NOTICES, "*"))) - before:
        os.remove(f)
    return {"rc": p.returncode, "out": p.stdout, "err": p.stderr}


rows = []
for i, hook in enumerate(STOP):
    row = {"hook": hook, "cases": {}}
    for j, name in enumerate(("control", "empty", "truncated", "nonjson")):
        sid = "s%02d%02d0000-0000-0000-0000-00000000000%d" % (i, j, j)
        full = json.dumps(ctrl(sid))
        text = {"control": full, "empty": "",
                "truncated": full[: full.index(TAIL) + 500],
                "nonjson": "not json\n"}[name]
        row["cases"][name] = run(hook, text)
    c = row["cases"]
    print("%-32s ctrl(rc=%s out=%4d err=%4d) empty(rc=%s out=%4d) trunc(rc=%s out=%4d) nonjson(rc=%s out=%4d)" % (
        hook, c["control"]["rc"], len(c["control"]["out"]), len(c["control"]["err"]),
        c["empty"]["rc"], len(c["empty"]["out"]),
        c["truncated"]["rc"], len(c["truncated"]["out"]),
        c["nonjson"]["rc"], len(c["nonjson"]["out"])), flush=True)
    rows.append(row)

with open(os.path.join(S, "sweep6-stop.json"), "w") as fh:
    json.dump(rows, fh, indent=1)
print("\nwrote sweep6-stop.json")
print("leftover notice-state files:", len(glob.glob(os.path.join(NOTICES, "s*0000*"))))
