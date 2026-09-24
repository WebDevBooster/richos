#!/usr/bin/env python3
"""perf.py — repeatable RichConnect speed and battery measurement, one record per run.

    perf.py android --adb ADB --serial SERIAL --kind emulator --owned-by randroid --stamp FILE [options]
    perf.py ios (--simulator UDID | --device UDID) --app PATH --stamp FILE [options]   (written, not yet run)
    perf.py stamp --artifact FILE --checkout DIR --paths P [P ...]     identity of a build, as JSON
    perf.py check RECORD.json [...]                                     a record's structural promises
    perf.py budgets                                                      the PRD §7 budgets this compares to
    perf.py merge PART.json PART.json [--out FILE]                      one record from a run split across boots

On Android use it through `randroid emu perf [options]`, which supplies the adb, the serial it
recorded and the stamp of the APK it installed; a physical phone is named explicitly with
`--kind physical --serial <serial>` and is checked to be one.

Exit 0 a record was written; 1 a phase failed (the record still says which and why); 2 usage;
3 REFUSED: the installed build is not the stamped one, the stamp is not the expected commit, or
the device is not the kind named. The record goes to --out (default: stdout). It is the measurement
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
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import perfcore  # noqa: E402
from perfcore import Refused, Unmeasurable  # noqa: E402

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
    problems = perfcore.check_record(merged)
    if problems:
        merged["recordProblems"] = problems
    emit(merged, args.out)
    return 1 if problems else 0


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


def android_identity(dev, stamp, kind):
    import android
    qemu = dev.prop("ro.kernel.qemu") == "1" or dev.prop("ro.boot.qemu") == "1"
    if kind == "physical" and qemu:
        raise Refused(f"{dev.serial} is an emulator, not a physical phone")
    if kind == "emulator" and not qemu:
        raise Refused(f"{dev.serial} is a physical device; name it with --kind physical")
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


def run_android(args, runner=None, sleep=None, host=None, touch=None, log=None):
    """The Android run. `runner`, `sleep`, `host` and `touch` are replaceable for the suite."""
    import android
    if args.production and not args.route:
        raise Refused("--production requires --route managed or tailnet")
    if args.kind == "emulator" and args.owned_by != "randroid":
        raise Refused("an emulator is measured only through `randroid emu perf` (its recorded serial), never by a raw serial")
    stamp = load_stamp(args.stamp, args.expect_commit)
    log = log or (lambda s: print(s, file=sys.stderr, flush=True))
    dev = android.Device(args.adb, args.serial, runner=runner or subprocess.run, sleep=sleep or time.sleep,
                         touch=touch or lease_toucher(args.lease))
    build, device, uid = android_identity(dev, stamp, args.kind)
    if host is None and args.kind == "emulator":
        host = host_sampler()
    pace, waits = (None, [])
    if args.kind == "emulator" and args.lease and not runner:
        pace, waits = emulator_pacer(args.lease)
    m = android.Measure(dev, log=log, settle_s=args.settle, pace=pace)
    record = {"schema": perfcore.SCHEMA, "platform": "android", "startedAt": now_iso(),
              "tool": {"path": "richos/mobile/perf/perf.py", **perfcore.source_identity(REPO, ["richos/mobile/perf"])},
              "build": build, "device": device, "metrics": {}, "phases": {}, "notMeasured": []}
    if host:
        device["host"] = {"note": "an emulator's timings depend on the Mac running it; sampled at each phase", "samples": {}}
    only = set(args.only.split(",")) if args.only else None
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
    if args.theme != "device":
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
        conditions = {"theme": args.theme, "systemNightModeBefore": night,
                      "productionControls": args.production, "networkCondition": "scripted-unreachable" if bridge else args.network_condition}
        if bridge:
            seeded = phase("seed", lambda: m.seed(args.history, "unreachable"))
            if seeded:
                conditions.update(seeded)
        record["conditions"] = conditions
        record["route"] = {"name": "development fixture" if bridge else (args.route or "as installed"),
                           "detail": ("the debug build's scripted Mac inside the app: no network. Launch series run with the "
                                      "scripted Mac UNREACHABLE (Sage T6: launch must not depend on the network); the live "
                                      "spot check with it accepting") if bridge else "whatever state the installed app holds",
                           "persistence": ("the development world's document (DevBridge), written through the same "
                                           "RichCore.commit as production but not through the production JsonFile port")
                           if bridge else "production"}
        newest = f"Synthetic message {args.history} " if bridge and args.history else None

        cold = phase("cold", lambda: m.cold(args.cold, newest, physical=args.kind == "physical"))
        if cold:
            record["metrics"]["coldLaunch"] = metric(
                ("System launchingActivity trace start to DisplayPresentTime of the frame carrying foreground-useful; "
                 "the app's monotonic counter joins the OEM trace clock to FrameMetrics without mixing clock origins. " if args.kind == "physical" else
                "am force-stop; am start -W (LaunchState COLD); useful content = ActivityTaskManager 'Fully drawn' "
                "(MainActivity ReportDrawnWhen: first frame after the saved state is read); see conditions.networkCondition"),
                cold["useful"], "coldLaunch", firstFrameMs=cold["first"], firstFrameStats=perfcore.stats(cold["first"]),
                rejected=cold["rejected"], screenCheck=cold["screenCheck"], presentationSamples=cold.get("presentationSamples", []))
        if bridge and args.live_spot_check:
            def live():
                m.transport("accept")
                try:
                    return m.cold(args.live_spot_check)
                finally:
                    m.transport("unreachable")
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
            cursor = (args.history or 0) + args.taps + 10
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
            restore = "yes" if "yes" in night else ("auto" if "auto" in night else "no")
            dev.sh(f"cmd uimode night {restore}", check=False)
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
    a.add_argument("--only", help="comma-separated phases: seed,cold,cold-live,idle-conversation,idle-settings,"
                                  "warm,scroll,tap,typing,streaming,background,idle-pairing")
    a.add_argument("--cold", type=int, default=20)
    a.add_argument("--live-spot-check", type=int, default=3)
    a.add_argument("--warm", type=int, default=20)
    a.add_argument("--away", type=float, default=2.0)
    a.add_argument("--taps", type=int, default=10)
    a.add_argument("--swipes", type=int, default=6)
    a.add_argument("--idle-seconds", type=float, default=10.0)
    a.add_argument("--background-seconds", type=float, default=60.0)
    a.add_argument("--background-settle", type=float, default=5.0)
    a.add_argument("--settle", type=float, default=2.0)
    a.add_argument("--history", type=int, default=40)
    a.add_argument("--type-text", default="measuredtypingcost")
    a.add_argument("--stream-deltas", type=int, default=8)
    a.add_argument("--theme", choices=("device", "light", "dark"), default="device")
    i = sub.add_parser("ios", help="measure an iOS build (written; not yet run)")
    target = i.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator", help="a simulator UDID (never 'booted')")
    target.add_argument("--device", help="a physical iPhone's UDID (xcrun devicectl list devices)")
    i.add_argument("--stamp")
    i.add_argument("--expect-commit")
    i.add_argument("--out")
    i.add_argument("--cold", type=int, default=20)
    i.add_argument("--background-seconds", type=float, default=60.0)
    i.add_argument("--background-settle", type=float, default=5.0)
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
    return p.parse_args(argv)


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
        if args.cmd == "android":
            record, failures = run_android(args)
        else:
            import ios
            record, failures = ios.run_ios(args)
        problems = perfcore.check_record(record)
        if problems:
            record.setdefault("recordProblems", problems)
        emit(record, args.out)
        return 1 if failures or problems else 0
    except Refused as e:
        print(json.dumps({"ok": False, "refused": str(e)}), file=sys.stderr)
        return 3
    except Unmeasurable as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
