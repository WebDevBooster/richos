#!/usr/bin/env python3
"""perf.py — repeatable RichConnect speed and battery measurement, one record per run.

    perf.py android --adb ADB --serial SERIAL --kind emulator --owned-by randroid --stamp FILE [options]
    perf.py ios (--simulator UDID | --device UDID | --reparse DIR) --stamp FILE [options]   (see README)
    perf.py stamp --artifact FILE --checkout DIR --paths P [P ...]     identity of a build, as JSON
    perf.py check RECORD.json [...]                                     a record's structural promises
    perf.py budgets                                                      the PRD §7 budgets this compares to
    perf.py merge PART.json PART.json [--out FILE]                      one record from a run split across boots
    perf.py compare RECORD.json [RECORD.json] [--benchmark FILE] [--json]
                                    cold launch and warm resume p95 against the start times already
                                    achieved (benchmarks.json); two records of one build (an iOS cold
                                    series and its warm series) are judged as one
    perf.py benchmark-update RECORD.json... [--benchmark FILE] [--allow-slower REASON] [--condition-declaration F]
                                    the only way a benchmark number changes; commit the file after
    perf.py declare-condition RECORD.json... --fixture F --rows N --mac M --build B --seeded-by S
                                    --evidence E --declared-by NAME [--out FILE]
                                    the condition of records measured before records named one, computed
                                    from the fixture and checked against each record

On Android use it through `randroid emu perf [options]`, which supplies the adb, the serial it
recorded and the stamp of the APK it installed; a physical phone is named explicitly with
`--kind physical --serial <serial>` and is checked to be one.

Every record names its condition (condition.py): the seeded made-up conversation (fixture, rows,
SHA-256), the Mac's state and the build type. `android` seeds that conversation by default
(--conversation fixture; a release build through --seed-twin); `ios` seeds the same conversation
on a simulator by default (`rios perf-seed`, the app's own core writing its saved state) and
refuses an iPhone until its path exists, where --conversation as-installed is never compared. Every record `android`, `ios`
and `merge` write is also compared with benchmarks.json, but only with a benchmark taken under the
same condition; anything else is NOT COMPARED ("different conditions"). The result is the record's
`benchmark`, and a slower build's `acceptance` reads REFUSED.

Exit 0 a record was written; 1 a phase failed (the record still says which and why); 2 usage;
3 REFUSED: the installed build is not the stamped one, the stamp is not the expected commit, or
the device is not the kind named; 4 the record was written and a p95 is SLOWER than the established
benchmark by more than the measured noise. `compare`: 0 nothing slower and at least one metric
compared, 4 slower, 5 nothing could be compared (no verdict). The record goes to --out (default: stdout). It is the measurement
PRD §9 step 1 asks for (private record: richos-hq/docs/prds/2026-09-24-richconnect-perceived-speed-and-no-annoyance.md);
see README.md beside this file for every method and every budget it cannot measure yet.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import benchmark  # noqa: E402
import condition  # noqa: E402
import perfcore  # noqa: E402
import test_copy  # noqa: E402
from perfcore import Refused, Unmeasurable  # noqa: E402

AS_INSTALLED = condition.AS_INSTALLED

EXIT_SLOWER = 4
EXIT_NOT_RESTORED = 6


class RestoreFailed(Exception):
    """The run could not put the phone's build and saved app data back; the saved copy is kept."""

    def __init__(self, problems):
        super().__init__("; ".join(problems))
        self.problems = problems


def not_restored_line(problems):
    return ("SAVED STATE NOT RESTORED: the phone is NOT as the run found it (" + "; ".join(problems) +
            "). Do not trust the app's pairing or conversation on this phone until it is put back.")
EXIT_NOT_COMPARED = 5

REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def host_sampler():
    """The Mac's CPU while an emulator or simulator runs on it (its timings depend on it)."""
    path = os.path.join(REPO, "richos", "app", "scripts", "testvm", "reserve.py")
    try:
        spec = importlib.util.spec_from_file_location("richos_reserve", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:  # noqa: BLE001 — any failure means "not sampled", said in the record
        return lambda: {"unavailable": f"{type(e).__name__}: {e}"}

    def sample():
        try:
            s = mod.host_sample(0.5)
            return {"cpuBusyPercent": round(100.0 - s["cpu_idle_percent"], 1), "memoryPressure": s["memory_pressure"]}
        except Exception as e:  # noqa: BLE001
            return {"unavailable": f"{type(e).__name__}: {e}"}
    return sample


# ------------------------------------------------------------------------------------------------
# stamp and check
# ------------------------------------------------------------------------------------------------

def cmd_stamp(args):
    ident = perfcore.source_identity(args.checkout, args.paths)
    digest = perfcore.tree_sha256(args.artifact) if os.path.isdir(args.artifact) else sha256_file(args.artifact)
    out = {"artifact": os.path.abspath(args.artifact), "sha256": digest, "commit": ident["commit"],
           "dirty": ident["dirty"], "paths": ident["paths"], "stampedAt": now_iso()}
    print(json.dumps(out, indent=2))
    return 0


def cmd_check(args):
    bad = 0
    for path in args.records:
        with open(path) as f:
            problems = perfcore.check_record(json.load(f))
        for p in problems:
            print(f"{path}: {p}")
        bad += bool(problems)
    if not bad:
        print(f"{len(args.records)} record(s) sound")
    return 1 if bad else 0


def merge_records(parts):
    """One record from runs split across emulator boots (`--only`): the same platform, build bytes,
    commit and device model, each phase measured in exactly one part. A phase one part could not
    run and another measured is the other's; `parts` keeps each run's own times and phases."""
    if len(parts) < 2:
        raise Refused("merge needs at least two records")
    first = parts[0]
    for r in parts[1:]:
        for key in ("platform",):
            if r.get(key) != first.get(key):
                raise Refused(f"cannot merge: {key} {r.get(key)} is not {first.get(key)}")
        # The build is its bytes: parts stamped at different commits merge only when the installed
        # APK is byte-identical and neither stamp saw uncommitted changes to its sources.
        for key in ("installedSha256", "builtSha256"):
            if (r.get("build") or {}).get(key) != (first.get("build") or {}).get(key):
                raise Refused(f"cannot merge: build {key} differs ({(r.get('build') or {}).get(key)} vs {(first.get('build') or {}).get(key)})")
        if (r.get("build") or {}).get("dirty") or (first.get("build") or {}).get("dirty"):
            raise Refused("cannot merge: a part was built from uncommitted changes")
        for key in ("kind", "model", "os"):
            if (r.get("device") or {}).get(key) != (first.get("device") or {}).get(key):
                raise Refused(f"cannot merge: device {key} differs")
        if not condition.same(r.get("condition"), first.get("condition")):
            raise Refused(f"cannot merge: the parts were measured under {condition.DIFFERENT}")
    merged = json.loads(json.dumps(first))
    merged["metrics"], merged["phases"], merged["notMeasured"], merged["parts"] = {}, {}, [], []
    measured = set()
    for r in parts:
        for name, state in r.get("phases", {}).items():
            if state == "measured":
                if name in measured and name != "seed":
                    raise Refused(f"cannot merge: phase {name} was measured in two parts")
                measured.add(name)
    for i, r in enumerate(parts, 1):
        for name, m in r.get("metrics", {}).items():
            have = merged["metrics"].get(name)
            if have is not None and "screens" in have and "screens" in m:
                # idle frames are per screen: parts may measure different screens, never the same one twice
                for screen, value in m["screens"].items():
                    if screen in have["screens"]:
                        raise Refused(f"cannot merge: idle frames on {screen} were measured in two parts")
                    have["screens"][screen] = dict(value, part=i)
                have["zeroFrames"] = all(v["framesRendered"] == 0 for v in have["screens"].values())
                continue
            if have is not None:
                raise Refused(f"cannot merge: metric {name} appears in two parts")
            m = dict(m, part=i)
            if "screens" in m:
                m["screens"] = {k: dict(v, part=i) for k, v in m["screens"].items()}
            merged["metrics"][name] = m
        for name, state in r.get("phases", {}).items():
            if state == "measured" or name not in measured:
                merged["phases"][name] = state if state != "measured" else f"measured (part {i})"
        for entry in r.get("notMeasured", []):
            if entry.get("what") not in measured and entry not in merged["notMeasured"]:
                merged["notMeasured"].append(entry)
        merged["parts"].append({"part": i, "tool": r.get("tool"), "build": {k: (r.get("build") or {}).get(k) for k in ("commit", "dirty")},
                                "startedAt": r.get("startedAt"), "finishedAt": r.get("finishedAt"),
                                "phases": r.get("phases"), "host": (r.get("device") or {}).get("host"),
                                "conditions": r.get("conditions")})
    checks = [r["condition"]["verified"] for r in parts if (r.get("condition") or {}).get("verified")]
    if checks:  # the part whose cold series checked the screen; a failed check in any part stands
        merged["condition"]["verified"] = next((c for c in checks if c.get("onScreen") is False), checks[0])
    merged["device"].pop("host", None)
    merged["build"]["commits"] = sorted({(r.get("build") or {}).get("commit") for r in parts})
    merged["startedAt"] = min(r.get("startedAt", "") for r in parts)
    merged["finishedAt"] = max(r.get("finishedAt", "") for r in parts)
    cold = (merged["metrics"].get("coldLaunch") or {}).get("samplesMs") or []
    merged["acceptance"] = perfcore.acceptance(merged["device"]["kind"], not merged["build"].get("debuggable"), len(cold))
    return merged


def cmd_merge(args):
    parts = []
    for path in args.records:
        with open(path) as f:
            parts.append(json.load(f))
    merged = merge_records(parts)
    slower = judge(merged, args.benchmark)
    problems = perfcore.check_record(merged)
    if problems:
        merged["recordProblems"] = problems
    emit(merged, args.out)
    return EXIT_SLOWER if slower else 1 if problems else 0


def judge(record, bench_path=None, log=None):
    """Compare a record just written with the established benchmark: the result goes into the
    record as `benchmark`, every metric is printed, and a slower build's acceptance reads REFUSED.
    Returns True when a p95 is slower than the benchmark by more than the noise allowance."""
    log = log or (lambda s: print(s, file=sys.stderr, flush=True))
    try:
        result = benchmark.compare([record], benchmark.load(bench_path), bench_path)
    except Refused as e:
        result = {"verdict": benchmark.VERDICT_NONE, "why": str(e), "metrics": {}}
        log(f"benchmark: NOT COMPARED: {e} (information only, not the §104 verdict)")
    else:
        log("benchmark comparison below is information only, not the §104 verdict")
        for line in benchmark.lines(result):
            log(f"benchmark: {line}")
    record["benchmark"] = result
    if result["verdict"] != benchmark.VERDICT_SLOWER:
        return False
    slow = [f"{name} p95 {r['p95Ms']} ms is over the limit {r['limitMs']} ms (benchmark {r['benchmarkP95Ms']} ms "
            f"+ {r['allowancePercent']}% noise)" for name, r in result["metrics"].items() if r["status"] == benchmark.SLOWER]
    acceptance = record.setdefault("acceptance", {})
    acceptance["verdict"] = "REFUSED: slower than the established benchmark"
    acceptance["why"] = slow + list(acceptance.get("why") or [])
    return True


def declarations(paths):
    try:
        return [condition.load_declaration(p) for p in paths or []]
    except condition.ConditionError as e:
        raise Refused(str(e))


def cmd_compare(args):
    records, conds = [], []
    decls = declarations(args.condition_declaration)
    for path in args.records:
        with open(path) as f:
            records.append(json.load(f))
        conds.append(benchmark.record_condition(records[-1], path, decls)[0])
    try:
        result = benchmark.compare(records, benchmark.load(args.benchmark), args.benchmark, conds)
    except benchmark.NoBenchmarkFile as e:
        result = {"verdict": benchmark.VERDICT_NONE, "why": str(e), "metrics": {
            name: {"status": benchmark.NOT_COMPARED, "why": benchmark.NO_FILE} for name in benchmark.METRICS}}
        if not args.json:
            print("\n".join(f"{name:11s} {benchmark.NOT_COMPARED:12s} {benchmark.NO_FILE}" for name in benchmark.METRICS))
            print(f"verdict: {benchmark.VERDICT_NONE} ({e})")
            return EXIT_NOT_COMPARED
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print("\n".join(benchmark.lines(result)))
    return {benchmark.VERDICT_SLOWER: EXIT_SLOWER, benchmark.VERDICT_NONE: EXIT_NOT_COMPARED}.get(result["verdict"], 0)


def cmd_benchmark_update(args):
    path = benchmark.resolve(args.benchmark)
    bench = benchmark.load(path)
    changes = benchmark.update(bench, args.records, allow_slower=args.allow_slower,
                               declarations=declarations(args.condition_declaration))
    with open(path, "w") as f:
        f.write(benchmark.dump(bench))
    for line in changes:
        print(line)
    print(f"written: {path} (commit it: a benchmark changes only by a committed update)")
    return 0


def cmd_declare_condition(args):
    try:
        decl = condition.declare(args.fixture, args.rows, args.mac, args.build, args.seeded_by, args.evidence,
                                 args.declared_by, args.date or now_iso()[:10], args.records, label=benchmark._display)
    except condition.ConditionError as e:
        raise Refused(str(e))
    emit(decl, args.out)
    return 0


def cmd_budgets(_args):
    print(json.dumps({"source": perfcore.PRD + " §7 (proposed targets)", "budgets": perfcore.BUDGETS}, indent=2))
    return 0


def load_stamp(path, expect_commit):
    if not path:
        raise Refused("no build stamp: without one the record cannot name the commit it measured (randroid emu perf supplies it)")
    try:
        with open(path) as f:
            stamp = json.load(f)
    except (OSError, ValueError) as e:
        raise Refused(f"the build stamp {path} is unreadable: {e}")
    if expect_commit:
        if not stamp.get("commit", "").startswith(expect_commit) or len(expect_commit) < 7:
            raise Refused(f"freshness mismatch: the build was made from {stamp.get('commit')}, not {expect_commit}")
        if stamp.get("dirty"):
            raise Refused(f"freshness mismatch: the build was made from uncommitted changes on top of {stamp.get('commit')}")
    return stamp


# ------------------------------------------------------------------------------------------------
# Android
# ------------------------------------------------------------------------------------------------

def lease_toucher(cache):
    """An emulator randroid booted is leased (testdevices.py: 300 s idle, 900 s lifetime); a
    measurement renews it as it works, and stops, said plainly, when the lifetime is over."""
    if not cache:
        return None
    script = os.path.join(REPO, "richos", "engine", "scripts", "lib", "testdevices.py")

    def touch():
        p = subprocess.run([sys.executable, script, "touch-lease", "--kind", "android-emulator", "--id", cache],
                           capture_output=True, text=True)
        if p.returncode:
            raise Unmeasurable("the emulator's lease ended (testdevices.py: 900 s lifetime, 300 s idle); "
                               f"measure fewer phases per boot (--only): {(p.stderr or p.stdout).strip()[:160]}")
    return touch


def emulator_pacer(cache, sleep=time.sleep, limit_cores=1.5, timeout_s=30.0, clock=time.monotonic, cpu_seconds=None, quiet_s=4):
    """Wait until the emulator's host process (its pid in <cache>/emulator.json, written by
    randroid) has used under `limit_cores` over a one-second sample, at most `timeout_s`. Returns
    (pace, waits): pace() blocks, waits lists each wait. (None, []) with no emulator record."""
    try:
        with open(os.path.join(cache, "emulator.json")) as f:
            pid = int(json.load(f)["pid"])
    except (OSError, ValueError, KeyError, TypeError):
        return None, []
    waits = []

    def read_cpu():
        out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if not out:
            return None
        seconds = 0.0
        for part in out.replace("-", ":").split(":"):
            seconds = seconds * 60 + float(part)
        return seconds
    read = cpu_seconds or read_cpu

    def pace():
        """Quiet means `quiet_s` consecutive one-second samples under the limit. The breaker samples
        every 2 s when the Mac is not busy and less often when it is; four quiet seconds cover two of
        its samples, so no run of ten busy seconds can span a trial boundary."""
        start = clock()
        streak = 0
        a = read()
        while True:
            sleep(1.0)
            b = read()
            if a is None or b is None:
                waits.append({"waitedSeconds": round(clock() - start, 1), "cores": None, "note": "emulator process not readable"})
                return
            cores = max(0.0, b - a)
            a = b
            streak = streak + 1 if cores < limit_cores else 0
            if streak >= quiet_s or clock() - start >= timeout_s:
                waits.append({"waitedSeconds": round(clock() - start, 1), "cores": round(cores, 2), "quiet": streak >= quiet_s})
                return
    return pace, waits


def metric(method, samples=None, budget=None, **extra):
    m = {"method": method}
    if samples is not None:
        m["samplesMs"] = samples
        m["stats"] = perfcore.stats(samples)
        if budget:
            m["budget"] = perfcore.compare(budget, m["stats"])
    m.update(extra)
    return m


def check_kind(dev, kind):
    qemu = dev.prop("ro.kernel.qemu") == "1" or dev.prop("ro.boot.qemu") == "1"
    if kind == "physical" and qemu:
        raise Refused(f"{dev.serial} is an emulator, not a physical phone")
    if kind == "emulator" and not qemu:
        raise Refused(f"{dev.serial} is a physical device; name it with --kind physical")


def android_identity(dev, stamp, kind):
    import android
    check_kind(dev, kind)
    paths = [l.split(":", 1)[1] for l in dev.sh(f"pm path {android.PACKAGE}", check=False).split() if l.startswith("package:")]
    if not paths:
        raise Refused(f"{android.PACKAGE} is not installed on {dev.serial}")
    base = next((p for p in paths if p.endswith("base.apk")), paths[0])
    installed = dev.sh(f"sha256sum {base}").split()[0]
    if installed != stamp.get("sha256"):
        raise Refused(f"freshness mismatch: the installed APK is {installed[:12]}…, the stamped build is "
                      f"{str(stamp.get('sha256'))[:12]}… (reinstall with randroid emu refresh)")
    pkg = dev.sh(f"dumpsys package {android.PACKAGE}", check=False)
    import re
    version = re.search(r"versionName=(\S+)", pkg)
    code = re.search(r"versionCode=(\d+)", pkg)
    flags = re.search(r"pkgFlags=\[([^\]]*)\]", pkg)
    uid = re.search(r"(?:userId|appId)=(\d+)", pkg)
    debuggable = bool(flags and "DEBUGGABLE" in flags.group(1))
    build = {"package": android.PACKAGE, "commit": stamp.get("commit"), "dirty": stamp.get("dirty"),
             "installedSha256": installed, "builtSha256": stamp.get("sha256"), "stampPaths": stamp.get("paths"),
             "versionName": version.group(1) if version else None, "versionCode": int(code.group(1)) if code else None,
             "debuggable": debuggable, "configuration": "debug" if debuggable else "release"}
    wm = dev.sh("wm size", check=False).strip().split()[-1:] or [None]
    density = dev.sh("wm density", check=False).strip().split()[-1:] or [None]
    sf = dev.sh("dumpsys SurfaceFlinger", check=False)
    rate = re.search(r"refresh-rate\s*:\s*([0-9.]+)", sf) or re.search(r"(\d+(?:\.\d+)?) ?fps", sf)
    device = {"kind": kind, "serial": dev.serial, "manufacturer": dev.prop("ro.product.manufacturer"),
              "model": dev.prop("ro.product.model"), "os": "Android " + dev.prop("ro.build.version.release"),
              "sdk": dev.prop("ro.build.version.sdk"), "abi": dev.prop("ro.product.cpu.abi"),
              "buildType": dev.prop("ro.build.type"), "display": wm[0], "density": density[0],
              "refreshHz": float(rate.group(1)) if rate else None}
    return build, device, int(uid.group(1)) if uid else None


def restore_android_from(args, runner=None, sleep=None):
    """A killed seeded run leaves its saved copy under perf-keep: put that build and data back (physical phones: only
    through `randroid device`, like every other phone command)."""
    import android
    if os.environ.get("RICHOS_DEVICE_VERB") != "randroid":
        raise Refused("a physical phone is restored only through `randroid device perf --restore-from DIR`")
    log = lambda s: print(s, file=sys.stderr, flush=True)
    android.use_package(test_copy.TEST_PACKAGE_ANDROID)  # the test copy's own copy of its data, never the CEO's app
    dev = android.Device(args.adb, args.serial, runner=runner or subprocess.run, sleep=sleep or time.sleep,
                         touch=lease_toucher(args.lease))
    dev.restore_leftovers(log)
    keeper = android.StateKeeper.from_kept(dev, args.restore_from, log=log, twin_apk=getattr(args, "seed_twin", None),
                                           apksigner=getattr(args, "apksigner", None))
    return keeper.restore()


def run_android(args, runner=None, sleep=None, host=None, touch=None, log=None, popen=None):
    """The Android run. `runner`, `sleep`, `host` and `touch` are replaceable for the suite."""
    import android
    if args.production and not args.route:
        raise Refused("--production requires --route managed or tailnet")
    if args.kind == "emulator" and args.owned_by != "randroid":
        raise Refused("an emulator is measured only through `randroid emu perf` (its recorded serial), never by a raw serial")
    if args.kind == "physical" and os.environ.get("RICHOS_DEVICE_VERB") != "randroid":
        raise Refused("a physical phone is measured only through `randroid device perf` (or `randroid device "
                      "seed`), which checks that the build on it is the release build (CEO 2026-10-02)")
    if args.kind == "physical":
        # CEO 2026-10-03: his own RichConnect is his. A phone is measured only through the TEST COPY beside it.
        android.use_package(test_copy.refuse_ceo_app(test_copy.TEST_PACKAGE_ANDROID))
    else:
        android.use_package(test_copy.CEO_APP_ANDROID)  # an emulator runs the app under its own ID
    stamp = load_stamp(args.stamp, args.expect_commit)
    log = log or (lambda s: print(s, file=sys.stderr, flush=True))
    dev = android.Device(args.adb, args.serial, runner=runner or subprocess.run, sleep=sleep or time.sleep,
                         touch=touch or lease_toucher(args.lease))
    dev.restore_leftovers(log)
    if args.kind == "physical":
        # CEO 2026-10-02: only the release build goes on a physical phone and every test on one tests
        # it. Checked before anything is saved, seeded or measured, so a debuggable build is neither
        # measured nor kept to be put back afterwards.
        check_kind(dev, "physical")
        if android.debuggable(dev):
            raise Refused(f"{dev.serial} has a DEBUGGABLE RichConnect installed: only the release build is measured on a "
                          "physical phone (CEO 2026-10-02). Put the release build over it first: `randroid build release`, "
                          f"then `randroid device --serial {dev.serial} install`")
    keeper = android.StateKeeper(dev, root=getattr(args, "keep_dir", None) or os.environ.get("RICHOS_PERF_KEEP_DIR"),
                                 log=log, accept_loss=getattr(args, "accept_state_loss", None),
                                 twin_apk=getattr(args, "seed_twin", None),
                                 apksigner=getattr(args, "apksigner", None))
    try:
        record, failures = measure_android(args, dev, stamp, keeper, host, log, popen=popen)
    except BaseException as e:  # noqa: BLE001 — including an interrupt: the phone is given back whatever ended the run
        problems = keeper.restore()
        if problems:
            raise RestoreFailed(problems) from e
        raise
    problems = keeper.restore()
    if problems:
        record["savedState"] = {"restored": False, "problems": problems}
    elif keeper.apk is not None:
        record["savedState"] = {"restored": True, "apkSha256": keeper.apk_sha,
                                "dataFiles": None if keeper.tar is None else len(keeper.manifest),
                                "dataLostBy": keeper.lost}
    return record, failures


def measure_android(args, dev, stamp, keeper, host, log, popen=None):
    """The measurement inside run_android's save-and-restore. `popen` is the cold-blank phase's
    screen recorder (blankstart.android_cold_blank), replaceable for the suite like `runner`."""
    import android
    runner = dev.runner if dev.runner is not subprocess.run else None
    conversation = getattr(args, "conversation", "fixture")
    mac = getattr(args, "mac", "unreachable")
    twin = getattr(args, "seed_twin", None)
    if conversation == "fixture" and twin:
        if mac != "unreachable":
            raise Refused("the seeded conversation's pairing names a host that never resolves: the Mac is unreachable "
                          "by construction; --mac reachable needs the Debug build's bridge")
        check_kind(dev, args.kind)  # before anything on the device changes
        rows = args.rows or condition.FILE_DEFAULT_ROWS
        keeper.save()  # the seeding below overwrites the app's saved state; refuses first when it cannot be kept
        with tempfile.TemporaryDirectory() as scratch:
            twin_seed = android.seed_release(dev, condition.file_fixture(rows), twin, stamp.get("artifact"),
                                             stamp.get("sha256"), scratch, log)
    build, device, uid = android_identity(dev, stamp, args.kind)
    plan = None
    if conversation == "fixture":
        if twin:
            plan = "twin"
        elif not build["debuggable"]:
            raise Refused("a release build is measured under the seeded condition only through its debuggable twin: "
                          "--seed-twin <debug APK of the same commit, signed with the same key> (the app's saved state "
                          "is saved first and put back after the run), or --conversation as-installed, whose record is never compared")
        elif not args.production:
            plan = "bridge"
        else:
            plan = "run-as"
    if host is None and args.kind == "emulator":
        host = host_sampler()
    pace, waits = (None, [])
    if args.kind == "emulator" and args.lease and not runner:
        pace, waits = emulator_pacer(args.lease)
    m = android.Measure(dev, log=log, settle_s=args.settle, pace=pace,
                        evidence_dir=(getattr(args, "evidence_dir", None) or default_evidence_dir(args.out))
                        if args.kind == "physical" and not runner else None)
    record = {"schema": perfcore.SCHEMA, "platform": "android", "startedAt": now_iso(),
              "tool": {"path": "richos/mobile/perf/perf.py", **perfcore.source_identity(REPO, ["richos/mobile/perf"])},
              "build": build, "device": device, "metrics": {}, "phases": {}, "notMeasured": []}
    if host:
        device["host"] = {"note": "an emulator's timings depend on the Mac running it; sampled at each phase", "samples": {}}
    only = set(args.only.split(",")) if args.only else None
    if only is not None and plan:
        only.add("seed")  # the condition is this run's own seeding, never an earlier run's
    if only is not None and "cold" in only:
        only.add("cold-blank")  # a cold run always records the screen from the tap (blankstart.py)
    failures = 0

    lost = []

    def phase(name, fn):
        """One phase. A failure is recorded and the run goes on; a device that is gone (the Mac's
        CPU breaker stops an emulator) ends the run, and every later phase says why it did not run.
        The record is written whatever happens."""
        nonlocal failures
        if only is not None and name not in only:
            return None
        if lost:
            record["phases"][name] = f"NOT RUN: {lost[0]}"
            record["notMeasured"].append({"what": name, "why": f"not run: {lost[0]}"})
            return None
        if host:
            device["host"]["samples"][name] = host()
        log(f"== {name}")
        try:
            result = fn()
            record["phases"][name] = "measured"
            return result
        except Exception as e:  # noqa: BLE001 — every failure lands in the record, by phase
            why = str(e) if isinstance(e, Unmeasurable) else f"{type(e).__name__}: {e}"
            record["phases"][name] = f"NOT MEASURED: {why}"
            record["notMeasured"].append({"what": name, "why": why})
            failures += 1
            log(f"{name}: NOT MEASURED, {why}")
            if not dev.present():
                lost.append(f"the device {dev.serial} went away during '{name}' (an emulator stopped by the Mac's "
                            "CPU circuit breaker is one way; see its events)")
                log(lost[0])
            return None

    night = dev.sh("cmd uimode night", check=False).strip()
    bridge = False
    night_undo = [f"cmd uimode night {'yes' if 'yes' in night else 'auto' if 'auto' in night else 'no'}"]
    if args.theme != "device":
        dev.begin_change("night", night_undo)  # on the Mac first: a killed run or a lost phone is still put back
        dev.sh(f"cmd uimode night {'yes' if args.theme == 'dark' else 'no'}", check=False)
        dev.sleep(args.settle)
    try:
        bridge = not args.production
        try:
            if bridge: m.bridge.state()
        except Unmeasurable as e:
            bridge = False
            record["notMeasured"].append({"what": "seeded state, tap, typing and streaming",
                                          "why": f"no development bridge in this build ({e}); a release build needs a real pairing"})
            if plan == "bridge":
                plan = "run-as"  # a debuggable build without its bridge is seeded through its files
        transport = "unreachable" if mac == "unreachable" else "accept"
        configuration = build["configuration"]
        network = ("scripted-unreachable" if bridge and transport == "unreachable" else "scripted-accepting" if bridge
                   else "mac-unreachable" if plan in ("twin", "run-as") else args.network_condition)
        conditions = {"theme": args.theme, "systemNightModeBefore": night,
                      "productionControls": args.production, "networkCondition": network}
        rows, marker, cond = None, None, None
        if plan == "bridge":
            rows = args.rows or condition.BRIDGE_DEFAULT_ROWS
            seeded = phase("seed", lambda: m.seed(rows, transport))
            if seeded:
                conditions.update(seeded)
                cond = condition.for_bridge(rows, android.history_frame(rows), mac, configuration)
                marker = f"Synthetic message {rows} "
        elif plan in ("twin", "run-as"):
            if mac != "unreachable":
                raise Refused("the seeded conversation's pairing names a host that never resolves: the Mac is unreachable "
                              "by construction; --mac reachable needs the Debug build's bridge")
            rows = args.rows or condition.FILE_DEFAULT_ROWS
            if plan == "twin":
                record["phases"]["seed"] = "measured"
                how = (f"the debuggable twin (sha256 {twin_seed['twinSha256']}) was installed, the fixture written "
                       "into files/core with run-as and read back, then the stamped release APK installed over it")
            else:
                keeper.save()  # files/core is overwritten below; refuses here, before the phone is touched
                def run_as():
                    with tempfile.TemporaryDirectory() as scratch:
                        return android.write_core_files(dev, condition.file_fixture(rows), scratch)
                how = "the fixture written into the installed debuggable build's files/core with run-as and read back"
                if phase("seed", run_as) is None:
                    how = None
            if how:
                conditions.update({"fixture": condition.FILE_FIXTURE, "history": rows})
                cond = condition.for_files(rows, configuration, how)
                marker = condition.file_fixture_marker(rows)
        else:
            cond = condition.as_installed(
                "unreachable" if args.network_condition in ("mac-unreachable", "phone-offline") else "reachable",
                configuration, "--conversation as-installed: the app held whatever it held; the Mac's state is the "
                               "operator's --network-condition")
        if conversation == "fixture" and cond is None:
            record["notMeasured"].append({"what": "the seeded condition",
                                          "why": "seeding did not complete (see phases.seed); the record names no condition "
                                                 "and is never compared"})
        record["condition"] = cond
        record["conditions"] = conditions
        seeded_files = plan in ("twin", "run-as") and cond is not None
        record["route"] = {"name": "development fixture" if bridge else "seeded fixture" if seeded_files
                           else (args.route or "as installed"),
                           "detail": ("the debug build's scripted Mac inside the app: no network. Launch series run with the "
                                      f"scripted Mac {'UNREACHABLE' if transport == 'unreachable' else 'ACCEPTING'} (Sage T6: "
                                      "launch must not depend on the network); the live spot check with it accepting") if bridge
                           else ("the seeded conversation's pairing names a host under .invalid, which never resolves: no "
                                 "Mac is reachable") if seeded_files
                           else "whatever state the installed app holds",
                           "persistence": ("the development world's document (DevBridge), written through the same "
                                           "RichCore.commit as production but not through the production JsonFile port")
                           if bridge else "production"}

        cold = phase("cold", lambda: m.cold(args.cold, marker, physical=args.kind == "physical"))
        if cold and cond is not None and cold.get("screenCheck") is not None:
            cond["verified"] = {"row": marker, "onScreen": cold["screenCheck"]["newestMessageOnScreen"]}
        if cold:
            record["metrics"]["coldLaunch"] = metric(
                ("System launchingActivity trace start to DisplayPresentTime of the frame carrying foreground-useful; "
                 "the app's monotonic counter joins the OEM trace clock to FrameMetrics without mixing clock origins. " if args.kind == "physical" else
                "am force-stop; am start -W (LaunchState COLD); useful content = ActivityTaskManager 'Fully drawn' "
                "(MainActivity ReportDrawnWhen: first frame after the saved state is read); see conditions.networkCondition"),
                cold["useful"], "coldLaunch", firstFrameMs=cold["first"], firstFrameStats=perfcore.stats(cold["first"]),
                rejected=cold["rejected"], screenCheck=cold["screenCheck"], presentationSamples=cold.get("presentationSamples", []))
        if cold and args.kind == "physical":  # §104: the cold-start standard, judged from the series (perfcore.COLD_STANDARD)
            record["metrics"]["coldStandard"] = perfcore.cold_verdict("android", cold["useful"])
        if args.blank_starts and (runner is None or popen is not None):  # a scripted adb scripts its recorder too
            import blankstart  # the no-blank-screen check (CEO 2026-10-02): its own module, limit in blank.py
            cb = phase("cold-blank", lambda: blankstart.android_cold_blank(
                m, args.blank_starts, str(args.out) + ".evidence" if args.out else None, log, **({"popen": popen} if popen else {})))
            if cb:
                record["metrics"]["coldBlank"] = cb
                failures += cb["verdict"] != "PASS"
        if bridge and args.live_spot_check:
            def live():
                m.transport("accept")
                try:
                    return m.cold(args.live_spot_check)
                finally:
                    m.transport(transport)
            spot = phase("cold-live", live)
            if spot:
                record["metrics"]["coldLaunchLive"] = metric(
                    "the cold-launch method with the scripted Mac ACCEPTING: a spot check that the network never "
                    "delays the useful-content mark (Sage T6)", spot["useful"], None, firstFrameMs=spot["first"],
                    rejected=spot["rejected"])

        def front_then_idle():
            m.foreground()
            dev.sleep(args.settle)
            return m.idle(args.idle_seconds)
        idle = {}
        conv = phase("idle-conversation", front_then_idle)
        if conv:
            idle["conversation"] = conv
        if bridge:
            def settings():
                m.open_settings()
                try:
                    return m.idle(args.idle_seconds)
                finally:
                    m.close_sheet()
            s = phase("idle-settings", settings)
            if s:
                idle["settings"] = s

        warm = phase("warm", lambda: m.warm(args.warm, args.away, physical=args.kind == "physical"))
        if warm:
            hot = [ms for ms, st in zip(warm["samples"], warm["states"]) if st == "HOT"]
            recreated = [ms for ms, st in zip(warm["samples"], warm["states"]) if st == "WARM"]
            record["metrics"]["warmResume"] = metric(
                ("HOME, --away seconds; system launchingActivity start to the useful frame's DisplayPresentTime using "
                 "the draw clock counter. Require the same process and preserve HOT/WARM labels. " if args.kind == "physical" else
                "HOME, --away seconds, the launcher settles, launcher intent with am start -W: TotalTime of a start in "
                "the same process (PRD J2: process retained). Android's HOT (activity kept) and WARM (activity "
                "recreated) both count, each sample keeps its state; a new pid is a cold start and is rejected"),
                warm["samples"], "warmResume", sampleStates=warm["states"], launchStates=warm["launchStates"],
                hotStats=perfcore.stats(hot), recreatedStats=perfcore.stats(recreated),
                firstRecreation=warm["firstRecreation"], rejected=warm["rejected"], presentationSamples=warm.get("presentationSamples", []))
            if args.kind == "physical":  # the warm standard (perfcore.WARM_STANDARD); an unset limit is said loudly
                try:
                    record["metrics"]["warmStandard"] = perfcore.warm_verdict("android", warm["samples"])
                except perfcore.LimitNotSet as exc:
                    record["metrics"]["warmStandard"] = {"verdict": "LIMIT NOT SET", "why": str(exc), "method": "the warm-start standard has placeholder limits"}

        if bridge or args.production:
            scroll = phase("scroll", lambda: m.scroll(args.swipes))
            if scroll:
                record["metrics"]["activeFrames"] = metric(
                    "input swipe on the transcript (older and back), gfxinfo framestats over the swipes: frames whose "
                    "FrameCompleted <= FrameDeadline, and frames of 100 ms or more", None, None, **scroll)
            tap = phase("tap", lambda: m.tap(args.taps, production=args.production)) if bridge or args.exercise_sends else None
            if tap:
                record["metrics"]["tapToFeedback"] = metric(
                    "input tap on 'Send message': the app's deliverInputEvent eventTimeNano (atrace input) to the "
                    "FrameCompleted of the frame carrying that InputEventId (gfxinfo framestats); both CLOCK_MONOTONIC. " +
                    ("Draft entered through real controls; " if args.production else "Draft set through the debug bridge; ") +
                    "sent text checked on screen after each tap",
                    tap["samples"], "tapToFeedback", settledMs=tap["settled"], settledStats=perfcore.stats(tap["settled"]),
                    burstFrames=tap["burstFrames"], rejected=tap["rejected"])
            typing = phase("typing", lambda: m.typing(args.type_text, production=args.production)) if bridge or args.exercise_sends else None
            if typing:
                record["metrics"]["typingCost"] = metric(
                    "one character per `input text` into the focused composer; /proc/<pid>/io write syscalls and bytes, "
                    "ftrace ext4/f2fs_sync_file_enter for the app's thread group (root), gfxinfo frames; per keystroke",
                    None, None, **typing)
            cursor = (rows or 0) + args.taps + 10
            stream = phase("streaming", lambda: m.streaming(args.stream_deltas, cursor)) if bridge else None
            if stream:
                record["metrics"]["streamCost"] = metric(
                    "a streamed reply fed as `receive` delta frames through the debug bridge; the same write, fsync and "
                    "frame counts per delta. The bridge's own save of its document per command is included",
                    None, None, **stream)

        bg = phase("background", lambda: m.background(args.background_seconds, args.background_settle, uid, physical=args.kind == "physical"))
        if bg:
            quiet = None if bg.get("readOnlyPhysicalObservation") else (
                (bg["threadWakeups"] or {}).get("total", 0) == 0 and not bg["batterystats"]["wakeupAlarms"]
                and not bg["batterystats"]["jobs"] and not bg["heldWakeLocks"]
                and bg["threadWakeups"] is not None and bg["batterystats"].get("uidSeen", False)
                and bg["batterystats"]["networkBytes"] is not None
                and bg["batterystats"]["networkBytes"].get("total") == 0)
            record["metrics"]["backgroundQuiet"] = metric(
                ("HOME; read-only UID battery-accounting snapshots before and after the interval; no reset or simulated unplugging. "
                 "Unknown counters and charging conditions prevent a zero-work verdict." if args.kind == "physical" else
                "HOME; after --background-settle seconds, over --background-seconds: context switches of every app "
                "thread, CPU ticks, batterystats reset at the start and read at the end (checkin: wakeup alarms, "
                "wake locks, jobs, syncs, network bytes), pending alarms, jobs, held wake locks, open sockets"),
                None, None, zeroWork=quiet, target={"row": perfcore.BUDGETS["backgroundQuiet"]["row"], "value": 0,
                                                    "source": perfcore.PRD + " §7 (proposed)"}, **bg)

        if bridge and (only is None or "idle-pairing" in only):
            def pairing():
                m.bridge.call("fixture", "unpaired")
                dev.sh(f"am force-stop {android.PACKAGE}")
                m.foreground()
                dev.sleep(args.settle)
                if android.find_node(m.dump_ui(), text="Use a pairing link instead") is None:
                    raise Unmeasurable("the pairing screen is not on screen after the unpaired fixture")
                return m.idle(args.idle_seconds)
            p = phase("idle-pairing", pairing)
            if p:
                idle["pairing"] = p
        if idle:
            record["metrics"]["idleFrames"] = metric(
                "gfxinfo reset, --idle-seconds untouched, 'Total frames rendered' for MainActivity's window "
                "(the app's own frames; the keyboard and system UI are other windows)", None, None, screens=idle,
                zeroFrames=all(v["framesRendered"] == 0 for v in idle.values()),
                target={"row": perfcore.BUDGETS["idleFrames"]["row"], "value": 0, "source": perfcore.PRD + " §7 (proposed)"})
    finally:
        if not lost:
            m.restore_root()
        if args.theme != "device" and not lost:
            dev.end_change("night", night_undo)  # a lost phone keeps its record: the next command puts it back
    if waits:
        record["device"].setdefault("host", {})["pacing"] = {
            "rule": "before each trial, keystroke, delta, swipe and window, wait until the emulator's host process used "
                    "under 1.5 cores for four consecutive one-second samples (at most 30 s); keeps the run under the "
                    "Mac's CPU circuit breaker (3 cores for 10 s, sampled every 2 s)",
            "waits": len(waits), "totalWaitSeconds": round(sum(w["waitedSeconds"] for w in waits), 1),
            "notQuiet": sum(1 for w in waits if w.get("quiet") is False)}
    record["notMeasured"].extend(android_gaps(record, args))
    samples = len((record["metrics"].get("coldLaunch") or {}).get("samplesMs") or [])
    record["acceptance"] = perfcore.acceptance(args.kind, not build["debuggable"], samples)
    record["finishedAt"] = now_iso()
    return record, failures


def android_gaps(record, args):
    """PRD §7 rows this run could not measure, each with what would settle it."""
    gaps = [
        {"what": "sendToQueued (small text send to durable local queued state, p95 <= 150 ms)",
         "why": "use release trace events richconnect:send-tapped and richconnect:durable-queued; "
                "the general tap metric is frame feedback and does not claim durability"},
        {"what": "receiveToVisible (received text to visible text, p95 <= 100 ms)",
         "why": "join release trace events richconnect:text-received and richconnect:transcript-drawn "
                "to frame presentation. Offscreen rows must not be reported as visible"},
        {"what": "energy (mAh, OS battery attribution, OEM power-intensive warnings)",
         "why": "an emulator has no battery or power model; its batterystats power estimates are not energy. Settle: "
                "the same background phase on a physical phone (PRD §8 names the mandatory OEM phone family), "
                "plus Settings > Battery and the OEM manager over the PRD §8 30-minute and overnight windows"},
        {"what": "managed Connect and Tailscale routes",
         "why": "this run used the debug build's scripted Mac (no network). Settle: pair with the lab Mac "
                "(native-android README 'Pairing the emulator') or a real Mac; count the phone's requests at the Mac "
                "and at the Connect Worker while backgrounded (Sage T7)"},
        {"what": "release-configuration timing",
         "why": "a debuggable, unminified build is slower than release; PRD §7 budgets are for release builds. "
                "Settle: a profileable release-configuration build signed for local install, and a real pairing to "
                "reach the conversation without the debug bridge"},
        {"what": "typing and streaming cost on the production persistence port",
         "why": "in a development world the core persists through the bridge's document, not AppPorts' JsonFile. "
                "RichCore.commit changes show here; JsonFile changes need a paired production core"},
    ]
    if args.production:
        gaps = [g for g in gaps if g["what"] not in ("managed Connect and Tailscale routes",
                                                     "typing and streaming cost on the production persistence port")]
        if not record["build"]["debuggable"]:
            gaps = [g for g in gaps if g["what"] != "release-configuration timing"]
        gaps.append({"what": "route attribution and physical qualification",
                     "why": "the selected route and network condition are operator declarations; pair them with network and energy traces. "
                            "This tool does not certify absence of OEM warnings or benchmark streamed text without a real reply"})
    if args.kind == "emulator":
        gaps.append({"what": "physical-device timing",
                     "why": "an emulator on a shared Mac (software GPU, host CPU recorded per phase) is a pilot, never "
                            "acceptance (PRD §8). Settle: the same command on a phone with --kind physical"})
    return gaps


# ------------------------------------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(prog="perf.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("android", help="measure the installed Android build")
    a.add_argument("--production", action="store_true", help="use the paired app through real controls, never the Debug bridge")
    a.add_argument("--route", choices=("managed", "tailnet"), help="route under test, recorded rather than inferred")
    a.add_argument("--network-condition", choices=("live", "phone-offline", "mac-unreachable"), default="live")
    a.add_argument("--exercise-sends", action="store_true", help="enter and send synthetic probes on an explicitly prepared test conversation")
    a.add_argument("--adb", required=True)
    a.add_argument("--serial", required=True)
    a.add_argument("--kind", choices=("emulator", "physical"), required=True)
    a.add_argument("--owned-by", default=None, help="randroid, for its recorded emulator")
    a.add_argument("--lease", help="the emulator's registered cache (testdevices.py): renewed while measuring")
    a.add_argument("--checkout", default=REPO)
    a.add_argument("--stamp", help="the build stamp (perf.py stamp) of the installed APK")
    a.add_argument("--expect-commit", help="refuse unless the installed build was made, clean, from this commit")
    a.add_argument("--out", help="write the record here (default stdout)")
    a.add_argument("--only", help="comma-separated phases: seed,cold (with cold-blank),cold-blank,cold-live,idle-conversation,idle-settings,"
                                  "warm,scroll,tap,typing,streaming,background,idle-pairing")
    a.add_argument("--cold", type=int, default=20)
    a.add_argument("--blank-starts", type=int, default=10,
                   help="cold starts from a tap on the home-screen icon, screen-recorded and judged by blank.py "
                        "(phase cold-blank, run with cold; 20 or more are judged by p95, fewer by the median; 0 skips)")
    a.add_argument("--live-spot-check", type=int, default=3)
    a.add_argument("--warm", type=int, default=20)
    a.add_argument("--away", type=float, default=2.0)
    a.add_argument("--taps", type=int, default=10)
    a.add_argument("--swipes", type=int, default=6)
    a.add_argument("--idle-seconds", type=float, default=10.0)
    a.add_argument("--background-seconds", type=float, default=60.0)
    a.add_argument("--background-settle", type=float, default=5.0)
    a.add_argument("--settle", type=float, default=2.0)
    a.add_argument("--conversation", choices=("fixture", AS_INSTALLED), default="fixture",
                   help="fixture (default): seed the made-up conversation and record the condition (condition.py); "
                        "as-installed: measure whatever the app holds, recorded as uncontrolled and never compared")
    a.add_argument("--rows", "--history", dest="rows", type=int, default=None,
                   help=f"rows in the seeded conversation (default {condition.FILE_DEFAULT_ROWS} seeded into the app's files, "
                        f"{condition.BRIDGE_DEFAULT_ROWS} through the Debug bridge: the counts the benchmarks were taken with)")
    a.add_argument("--mac", choices=condition.MAC_STATES, default="unreachable",
                   help="the Mac's state while measured (default unreachable; reachable only through the Debug bridge)")
    a.add_argument("--seed-twin", metavar="DEBUG_APK",
                   help="seed a release build through its debuggable twin (same commit, SAME SIGNING KEY): `adb install -r` "
                        "the twin over the app (data kept), write the fixture with run-as, `install -r` the stamped release APK "
                        "(the stamp's artifact) back. Never an uninstall: a different signature is refused and reported. The app's "
                        "build and data are saved first (read through the twin) and put back after the run")
    a.add_argument("--apksigner", help="the Android SDK's apksigner: reads who signed the twin and the installed app, "
                                       "which must be the same certificate before the twin is installed")
    a.add_argument("--accept-state-loss", metavar="WHO",
                   help="only when the app's saved state cannot be copied off the phone (a release build with no twin to read "
                        "it through): the run is refused unless that state is already empty or WHO agreed to lose it; WHO is recorded")
    a.add_argument("--restore-from", metavar="KEPT_DIR",
                   help="put the saved build and data back from the copy a killed run kept (under perf-keep), measure nothing; "
                        "run through `randroid device perf`, which supplies the twin")
    a.add_argument("--type-text", default="measuredtypingcost")
    a.add_argument("--stream-deltas", type=int, default=8)
    a.add_argument("--theme", choices=("device", "light", "dark"), default="device")
    a.add_argument("--benchmark", help="the benchmark file the record is judged against (default: the private benchmark file, see benchmark.py)")
    a.add_argument("--evidence-dir", help="a physical phone's retained traces (default: the record's path + .evidence)")
    i = sub.add_parser("ios", help="measure an iOS build with explicit evidence boundaries")
    target = i.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator", help="a simulator UDID (never 'booted')")
    target.add_argument("--device", help="a physical iPhone's UDID (xcrun devicectl list devices)")
    target.add_argument("--reparse", metavar="SERIES_DIR",
                        help="re-export and re-join a retained trace series (its series.json names class, device, build)")
    i.add_argument("--stamp")
    i.add_argument("--expect-commit")
    i.add_argument("--out")
    i.add_argument("--evidence-dir", help="external SSD directory for retained traces")
    i.add_argument("--cold", type=int, default=20, help="cold launches (0 skips the class)")
    i.add_argument("--warm", type=int, default=0, help="warm returns in the retained process (0 skips the class)")
    i.add_argument("--away", type=float, default=2.0, help="seconds with Settings in front before each return")
    i.add_argument("--trace-seconds", type=int, default=10, help="Instruments recording length per trial")
    i.add_argument("--trace-diagnostic", action="store_true",
                   help="iPhone: run the Instruments trace series as a DIAGNOSTIC (coldLaunchTraced/warmResumeTraced). "
                        "Never judged, never compared, never a pass or fail; without it --cold/--warm on a phone are the untraced series")
    i.add_argument("--returns", type=int, default=0,
                   help="iPhone, seeded: warm returns with nothing attached (another app in front, then RichConnect "
                        "opened with `devicectl process launch`, no terminate); the iPhone's warmResume (--warm N means this)")
    i.add_argument("--launches", type=int, default=0,
                   help="iPhone, seeded: the cold-start test, N starts with nothing attached (no profiler): terminate, "
                        "an ordinary launch request; start 1 unjudged, stops at the first of starts 2-5 over the "
                        "limit (perfcore.COLD_STANDARD, §104). This is the iPhone's coldLaunch")
    i.add_argument("--tap-launches", type=int, default=0,
                   help="iPhone, seeded: cold launches by a tap on the Home Screen icon with no profiler, timed by the "
                        "app's own clocks from the kernel's process start (record `unprofiled`, never compared)")
    i.add_argument("--tap-returns", type=int, default=0,
                   help="iPhone, seeded: returns by a tap on the icon, each with a probe touch on the transcript at a "
                        "set offset: is a touch delivered before iOS makes the scene active? (record `unprofiled`)")
    i.add_argument("--screen-recording", action="store_true",
                   help="with --tap-launches/--tap-returns: keep XCTest's recording of the phone's screen for the tap "
                        "session (phone-ios.py run --screen-recording), under the evidence directory's taps/run")
    i.add_argument("--xctrace", action="store_true",
                   help="simulator only: run the physical trace path as a dry run (its frame data is refused)")
    i.add_argument("--app-arg", action="append",
                   help="an argument for the app's launches (a Debug fixture on a simulator; none on a phone)")
    i.add_argument("--background-seconds", type=float, default=60.0)
    i.add_argument("--background-settle", type=float, default=5.0)
    i.add_argument("--conversation", choices=("fixture", AS_INSTALLED), default="fixture",
                   help="fixture (default): Android's made-up conversation written as the app's saved state (rios "
                        "perf-seed), on a simulator into its data container, on an iPhone with devicectl after a copy of "
                        "the phone's own state is taken; checked on screen after the launches; the app's own state put "
                        "back and read back after. as-installed: whatever the app holds, recorded as uncontrolled and "
                        "never compared")
    i.add_argument("--rows", type=int, default=None,
                   help=f"rows in the seeded conversation (default {condition.FILE_DEFAULT_ROWS}, Android's benchmark count)")
    i.add_argument("--mac", choices=condition.MAC_STATES,
                   help="the Mac's state while measured: unreachable by construction when seeded; with --conversation "
                        "as-installed, as the operator set it")
    i.add_argument("--benchmark", help="the benchmark file the record is judged against (default: the private benchmark file, see benchmark.py)")
    ir = sub.add_parser("ios-restore", help="put an iPhone app's own saved state back from the copy a killed seeded run kept")
    ir.add_argument("--device", required=True, help="the iPhone the copy was taken from")
    ir.add_argument("--backup", required=True, help="<evidence>/ios-seed-*/backup (holds RichOS/ and manifest.json)")
    s = sub.add_parser("stamp", help="the identity of a build artifact")
    s.add_argument("--artifact", required=True)
    s.add_argument("--checkout", required=True)
    s.add_argument("--paths", nargs="+", required=True)
    c = sub.add_parser("check", help="check records' structural promises")
    c.add_argument("records", nargs="+")
    sub.add_parser("budgets", help="print the PRD §7 budgets")
    mg = sub.add_parser("merge", help="one record from runs split across boots with --only")
    mg.add_argument("records", nargs="+")
    mg.add_argument("--out")
    mg.add_argument("--benchmark", help="the benchmark file the merged record is judged against")
    cp = sub.add_parser("compare", help="cold launch and warm resume p95 against the established benchmark")
    cp.add_argument("records", nargs="+", help="one record, or the cold and warm records of one build")
    cp.add_argument("--benchmark", help="default: the private benchmark file (see benchmark.py: $RICHOS_MOBILE_PERF_BENCHMARKS, else richos-hq/docs/mobile-perf/benchmarks.json)")
    cp.add_argument("--json", action="store_true", help="the whole comparison as JSON")
    cp.add_argument("--condition-declaration", action="append", metavar="FILE",
                    help="the condition of records measured before perf.py wrote one, for exactly the files it names by sha256")
    bu = sub.add_parser("benchmark-update", help="establish or raise benchmarks from sound records; commit the file after")
    bu.add_argument("records", nargs="+")
    bu.add_argument("--benchmark", help="default: the private benchmark file (see benchmark.py: $RICHOS_MOBILE_PERF_BENCHMARKS, else richos-hq/docs/mobile-perf/benchmarks.json)")
    bu.add_argument("--allow-slower", metavar="REASON",
                    help="let a slower series replace a benchmark; the reason is written beside the number")
    bu.add_argument("--condition-declaration", action="append", metavar="FILE",
                    help="the condition of records measured before perf.py wrote one, for exactly the files it names by sha256")
    dc = sub.add_parser("declare-condition", help="state the condition of records measured before records named one")
    dc.add_argument("records", nargs="+", help="the exact record files (named by sha256 in the declaration)")
    dc.add_argument("--fixture", required=True, choices=(condition.FILE_FIXTURE, condition.BRIDGE_FIXTURE))
    dc.add_argument("--rows", type=int, required=True)
    dc.add_argument("--mac", required=True, choices=condition.MAC_STATES)
    dc.add_argument("--build", required=True, choices=condition.BUILDS)
    dc.add_argument("--seeded-by", required=True, help="how the conversation was put on the device")
    dc.add_argument("--evidence", required=True, help="how the condition is known: the retained logs and scripts")
    dc.add_argument("--declared-by", required=True)
    dc.add_argument("--date", help="default today (UTC)")
    dc.add_argument("--out", help="write the declaration here (default stdout); keep it private beside the benchmark file")
    return p.parse_args(argv)


def default_evidence_dir(out):
    """Where a physical run's traces go with no --evidence-dir: beside the record when it has a path, else a
    scratch folder, never the working directory (a run with no --out once wrote `None.evidence` into the repository)."""
    return str(out) + ".evidence" if out else tempfile.mkdtemp(prefix="richos-perf-evidence-")


def emit(record, out):
    text = perfcore.dump(record)
    if out:
        with open(out, "w") as f:
            f.write(text)
        print(f"record: {out}", file=sys.stderr)
    else:
        sys.stdout.write(text)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.cmd == "stamp":
            return cmd_stamp(args)
        if args.cmd == "check":
            return cmd_check(args)
        if args.cmd == "budgets":
            return cmd_budgets(args)
        if args.cmd == "merge":
            return cmd_merge(args)
        if args.cmd == "compare":
            return cmd_compare(args)
        if args.cmd == "benchmark-update":
            return cmd_benchmark_update(args)
        if args.cmd == "declare-condition":
            return cmd_declare_condition(args)
        if args.cmd == "ios-restore":
            import ios
            print(json.dumps({"ok": True, **ios.restore_device(args.device, args.backup)}))
            return 0
        if args.cmd == "android" and getattr(args, "restore_from", None):
            problems = restore_android_from(args)
            print(json.dumps({"ok": not problems, "problems": problems}))
            if problems:
                print(not_restored_line(problems), file=sys.stderr, flush=True)  # the last line
                return EXIT_NOT_RESTORED
            return 0
        if args.cmd == "android":
            record, failures = run_android(args)
        else:
            import ios
            record, failures = ios.run_ios(args)
        for line in perfcore.standard_report(record.get("platform") or args.cmd, record):
            print(line, file=sys.stderr, flush=True)
        slower = judge(record, args.benchmark)
        problems = perfcore.check_record(record)
        if problems:
            record.setdefault("recordProblems", problems)
        emit(record, args.out)
        kept = (record.get("savedState") or {})
        if kept.get("restored") is False:
            print(not_restored_line(kept["problems"]), file=sys.stderr, flush=True)  # the last line
            return EXIT_NOT_RESTORED
        return EXIT_SLOWER if slower else 1 if failures or problems else 0
    except Refused as e:
        print(json.dumps({"ok": False, "refused": str(e)}), file=sys.stderr)
        return 3
    except RestoreFailed as e:
        cause = e.__cause__
        if cause is not None:
            print(json.dumps({"ok": False, "error": f"{type(cause).__name__}: {cause}"}), file=sys.stderr)
        print(not_restored_line(e.problems), file=sys.stderr, flush=True)  # the last line
        return EXIT_NOT_RESTORED
    except Unmeasurable as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
