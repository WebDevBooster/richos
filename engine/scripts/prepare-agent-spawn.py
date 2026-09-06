#!/usr/bin/env python3
"""Build an isolated Agent tool input with the mandatory acknowledgement contract.

Read task-specific Agent input JSON from --file (or stdin), print prepared JSON.
This creates no worktree, dispatches nobody and grants no guard exemptions.
Cross-repo work still needs create-teammate-worktree.sh and its registered path
on a cross-repo-worktree: prompt line. Live guards remain authoritative.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
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
    helper = shlex.quote(str(Path(__file__).resolve().parent / "inflight-ack.sh"))
    contract = ("If notified that main moved, inspect the change and acknowledge it durably from your worktree: "
                f"{helper} --sha <sha> --impact <conflict|stale-record|grew-scope|none> "
                '--detail "<your assessment>" --paths "<paths or none>". A chat reply alone is not the acknowledgement.')
    if not re.search(r"inflight-ack\.sh|inflight-acks/", result["prompt"]):
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
