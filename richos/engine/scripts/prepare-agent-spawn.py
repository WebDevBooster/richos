#!/usr/bin/env python3
"""Build an isolated Agent tool input with the mandatory merge-main-at-handover line.

Read task-specific Agent input JSON from --file (or stdin), print prepared JSON.
This creates no worktree, dispatches nobody and grants no guard exemptions.
Cross-repo work still needs create-teammate-worktree.sh and its registered path
on a cross-repo-worktree: prompt line. Live guards remain authoritative.
"""
import argparse
import json
from pathlib import Path
import re
import sys


def prepare(value):
    if not isinstance(value, dict):
        raise ValueError("input must be an Agent tool-input object")
    problems = [f"missing {key}" for key in ("name", "subagent_type", "prompt")
                if not isinstance(value.get(key), str) or not value[key].strip()]
    if value.get("resume"):
        problems.append("this helper prepares new spawns; use the resume contract for an existing agent")
    if value.get("cwd"):
        problems.append("cwd cannot carry a native lifecycle witness; use a registered cross-repo-worktree: prompt line")
    if value.get("isolation") not in (None, "worktree"):
        problems.append("this helper prepares isolation=worktree only; it will not override another isolation mode")
    if problems:
        raise ValueError("; ".join(problems))
    result = dict(value, isolation="worktree")
    result.pop("cwd", None)
    contract = ("Your last step before you hand over, and only if you committed anything: in each repository you committed to, "
                "run `git merge main` inside your own worktree. `main` here is the local branch named `main`, not `origin/main`. "
                "Never rebase. If git reports a conflict, resolve it and commit the merge. If the conflict is in a screenshot "
                "baseline picture (a `.png` under `ui/tests/shots-*`), regenerate that picture from the merged tree and look at it: "
                "if it shows anything besides your change and main's change together, do not commit it; say what it shows in your "
                "report. Merge only once; if main moves again after your merge, do not merge again. Then hand over.")
    if not re.search(r"inflight-ack\.sh|inflight-acks/|git merge main", result["prompt"]):
        result["prompt"] = result["prompt"].rstrip() + "\n\n" + contract
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default="-", help="task-specific Agent tool input JSON, or - for stdin")
    args = parser.parse_args()
    try:
        raw = sys.stdin.read() if args.file == "-" else Path(args.file).read_text()
        print(json.dumps(prepare(json.loads(raw)), indent=2))
    except (ValueError, OSError) as exc:
        print(f"prepare-agent-spawn: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
