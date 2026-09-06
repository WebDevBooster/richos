#!/usr/bin/env python3
"""Trace probe: did the hook ever REACH its decision, or did it leave early?

`bash -x` on every hook, for the control payload and for each degraded one.
Two observables per run:
  steps    number of executed trace lines (how far the script got)
  judged   whether the trace shows the hook running its actual analyzer
           (a python3 invocation or a scripts/lib helper) -- i.e. whether it
           evaluated anything at all

A hook that exits 0 with far fewer steps than its control and never reaches
its analyzer did not decide the call was safe; it never looked.
"""
import json, os, re, subprocess, sys, time

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
SANDBOX = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"

sys.path.insert(0, SANDBOX)
import sweep3

JUDGE = re.compile(r"(python3|/lib/|\.py\b|interactive-prompt|publication-boundary|named-persons)")


def run(hook, root, text, timeout=60):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = root
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    env["PS4"] = "+ "
    try:
        p = subprocess.run(["/bin/bash", "-x", os.path.join(HOOKS, hook)],
                           input=text.encode(), capture_output=True,
                           env=env, cwd=root, timeout=timeout)
        p.stderr = p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return {"rc": None, "steps": None, "judged": None, "timeout": True, "last": ""}
    trace = [ln for ln in p.stderr.splitlines() if ln.startswith("+")]
    judged = any(JUDGE.search(ln) for ln in trace)
    return {"rc": p.returncode, "steps": len(trace), "judged": judged,
            "timeout": False, "last": trace[-1][:160] if trace else ""}


def main():
    rows = []
    jobs = [(h, r, o, w) for h, r, o, w in sweep3.CASES] + \
           [(h, FB, o, w) for h, o, w in sweep3.STOP_CASES]
    for hook, root, obj, what in jobs:
        row = {"hook": hook, "cases": {}}
        for name, text in sweep3.degrade(obj):
            row["cases"][name] = run(hook, root, text)
        c = row["cases"]
        print("%-34s ctrl(rc=%s steps=%s judged=%s) | empty(rc=%s steps=%s judged=%s) | trunc(rc=%s steps=%s judged=%s) | nonjson(rc=%s steps=%s judged=%s)" % (
            hook,
            c["violation"]["rc"], c["violation"]["steps"], c["violation"]["judged"],
            c["empty"]["rc"], c["empty"]["steps"], c["empty"]["judged"],
            c["truncated"]["rc"], c["truncated"]["steps"], c["truncated"]["judged"],
            c["nonjson"]["rc"], c["nonjson"]["steps"], c["nonjson"]["judged"]), flush=True)
        rows.append(row)
    with open(os.path.join(SANDBOX, "sweep4-trace.json"), "w") as fh:
        json.dump(rows, fh, indent=1)
    print("\nwrote sweep4-trace.json")


if __name__ == "__main__":
    main()
