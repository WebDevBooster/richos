#!/usr/bin/env python3
"""Targeted probes for the two behaviors the table turns on.

P1  notice-unasked-deferral.sh: does a payload that parses but carries NO
    last_assistant_message still emit the "this turn's text was checked" line?
    If yes, the reassurance is decoupled from the check.

P2  Stop-hook loop safety: a Stop hook that exits 2 relies on stop_hook_active
    to avoid an endless block. Does guard-stated-actions.sh stand down when
    stop_hook_active is true -- and what happens when that field is the thing
    the truncation removed?
"""
import json, os, subprocess, time

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
TRANS = os.path.join(S, "trans-violate.jsonl")
SESSION = "p5sweep00-0000-0000-0000-000000000000"


def run(hook, text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    p = subprocess.run(["/bin/bash", os.path.join(HOOKS, hook)],
                       input=text, capture_output=True, text=True, env=env,
                       cwd=FB, timeout=60)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def show(label, hook, obj):
    rc, out, err = run(hook, json.dumps(obj) if isinstance(obj, dict) else obj)
    print("--- %s  [%s]  rc=%s" % (label, hook, rc))
    if out:
        print("    out: %s" % out[:600])
    if err:
        print("    err: %s" % err[:600])
    print("")


DEFER = "I am not spawning that right now; it goes in with the next land."

print("=== P1: is the 'was checked' line decoupled from the check? ===\n")
show("a. full payload, deferral text present", "notice-unasked-deferral.sh",
     {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
      "hook_event_name": "Stop", "stop_hook_active": False,
      "prompt_id": "p5", "last_assistant_message": DEFER})
show("b. parses, session_id present, NO last_assistant_message", "notice-unasked-deferral.sh",
     {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
      "hook_event_name": "Stop", "stop_hook_active": False, "prompt_id": "p5"})
show("c. parses, NO session_id, deferral text present", "notice-unasked-deferral.sh",
     {"transcript_path": TRANS, "cwd": FB, "hook_event_name": "Stop",
      "prompt_id": "p5", "last_assistant_message": DEFER})

print("=== P2: Stop-hook loop safety depends on a payload field ===\n")
ACT = "Zach builds it tomorrow."
show("a. violation, stop_hook_active=false", "guard-stated-actions.sh",
     {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
      "hook_event_name": "Stop", "stop_hook_active": False,
      "prompt_id": "p5", "last_assistant_message": ACT})
show("b. same violation, stop_hook_active=TRUE", "guard-stated-actions.sh",
     {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
      "hook_event_name": "Stop", "stop_hook_active": True,
      "prompt_id": "p5", "last_assistant_message": ACT})
show("c. violation, stop_hook_active field ABSENT", "guard-stated-actions.sh",
     {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
      "hook_event_name": "Stop", "prompt_id": "p5", "last_assistant_message": ACT})
