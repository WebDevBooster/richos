#!/usr/bin/env python3
"""ios_ui_shards.py — the split and the proof for native-ios-ui.test.sh's sharded simulator run.

    ios_ui_shards.py split <work> <shards> <times.tsv> <-only-testing selectors...>
        <work>/tests.json (xcodebuild -enumerate-tests, flat JSON) -> <work>/shard-N.args, one
        `-only-testing:<id>` per line, and <work>/expected.txt, the whole list. Balanced by the
        seconds each test cost last time (<times.tsv>), longest first; by count when unknown.
        With one shard, the selectors pass through unchanged and nothing is enumerated.
    ios_ui_shards.py verify <work> <shards> <times.tsv> <device>...
        For every device (shards consecutive in <work>/result-<i>.xcresult): every shard exited
        0, and the tests the bundles report are EXACTLY the listed tests. Prints the counts and
        each skip with its reason; records per-test seconds in <times.tsv>. Exit 1 on any gap.
    ios_ui_shards.py name-shots <exported-dir> <out-dir>
        Renames exported attachments after their screen, as the unsplit suite always did.
    ios_ui_shards.py selftest
        The split and the proof against fixtures, no simulator (native-ios-ui --headless runs it).

WHY THE PROOF IS BY NAME. Splitting a list is where a test goes missing without anything going
red: a selector that matched nothing, a shard that died before its bundle was written, an
identifier spelled one way by the enumeration and another by the result bundle. So the proof is
not "every shard exited 0" — it is "the set of tests that ran equals the set that exists".
"""
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile


def norm(ident):
    """`RichOSNativeUITests/ScreenshotTests/testX()` and `.../testX` are one test."""
    return ident[:-2] if ident.endswith("()") else ident


def enumerated(tests_json):
    data = json.load(open(tests_json))
    if data.get("errors"):
        raise ValueError("xcodebuild reported errors while listing the tests: %s" % data["errors"])
    ids = []
    for plan in data.get("values", []):
        for target in plan.get("enabledTests", []):
            ids.append(target["identifier"])
    return sorted(set(ids))


def read_times(path):
    cost = {}
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("\t")
            try:
                cost[norm(k)] = float(v)
            except ValueError:
                pass
    except OSError:
        pass
    return cost


def split(ids, shards, cost):
    default = (sum(cost.values()) / len(cost)) if cost else 1.0
    load = [0.0] * shards
    bins = [[] for _ in range(shards)]
    for t in sorted(ids, key=lambda i: (-cost.get(norm(i), default), i)):
        j = load.index(min(load))
        bins[j].append(t)
        load[j] += cost.get(norm(t), default)
    return bins, load


def cmd_split(work, shards, times, select):
    shards = int(shards)
    if shards == 1:
        open(os.path.join(work, "shard-1.args"), "w").write("".join(a + "\n" for a in select))
        open(os.path.join(work, "expected.txt"), "w").write("")
        return 0
    try:
        ids = enumerated(os.path.join(work, "tests.json"))
    except (OSError, ValueError, KeyError) as exc:
        print("native-ios-ui: the test list could not be read: %s" % exc)
        return 1
    if not ids:
        print("native-ios-ui: xcodebuild listed no tests; refusing to call that green")
        return 1
    if len(ids) < shards:
        # An empty shard would run xcodebuild with no selector at all, which is EVERY test.
        print("native-ios-ui: %d tests for %d simulators per device; set RICHOS_IOS_UI_SHARDS lower" % (len(ids), shards))
        return 1
    bins, load = split(ids, shards, read_times(times))
    for j, b in enumerate(bins, 1):
        open(os.path.join(work, "shard-%d.args" % j), "w").write("".join("-only-testing:%s\n" % t for t in b))
    open(os.path.join(work, "expected.txt"), "w").write("".join(i + "\n" for i in ids))
    print("native-ios-ui: %d tests per device, split %s" % (
        len(ids), " / ".join("%d (~%.0f s)" % (len(b), l) for b, l in zip(bins, load))))
    return 0


def result_tests(bundle, runner=subprocess.run):
    """(counts, [(identifier, result, seconds, skip-reason)]) from one result bundle."""
    def get(kind):
        result = runner(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", bundle],
                        capture_output=True, text=True)
        if getattr(result, "returncode", 0):
            raise ValueError("xcresulttool failed reading " + kind)
        return json.loads(result.stdout)
    summ = get("summary")
    counts = {k: int(summ.get(key) or 0) for k, key in (("passed", "passedTests"), ("failed", "failedTests"),
                                                          ("skipped", "skippedTests"), ("total", "totalTestCount"))}
    rows = []
    kinds = {}

    def walk(n, bundle_name):
        kind = n.get("nodeType", "")
        if kind in ("Unit test bundle", "UI test bundle"):
            bundle_name = n.get("name", "")
            kinds[bundle_name] = kind
        if kind == "Test Case":
            ident = n.get("nodeIdentifier") or n.get("name", "")
            reason = ""
            if n.get("result") == "Skipped":
                reason = next((c.get("name", "") for c in n.get("children", [])
                               if "Skip" in c.get("nodeType", "") or c.get("nodeType") == "Failure Message"), "")
            rows.append((norm("%s/%s" % (bundle_name, ident)), n.get("result"), n.get("durationInSeconds"), reason))
            return
        for c in n.get("children", []):
            walk(c, bundle_name)
    for n in get("tests").get("testNodes", []):
        walk(n, "")
    result_tests.kinds = kinds
    return counts, rows


STAMP_ATTACHMENT = "richos-build-stamp"


def stamps(bundle, out, runner=subprocess.run):
    """{"Class/test()": stamp} from one result bundle's exported attachments.

    TestSupport/BuildStamp.swift attaches the stamp its bundle was built with to every test."""
    os.makedirs(out, exist_ok=True)
    result = runner(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", out],
                    capture_output=True, text=True)
    if getattr(result, "returncode", 0):
        raise ValueError("xcresulttool could not export attachments")
    found = {}
    for test in json.load(open(os.path.join(out, "manifest.json"))):
        for a in test.get("attachments", []):
            if a.get("suggestedHumanReadableName", "").startswith(STAMP_ATTACHMENT):
                with open(os.path.join(out, a["exportedFileName"])) as fh:
                    found[norm(test["testIdentifier"])] = fh.read().strip()
    return found


def cmd_verify(work, shards, times, devices, runner=subprocess.run):
    """0 every device green; 1 any failure; 2 a device NOT RUN (its lease ended) and no failure."""
    shards = int(shards)
    expected = sorted(set(norm(l) for l in open(os.path.join(work, "expected.txt")).read().split("\n") if l))
    try:
        build_stamp = open(os.path.join(work, "build-stamp.txt")).read().strip()
    except OSError:
        build_stamp = ""
    status, seconds = 0, {}
    for d, device in enumerate(devices):
        counts = {"passed": 0, "failed": 0, "skipped": 0, "total": 0}
        ran, walls, bad, lost = [], [], [], []
        for s in range(shards):
            i = d * shards + s

            def read(name, default):
                try:
                    return open(os.path.join(work, name)).read().strip() or default
                except OSError:
                    return default
            # A run whose lease ended was stopped by run-active: whatever its bundle holds may
            # be another run's device's doing, so it is NOT RUN, never read as a result.
            if os.path.exists(os.path.join(work, "test-%d.lost" % i)):
                try:
                    why = json.load(open(os.path.join(work, "test-%d.lost" % i))).get("why", "")
                except (OSError, ValueError):
                    why = "unreadable record"
                lost.append("simulator %d of %d: its lease ended mid-run (%s); the run was stopped" % (s + 1, shards, why))
                walls.append(int(read("test-%d.secs" % i, "0")))
                continue
            rc = read("test-%d.rc" % i, "no exit status")
            walls.append(int(read("test-%d.secs" % i, "0")))
            if rc != "0":
                bad.append("simulator %d of %d exited %s" % (s + 1, shards, rc))
            try:
                c, rows = result_tests(os.path.join(work, "result-%d.xcresult" % i), runner)
            except (ValueError, OSError):
                bad.append("simulator %d of %d left no readable result bundle" % (s + 1, shards))
                continue
            if c["failed"] or any(result not in ("Passed", "Skipped") for _, result, _, _ in rows):
                bad.append("simulator %d reports a failed or unknown test result" % (s + 1))
            if c["total"] != len(rows) or c["passed"] + c["failed"] + c["skipped"] != c["total"]:
                bad.append("simulator %d has inconsistent result counts" % (s + 1))
            if build_stamp:
                # ATTRIBUTION: every test that ran must carry THIS run's build stamp. A test
                # without it, or with another build's, came from a bundle this run did not build.
                try:
                    got_stamps = stamps(os.path.join(work, "result-%d.xcresult" % i),
                                        os.path.join(work, "attribution-%d" % i), runner)
                except (ValueError, OSError, KeyError) as exc:
                    got_stamps = None
                    bad.append("simulator %d: its tests' build stamps could not be read (%s)" % (s + 1, exc))
                if got_stamps is not None:
                    # Every XCTest in a UI test bundle carries the stamp itself. A bundle of Swift
                    # Testing tests (which never pass through XCTestCase) is proven by its stamped
                    # BuildStampTests probe. No test anywhere may carry another build's stamp.
                    kinds = getattr(result_tests, "kinds", {})
                    foreign, proven, ran_bundles = [], set(), set()
                    for ident, result, _, _ in rows:
                        if result == "Skipped":
                            continue
                        bundle, _, key = ident.partition("/")
                        ran_bundles.add(bundle)
                        got = got_stamps.get(key)
                        if got == build_stamp:
                            proven.add(bundle)
                        elif got is not None or kinds.get(bundle) == "UI test bundle":
                            foreign.append("%s (%s)" % (key, got or "no stamp"))
                    unproven = sorted(ran_bundles - proven)
                    if foreign:
                        bad.append("simulator %d ran %d test(s) NOT from this run's build %s: %s" % (
                            s + 1, len(foreign), build_stamp, ", ".join(foreign[:4])))
                    if unproven:
                        bad.append("simulator %d: no test in %s carries this run's build stamp %s, so nothing "
                                   "proves which build ran it" % (s + 1, ", ".join(unproven), build_stamp))
            for k in counts:
                counts[k] += c[k]
            for ident, result, dur, reason in rows:
                ran.append(ident)
                if result == "Skipped":
                    print("        skipped: %s  %s" % (ident.rsplit("/", 1)[-1], reason))
                if dur is not None:
                    seconds[ident] = float(dur)
        if expected:
            got = sorted(set(ran))
            if got != expected or len(ran) != len(set(ran)):
                missing = sorted(set(expected) - set(got))
                extra = sorted(set(got) - set(expected))
                twice = sorted({r for r in ran if ran.count(r) > 1})
                bad.append("the simulators ran %d of the %d listed tests; missing: %s%s%s" % (
                    len(set(expected) & set(got)), len(expected), ", ".join(missing[:6]) or "none",
                    "; not listed: " + ", ".join(extra[:6]) if extra else "",
                    "; ran twice: " + ", ".join(twice[:6]) if twice else ""))
        elif counts["total"] == 0 and not lost:
            bad.append("no test ran")
        if lost and not bad:
            print("  NOT RUN  %s: its simulator lease ended mid-run, so this device has no result" % device)
            for b in lost:
                print("        %s" % b)
            status = status or 2
            continue
        bad = lost + bad
        line = "%s: UI tests %s in %d s on %d simulator(s)" % (device, "FAILED" if bad else "passed", max(walls or [0]), shards)
        print(("  FAIL  " if bad else "  ok    ") + line)
        print("        %d passed, %d failed, %d skipped of %d" % (counts["passed"], counts["failed"], counts["skipped"], counts["total"]))
        for b in bad:
            print("        %s" % b)
        if bad:
            status = 1
    if seconds:
        old = read_times(times)
        old.update(seconds)
        with open(times, "w") as fh:
            for k in sorted(old):
                fh.write("%s\t%.1f\n" % (k, old[k]))
    return status


def cmd_name_shots(src, out):
    m = os.path.join(src, "manifest.json")
    if not os.path.exists(m):
        return 0
    for test in json.load(open(m)):
        for a in test.get("attachments", []):
            if a.get("suggestedHumanReadableName", "").startswith(STAMP_ATTACHMENT):
                continue                  # attribution, not a screen
            path = os.path.join(src, a["exportedFileName"])
            name = re.sub(r"_\d+_[0-9A-F-]+(\.\w+)$", r"\1", a["suggestedHumanReadableName"])
            if a.get("isAssociatedWithFailure"):
                name = "FAILED-" + test["testIdentifier"].replace("/", "-").replace("()", "") + "-" + name
            if os.path.exists(path):
                os.replace(path, os.path.join(out, name))
    return 0


def selftest():
    ok = bad = 0

    def check(cond, what):
        nonlocal ok, bad
        if cond:
            ok += 1
            print("  ok    shards: %s" % what, file=sys.stderr)
        else:
            bad += 1
            print("  FAIL  shards: %s" % what, file=sys.stderr)
    ids = ["B/C/t%d" % n for n in range(7)] + ["U/S/u()"]
    bins, load = split(ids, 2, {"B/C/t0": 30, "B/C/t1": 20, "B/C/t2": 10})
    flat = [t for b in bins for t in b]
    check(sorted(flat) == sorted(ids) and len(flat) == len(ids), "every listed test is in exactly one shard")
    check(abs(load[0] - load[1]) <= 30, "the split is balanced by recorded seconds (%s)" % load)
    # The fixture's own verdict lines are captured, not printed: a fixture device printing
    # "  FAIL  " would read, to run-tests.sh and to a person, as a failed case of this suite.
    quiet = contextlib.redirect_stdout(io.StringIO())
    with tempfile.TemporaryDirectory() as work, quiet:
        json.dump({"values": [{"enabledTests": [{"identifier": i} for i in ids]}]}, open(os.path.join(work, "tests.json"), "w"))
        rc = cmd_split(work, 3, os.path.join(work, "none.tsv"), ["-only-testing:B"])
        args = sorted(l for n in (1, 2, 3) for l in open(os.path.join(work, "shard-%d.args" % n)).read().split("\n") if l)
        check(rc == 0 and args == sorted("-only-testing:" + i for i in ids), "three shard files hold the whole list once")
        # Fake result bundles: device 0 complete, device 1 missing one test.
        bundles = {}
        for i, (dev, shard) in enumerate([(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]):
            names = [l.split(":", 1)[1] for l in open(os.path.join(work, "shard-%d.args" % (shard + 1))).read().split("\n") if l]
            if dev == 1 and shard == 2:
                names = names[1:]
            bundles[os.path.join(work, "result-%d.xcresult" % i)] = names
            open(os.path.join(work, "test-%d.rc" % i), "w").write("0")
            open(os.path.join(work, "test-%d.secs" % i), "w").write("5")

        class R:
            def __init__(self, out):
                self.stdout = out

        def runner(argv, **_kw):
            names = bundles[argv[-1]]
            if argv[4] == "summary":
                return R(json.dumps({"passedTests": len(names), "failedTests": 0, "skippedTests": 0, "totalTestCount": len(names)}))
            by_bundle = {}
            for n in names:
                b, rest = n.split("/", 1)
                by_bundle.setdefault(b, []).append({"nodeType": "Test Case", "nodeIdentifier": rest + ("" if rest.endswith("()") else "()"),
                                                    "result": "Passed", "durationInSeconds": 1.0})
            return R(json.dumps({"testNodes": [{"nodeType": "Test Plan", "children": [
                {"nodeType": "UI test bundle", "name": b, "children": [{"nodeType": "Test Suite", "children": c}]}
                for b, c in by_bundle.items()]}]}))
        rc = cmd_verify(work, 3, os.path.join(work, "t.tsv"), ["complete", "short"], runner)
        check(rc == 1, "a device whose simulators ran one test fewer than listed is a FAILURE")
        del bundles[os.path.join(work, "result-5.xcresult")]
        bundles[os.path.join(work, "result-5.xcresult")] = [l.split(":", 1)[1] for l in open(os.path.join(work, "shard-3.args")).read().split("\n") if l]
        rc = cmd_verify(work, 3, os.path.join(work, "t.tsv"), ["complete", "complete-too"], runner)
        check(rc == 0, "and with every listed test reported, both devices pass")
        def failed_summary(argv, **kwargs):
            result = runner(argv, **kwargs)
            if argv[4] == "summary":
                data = json.loads(result.stdout)
                data["failedTests"] = 1
                data["passedTests"] -= 1
                result.stdout = json.dumps(data)
            return result
        check(cmd_verify(work, 3, os.path.join(work, "t.tsv"), ["failed-results"], failed_summary) == 1,
              "a failed result bundle cannot be green even when xcodebuild exits zero")
        open(os.path.join(work, "test-4.rc"), "w").write("65")
        rc = cmd_verify(work, 3, os.path.join(work, "t.tsv"), ["complete", "a-shard-exited-65"], runner)
        check(rc == 1, "a simulator whose xcodebuild exited non-zero fails its device even if its bundle looks whole")
    # ATTRIBUTION AND THE LOST LEASE (esc-20260925T014934Z-0a4bf206), one device per case.
    with tempfile.TemporaryDirectory() as work, contextlib.redirect_stdout(io.StringIO()) as said:
        open(os.path.join(work, "expected.txt"), "w").write("")
        open(os.path.join(work, "build-stamp.txt"), "w").write("key-abc123-run.OWN\n")
        results = {}                      # bundle -> [(Class/test(), result, stamp or None)]

        class R:
            def __init__(self, out):
                self.stdout, self.returncode = out, 0

        def runner(argv, **_kw):
            if argv[2] == "export":
                bundle, out = argv[argv.index("--path") + 1], argv[argv.index("--output-path") + 1]
                manifest = []
                for n, (ident, _res, stamp) in enumerate(results[bundle]):
                    if stamp is not None:
                        open(os.path.join(out, "s%d.txt" % n), "w").write(stamp)
                        manifest.append({"testIdentifier": ident, "attachments": [
                            {"exportedFileName": "s%d.txt" % n,
                             "suggestedHumanReadableName": STAMP_ATTACHMENT + "_0_AB-CD.txt"}]})
                json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"))
                return R("")
            rows = results[argv[-1]]
            if argv[4] == "summary":
                return R(json.dumps({"passedTests": sum(r == "Passed" for _, r, _ in rows), "failedTests": 0,
                                     "skippedTests": sum(r == "Skipped" for _, r, _ in rows), "totalTestCount": len(rows)}))
            kind = "Unit test bundle" if any(i.startswith("Unit.") for i, _, _ in rows) else "UI test bundle"
            return R(json.dumps({"testNodes": [{"nodeType": kind, "name": "U", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": i, "result": r, "durationInSeconds": 1.0} for i, r, _ in rows]}]}))

        def case(rows, lost=False):
            bundle = os.path.join(work, "result-0.xcresult")
            results[bundle] = rows
            open(os.path.join(work, "test-0.rc"), "w").write("75" if lost else "0")
            open(os.path.join(work, "test-0.secs"), "w").write("5")
            lost_file = os.path.join(work, "test-0.lost")
            if lost:
                json.dump({"why": "the device now belongs to another run"}, open(lost_file, "w"))
            elif os.path.exists(lost_file):
                os.unlink(lost_file)
            return cmd_verify(work, 1, os.path.join(work, "t.tsv"), ["device"], runner)
        own = "key-abc123-run.OWN"
        rc_own = case([("C/a()", "Passed", own), ("C/b()", "Passed", own), ("C/skip()", "Skipped", None)])
        rc_foreign = case([("C/a()", "Passed", own), ("C/onlyOnTheOtherBranch()", "Passed", "key-def456-run.OTHER")])
        foreign_said = said.getvalue()
        before = len(said.getvalue())
        rc_unstamped = case([("C/a()", "Passed", own), ("C/b()", "Passed", None)])
        said_unstamped = said.getvalue()[before:]
        # The handover itself: the bundle LOOKS whole and green, but the lease was lost mid-run.
        rc_lost = case([("C/a()", "Passed", own), ("C/onlyOnTheOtherBranch()", "Passed", "key-def456-run.OTHER")], lost=True)
        lost_said = said.getvalue()
        # A Swift Testing bundle: its tests carry no stamp of their own; its probe does.
        rc_unit_probe = case([("Unit.S/swiftTesting()", "Passed", None), ("BuildStampTests/probe()", "Passed", own)])
        before = len(said.getvalue())
        rc_unit_bare = case([("Unit.S/swiftTesting()", "Passed", None), ("Unit.S/other()", "Passed", None)])
        said_bare = said.getvalue()[before:]
    check(rc_unit_probe == 0, "a Swift Testing bundle is proven by its stamped probe test")
    check(rc_unit_bare == 1 and "nothing proves which build ran it" in said_bare,
          "a bundle with no stamped test at all is a FAILURE")
    check(rc_own == 0, "every test that ran carries this run's build stamp: green")
    check(rc_foreign == 1 and "ran 1 test(s) NOT from this run's build" in foreign_said
          and "onlyOnTheOtherBranch (key-def456-run.OTHER)" in foreign_said,
          "a test stamped by another checkout's build is a FAILURE, named")
    check(rc_unstamped == 1 and "C/b (no stamp)" in said_unstamped,
          "a test that carries no stamp is a FAILURE: nothing proves whose bundle ran it")
    check(rc_lost == 2 and "NOT RUN" in lost_said.split("onlyOnTheOtherBranch")[-1],
          "a run whose lease was lost is NOT RUN (exit 2) even when its bundle looks green")
    print("  shards selftest: %d passed, %d failed" % (ok, bad))
    return 1 if bad else 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "split":
        return cmd_split(rest[0], rest[1], rest[2], rest[3:])
    if cmd == "verify":
        return cmd_verify(rest[0], rest[1], rest[2], rest[3:])
    if cmd == "name-shots":
        return cmd_name_shots(rest[0], rest[1])
    if cmd == "selftest":
        return selftest()
    print("ios_ui_shards.py: unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
