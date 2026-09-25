#!/usr/bin/env python3
"""test_results.py — a failing test is always NAMED, and its result files outlive the next run.

    test_results.py names [--log FILE]... [PATH]...
        The failing tests in PATH (JUnit XML, a directory of it, an .xcresult bundle), one
        `  FAILED TEST  <class> > <test> — <first line of the failure>` line each. A test log
        given with --log is read only when no result file names anything: the result files are
        the ground truth, the log is the fallback (a build that failed before writing any).
    test_results.py report --label L [--into DIR] [--since EPOCH] [--collect NAME=SRC]... [--move NAME=SRC]...
        Copy each SRC (a result folder, a bundle or a log) to DIR/NAME, never over an earlier
        copy, then name every failing test they hold. --move moves instead (a bundle this run
        alone made). Without --into nothing is copied or moved.
    test_results.py run --lock FILE --label L [--into DIR] [--collect NAME=SRC]... -- COMMAND...
        Run COMMAND holding FILE exclusively; when it ends, and BEFORE the lock is released, do
        `report` over what COMMAND wrote (files older than its start are not its results). Exits
        with COMMAND's status.

WHY THIS EXISTS (2026-09-25). A proof run's `native-android-app` failed with "133 tests completed,
1 failed". Its log named no test, only Gradle's report folder in the checkout's build cache
(`<cache>/out/app/reports/tests/testDebugUnitTest/`). By the time anyone opened that folder,
`native-android-ui` (the next Gradle suite in the same run: the same task, the same folder) had
replaced it with 139 tests and 0 failures. The failing test's identity was gone. The CEO:
"are you shitting me?? what now???"

So, three things, all here so no caller carries a second copy:
  * the name is PRINTED where the failure happens, into the log that is kept, the moment the test
    run ends; a log that says "1 failed" and not which is not evidence;
  * the result files are COPIED out of any folder another run can write, into the run's own
    directory (the caller's --into), before anything else can run: `run` holds a lock across the
    test run and the copy, so two test runs never have that folder at the same time;
  * a copy never replaces another copy (NAME, NAME-2, ...).

Printed to stderr: `bin/randroid` keeps stdout for its JSON results.
"""
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

MARK = "  FAILED TEST  "
DETAIL_CHARS = 200


def _first_line(text):
    for text_line in (text or "").splitlines():
        text_line = text_line.strip()
        if text_line:
            return text_line[:DETAIL_CHARS]
    return ""


def _fresh(path, since):
    """True when PATH (a file, or anything under a directory) was written at or after SINCE."""
    if since is None:
        return True
    try:
        if not os.path.isdir(path) or os.path.islink(path):
            return os.lstat(path).st_mtime >= since
        for top, _dirs, files in os.walk(path):
            for f in files:
                try:
                    if os.lstat(os.path.join(top, f)).st_mtime >= since:
                        return True
                except OSError:
                    continue
    except OSError:
        return False
    return False


# ---------------------------------------------------------------------------------------
# readers: each returns a list of (name, detail)
# ---------------------------------------------------------------------------------------
def junit(path):
    """Gradle/JUnit XML: every <testcase> holding a <failure> or an <error>."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        return [("unreadable result file %s" % path, _first_line(str(exc)))]
    found = []
    for case in root.iter("testcase"):
        for kind in ("failure", "error"):
            bad = case.find(kind)
            if bad is not None:
                cls = case.get("classname") or root.get("name") or "?"
                found.append(("%s > %s" % (cls, case.get("name") or "?"),
                              _first_line(bad.get("message") or bad.text or kind)))
                break
    return found


def xcresult(path):
    """An Xcode result bundle, through xcresulttool's summary (its `testFailures`)."""
    tool = os.environ.get("RICHOS_XCRESULTTOOL")
    argv = ([tool] if tool else ["xcrun", "xcresulttool"]) + ["get", "test-results", "summary", "--path", path]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [("unreadable result bundle %s" % path, _first_line(str(exc)))]
    try:
        summary = json.loads(r.stdout)
    except ValueError:
        return [("unreadable result bundle %s" % path, _first_line(r.stderr) or "exit %d" % r.returncode)]
    found = []
    for f in summary.get("testFailures") or []:
        ident = f.get("testIdentifierString") or f.get("testName") or "?"
        suite, _, test = ident.rpartition("/")
        owner = ".".join(p for p in (f.get("targetName"), suite.replace("/", ".")) if p)
        found.append(("%s > %s" % (owner or "?", test), _first_line(f.get("failureText"))))
    failed = summary.get("failedTests") or 0
    if failed and not found:
        found.append(("%d failing test(s) in %s" % (failed, path), "the bundle lists no failure by name"))
    return found


# Test logs, read when no result file names anything.
LOG_PATTERNS = (
    # our own marker, so a log that carries names printed by `report` reads back as the same names
    (re.compile(r"^%s(.+?)(?: — (.*))?$" % re.escape(MARK)), lambda m: (m.group(1), m.group(2) or "")),
    # XCTest: Test Case '-[Module.Class testMethod]' failed (0.01 seconds).
    (re.compile(r"Test Case '-\[([\w.]+) (\w+)\]' failed"), lambda m: ("%s > %s" % (m.group(1), m.group(2)), "")),
    (re.compile(r"Test Case '([\w.]+)\.(\w+)' failed"), lambda m: ("%s > %s" % (m.group(1), m.group(2)), "")),
    # swift-testing: ✘ Test someTest() failed after 0.002 seconds with 1 issue.
    (re.compile(r"✘ Test (.+?) failed"), lambda m: (m.group(1), "")),
    # Gradle's console: dev.richos.X > a test name FAILED
    (re.compile(r"^([\w.$]+) > (.+) FAILED\s*$"), lambda m: ("%s > %s" % (m.group(1), m.group(2)), "")),
)


def log(path):
    found = []
    try:
        with open(path, errors="replace") as fh:
            for text_line in fh:
                text_line = text_line.rstrip("\n")
                for rx, make in LOG_PATTERNS:
                    m = rx.search(text_line)
                    if m:
                        found.append(make(m))
                        break
    except OSError:
        pass
    return found


def results(path, since=None):
    """Every failing test in PATH: a JUnit XML file, an .xcresult bundle, or a directory of
    either (a bundle is never descended into). Files older than SINCE are not read."""
    path = path.rstrip("/")
    if path.endswith(".xcresult"):
        return xcresult(path) if _fresh(path, since) else []
    if os.path.isfile(path):
        return junit(path) if path.endswith(".xml") and _fresh(path, since) else []
    found = []
    for top, dirs, files in os.walk(path):
        for d in [d for d in dirs if d.endswith(".xcresult")]:
            dirs.remove(d)
            if _fresh(os.path.join(top, d), since):
                found += xcresult(os.path.join(top, d))
        dirs.sort()
        for f in sorted(files):
            full = os.path.join(top, f)
            if f.endswith(".xml") and _fresh(full, since):
                found += junit(full)
    return found


PROBLEMS = ("unreadable result ",)


def names(paths, logs=(), since=None):
    found = []
    for p in paths:
        if os.path.exists(p):
            found += results(p, since)
    # A result file that could not be read (a shard that crashed before its bundle was closed)
    # names nothing, so the logs are still read; the unreadable file is still reported.
    problems = [f for f in found if f[0].startswith(PROBLEMS)]
    found = [f for f in found if not f[0].startswith(PROBLEMS)]
    if not found:
        for p in logs:
            found += log(p)
    seen, unique = set(), []
    for name, detail in found + problems:
        if name not in seen:
            seen.add(name)
            unique.append((name, detail))
    return unique


def line(name, detail):
    return MARK + name + (" — " + detail if detail else "")


# ---------------------------------------------------------------------------------------
# copies
# ---------------------------------------------------------------------------------------
def keep(into, name, src, move=False):
    """Copy SRC to INTO/NAME, or INTO/NAME-2, ...: never over an earlier copy. Returns the path.
    MOVE moves it instead: for a result this run alone made and nothing else will read (an
    Xcode bundle of 50 to 150 MB), so the evidence is not held twice."""
    os.makedirs(into, exist_ok=True)
    dest, n = os.path.join(into, name), 1
    while os.path.lexists(dest):
        n += 1
        dest = os.path.join(into, "%s-%d" % (name, n))
    if move:
        shutil.move(src, dest)
    elif os.path.isdir(src) and not os.path.islink(src):
        shutil.copytree(src, dest, symlinks=True)
    else:
        shutil.copy2(src, dest, follow_symlinks=False)
    return dest


def parse_collect(values, move=False):
    out = []
    for v in values:
        name, sep, src = v.partition("=")
        if not sep or not name or not src or "/" in name:
            raise SystemExit("test_results.py: --collect/--move take NAME=PATH (NAME without a slash), got %r" % v)
        out.append((name, src, move))
    return out


def report(label, collect, into=None, since=None, rc=None, stream=None):
    """Copy (or move) what the run wrote, then name its failing tests. COLLECT is a list of
    (name, path, move). Returns the named failures."""
    stream = stream or sys.stderr
    kept, sources, logs = [], [], []
    for entry in collect:
        name, src, move = entry if len(entry) == 3 else (entry[0], entry[1], False)
        if not os.path.lexists(src) or not _fresh(src, since):
            continue
        is_log = os.path.isfile(src) and not src.endswith(".xml")
        where = src
        if into:
            try:
                where = keep(into, name, src, move)
                kept.append(where)
            except OSError as exc:
                print("%s: could NOT copy %s to %s: %s" % (label, src, into, exc), file=stream, flush=True)
        (logs if is_log else sources).append(where)
    failing = names(sources, logs)
    if failing:
        print("%s: %d failing test(s):" % (label, len(failing)), file=stream)
        for name, detail in failing:
            print(line(name, detail), file=stream)
    elif rc not in (None, 0):
        print("%s: exited %d, and no result file or log it wrote names a failing test (a build or"
              " setup failure rather than a test; the output above says which)" % (label, rc), file=stream)
    if kept and (failing or rc not in (None, 0)):
        print("%s: per-test results kept at %s" % (label, into), file=stream)
    stream.flush()
    return failing


# ---------------------------------------------------------------------------------------
# run: the lock, the command, the copy, in that order, one holder at a time
# ---------------------------------------------------------------------------------------
def run(lock_path, label, collect, into, command):
    os.makedirs(os.path.dirname(os.path.abspath(lock_path)), exist_ok=True)
    lock = open(lock_path, "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("%s: waiting for another test run of this build folder to finish (%s)" % (label, lock_path),
              file=sys.stderr, flush=True)
        waited = time.monotonic()
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("%s: waited %.0f s" % (label, time.monotonic() - waited), file=sys.stderr, flush=True)
    # One second of slack: some filesystems keep whole-second modification times.
    since = time.time() - 1
    try:
        child = subprocess.Popen(command)
    except OSError as exc:
        print("%s: could not start %s: %s" % (label, command[0], exc), file=sys.stderr, flush=True)
        return 127

    def forward(signum, _frame):
        # A caller stops this run with a signal: the test run is stopped with it, and what it
        # wrote is still copied and named below.
        try:
            child.send_signal(signum)
        except OSError:
            pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    rc = child.wait()
    report(label, collect, into, since, rc)
    lock.close()
    return rc


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    command = []
    if "--" in rest:
        i = rest.index("--")
        rest, command = rest[:i], rest[i + 1:]
    opts = {"--log": [], "--collect": [], "--move": [], "--into": None, "--label": None, "--lock": None,
            "--since": None}
    paths = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in opts:
            if i + 1 >= len(rest):
                raise SystemExit("test_results.py: %s needs a value" % a)
            if isinstance(opts[a], list):
                opts[a].append(rest[i + 1])
            else:
                opts[a] = rest[i + 1]
            i += 2
        elif a.startswith("--"):
            raise SystemExit("test_results.py: unknown option %s" % a)
        else:
            paths.append(a)
            i += 1
    if cmd == "names":
        for name, detail in names(paths, opts["--log"]):
            print(line(name, detail))
        return 0
    label = opts["--label"] or "tests"
    collect = parse_collect(opts["--collect"]) + parse_collect(opts["--move"], move=True)
    into = opts["--into"] or None
    if cmd == "report":
        since = float(opts["--since"]) if opts["--since"] else None
        report(label, collect, into, since)
        return 0
    if cmd == "run":
        if not opts["--lock"] or not command:
            raise SystemExit("test_results.py: run needs --lock FILE and -- COMMAND")
        return run(opts["--lock"], label, collect, into, command)
    raise SystemExit("test_results.py: unknown command %r (names, report, run)" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
