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
  S   the static rule, per suite: every line that prints the `  NOT RUN  ` marker either stops
      the suite with exit 2 there, or is counted by a variable the suite's verdict turns into
      exit 2, or is declared on the line as `# not-a-subcheck: <reason>` (an intentional scope
      decision, such as a case that is off every land by a recorded decision).
  S*  the same rule over every suite in this directory, so the class stays closed.
  V2, V3  the two native iOS suites' own final verdicts, executed with the counters injected
      (their cases need Xcode and simulators; their verdict does not).

Nothing builds, boots or opens a window.
"""
import os
import re
import shlex
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
# Fixture text: a suite that writes a NOT RUN line into a log file for the code under test to read
# (Path(...).write_text('  NOT RUN  ...')) is not printing a verdict of its own.
FIXTURE = re.compile(r"\.write_text\(")
# Only the text inside the write_text(...) argument is exempt; a NOT RUN printed elsewhere on the
# same line is audited.


def outside_fixtures(line):
    """`line` with every write_text(...) argument blanked out (quotes respected, so a paren inside a
    string does not end the call; a call left open at the end of the line blanks to the end)."""
    out, i = [], 0
    while True:
        m = FIXTURE.search(line, i)
        if not m:
            out.append(line[i:])
            return "".join(out)
        out.append(line[i:m.end()])
        depth, quote, j = 1, None, m.end()
        while j < len(line) and depth:
            c = line[j]
            if quote:
                if c == "\\":
                    j += 1
                elif c == quote:
                    quote = None
            elif c in "'\"":
                quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        i = j
ASSIGNS = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+?=|\.append\()")


def counters(line):
    """The not-run counters or flags `line` sets: NOTRUN=..., S7_NOT_RUN=1, NOT_RUN.append(...)."""
    return [n for n in ASSIGNS.findall(line) if re.search(r"not_?run", n, re.I)]


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
        if MARKER not in line or line.lstrip().startswith("#") or MARKER not in outside_fixtures(line):
            continue
        window = lines[i:i + 3]
        if DECLARED.search(line) or any(STOPS.search(l) for l in window):
            continue
        counted = [name for l in window for name in counters(l)]
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


def every_suite():
    """The class, not the list: every suite in this directory, so the next suite written with
    `echo "  NOT RUN  ..."` and an exit 0 after it is red on its first run. This file is left
    out only because it spells the marker it looks for."""
    own = os.path.basename(__file__)
    rest = sorted(n for n in os.listdir(HERE)
                  if n.endswith((".test.sh", ".test.py")) and n != own)
    bad = ["%s:%s" % (n, line) for n in rest for line in unaccounted(os.path.join(HERE, n))]
    check(len(rest) > 20 and not bad,
          "S* every suite under app/scripts (%d) holds every NOT RUN it prints to exit 2" % len(rest),
          "; ".join(bad))


def probes():
    """P  Codex's three probes (richos-hq docs/verification/2026-09-30-codex/baseline-repair-audit):
    a real NOT RUN printed on the same line as a write_text call is flagged; NOT RUN text only inside
    the write_text argument is accepted; a plain print with exit 0 is flagged."""
    cases = [
        ("P1 a printed NOT RUN sharing a line with write_text is flagged",
         "import sys\nfrom pathlib import Path\nprint('  NOT RUN  unavailable'); Path('artifact').write_text('note')\nsys.exit(0)\n", True),
        ("P2 NOT RUN text only inside a write_text argument is accepted",
         "import sys\nfrom pathlib import Path\nPath('log').write_text('  NOT RUN  (fixture) x')\nsys.exit(0)\n", False),
        ("P3 a printed NOT RUN with exit 0 is flagged",
         "import sys\nprint('  NOT RUN  unavailable')\nsys.exit(0)\n", True),
    ]
    for what, text, flagged in cases:
        tmp = tempfile.mkdtemp(prefix="not-run-probe.", dir=os.environ.get("TMPDIR"))
        try:
            path = os.path.join(tmp, "probe.py")
            with open(path, "w") as fh:
                fh.write(text)
            check(bool(unaccounted(path)) == flagged, what, unaccounted(path))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


VERDICT_START = re.compile(r'^if \[ "\$FAILED" -eq 0 \] && \[ -n "\$NOT_RUN" \]; then$')


def verdict(name, **counters):
    """Run `name`'s own final verdict, from its NOT RUN branch to the end of the file, with the
    counters the suite would have reached: (exit status, output), or None if it has no such
    branch. The cases before it (builds, simulators) cannot run here; the verdict can."""
    with open(os.path.join(HERE, name)) as fh:
        lines = fh.read().split("\n")
    start = next((i for i, line in enumerate(lines) if VERDICT_START.match(line)), None)
    if start is None:
        return None
    script = "set -uo pipefail\n%s\n%s\n" % (
        "\n".join("%s=%s" % (k, shlex.quote(str(v))) for k, v in counters.items()), "\n".join(lines[start:]))
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def verdict_cases(name, label, subcheck):
    got = [verdict(name, PASS=6, FAILED=0, NOT_RUN=", %s" % subcheck),
           verdict(name, PASS=7, FAILED=0, NOT_RUN=""),
           verdict(name, PASS=6, FAILED=1, NOT_RUN=", %s" % subcheck)]
    check(None not in got and [g[0] for g in got] == [2, 0, 1] and "NOT RUN: %s" % subcheck in got[0][1]
          and "all 7 passed" in got[1][1],
          "%s %s's own verdict: a NOT RUN case with nothing failed exits 2 and names it; none exits 0; "
          "a failure still exits 1" % (label, name), got)


def r18_cargo_cache_env_without_a_compiler():
    """R18 (hunt part 2 v2): with no rustc on PATH, cargo-cache-env.test.sh compiled nothing and
    printed SKIP over exit 0, which run-tests.sh records as `passed`. It must exit 2 and say NOT RUN."""
    tmp = tempfile.mkdtemp(prefix="not-run-verdict-r18.", dir=os.environ.get("TMPDIR"))
    try:
        r = subprocess.run(["/bin/bash", os.path.join(HERE, "cargo-cache-env.test.sh")], cwd=tmp,
                           capture_output=True, text=True, env={"HOME": tmp, "PATH": "/usr/bin:/bin"})
        check(r.returncode == 2 and "NOT RUN" in r.stdout,
              "R18 cargo-cache-env.test.sh with no compiler exits 2 and names NOT RUN, never 0",
              (r.returncode, r.stdout, r.stderr))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


SKIP_VERDICT_START = re.compile(r'^if \[ "\$SKIP" -gt 0 \]; then$')


def skip_verdict_cases(name, label):
    """The same rule for a suite that counts skip() cases: from its SKIP branch to the end of the
    file, with SKIP=2 it exits 2 (a skipped case is a case that did not run); with SKIP=0 it exits 0."""
    with open(os.path.join(HERE, name)) as fh:
        lines = fh.read().split("\n")
    start = next((i for i, line in enumerate(lines) if SKIP_VERDICT_START.match(line)), None)
    got = []
    for skipped in (2, 0):
        if start is None:
            got.append(None)
            continue
        script = "set -uo pipefail\nPASS=9\nFAIL=0\nSKIP=%d\n%s\n" % (skipped, "\n".join(lines[start:]))
        got.append(subprocess.run(["bash", "-c", script], capture_output=True, text=True).returncode)
    check(got == [2, 0], "%s %s: skipped cases exit 2 (never a pass); none skipped exits 0" % (label, name), got)


# The suites hunt part 2 finding 18 named, each added with its own fix.
NAMED = [
    "battery-check.test.py",
    "proof-for.test.sh",
    "native-ios-share.test.sh",
    "native-ios-app.test.sh",
    # Not named by the finding; the same shape, found by listing every NOT RUN line in app/scripts.
    "test-results.test.sh",
]


if __name__ == "__main__":
    print("=== not-run-verdict ===")
    v1_battery_check_in_a_shallow_history()
    verdict_cases("native-ios-share.test.sh", "V2", "S5 (the tag is not in this clone)")
    verdict_cases("native-ios-app.test.sh", "V3", "A8 (no test files)")
    r18_cargo_cache_env_without_a_compiler()
    skip_verdict_cases("qa.test.sh", "R18")
    probes()
    static_rule(NAMED)
    every_suite()
    if FAILED:
        print("=== not-run-verdict tests: %d FAILED, %d passed ===" % (FAILED, PASSED))
        sys.exit(1)
    print("=== not-run-verdict tests: all %d passed ===" % PASSED)
