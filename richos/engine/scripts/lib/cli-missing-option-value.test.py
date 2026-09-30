#!/usr/bin/env python3
"""A value-taking option given as the LAST argument must fail fast, not spin (hunt part 5, P5-27).

`shift 2` fails without consuming anything when one argument is left, so a parser
that does not check the count runs the same case forever. Each command below is run
with only the dangling option: it must exit 2 and say which option needs a value,
well inside the timeout. A command that is still running at the timeout was the
process this test started, and the test kills exactly that child. Run directly:
    python3 scripts/lib/cli-missing-option-value.test.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
TIMEOUT = 8

# (script, leading mode/subcommand the script takes before its options, the dangling option)
CASES = [
    ("install-ack-protocol.sh", [], "--repo"),
    ("install-escalation-protocol.sh", [], "--repo"),
    ("escalate.sh", ["raise"], "--title"),
    ("escalate.sh", ["raise"], "--format"),
    ("escalate.sh", ["raise"], "--until"),
    ("inflight-ack.sh", [], "--sha"),
    ("inflight-ack.sh", [], "--repo"),
    ("inflight-notify.sh", ["status"], "--tip"),
    ("inflight-notify.sh", ["status"], "--transcript"),
    ("named-persons.sh", ["scan"], "--repo"),
    ("named-persons.sh", ["scan"], "--hq"),
    ("stop.sh", [], "--entity"),
]

failed = 0
for script, lead, opt in CASES:
    path = os.path.join(SCRIPTS, script)
    try:
        r = subprocess.run(["bash", path] + lead + [opt], capture_output=True, text=True, timeout=TIMEOUT,
                           stdin=subprocess.DEVNULL)
        ok = r.returncode == 2 and opt in r.stderr and "needs a value" in r.stderr
        detail = "rc=%s stderr=%r" % (r.returncode, r.stderr[-120:])
    except subprocess.TimeoutExpired:
        ok, detail = False, "still running after %ds (it spins)" % TIMEOUT
    print("  %s  %s %s  %s" % ("PASS" if ok else "FAIL", script, opt, "" if ok else detail))
    if not ok:
        failed += 1

print("=== cli-missing-option-value: %s ===" % ("%d FAILED" % failed if failed else "all %d passed" % len(CASES)))
sys.exit(1 if failed else 0)
