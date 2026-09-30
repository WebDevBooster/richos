#!/usr/bin/env python3
"""not-run-verdict.test.py — a suite that prints NOT RUN over a subcheck exits 2, never 0.

Hunt part 2, finding 18 (2026-09-29): several suites under app/scripts printed `  NOT RUN  <case>`
for a subcheck that could not run on this host (a tag or commit missing from a shallow clone, no
iOS simulator runtime, no node or cargo) and then exited 0 because every case that DID run
passed. run-tests.sh records exit 0 as `passed` without reading the text, and proof-run.py
consumes that state, so a land passed over checks that never ran.

The repository's contract for this is already written down (run-tests.sh, "EXIT 2 FROM A SUITE
MEANS THIS HOST CANNOT ANSWER"): exit 2 is a gap, tolerated only when the caller declares it,
red otherwise, and never a pass. The suites keep their reasons for skipping a subcheck whose tool
is genuinely absent; what changes is the machine verdict, never the skip.

  V1  battery-check.test.py, run for real in a throwaway clone without the historical commit
      it needs, exits 2 and says NOT RUN in its summary line.
  S*  the static rule, per suite: every line that prints the `  NOT RUN  ` marker either stops
      the suite with exit 2 there, or is counted by a variable the suite's verdict turns into
      exit 2, or is declared on the line as `# not-a-subcheck: <reason>` (an intentional scope
      decision, such as a case that is off every land by a recorded decision).

Nothing builds, boots or opens a window.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PASSED = FAILED = 0


def check(ok, what, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  ok    %s" % what)
    else:
        FAILED += 1
        print("  FAIL  %s%s" % (what, ("\n        %s" % str(detail)[:900]) if detail else ""))


GIT = ["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Verdict Test",
       "-c", "user.email=verdict-test@example.invalid", "-c", "commit.gpgsign=false",
       "-c", "init.defaultBranch=main"]


def v1_battery_check_in_a_shallow_history():
    tmp = tempfile.mkdtemp(prefix="not-run-verdict.", dir=os.environ.get("TMPDIR"))
    try:
        scripts = os.path.join(tmp, "richos", "app", "scripts")
        os.makedirs(scripts)
        for name in ("battery-check.py", "battery-check.test.py"):
            shutil.copy(os.path.join(HERE, name), scripts)
        subprocess.run(GIT + ["-C", tmp, "init", "-q"], check=True)
        subprocess.run(GIT + ["-C", tmp, "add", "-A"], check=True)
        subprocess.run(GIT + ["-C", tmp, "commit", "-qm", "fixture without the historical commit"], check=True)
        r = subprocess.run([sys.executable, os.path.join(scripts, "battery-check.test.py")], cwd=tmp,
                           capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        last = (r.stdout.strip().splitlines() or [""])[-1]
        check(r.returncode == 2 and "  NOT RUN  R1/R2" in r.stdout and "NOT RUN" in last and " 0 failed" in last,
              "V1 battery-check.test.py without e879df50 in its clone exits 2 and names NOT RUN in its summary",
              (r.returncode, last, r.stderr[-300:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check(not os.path.exists(tmp), "V1b the throwaway clone is gone (§54)", tmp)


MARKER = "  NOT RUN  "
STOPS = re.compile(r"\bexit 2\b|SystemExit\(2\)|^\s*(return|sys\.exit\()[^#]*\b2\b")
DECLARED = re.compile(r"#\s*not-a-subcheck:\s*\S")
COUNTS = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*(?:NOT_?RUN|NOTRUN)[A-Za-z0-9_]*)(?:=|\+=|\.append\()", re.I)


def stops_with_2(lines, name):
    """Some line naming `name` is followed, within two lines, by a stop with exit 2."""
    for i, line in enumerate(lines):
        if re.search(r"\b%s\b" % re.escape(name), line) and not line.lstrip().startswith("#"):
            if any(STOPS.search(l) for l in lines[i:i + 3]):
                return True
    return False


def unaccounted(path):
    """Every `  NOT RUN  ` line in `path` that neither stops with exit 2, nor is counted into an
    exit-2 verdict, nor is declared as not a subcheck, as `line: text`."""
    with open(path, errors="replace") as fh:
        lines = fh.read().split("\n")
    bad = []
    for i, line in enumerate(lines):
        if MARKER not in line or line.lstrip().startswith("#"):
            continue
        window = lines[i:i + 3]
        if DECLARED.search(line) or any(STOPS.search(l) for l in window):
            continue
        counted = [m.group(1) for l in window for m in COUNTS.finditer(l)]
        if counted and all(stops_with_2(lines, name) for name in counted):
            continue
        bad.append("%d: %s" % (i + 1, line.strip()[:140]))
    return bad


def static_rule(names):
    for name in names:
        path = os.path.join(HERE, name)
        bad = unaccounted(path)
        check(os.path.exists(path) and not bad,
              "S %s: every NOT RUN it prints reaches exit 2 or is declared not a subcheck" % name,
              "; ".join(bad))


# The suites hunt part 2 finding 18 named, each added with its own fix.
NAMED = [
    "battery-check.test.py",
]


if __name__ == "__main__":
    print("=== not-run-verdict ===")
    v1_battery_check_in_a_shallow_history()
    static_rule(NAMED)
    if FAILED:
        print("=== not-run-verdict tests: %d FAILED, %d passed ===" % (FAILED, PASSED))
        sys.exit(1)
    print("=== not-run-verdict tests: all %d passed ===" % PASSED)
