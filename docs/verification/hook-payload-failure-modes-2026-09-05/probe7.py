#!/usr/bin/env python3
"""Why does a TRUNCATED payload silence a notice that an EMPTY payload does not?

Vary one field at a time against notice-ceo-unasked.sh, which emitted 511
bytes on both the control and the empty payload and nothing on the truncated
one.
"""
import json, os, subprocess

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
TRANS = os.path.join(S, "trans-violate.jsonl")
HOOK = "notice-ceo-unasked.sh"


def run(text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    p = subprocess.run(["/bin/bash", os.path.join(HOOKS, HOOK)], input=text,
                       capture_output=True, text=True, env=env, cwd=FB, timeout=90)
    return p.returncode, len(p.stdout), p.stdout[:200]


BASE = {"session_id": "pr7-0000", "transcript_path": TRANS, "cwd": FB,
        "hook_event_name": "Stop", "stop_hook_active": False}

VARIANTS = [
    ("full, well formed", json.dumps(BASE)),
    ("empty", ""),
    ("cwd = a path that does not exist",
     json.dumps(dict(BASE, cwd="/Users/alex/ab/nowhere-at-all"))),
    ("cwd = a truncated path prefix",
     json.dumps(dict(BASE, cwd="/Users/alex/ab/femcb"))),
    ("session_id truncated mid-value", json.dumps(dict(BASE, session_id="pr"))),
    ("valid JSON, but not an object", "[1,2,3]"),
    ("JSON cut mid-string",
     json.dumps(BASE)[: json.dumps(BASE).index('"cwd"') + 12]),
    ("JSON cut after the last complete field",
     json.dumps(BASE).rsplit(",", 1)[0]),
]

for label, text in VARIANTS:
    rc, n, head = run(text)
    print("%-42s rc=%s stdout=%4d  %s" % (label, rc, n, head[:90].replace("\n", " ")))
