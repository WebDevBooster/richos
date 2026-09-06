#!/usr/bin/env python3
"""Degraded-payload sweep across every PreToolUse and Stop hook.

For each hook, four stdin variants are fed to the real script:
  control   a well-formed, benign payload for that hook's event/matcher
  empty     zero bytes, stdin closed immediately
  truncated the control payload cut at 60% of its length (broken JSON)
  nonjson   plain prose, no JSON at all

Records exit code, stdout, stderr, wall time. Nothing is inferred from source.
"""
import json, os, subprocess, sys, time

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
SANDBOX = os.path.dirname(os.path.abspath(__file__))
ENTITY = os.path.join(SANDBOX, "entity")

SESSION = "sweep0000-0000-0000-0000-000000000000"
TRANSCRIPT = os.path.join(SANDBOX, "transcript.jsonl")

# --- control payloads, one per matcher shape --------------------------------
def base(**kw):
    d = {"session_id": SESSION, "transcript_path": TRANSCRIPT, "cwd": ENTITY}
    d.update(kw)
    return d

CTRL = {}

def pre(tool, tool_input):
    return base(hook_event_name="PreToolUse", tool_name=tool, tool_input=tool_input)

WRITE_CTRL = pre("Write", {"file_path": os.path.join(ENTITY, "notes.md"),
                           "content": "A short American English note about the color of the analyzer.\n"})
BASH_CTRL = pre("Bash", {"command": "ls -la", "description": "List files"})
AGENT_CTRL = pre("Agent", {"subagent_type": "clark", "name": "clark-sonnet-zz1",
                           "prompt": "Research one narrow question and report back.",
                           "description": "research"})
SEND_CTRL = pre("SendMessage", {"to": "main", "message": "status"})
ASK_CTRL = pre("AskUserQuestion", {"questions": [{"question": "Which option?",
                                                  "options": [{"label": "A"}, {"label": "B"}]}]})
WF_CTRL = pre("Workflow", {"workflow": "x"})
STOP_CTRL = base(hook_event_name="Stop", stop_hook_active=False)

PRETOOL = [
    ("guard-sealed-worktree.sh", "(all)", WRITE_CTRL),
    ("guard-worktree-isolation.sh", "Agent", AGENT_CTRL),
    ("guard-definition-drift.sh", "Agent", AGENT_CTRL),
    ("reader-teammate-hint.sh", "Agent", AGENT_CTRL),
    ("verify-agent-prompt.sh", "Agent", AGENT_CTRL),
    ("guard-ceo-ask-first.sh", "Agent", AGENT_CTRL),
    ("guard-model-ceiling.sh", "Agent", AGENT_CTRL),
    ("guard-main-checkout-writes.sh", "Write|Edit|MultiEdit|NotebookEdit", WRITE_CTRL),
    ("scan-secrets.sh", "Write|Edit|MultiEdit|NotebookEdit", WRITE_CTRL),
    ("guard-publication-writes.sh", "Write|Edit|MultiEdit|NotebookEdit", WRITE_CTRL),
    ("guard-named-persons-writes.sh", "Write|Edit|MultiEdit|NotebookEdit", WRITE_CTRL),
    ("guard-dialect.sh", "Write|Edit|MultiEdit|NotebookEdit", WRITE_CTRL),
    ("guard-resume-isolation.sh", "SendMessage", SEND_CTRL),
    ("guard-ceo-ruled-ask.sh", "AskUserQuestion", ASK_CTRL),
    ("guard-interactive-prompt.sh", "Bash", BASH_CTRL),
    ("guard-bash-main-writes.sh", "Bash", BASH_CTRL),
    ("guard-inflight-notify.sh", "Bash", BASH_CTRL),
    ("guard-worktree-removal.sh", "Bash", BASH_CTRL),
    ("guard-publication-commits.sh", "Bash", BASH_CTRL),
    ("guard-named-persons-commands.sh", "Bash", BASH_CTRL),
    ("guard-ceo-todos-commits.sh", "Bash", BASH_CTRL),
    ("guard-completeness-commits.sh", "Bash", BASH_CTRL),
    ("guard-row-currency-commits.sh", "Bash", BASH_CTRL),
    ("guard-vendoring-commits.sh", "Bash", BASH_CTRL),
    ("guard-workflow-ban.sh", "Workflow", WF_CTRL),
]

STOP = [
    "guard-unresolved-claims.sh", "turn-manifest.sh", "notice-hook-staleness.sh",
    "notice-inflight-acks.sh", "notice-mechanical-findings.sh", "notice-unstarted-rows.sh",
    "notice-ceo-unasked.sh", "notice-unasked-deferral.sh", "notice-ceo-ruled-prose.sh",
    "notice-waiver-repetition.sh", "notice-escalations.sh", "guard-agent-state-claims.sh",
    "guard-idle-land.sh", "guard-stated-actions.sh", "notice-ceo-inputs-unheld.sh",
]


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


def variants(ctrl_obj):
    ctrl = json.dumps(ctrl_obj)
    cut = ctrl[: int(len(ctrl) * 0.6)]
    return [("control", ctrl), ("empty", ""), ("truncated", cut),
            ("nonjson", "the payload never arrived and this is not JSON\n")]


def main():
    # a minimal transcript so transcript-reading hooks have something real
    with open(TRANSCRIPT, "w") as fh:
        fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant",
                 "content": [{"type": "text", "text": "Work is done."}]}}) + "\n")

    results = []
    jobs = [("PreToolUse", h, m, c) for h, m, c in PRETOOL] + \
           [("Stop", h, "(all)", STOP_CTRL) for h in STOP]
    for event, hook, matcher, ctrl_obj in jobs:
        row = {"event": event, "hook": hook, "matcher": matcher, "cases": {}}
        for name, payload in variants(ctrl_obj):
            r = run(hook, payload)
            row["cases"][name] = r
            print("%-14s %-34s %-10s rc=%-5s %5.2fs out=%d err=%d" % (
                event, hook, name, "TIMEOUT" if r["timeout"] else r["rc"],
                r["sec"], len(r["out"]), len(r["err"])), flush=True)
        results.append(row)
    with open(os.path.join(SANDBOX, "sweep-results.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    print("\nwrote sweep-results.json (%d hooks)" % len(results))


if __name__ == "__main__":
    main()
