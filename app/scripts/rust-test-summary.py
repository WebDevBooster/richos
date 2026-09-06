#!/usr/bin/env python3
"""Summarize Cargo output without counting doc tests as ordinary test passes.

This inspects a captured log; it never claims the cargo process exited zero.
Use with a successful, complete cargo invocation and retain its exit status.
"""
import argparse
import json
import re
from pathlib import Path

RESULT = re.compile(r"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;", re.M)


def summarize(text):
    counts = {k: {"passed": 0, "failed": 0, "ignored": 0, "suites": 0} for k in ("ordinary", "documentation")}
    kind = "ordinary"
    for line in text.splitlines():
        if re.match(r"\s*Doc-tests\s+", line):
            kind = "documentation"
        elif re.match(r"\s*(?:Running|Finished)\s+", line):
            kind = "ordinary"
        m = RESULT.match(line)
        if m:
            counts[kind]["suites"] += 1
            for key, value in zip(("passed", "failed", "ignored"), m.groups()[1:]):
                counts[kind][key] += int(value)
    if not counts["ordinary"]["suites"]:
        raise ValueError("no ordinary test result found; an empty or compiler-error log is not a passing run")
    counts["ordinary"]["total"] = sum(counts["ordinary"][k] for k in ("passed", "failed", "ignored"))
    counts["process_exit_verified"] = False
    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        result = summarize(args.file.read_text())
    except (ValueError, OSError) as exc:
        parser.exit(2, str(exc) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(1 if any(result[k]["failed"] for k in ("ordinary", "documentation")) else 0)
