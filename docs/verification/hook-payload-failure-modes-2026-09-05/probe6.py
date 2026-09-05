#!/usr/bin/env python3
"""Last two controls: the hooks whose trigger the earlier payloads missed."""
import json, os, subprocess

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
S = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
TRANS = os.path.join(S, "trans-violate.jsonl")
SESSION = "p6sweep00-0000-0000-0000-000000000000"
TAIL = "z" * 4000


def run(hook, text):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = FB
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    p = subprocess.run(["/bin/bash", os.path.join(HOOKS, hook)], input=text,
                       capture_output=True, text=True, env=env, cwd=FB, timeout=60)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def cases(obj):
    full = json.dumps(obj)
    return [("violation", full),
            ("empty", ""),
            ("truncated", full[: full.index(TAIL) + 500]),
            ("nonjson", "not json\n")]


def go(hook, obj):
    print("=" * 70)
    print(hook)
    for name, text in cases(obj):
        rc, out, err = run(hook, text)
        print("  %-10s rc=%s out=%d err=%d" % (name, rc, len(out), len(err)))
        if out:
            print("     out: %s" % out[:400])
        if err:
            print("     err: %s" % err[:400].replace("\n", "\n          "))
    print("")


go("guard-inflight-notify.sh",
   {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
    "hook_event_name": "PreToolUse", "tool_name": "Bash",
    "tool_input": {"command": "git push origin main", "description": "push"},
    "_pad": TAIL})

go("reader-teammate-hint.sh",
   {"session_id": SESSION, "transcript_path": TRANS, "cwd": FB,
    "hook_event_name": "PreToolUse", "tool_name": "Agent",
    "tool_input": {"subagent_type": "mark", "name": "mark-sonnet-zz7",
                   "isolation": "worktree",
                   "prompt": "Read in full every one of the following wiki pages and docs, ingest all of them end-to-end, and enumerate every decision across those sources.",
                   "description": "x"},
    "_pad": TAIL})
