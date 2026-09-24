#!/usr/bin/env python3
"""mobile-perf.test.py — the RichConnect measurement tool (richos/mobile/perf) answers from what the
platform printed, and refuses rather than measure the wrong build or the wrong device.

Parsers run against output captured from the API 34 emulator on 2026-09-24 (fixtures/android/),
the whole Android run against a scripted adb and iOS parsers against both scripted output and
the field/reference layout captured on an iPhone SE with iOS 26.3.1. Nothing boots,
builds or opens a window; no adb, simulator or network is touched.
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
PERF = os.path.abspath(os.path.join(HERE, "..", "..", "mobile", "perf"))
FIX = os.path.join(PERF, "fixtures", "android")
MOBILE = os.path.abspath(os.path.join(PERF, ".."))
sys.path.insert(0, PERF)

import android  # noqa: E402
import ios  # noqa: E402
import perf  # noqa: E402
import perfcore  # noqa: E402

failures = []


def case(name):
    def wrap(fn):
        try:
            fn()
            print(f"  ok    {name}")
        except Exception as e:  # noqa: BLE001 — every failure is reported by name
            failures.append(name)
            print(f"  FAIL  {name}: {type(e).__name__}: {e}")
        return fn
    return wrap


def fixture(name):
    with open(os.path.join(FIX, name)) as f:
        return f.read()


def raises(exc, fn, *a, **kw):
    try:
        fn(*a, **kw)
    except exc as e:
        return str(e)
    raise AssertionError(f"expected {exc.__name__}")


# ---------------------------------------------------------------------------------------------
# statistics and the record
# ---------------------------------------------------------------------------------------------

@case("S1 nearest-rank percentiles; p95 only from 20 samples, p99 only from 100")
def _():
    s = perfcore.stats(list(range(1, 21)))
    assert (s["n"], s["p50"], s["p95"], s["p99"], s["max"]) == (20, 10, 19, None, 20), s
    small = perfcore.stats([5, 1, 9])
    assert small["p95"] is None and small["p50"] == 5 and "pilot" in small["why"], small
    big = perfcore.stats(list(range(1, 101)))
    assert big["p99"] == 99 and "why" not in big, big


@case("S2 a budget comparison without a p95 says why instead of passing")
def _():
    c = perfcore.compare("coldLaunch", perfcore.stats([400, 500]))
    assert c["within"] is None and "p95" in c["why"] and c["budget"] == 1000, c
    ok = perfcore.compare("coldLaunch", perfcore.stats([900] * 20))
    assert ok["within"] is True and "proposed" in ok["source"], ok
    over = perfcore.compare("warmResume", perfcore.stats([150] * 18 + [900, 900]))  # rank 19 of 20
    assert over["within"] is False, over


@case("S3 acceptance is NOT VERIFIED on an emulator, a debug build or under 100 trials; never PASS")
def _():
    a = perfcore.acceptance("emulator", False, 20)
    assert a["verdict"] == "NOT VERIFIED" and len(a["why"]) == 3, a
    b = perfcore.acceptance("physical", True, 100)
    assert b["verdict"] != "PASS" and not b["why"], b
    problems = perfcore.check_record({"schema": perfcore.SCHEMA, "acceptance": {"verdict": "PASS"}})
    assert any("never says PASS" in p for p in problems), problems


@case("S4 a record whose installed bytes are not the stamped bytes, or with no commit, is unsound")
def _():
    rec = {"schema": perfcore.SCHEMA, "platform": "android", "build": {"installedSha256": "a", "builtSha256": "b"},
           "device": {"kind": "emulator"}, "route": {}, "metrics": {"x": {"samplesMs": [1, 2], "stats": {"n": 3}}},
           "acceptance": {}, "notMeasured": [{"what": "y"}], "startedAt": "t"}
    problems = " | ".join(perfcore.check_record(rec))
    for needle in ("names no commit", "not the stamped build", "states no method", "stats.n 3 but 2", "lacks what or why"):
        assert needle in problems, (needle, problems)


@case("S5 stamp names the checkout's commit and whether the build's paths were uncommitted")
def _():
    with tempfile.TemporaryDirectory() as repo:
        # A throwaway repository: no user-global hooks, a placeholder identity (as battery-check.test.py).
        git = ["git", "-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "user.name=Perf Test",
               "-c", "user.email=perf-test@example.invalid", "-c", "commit.gpgsign=false"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "x"], check=True)
        os.makedirs(os.path.join(repo, "src"))
        artifact = os.path.join(repo, "a.apk")
        with open(artifact, "wb") as f:
            f.write(b"bytes")
        ident = perfcore.source_identity(repo, ["src"])
        assert len(ident["commit"]) == 40 and ident["dirty"] is False, ident
        with open(os.path.join(repo, "src", "x.kt"), "w") as f:
            f.write("changed")
        assert perfcore.source_identity(repo, ["src"])["dirty"] is True
        d = os.path.join(repo, "App.app")
        os.makedirs(d)
        with open(os.path.join(d, "Info.plist"), "w") as f:
            f.write("one")
        first = perfcore.tree_sha256(d)
        with open(os.path.join(d, "Info.plist"), "w") as f:
            f.write("two")
        assert perfcore.tree_sha256(d) != first


@case("S6 a stamp from another commit, or from uncommitted changes, is refused as a freshness mismatch")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "s.json")
        with open(path, "w") as f:
            json.dump({"commit": "abcdef1234", "dirty": False, "sha256": "x"}, f)
        assert perf.load_stamp(path, "abcdef1")["commit"] == "abcdef1234"
        assert "freshness mismatch" in raises(perfcore.Refused, perf.load_stamp, path, "1234567")
        with open(path, "w") as f:
            json.dump({"commit": "abcdef1234", "dirty": True, "sha256": "x"}, f)
        assert "uncommitted" in raises(perfcore.Refused, perf.load_stamp, path, "abcdef1")
        assert "no build stamp" in raises(perfcore.Refused, perf.load_stamp, None, None)


# ---------------------------------------------------------------------------------------------
# Android parsers, on captured output
# ---------------------------------------------------------------------------------------------

AM_COLD = """Starting: Intent { cmp=dev.richos.connect/dev.richos.android.app.MainActivity }
Status: ok
LaunchState: COLD
Activity: dev.richos.connect/dev.richos.android.app.MainActivity
TotalTime: 1239
WaitTime: 1251
Complete
"""
AM_HOT = AM_COLD.replace("COLD", "HOT").replace("1239", "185").replace("1251", "190")
LOGCAT = """09-24 03:37:11.573   514   533 I ActivityTaskManager: Displayed dev.richos.connect/dev.richos.android.app.MainActivity for user 0: +1s239ms
09-24 03:37:12.197   514   533 I ActivityTaskManager: Fully drawn dev.richos.connect/dev.richos.android.app.MainActivity: +1s863ms
"""


@case("A1 am start -W: launch state and TotalTime; a failed start is unmeasurable, not zero")
def _():
    assert android.parse_am_start(AM_COLD) == {"status": "ok", "launchState": "COLD", "totalMs": 1239, "waitMs": 1251}
    assert android.parse_am_start(AM_HOT)["launchState"] == "HOT"
    raises(perfcore.Unmeasurable, android.parse_am_start, "Error: Activity class does not exist.")


@case("A2 'Fully drawn' in every duration form; none is None, never 0")
def _():
    assert android.parse_fully_drawn(LOGCAT) == 1863
    assert android.parse_plus_duration("+863ms") == 863
    assert android.parse_plus_duration("+1m2s3ms") == 62003
    assert android.parse_plus_duration("+2s") == 2000
    assert android.parse_fully_drawn(LOGCAT.splitlines()[0]) is None
    raises(perfcore.Unmeasurable, android.parse_plus_duration, "+")


@case("A3 framestats: the activity's window only, 19 rows, 18 timed frames")
def _():
    windows = android.parse_framestats(fixture("gfxinfo-framestats-tap.txt"))
    w = android.app_window(windows)
    assert list(windows) == ["dev.richos.connect/dev.richos.android.app.MainActivity"], list(windows)
    assert w["totalFrames"] == 18 and len(w["rows"]) == 19, (w["totalFrames"], len(w["rows"]))
    assert sum(1 for r in w["rows"] if android.frame_ok(r)) == 18
    raises(perfcore.Unmeasurable, android.app_window, {})


@case("A4 tap: the app's own input event to the frame carrying its id (79.6 ms), settled at 752.6 ms")
def _():
    rows = android.app_window(android.parse_framestats(fixture("gfxinfo-framestats-tap.txt")))["rows"]
    events = android.parse_input_events(fixture("atrace-tap.txt"), 5911)
    assert [e["id"] for e in events] == [android.signed32(0xe55a39f2), android.signed32(0xc4bbd379)], events
    assert not android.parse_input_events(fixture("atrace-tap.txt"), 843) == events  # SystemUI's event is not the app's
    r = android.tap_latency(events, rows)
    # By hand: FrameCompleted 264288579957 - eventTimeNano 264209000000 = 79.58 ms; the last frame
    # of the burst completes at 264961640166 → 752.64 ms; the Flags=8 row is not a frame.
    assert (r["inputToFrameMs"], r["inputToSettledMs"], r["burstFrames"]) == (79.6, 752.6, 18), r
    assert "no deliverInputEvent" in raises(perfcore.Unmeasurable, android.tap_latency, [], rows)
    assert "InputEventId" in raises(perfcore.Unmeasurable, android.tap_latency, [{"id": 1, "eventTimeNs": 0}], rows)


@case("A12 launch joins different trace and frame clock origins through the draw counter")
def _():
    trace = "\n".join([
        " system-1 (1) [000] .... 10.000000: tracing_mark_write: S|1|launchingActivity#7|0",
        " system-1 (1) [000] .... 10.500000: tracing_mark_write: I|1|launchingActivity#7:completed-cold:dev.richos.connect",
        " app-42 (42) [000] .... 10.999999: tracing_mark_write: B|42|richconnect:foreground-useful",
        " worker-43 (42) [001] .... 10.999999: tracing_mark_write: E|42",
        " worker-43 (42) [001] .... 10.999999: tracing_mark_write: C|42|richconnect:monotonic-ns|9000000000",
        " app-42 (42) [000] .... 11.000000: tracing_mark_write: C|42|richconnect:monotonic-ns|3000000000",
        " app-42 (42) [000] .... 11.000001: tracing_mark_write: E|42",
    ])
    frame = {"Flags": 0, "DrawStart": 2_900_000_000, "SyncQueued": 3_050_000_000,
             "FrameCompleted": 3_060_000_000, "DisplayPresentTime": 3_100_000_000, "FrameTimelineVsyncId": 55}
    result = android.useful_launch_frame(trace, [frame], 42)
    assert result["usefulMs"] == 1100 and result["frameTimelineId"] == 55, result
    assert android.useful_launch_frame(trace, [{**frame, "Flags": 1}], 42) == result
    raises(perfcore.Unmeasurable, android.useful_launch_frame, trace, [{**frame, "Flags": 8}], 42)
    raises(perfcore.Unmeasurable, android.useful_launch_frame, trace, [frame, frame], 42)
    raises(perfcore.Unmeasurable, android.useful_launch_frame, trace, [{**frame, "DisplayPresentTime": 0}], 42)
    raises(perfcore.Unmeasurable, android.useful_launch_frame, trace.replace("monotonic-ns", "missing"), [frame], 42)


@case("A13 a rejected launch retains its raw report and trace")
def _():
    class Device:
        def sh(self, command, **kw):
            if command.startswith("am start"):
                return "Status: ok\nLaunchState: UNKNOWN (0)\n"
            return ""
        def run(self, *args, **kw): return "captured trace"
        def sleep(self, seconds): pass
        def pid(self): return 42
    with tempfile.TemporaryDirectory(prefix="perf-launch-evidence-") as directory:
        measure = android.Measure(Device(), evidence_dir=directory)
        measure.gfx = lambda: {"rows": []}
        raises(perfcore.Unmeasurable, measure.traced_launch)
        with open(os.path.join(directory, "launch-0001.json")) as file: saved = json.load(file)
        assert "UNKNOWN" in saved["rawLaunch"] and saved["error"], saved
        with android.gzip.open(os.path.join(directory, "launch-0001.trace.gz"), "rt") as file:
            assert file.read() == "captured trace"


@case("A5 frame timing counts deadline misses and stalls of 100 ms or more")
def _():
    rows = android.app_window(android.parse_framestats(fixture("gfxinfo-framestats-tap.txt")))["rows"]
    t = android.frame_timing(rows)
    assert t["frames"] == 18 and t["skippedRows"] == 1 and 0 <= t["onTimePercent"] <= 100, t
    assert t["maxFrameMs"] >= 60 and t["stallsOver100Ms"] >= 0, t
    assert android.frame_timing([]) == {"frames": 0, "skippedRows": 0}


@case("A6 batterystats checkin: the uid's rows only (captured), and every kind the background check reads")
def _():
    got = android.parse_checkin(fixture("batterystats-checkin.txt"), 10192)
    assert got["cpuMs"] == {"user": 23, "system": 40} and got["uidSeen"], got
    assert got["networkBytes"]["total"] == 0 and got["processes"][0]["name"] == "dev.richos.connect", got
    synthetic = "\n".join([  # SYNTHETIC rows in the checkin grammar, for the kinds the capture had none of
        '9,10192,l,nt,100,20,3000,400,1,1,2,2,0,0,0,0',
        '9,10192,l,wua,"*walarm*:dev.richos.connect/.Retry",3',
        '9,10192,l,wl,"*job*/dev.richos.connect/x",0,f,0,1200,p,2,0,bp,0',
        '9,10192,l,jb,"dev.richos.connect/x",1500,2',
        '9,10193,l,cpu,999,999,0',
        '9,10192,l,awl,1200,1200'])
    s = android.parse_checkin(synthetic, 10192)
    assert s["networkBytes"]["total"] == 3520 and s["wakeupAlarms"] == [{"name": "*walarm*:dev.richos.connect/.Retry", "count": 3}], s
    assert s["jobs"][0]["count"] == 2 and s["partialWakelockMs"] == 1200 and s["cpuMs"] is None, s
    assert android.parse_checkin(synthetic, 424242)["uidSeen"] is False


@case("A7 thread wakeups are per thread id, attribute new and ended threads, and sum")
def _():
    a = android.parse_threads("5911|.richos.connect|voluntary_ctxt_switches: 386 nonvoluntary_ctxt_switches: 931\n"
                              "5920|HeapTaskDaemon|voluntary_ctxt_switches: 15 nonvoluntary_ctxt_switches: 5\n"
                              "5930|DefaultDispatch|voluntary_ctxt_switches: 1 nonvoluntary_ctxt_switches: 1\n")
    b = android.parse_threads("5911|.richos.connect|voluntary_ctxt_switches: 388 nonvoluntary_ctxt_switches: 931\n"
                              "5920|HeapTaskDaemon|voluntary_ctxt_switches: 15 nonvoluntary_ctxt_switches: 5\n"
                              "5940|OkHttp Dispatch|voluntary_ctxt_switches: 4 nonvoluntary_ctxt_switches: 0\n")
    w = android.thread_wakeups(a, b)
    assert w["total"] == 6 and w["threadsEnded"] == [5930], w
    assert w["threads"][0] == {"tid": 5940, "thread": "OkHttp Dispatch", "switches": 4, "new": True}, w
    assert android.thread_wakeups(b, b)["total"] == 0


@case("A8 /proc stat, io, fsync trace and socket tables")
def _():
    assert android.parse_proc_stat_ticks("5911 (.richos connect) S 1 2 3 4 5 6 7 8 9 10 142 86 0 0 0 0 1 0 123 0") == 228
    io = android.parse_proc_io("rchar: 10\nwchar: 7020735\nsyscr: 3\nsyscw: 28108\nread_bytes: 0\nwrite_bytes: 180224\n")
    assert android.io_delta(io, dict(io, wchar=io["wchar"] + 500, syscw=io["syscw"] + 2))["wchar"] == 500
    raises(perfcore.Unmeasurable, android.parse_proc_io, "Permission denied")
    trace = ("  DefaultDispatch-5930  ( 5911) [001] ..... 300.1: ext4_sync_file_enter: dev 253,39 ino 1 parent 2 datasync 0\n"
             "  kworker-77  (   77) [000] ..... 300.2: ext4_sync_file_enter: dev 253,39 ino 9 parent 2 datasync 1\n"
             "  .richos.connect-5911  ( 5911) [001] ..... 300.3: f2fs_sync_file_enter: dev 253,39 ino 3\n")
    assert android.count_fsyncs(trace, 5911) == 2
    tcp = ("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
           "   0: 0100007F:1F90 0100007F:D2F0 01 00000000:00000000 00:00000000 00000000 10192        0 1\n"
           "   1: 0100007F:1F91 0100007F:D2F1 0A 00000000:00000000 00:00000000 00000000  1000        0 2\n")
    assert android.parse_sockets(tcp, 10192) == {"ESTABLISHED": 1}


@case("A9 the UI dump: nodes by description, text or substring, and their centers")
def _():
    xml = ('<?xml version="1.0"?><hierarchy><node text="perf probe" content-desc="" bounds="[21,2179][1059,2316]" clickable="true"/>'
           '<node text="" content-desc="Send message" bounds="[928,2185][1054,2311]" clickable="true"/></hierarchy>')
    nodes = android.ui_nodes(xml)
    assert android.center(android.find_node(nodes, desc="Send message")) == (991, 2248)
    assert android.find_node(nodes, contains="probe")["text"] == "perf probe"
    assert android.find_node(nodes, desc="Settings") is None
    raises(perfcore.Unmeasurable, android.ui_nodes, "null root node")


@case("A10 seeded history and streamed replies are synthetic frames of the phone protocol")
def _():
    frame = android.history_frame(3)
    data = json.loads(frame["wire"].split("data: ", 1)[1])
    assert frame["type"] == "receive" and frame["wire"].startswith("id: 1\nevent: hello\n")
    assert [m["role"] for m in data["messages"]] == ["ceo", "rich", "ceo"] and data["latest_cursor"] == 3
    opening, middle, final, full = android.stream_frames(50, 3)
    assert len(middle) == 3 and full == "word1 word2 word3 " and "event: delta" in middle[0]["wire"]
    assert json.loads(final["wire"].split("data: ", 1)[1])["complete"] is True


# ---------------------------------------------------------------------------------------------
# the whole Android run, against a scripted adb
# ---------------------------------------------------------------------------------------------

def quiet(_line):
    pass


SHA = "1602b71dcf27431d9b9a357d3a29fcd9565806a16e708dc247ddf233808660bf"


class FakeAdb:
    """Answers the adb commands the run issues, as the API 34 emulator did; records them all."""

    def __init__(self, installed=SHA, qemu="1", pid_changes_on_warm=False):
        self.calls, self.installed, self.qemu = [], installed, qemu
        self.cold_next, self.pid, self.pid_changes = True, 5911, pid_changes_on_warm
        self.state = {"draft": "", "messages": [], "paired": True}

    def bridge(self, cmd):
        command = re.search(r"--es command (\S+)", cmd).group(1)
        arg = re.search(r"--es arg64 (\S+)", cmd)
        arg = base64.b64decode(arg.group(1)).decode() if arg else None
        if command == "action":
            obj = json.loads(arg)
            if obj.get("type") == "receive" and "event: hello" in obj["wire"]:
                self.state["messages"] = json.loads(obj["wire"].split("data: ", 1)[1])["messages"]
        body = {"ok": True, "result": {"state": self.state}}
        return f'Broadcast completed: result=0, data="{base64.b64encode(json.dumps(body).encode()).decode()}"'

    def __call__(self, argv, capture_output=True, text=True, timeout=None):
        assert argv[:3] == ["/fake/adb", "-s", "emulator-5580"], argv  # never a bare adb
        args = argv[3:]
        cmd = " ".join(args[1:]) if args[0] == "shell" else " ".join(args)
        self.calls.append(cmd)
        out = ""
        if cmd.startswith("getprop ro.kernel.qemu"):
            out = self.qemu
        elif cmd.startswith("getprop"):
            out = "x"
        elif cmd.startswith("pm path"):
            out = "package:/data/app/~~x/dev.richos.connect/base.apk"
        elif cmd.startswith("sha256sum"):
            out = f"{self.installed}  /data/app/base.apk"
        elif cmd.startswith("dumpsys package"):
            out = "versionName=0.1.0-dev\n    versionCode=1 minSdk=29\n    pkgFlags=[ DEBUGGABLE HAS_CODE ]\n    appId=10192"
        elif cmd.startswith("am broadcast"):
            out = self.bridge(cmd)
        elif cmd.startswith("am force-stop"):
            self.cold_next = True
        elif cmd.startswith("am start"):
            out = AM_COLD if self.cold_next else AM_HOT
            self.cold_next = False
        elif cmd.startswith("input keyevent KEYCODE_HOME") and self.pid_changes:
            self.pid += 1
        elif cmd.startswith("date"):
            out = "1790217517.123456789"
        elif cmd.startswith("logcat"):
            out = LOGCAT
        elif cmd.startswith("pidof"):
            out = str(self.pid)
        elif cmd.startswith("exec-out cat /sdcard"):
            out = ('<?xml version="1.0"?><hierarchy><node text="Synthetic message 4 for the launch" content-desc="" bounds="[0,0][1,1]"/>'
                   '<node text="" content-desc="Message Rich" bounds="[21,2179][1059,2316]"/></hierarchy>')
        elif "gfxinfo" in cmd and "framestats" in cmd:
            out = "Window: dev.richos.connect/dev.richos.android.app.MainActivity\nTotal frames rendered: 0\n"
        elif cmd.startswith("for t in"):
            out = f"{self.pid}|.richos.connect|voluntary_ctxt_switches: 386 nonvoluntary_ctxt_switches: 931\n"
        elif cmd.startswith("cat /proc/") and cmd.endswith("/stat"):
            out = f"{self.pid} (.richos.connect) S 1 2 3 4 5 6 7 8 9 10 142 86 0 0 0 0 1 0 123 0"
        elif cmd.startswith("dumpsys batterystats --checkin"):
            out = fixture("batterystats-checkin.txt")
        elif cmd.startswith("cmd uimode night") and cmd.strip() == "cmd uimode night":
            out = "Night mode: no"
        return types.SimpleNamespace(returncode=0, stdout=out, stderr="")


def android_args(tmp, **over):
    stamp = os.path.join(tmp, "stamp.json")
    with open(stamp, "w") as f:
        json.dump({"commit": "b4b1b517011837108979b5e690cb84105fef6a53", "dirty": False, "sha256": SHA,
                   "paths": ["richos/mobile/native-android"]}, f)
    base = perf.parse_args(["android", "--adb", "/fake/adb", "--serial", "emulator-5580", "--kind", "emulator",
                            "--owned-by", "randroid", "--stamp", stamp, "--cold", "2", "--warm", "2",
                            "--history", "4", "--idle-seconds", "1", "--background-seconds", "1",
                            "--only", "seed,cold,idle-conversation,warm,background"])
    for k, v in over.items():
        setattr(base, k, v)
    return base


@case("R1 a scripted run yields a sound record: build, device, route, every metric with its method")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        fake, touched = FakeAdb(), []
        record, failures_ = perf.run_android(android_args(tmp), runner=fake, sleep=lambda s: None, log=quiet,
                                            host=lambda: {"cpuBusyPercent": 1.0}, touch=lambda: touched.append(1))
        assert failures_ == 0 and not perfcore.check_record(record), (failures_, perfcore.check_record(record), record["phases"])
        m = record["metrics"]
        assert m["coldLaunch"]["samplesMs"] == [1863, 1863] and m["coldLaunch"]["firstFrameMs"] == [1239, 1239], m["coldLaunch"]
        assert m["coldLaunch"]["screenCheck"] == {"composerOnScreen": True, "newestMessageOnScreen": True}
        assert m["warmResume"]["samplesMs"] == [185, 185] and m["idleFrames"]["zeroFrames"] is True
        assert m["backgroundQuiet"]["zeroWork"] is True and m["backgroundQuiet"]["threadWakeups"]["total"] == 0
        assert record["build"]["commit"].startswith("b4b1b517") and record["build"]["configuration"] == "debug"
        assert record["acceptance"]["verdict"] == "NOT VERIFIED" and record["device"]["kind"] == "emulator"
        assert record["conditions"]["transport"] == "unreachable"  # launch never waits on the network (Sage T6)
        assert touched, "the emulator lease was never renewed"
        assert "dumpsys battery reset" in fake.calls  # the unplugged state is always put back
        assert any("sendToQueued" in g["what"] for g in record["notMeasured"])


@case("R8 production launch and resume never invoke the Debug bridge")
def _():
    class ProductionAdb(FakeAdb):
        def bridge(self, cmd):
            raise AssertionError("production run invoked the development bridge")
    with tempfile.TemporaryDirectory() as tmp:
        record, failures_ = perf.run_android(
            android_args(tmp, production=True, route="tailnet", only="cold,warm"),
            runner=ProductionAdb(), sleep=lambda s: None, log=quiet, host=lambda: {})
        assert failures_ == 0, record["phases"]
        assert record["route"]["name"] == "tailnet"
        assert record["route"]["persistence"] == "production"
        assert record["conditions"]["productionControls"] is True
        assert "seed" not in record["phases"]


@case("R9 production Send timing records its method without invoking the bridge")
def _():
    from unittest.mock import patch
    with tempfile.TemporaryDirectory() as tmp:
        with patch.object(android.Measure, "tap", return_value={"samples": [20], "settled": [30], "burstFrames": [], "rejected": []}):
            record, failures_ = perf.run_android(
                android_args(tmp, production=True, exercise_sends=True, route="managed", only="tap"),
                runner=FakeAdb(), sleep=lambda s: None, log=quiet, host=lambda: {})
        assert failures_ == 0, record["phases"]
        assert "real controls" in record["metrics"]["tapToFeedback"]["method"]


@case("R10 physical background observation preserves battery history and reports unknown work")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        fake = FakeAdb(qemu="0")
        record, failures_ = perf.run_android(
            android_args(tmp, kind="physical", production=True, route="managed", only="background"),
            runner=fake, sleep=lambda s: None, log=quiet, host=lambda: {})
        assert failures_ == 0, record["phases"]
        assert record["metrics"]["backgroundQuiet"]["zeroWork"] is None
        assert record["metrics"]["backgroundQuiet"]["cpuTicks"] == 0
        assert not any("batterystats --reset" in c or "battery unplug" in c or "battery reset" in c for c in fake.calls)


@case("R11 native composer text is read from the EditText sharing its label bounds")
def _():
    nodes = android.ui_nodes('<hierarchy><node class="android.widget.EditText" text="keep existing work" bounds="[0,0][100,50]"/>'
                             '<node class="android.view.View" content-desc="Message Rich" text="" bounds="[0,0][100,50]"/></hierarchy>')
    assert android.composer_node(nodes)["text"] == "keep existing work"
    from unittest.mock import patch
    fake = FakeAdb()
    measure = android.Measure(android.Device("/fake/adb", "phone", runner=fake, sleep=lambda s: None), log=quiet)
    with patch.object(measure, "dump_ui", return_value=nodes):
        raises(perfcore.Unmeasurable, measure.enter_empty_composer, "probe")
    assert not any("input text" in c for c in fake.calls)


@case("R11b probe preparation delivers each ASCII character through a separate input invocation")
def _():
    from unittest.mock import patch
    nodes = android.ui_nodes('<hierarchy><node class="android.widget.EditText" text="" bounds="[0,0][100,50]"/>'
                             '<node class="android.view.View" content-desc="Message Rich" text="" bounds="[0,0][100,50]"/></hierarchy>')
    measure = android.Measure(android.Device("/fake/adb", "phone", runner=FakeAdb(), sleep=lambda s: None), log=quiet)
    commands = []
    with patch.object(measure, "dump_ui", return_value=nodes), patch.object(measure.d, "sh", side_effect=commands.append):
        measure.enter_empty_composer("Probe 190007")
    # Execute the generated device shell loop with a recording input command. No
    # Android device is touched. This catches grouping and whitespace mistakes.
    record_input = 'input() { [ "$1" = text ] || exit 9; printf "%s\\n" "$2"; }; '
    calls = subprocess.check_output(["/bin/sh", "-c", record_input + commands[-1]], text=True).splitlines()
    assert calls == list("Probe") + ["%s"] + list("190007"), calls
    for unsafe in ("probe;echo", "$(probe)", "é"):
        commands.clear()
        with patch.object(measure, "dump_ui", return_value=nodes), patch.object(measure.d, "sh", side_effect=commands.append):
            raises(perfcore.Unmeasurable, measure.enter_empty_composer, unsafe)
        assert not commands, "invalid probe must not tap or inject anything"


@case("R12 stopped Send setup retains completed trials and their raw evidence")
def _():
    from unittest.mock import patch
    with tempfile.TemporaryDirectory() as tmp:
        measure = android.Measure(android.Device("/fake/adb", "emulator-5580", runner=FakeAdb(), sleep=lambda s: None),
                                  log=quiet, evidence_dir=tmp)
        measure.probe_prefix = "unique probe"
        nodes = [{"text": "unique probe 1", "desc": "Send message", "bounds": [0, 0, 100, 50]},
                 {"text": "", "desc": "Message Rich", "bounds": [0, 50, 100, 100]}]
        before = [nodes[0], dict(nodes[1], text="unique probe 1")]
        with patch.object(measure, "enter_empty_composer", side_effect=[None, perfcore.Unmeasurable("occupied")]), \
             patch.object(measure, "dump_ui", side_effect=[before, nodes]), \
             patch.object(measure, "atrace", return_value="raw test trace"), \
             patch.object(measure, "gfx", return_value={"rows": []}), \
             patch.object(android, "tap_latency", return_value={"inputToFrameMs": 20, "inputToSettledMs": 30, "burstFrames": 1}):
            result = measure.tap(3, production=True)
        assert result["samples"] == [20]
        assert result["rejected"] == [{"trial": 2, "why": "occupied", "stoppedSeries": True}]
        assert os.path.exists(os.path.join(tmp, "tap-0001.trace.gz"))
        assert os.path.exists(os.path.join(tmp, "tap-0001.json"))


@case("R13 altered synthetic input is retained and never sent")
def _():
    from unittest.mock import patch
    fake = FakeAdb()
    measure = android.Measure(android.Device("/fake/adb", "emulator-5580", runner=fake, sleep=lambda s: None), log=quiet)
    measure.probe_prefix = "Perf probe 123456"
    nodes = [{"text": "Perf probe 12346 1", "desc": "Message Rich", "bounds": [0, 0, 100, 50]},
             {"text": "", "desc": "Send message", "bounds": [100, 0, 150, 50]}]
    with patch.object(measure, "enter_empty_composer"), patch.object(measure, "dump_ui", return_value=nodes):
        result = measure.tap(2, production=True)
    assert result["samples"] == [] and result["rejected"][0]["stoppedSeries"] is True
    assert not any("input tap" in c for c in fake.calls)


@case("R2 an installed APK that is not the stamped one is REFUSED before any measurement")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        fake = FakeAdb(installed="0" * 64)
        msg = raises(perfcore.Refused, perf.run_android, android_args(tmp), runner=fake, sleep=lambda s: None, log=quiet, host=lambda: {})
        assert "freshness mismatch" in msg and not any(c.startswith("am start") for c in fake.calls), (msg, fake.calls)


@case("R3 an emulator named without randroid, or a phone that is really an emulator, is REFUSED")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        msg = raises(perfcore.Refused, perf.run_android, android_args(tmp, owned_by=None), runner=FakeAdb(), sleep=lambda s: None, log=quiet)
        assert "randroid emu perf" in msg, msg
        msg = raises(perfcore.Refused, perf.run_android, android_args(tmp, kind="physical"), runner=FakeAdb(), sleep=lambda s: None, log=quiet, host=lambda: {})
        assert "is an emulator" in msg, msg
        msg = raises(perfcore.Refused, perf.run_android, android_args(tmp), runner=FakeAdb(qemu="0"), sleep=lambda s: None, log=quiet, host=lambda: {})
        assert "physical device" in msg, msg
        raises(perfcore.Refused, android.Device, "/fake/adb", "")


@case("R4 a warm trial whose process changed is rejected as cold, never counted as warm")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        record, _ = perf.run_android(android_args(tmp, only="seed,warm"), runner=FakeAdb(pid_changes_on_warm=True),
                                     sleep=lambda s: None, log=quiet, host=lambda: {})
        warm = record["metrics"]["warmResume"]
        assert warm["samplesMs"] == [] and len(warm["rejected"]) == 2 and "cold start" in warm["rejected"][0]["why"], warm


class VanishingAdb(FakeAdb):
    """The emulator is stopped (as the Mac's CPU breaker does) at the Nth launch: every later adb
    call fails as adb does, and one hangs past its timeout."""

    def __init__(self, launches):
        super().__init__()
        self.launches, self.gone = launches, False

    def __call__(self, argv, capture_output=True, text=True, timeout=None):
        cmd = " ".join(argv[3:])
        if "am start" in cmd:
            self.launches -= 1
            if self.launches < 0:
                self.gone = True
        if self.gone:
            if "wait-for-device" in cmd:
                raise subprocess.TimeoutExpired(argv, timeout)
            return types.SimpleNamespace(returncode=1, stdout="", stderr="adb: device 'emulator-5580' not found")
        return super().__call__(argv, capture_output, text, timeout)


@case("R6 a device that goes away mid-run still yields a record: what was measured, and why the rest was not")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        record, failures_ = perf.run_android(android_args(tmp), runner=VanishingAdb(launches=1), sleep=lambda s: None,
                                             host=lambda: {}, log=quiet)
        assert failures_ >= 1 and record["phases"]["cold"].startswith("NOT MEASURED"), record["phases"]
        assert record["phases"]["warm"].startswith("NOT RUN") and record["phases"]["background"].startswith("NOT RUN")
        assert any("went away" in g["why"] for g in record["notMeasured"]), record["notMeasured"]
        assert not perfcore.check_record(record), perfcore.check_record(record)
    dev = android.Device("/fake/adb", "emulator-5580", runner=VanishingAdb(launches=-1))
    dev.runner.gone = True
    assert "did not answer" in raises(perfcore.Unmeasurable, dev.run, "wait-for-device", timeout=1)


class RecreatingAdb(FakeAdb):
    """The process stays, the activity is recreated on every return (Android's WARM start)."""

    def __call__(self, argv, capture_output=True, text=True, timeout=None):
        out = super().__call__(argv, capture_output, text, timeout)
        cmd = " ".join(argv[3:])
        if "am start" in cmd and "HOT" in out.stdout:
            out.stdout = out.stdout.replace("HOT", "WARM").replace("185", "420")
        if "logcat -b events" in cmd:
            out.stdout = "1790220400.1 1000 1000 I wm_destroy_activity: [0,1,2,dev.richos.connect/dev.richos.android.app.MainActivity,trim]\n"
        return out


@case("R7 a resume that recreates the activity in the same process is warm (PRD J2), kept apart, with its reason")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        record, _ = perf.run_android(android_args(tmp, only="seed,warm"), runner=RecreatingAdb(), sleep=lambda s: None,
                                     host=lambda: {}, log=quiet)
        warm = record["metrics"]["warmResume"]
        assert warm["samplesMs"] == [420, 420] and warm["sampleStates"] == ["WARM", "WARM"], warm
        assert warm["recreatedStats"]["n"] == 2 and warm["hotStats"]["n"] == 0, warm
        assert warm["firstRecreation"] and warm["firstRecreation"][0].endswith("trim]"), warm["firstRecreation"]


@case("R5 perf.py main exits 3 with a sentence on a refusal and writes no record")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "r.json")
        code = perf.main(["android", "--adb", "/fake/adb", "--serial", "emulator-5580", "--kind", "emulator", "--out", out])
        assert code == 3 and not os.path.exists(out), code


# ---------------------------------------------------------------------------------------------
# iOS: parsers, the PRD §7 presentation join, the export re-read and the trace series
# ---------------------------------------------------------------------------------------------

@case("I1 a simulator is named by UDID and must be booted; 'booted' is refused")
def _():
    listing = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "AAA", "name": "iPhone 16", "state": "Booted"}, {"udid": "BBB", "name": "iPhone SE", "state": "Shutdown"}]}})
    assert ios.simulator(listing, "AAA") == {"kind": "simulator", "udid": "AAA", "model": "iPhone 16", "os": "iOS 18.0"}
    assert "never 'booted'" in raises(perfcore.Refused, ios.simulator, listing, "booted")
    assert "Shutdown" in raises(perfcore.Refused, ios.simulator, listing, "BBB")
    raises(perfcore.Refused, ios.simulator, listing, "CCC")


@case("I2 the useful-content signpost's time comes from the log; other subsystems and names are ignored")
def _():
    lines = "\n".join([
        json.dumps({"subsystem": "dev.richos.connect", "signpostName": "useful-content", "timestamp": "2026-09-25 10:00:01.250000+0000"}),
        json.dumps({"subsystem": "com.apple.UIKit", "signpostName": "useful-content", "timestamp": "2026-09-25 10:00:00.100000+0000"}),
        json.dumps({"subsystem": "dev.richos.connect", "signpostName": "foreground-useful", "timestamp": "2026-09-25 10:00:02.000000+0000"}),
        "Filtering the log data using ..."])
    marks = ios.parse_log_marks(lines, "useful-content")
    assert len(marks) == 1 and abs(marks[0] - 1790330401.25) < 1e-3, marks


@case("I3 simulator background: top's cumulative wakeups, switches and CPU; nettop bytes; launchctl pid")
def _():
    top = "Processes: 1 total\nPID  IDLEW CSW      TIME     \n4242 17    21494302+ 1:02:03.50\n"
    assert ios.parse_top(top) == {"idleWakeups": 17, "switches": 21494302, "cpuSeconds": 3723.5}
    raises(perfcore.Unmeasurable, ios.parse_top, "nothing")
    assert ios.parse_nettop(",bytes_in,bytes_out,\nRichOS.4242,120,30,\nother.1,5,5,\n", 4242) == 150
    assert ios.parse_launchctl_pid("PID\tStatus\tLabel\n4242\t0\tUIKitApplication:dev.richos.connect[1a2b][rb-legacy]\n") == 4242
    assert ios.parse_launchctl_pid("-\t0\tcom.apple.x\n") is None


@case("I4 an exported xctrace os-signpost table resolves id/ref values to the signpost's time")
def _():
    xml = ('<trace-query-result><node><schema name="os-signpost"/>'
           '<row><event-time id="1" fmt="00:00.812">812000000</event-time><name id="2">useful-content</name></row>'
           '<row><event-time id="3">900000000</event-time><name ref="2"/></row>'
           '<row><event-time id="4">50000000</event-time><name id="5">other</name></row>'
           '</node></trace-query-result>')
    assert ios.parse_xctrace_signposts(xml, "useful-content") == [812000000, 900000000]


@case("I5 physical draw timing joins lifecycle and signpost PID, rejects ambiguous or foreign marks")
def _():
    # Field tags and reference layout captured on iOS 26.3.1 with Xcode 26.3.
    # Nonzero origin deliberately prevents treating trace time as elapsed launch time.
    life = ('<trace-query-result><node><row><start-time>400000000</start-time>'
            '<process id="5"><pid id="6">717</pid></process>'
            '<app-period>Initializing - Process Creation</app-period></row></node></trace-query-result>')
    marks = ('<trace-query-result><node><row><event-time>500000000</event-time>'
             '<process id="4"><pid>717</pid></process><event-type id="7">Event</event-type>'
             '<signpost-name id="10">other</signpost-name><subsystem id="12">dev.richos.connect</subsystem></row>'
             '<row><event-time>1101743958</event-time><process ref="4"/><event-type ref="7"/>'
             '<signpost-name>useful-content</signpost-name><subsystem ref="12"/></row></node></trace-query-result>')
    result = ios.trace_useful_draw(life, marks)
    assert result == {"pid": 717, "creationNs": 400000000, "usefulDrawNs": 1101743958, "durationMs": 701.743958}
    raises(perfcore.Unmeasurable, ios.trace_useful_draw, life, marks.replace('<pid>717</pid>', '<pid>718</pid>'))
    raises(perfcore.Unmeasurable, ios.trace_useful_draw, life, marks.replace('dev.richos.connect', 'other.app'))
    raises(perfcore.Unmeasurable, ios.trace_useful_draw, life, marks.replace('1101743958', '300000000'))
    raises(perfcore.Unmeasurable, ios.trace_useful_draw, life, marks.replace('>other<', '>useful-content<'))
    raises(perfcore.Unmeasurable, ios.trace_useful_draw, '<root/>', marks)


@case("I6 a failed physical capture stops before trial two and retains the error")
def _():
    from unittest.mock import patch
    calls = []
    def failed(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 1, "partial capture", "device disconnected")
    with tempfile.TemporaryDirectory() as evidence, patch.object(ios, "evidence_root_ok", return_value=True):
        samples, rejected, retained = ios.device_cold("test-device", 100, evidence, failed)
        assert not samples and len(rejected) == 1 and len(calls) == 1
        assert 'os_signpost' in calls[0] and 'Frame Lifetimes' in calls[0] and '--launch' in calls[0]
        assert os.path.exists(os.path.join(retained, 'launch-0001.rejected.json'))
        assert open(os.path.join(retained, 'launch-0001.log.stderr')).read() == 'device disconnected'


@case("I6b traces are refused outside the mounted external SSD, before anything is captured")
def _():
    calls = []
    def never(cmd, **kwargs):
        calls.append(cmd)
        raise AssertionError("nothing may run")
    with tempfile.TemporaryDirectory() as elsewhere:
        if not os.path.realpath(elsewhere).startswith("/Volumes/E1TB/"):
            assert "--evidence-dir" in raises(perfcore.Refused, ios.trace_series, "cold", ios.Devicectl("d", never), 1, elsewhere, never)
    assert "--evidence-dir" in raises(perfcore.Refused, ios.trace_series, "cold", ios.Devicectl("d", never), 1, None, never)
    assert not calls


# Synthetic exports shaped exactly like Xcode 26.3's (columns, engineering-type tags, id/ref reuse),
# checked field by field against a physical iPhone SE capture whose data stays private (richos-hq).
LIFE_COLS = ["start", "group", "lane", "duration", "process", "period", "narrative"]
SIGN_COLS = ["time", "thread", "process", "event-type", "scope", "identifier", "name", "format-string", "backtrace",
             "subsystem", "category", "message", "emit-location"]
FRAME_COLS = ["start", "duration", "display-id", "lifetime-id", "swap-id", "frame-seed", "hitch-duration",
              "acceptable-latency", "hid-latency", "render-start", "render-duration", "layout-qualifier", "type-label",
              "narrative", "severity", "color"]
SWAP_COLS = ["timestamp", "delay", "display-name", "surface-id", "framebuffer-index", "swap-id", "color", "pixel-format",
             "hid-time", "generation-time", "min-quanta", "desired-presentation-time", "layer1-surface-id",
             "layer2-surface-id", "layer1-pixel-format", "layer2-pixel-format"]


def export(schema, cols, rows, schema_tag=True):
    head = "<schema name=\"%s\">%s</schema>" % (schema, "".join(f"<col><mnemonic>{c}</mnemonic></col>" for c in cols)) if schema_tag else ""
    return f"<?xml version=\"1.0\"?><trace-query-result><node xpath='//x'>{head}{''.join(rows)}</node></trace-query-result>"


def life_row(start, period, pid=717):
    return (f"<row><start-time>{start}</start-time><string>States</string><layout-id>0</layout-id><duration>1</duration>"
            f"<process><pid>{pid}</pid></process><app-period>{period}</app-period><narrative>n</narrative></row>")


def sign_row(ns, name, sub="dev.richos.connect", kind="Event", pid=717, main=True, message=None):
    thread = f"{'Main Thread 0x78d2' if main else 'Thread 0x9a1'} (RichOSNative, pid: {pid})"
    msg = f'<os-log-metadata fmt="{message}"/>' if message else "<sentinel/>"
    return (f"<row><event-time>{ns}</event-time><thread fmt=\"{thread}\"><tid>1</tid><process><pid>{pid}</pid></process>"
            f"</thread><process><pid>{pid}</pid></process><event-type>{kind}</event-type><string>Process</string>"
            f"<os-signpost-identifier>1</os-signpost-identifier><signpost-name>{name}</signpost-name><sentinel/><sentinel/>"
            f"<subsystem>{sub}</subsystem><category>c</category>{msg}<sentinel/></row>")


def frame_row(start, duration, swap, render):
    return (f"<row><start-time>{start}</start-time><duration>{duration}</duration><uint32>4294967295</uint32><uint32>1</uint32>"
            f"<uint32>{swap}</uint32><uint32>4294967295</uint32><sentinel/><sentinel/><sentinel/><start-time>{render}</start-time>"
            f"<duration>5000000</duration><layout-id>0</layout-id><sentinel/><formatted-label fmt=\"Frame\"/>"
            f"<event-concept>Info</event-concept><sentinel/></row>")


def swap_row(ns, swap):
    return (f"<row><start-time>{ns}</start-time><duration>1</duration><string>Built-In Display</string><uint32>160</uint32>"
            f"<uint32>0</uint32><uint32>{swap}</uint32><uint32>0</uint32><sentinel/><start-time>0</start-time>"
            f"<start-time>0</start-time><uint32>1</uint32><start-time>0</start-time><sentinel/><sentinel/><sentinel/><sentinel/></row>")


CA = "com.apple.coreanimation"


def launch_tables(**over):
    """A cold launch: creation at 400 ms; composer 900, viewport 1010 (after a commit ending at 1000
    that only carried the first draw), carrying commit 1011-1015, input-ready 1015.05; a frame whose
    render began at 1012 (before the commit ended) and the first frame rendered after it at 1020."""
    marks = over.get("marks") or [
        sign_row(900_000_000, "composer-ready"), sign_row(990_000_000, "Commit", CA, "Begin"),
        sign_row(995_000_000, "useful-content"), sign_row(1_000_000_000, "Commit", CA, "End"),
        sign_row(1_010_000_000, "viewport-ready"), sign_row(1_011_000_000, "Commit", CA, "Begin"),
        sign_row(1_013_000_000, "Commit", CA, "End", main=False),  # another thread's commit never carries it
        sign_row(1_015_000_000, "Commit", CA, "End"), sign_row(1_015_050_000, "input-ready")]
    frames = over.get("frames") or [frame_row(996_000_000, 40_000_000, 10, 1_012_000_000),
                                     frame_row(1_003_000_000, 50_000_000, 11, 1_020_000_000),
                                     frame_row(1_019_000_000, 50_000_000, 12, 1_036_000_000)]
    swaps = over.get("swaps") or [swap_row(1_036_000_000, 10), swap_row(1_053_000_000, 11), swap_row(1_069_000_000, 12)]
    life = over.get("life") or [life_row(400_000_000, "Initializing - Process Creation"),
                                life_row(1_300_000_000, "Launching - UIKit Scene Creation")]
    return {"life-cycle-period": export("life-cycle-period", LIFE_COLS, life),
            "os-signpost": export("os-signpost", SIGN_COLS, marks),
            "coreanimation-lifetime-interval": export("coreanimation-lifetime-interval", FRAME_COLS, frames),
            "display-surface-swap": export("display-surface-swap", SWAP_COLS, swaps)}


@case("I7 a cold launch ends at the swap presenting the commit that carried viewport and composer, not at the draw")
def _():
    s = ios.launch_sample(launch_tables())
    assert s["pid"] == 717 and s["commitEndNs"] == 1_015_000_000 and s["swapId"] == 11, s
    assert s["presentedNs"] == 1_053_000_000 and s["inputReadyNs"] == 1_015_050_000 and s["endNs"] == 1_053_000_000
    assert s["durationMs"] == 653.0 and s["startBoundary"] == "Initializing - Process Creation"
    assert s["phasesMs"]["usefulDraw"] == 595.0 and s["phasesMs"]["presented"] == 653.0, s["phasesMs"]


@case("I8 the join rejects foreign, ambiguous, missing and out-of-order marks rather than guess")
def _():
    base = launch_tables()
    def with_marks(change):
        rows = [sign_row(900_000_000, "composer-ready"), sign_row(995_000_000, "useful-content"),
                sign_row(1_000_000_000, "Commit", CA, "End"), sign_row(1_010_000_000, "viewport-ready"),
                sign_row(1_015_000_000, "Commit", CA, "End"), sign_row(1_015_050_000, "input-ready")]
        return {**base, "os-signpost": export("os-signpost", SIGN_COLS, change(rows))}
    cases = {
        # the app's marks from another process while the target's own commits stay: only the pid check rejects it
        "foreign process": lambda r: [x.replace("pid>717<", "pid>718<").replace("pid: 717", "pid: 718")
                                      if "dev.richos.connect" in x else x for x in r],
        "two input-ready": lambda r: r + [sign_row(1_016_000_000, "input-ready")],
        "no input-ready (composer disabled)": lambda r: r[:-1],
        "no composer-ready": lambda r: r[1:],
        "no viewport-ready": lambda r: r[:3] + r[4:],
        "input-ready before the carrying commit": lambda r: r[:4] + [sign_row(1_012_000_000, "input-ready"),
                                                                    sign_row(1_015_000_000, "Commit", CA, "End")],
        "other subsystem": lambda r: [x.replace("dev.richos.connect", "com.example") for x in r],
    }
    for name, change in cases.items():
        try:
            ios.launch_sample(with_marks(change))
        except perfcore.Unmeasurable:
            continue
        raise AssertionError(f"accepted: {name}")
    assert "exactly one" in raises(perfcore.Unmeasurable, ios.launch_sample,
                                   {**base, "life-cycle-period": export("life-cycle-period", LIFE_COLS, [])})
    assert ios.launch_sample(with_marks(lambda r: r))["swapId"] == 11  # the unchanged control is accepted


@case("I9 presentation is refused when the frame data cannot be a display pipeline or is ambiguous")
def _():
    frames = lambda rows: {**launch_tables(), "coreanimation-lifetime-interval": export("coreanimation-lifetime-interval", FRAME_COLS, rows)}
    swaps = lambda rows: {**launch_tables(), "display-surface-swap": export("display-surface-swap", SWAP_COLS, rows)}
    assert "no frame" in raises(perfcore.Unmeasurable, ios.launch_sample, frames([frame_row(996_000_000, 40_000_000, 10, 1_012_000_000)]))
    assert "same instant" in raises(perfcore.Unmeasurable, ios.launch_sample, frames(
        [frame_row(1_003_000_000, 50_000_000, 11, 1_020_000_000), frame_row(1_004_000_000, 60_000_000, 12, 1_020_000_000)]))
    assert "lifetime ends" in raises(perfcore.Unmeasurable, ios.launch_sample, swaps([swap_row(1_070_000_000, 11)]))
    assert "display swaps" in raises(perfcore.Unmeasurable, ios.launch_sample, swaps([swap_row(1_069_000_000, 12)]))
    # the Simulator (Xcode 26.3): a swap shown before its own render began
    sim = {**launch_tables(), "coreanimation-lifetime-interval": export("coreanimation-lifetime-interval", FRAME_COLS,
                                                                        [frame_row(0, 1_030_000_000, 11, 1_040_000_000)]),
           "display-surface-swap": export("display-surface-swap", SWAP_COLS, [swap_row(1_030_000_000, 11)])}
    assert "not physical" in raises(perfcore.Unmeasurable, ios.launch_sample, sim)


@case("I10 an export is read only with its own schema: no schema, several tables or a short row is refused")
def _():
    t = launch_tables()
    rows = ios.lifecycle(t["life-cycle-period"])
    assert rows[0] == {"start": 400_000_000, "duration": 1, "pid": 717, "period": "Initializing - Process Creation"}
    refd = ('<trace-query-result><node><schema name="os-signpost">' + "".join(f"<col><mnemonic>{c}</mnemonic></col>" for c in SIGN_COLS)
            + '</schema>' + sign_row(5, "input-ready").replace("<process><pid>717</pid></process><event-type>",
                                                                  '<process id="9"><pid id="10">717</pid></process><event-type>')
            + sign_row(6, "input-ready").replace('<process><pid>717</pid></process><event-type>', '<process ref="9"/><event-type>')
            + '</node></trace-query-result>')
    assert [m["pid"] for m in ios.signposts(refd)] == [717, 717]  # a ref resolves to the first row's process
    assert "schema" in raises(perfcore.Unmeasurable, ios.lifecycle, export("life-cycle-period", LIFE_COLS, [], schema_tag=False))
    two = t["life-cycle-period"].replace("</trace-query-result>", "<node xpath='//y'><row/></node></trace-query-result>")
    assert "found 2" in raises(perfcore.Unmeasurable, ios.lifecycle, two)
    short = export("life-cycle-period", LIFE_COLS, ["<row><start-time>1</start-time></row>"])
    assert "cells" in raises(perfcore.Unmeasurable, ios.lifecycle, short)
    assert "found 0" in raises(perfcore.Unmeasurable, ios.frame_lifetimes, "<trace-query-result/>")


def return_tables(**over):
    """A warm return in retained process 717: AppResume at 2496 ms, the foreground draw at 2940.9
    inside a commit ending 2940.92, input-ready 2941.04, the next render 2950 shown at 2975."""
    marks = over.get("marks") or [
        sign_row(2_496_000_000, "AppResume", "com.apple.UIKit", "Begin", message=" enableTelemetry=YES WasFrozen= 0  IsForeground= 1"),
        sign_row(2_503_000_000, "AppResume", "com.apple.UIKit", "End"),
        sign_row(2_940_900_000, "foreground-useful"), sign_row(2_940_920_000, "Commit", CA, "End"),
        sign_row(2_941_040_000, "input-ready")]
    return {"life-cycle-period": export("life-cycle-period", LIFE_COLS, over.get("life") or []),
            "os-signpost": export("os-signpost", SIGN_COLS, marks),
            "coreanimation-lifetime-interval": export("coreanimation-lifetime-interval", FRAME_COLS,
                                                      [frame_row(2_930_000_000, 45_000_000, 40, 2_950_000_000)]),
            "display-surface-swap": export("display-surface-swap", SWAP_COLS, [swap_row(2_975_000_000, 40)])}


@case("I11 a warm return runs from UIKit's AppResume to the presented foreground draw in the same process; a relaunch is cold")
def _():
    s = ios.return_sample(return_tables(), 717)
    assert s["class"] == "warm" and s["startNs"] == 2_496_000_000 and s["presentedNs"] == 2_975_000_000
    assert s["durationMs"] == 479.0 and s["phasesMs"]["inputReady"] == 445.04, s
    assert "cold start" in raises(perfcore.Unmeasurable, ios.return_sample,
                                  return_tables(life=[life_row(2_400_000_000, "Initializing - Process Creation")]), 717)
    assert "not the retained process" in raises(perfcore.Unmeasurable, ios.return_sample, return_tables(), 718)
    background = [sign_row(2_496_000_000, "AppResume", "com.apple.UIKit", "Begin", message="IsForeground= 0"),
                  sign_row(2_940_900_000, "foreground-useful"), sign_row(2_940_920_000, "Commit", CA, "End"),
                  sign_row(2_941_040_000, "input-ready")]
    assert "AppResume" in raises(perfcore.Unmeasurable, ios.return_sample, return_tables(marks=background), 717)


@case("I12 an exporter killed by a signal is re-read and every attempt is kept; other failures stop at once")
def _():
    good = launch_tables()
    def exporter(script):
        calls = []
        def run(cmd, **kwargs):
            table = cmd[cmd.index("--xpath") + 1].split('"')[-2]
            calls.append(table)
            code = script.pop(0) if script else 0
            return subprocess.CompletedProcess(cmd, code, good[table] if code == 0 else "", "")
        return run, calls
    with tempfile.TemporaryDirectory() as d:
        prefix = os.path.join(d, "launch-0001")
        run, calls = exporter([-11, -9, 0])
        tables, attempts = ios.export_tables("t.trace", prefix, run, pause=lambda s: None)
        assert set(tables) == set(ios.TABLES) and calls[:3] == ["life-cycle-period"] * 3
        assert [a["exit"] for a in attempts][:3] == [-11, -9, 0]
        assert json.load(open(prefix + ".exports.json")) == attempts
        run, calls = exporter([1])
        assert "exit 1" in raises(perfcore.Unmeasurable, ios.export_tables, "t.trace", prefix, run, pause=lambda s: None)
        assert calls == ["life-cycle-period"]
        run, calls = exporter([-11] * ios.EXPORT_ATTEMPTS)
        assert "--reparse" in raises(perfcore.Unmeasurable, ios.export_tables, "t.trace", prefix, run, pause=lambda s: None)
        assert len(calls) == ios.EXPORT_ATTEMPTS and len(json.load(open(prefix + ".exports.json"))) == ios.EXPORT_ATTEMPTS


@case("I13 the build configuration comes from the stamped bundle's bytes, by check-release's own markers")
def _():
    with open(os.path.join(MOBILE, "native-ios", "Core", "Sources", "RichOSCLI", "Simulator.swift")) as f:
        swift = f.read()
    listed = re.search(r"static let developmentMarkers = \[(.*?)\]", swift).group(1)
    assert [m.strip().strip('"') for m in listed.split(",")] == ios.DEVELOPMENT_MARKERS
    with tempfile.TemporaryDirectory() as d:
        app = os.path.join(d, "RichOSNative.app")
        os.makedirs(app)
        with open(os.path.join(app, "RichOSNative"), "wb") as f:
            f.write(b"\0".join(m.encode() for m in ios.DEVELOPMENT_MARKERS))
        assert ios.build_configuration(app) == "debug"
        with open(os.path.join(app, "RichOSNative"), "wb") as f:
            f.write(b"release code only")
        assert ios.build_configuration(app) == "release"
        with open(os.path.join(app, "RichOSNative"), "wb") as f:
            f.write(b"rios-fixture")
        assert ios.build_configuration(app) is None  # partial: neither claim
    assert ios.build_configuration(None) is None and ios.build_configuration("/no/such.app") is None


@case("I14 the tool's mark names are the app's: every one is emitted by PerformanceMarks.swift")
def _():
    with open(os.path.join(MOBILE, "native-ios", "App", "Platform", "PerformanceMarks.swift")) as f:
        swift = f.read()
    for name in (ios.VIEWPORT, ios.COMPOSER, ios.READY, ios.USEFUL, ios.FOREGROUND):
        assert f'name: "{name}")' in swift, name
    assert "CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false" in swift  # one-shot
    assert "Timer" not in swift and "DispatchSourceTimer" not in swift and "asyncAfter" not in swift


class FakeProc:
    def __init__(self, code=0):
        self.code, self.returncode = code, None
    def wait(self, timeout=None):
        if self.returncode is None:
            self.returncode = self.code
        return self.returncode
    def poll(self):
        return self.returncode
    def terminate(self):
        self.returncode = -15


class FakeDriver:
    target = "test-device"
    def __init__(self, pids):
        self.pids, self.events = list(pids), []
    def pid(self):
        self.events.append("pid")
        return self.pids.pop(0)
    def launch(self, bundle, *args):
        self.events.append(("launch", bundle) + args)


@case("I15 a warm trial backgrounds, attaches, returns only after tracing started, and rejects a changed process")
def _():
    from unittest.mock import patch
    started = []
    def popen(cmd, **kwargs):
        started.append(cmd)
        return FakeProc(0)
    good = return_tables()
    def exporter(cmd, **kwargs):
        table = cmd[cmd.index("--xpath") + 1].split('"')[-2]
        return subprocess.CompletedProcess(cmd, 0, good[table], "")
    with tempfile.TemporaryDirectory() as d, patch.object(ios, "evidence_root_ok", return_value=True):
        driver = FakeDriver([717, 717])
        samples, rejected, ev = ios.trace_series("warm", driver, 1, d, exporter, popen, lambda s: None)
        assert not rejected and samples[0]["durationMs"] == 479.0, rejected
        assert driver.events == ["pid", ("launch", ios.AWAY_APP), ("launch", ios.BUNDLE), "pid"], driver.events
        notify, record = started
        assert notify[:2] == ["notifyutil", "-1"] and record[record.index("--notify-tracing-started") + 1] == notify[2]
        assert record[record.index("--attach") + 1] == "717" and "Frame Lifetimes" in record
        assert json.load(open(os.path.join(ev, "return-0001.trial.json"))) == {"pid": 717}
        driver = FakeDriver([717, 902])
        samples, rejected, _ = ios.trace_series("warm", driver, 5, d, exporter, popen, lambda s: None)
        assert not samples and len(rejected) == 1 and "cold start" in rejected[0]["why"]
        failing = lambda cmd, **kw: FakeProc(0) if cmd[0] == "notifyutil" else FakeProc(3)
        samples, rejected, _ = ios.trace_series("warm", FakeDriver([717, 717]), 5, d, exporter, failing, lambda s: None)
        assert not samples and "capture failed (3)" in rejected[0]["why"]


class SilentWaiter(FakeProc):
    """notifyutil that never hears the notification (a recorder that could not attach)."""
    def wait(self, timeout=None):
        if timeout is not None and self.returncode is None:
            raise subprocess.TimeoutExpired("notifyutil", timeout)
        return super().wait(timeout)


class EndedRecorder(FakeProc):
    def __init__(self):
        super().__init__(70)
        self.returncode = 70  # already exited


@case("I15b a recorder that ends before tracing starts fails the trial at once; the app is never backgrounded")
def _():
    from unittest.mock import patch
    procs = []
    def popen(cmd, **kwargs):
        procs.append(SilentWaiter() if cmd[0] == "notifyutil" else EndedRecorder())
        return procs[-1]
    with tempfile.TemporaryDirectory() as d, patch.object(ios, "evidence_root_ok", return_value=True):
        driver = FakeDriver([717])
        samples, rejected, _ = ios.trace_series("warm", driver, 3, d, None, popen, lambda s: None)
        assert not samples and "ended (70) before tracing started" in rejected[0]["why"], rejected
        assert driver.events == ["pid"], driver.events  # never sent to the background
        assert procs[0].returncode == -15  # the waiter it started was stopped
        assert "--trace-seconds" in raises(perfcore.Refused, ios.trace_series, "warm", FakeDriver([717]), 1, d,
                                           None, popen, lambda s: None, seconds=6, away=2.0)


def ios_args(**over):
    base = dict(simulator=None, device="test-device", reparse=None, stamp=None, expect_commit=None, cold=1, warm=0,
                evidence_dir="unused", away=2.0, trace_seconds=10, app_arg=None, xctrace=False)
    base.update(over)
    return types.SimpleNamespace(**base)


def devicectl_listing(cmd, **kwargs):
    with open(cmd[cmd.index('--json-output') + 1], 'w') as f:
        json.dump({"result": {"devices": [{"identifier": "test-device", "hardwareProperties": {"marketingName": "iPhone"},
                    "deviceProperties": {"osVersionNumber": "26.3.1"}}]}}, f)
    return subprocess.CompletedProcess(cmd, 0, '', '')


@case("I16 a physical record carries the PRD boundary, a budget comparison and why acceptance is still NOT VERIFIED")
def _():
    from unittest.mock import patch
    sample = {**ios.launch_sample(launch_tables()), "trial": 1, "trace": "/t/launch-0001.trace", "exportAttempts": 5}
    with tempfile.TemporaryDirectory() as d:
        stamp = os.path.join(d, "stamp.json")
        with open(stamp, "w") as f:
            json.dump({"commit": "c" * 40, "dirty": False, "sha256": "f" * 64, "artifact": "/no/longer/here.app"}, f)
        with patch.object(ios, 'trace_series', return_value=([sample], [], d)):
            record, failed = ios.run_ios(ios_args(stamp=stamp, expect_commit="ccc"), runner=devicectl_listing)
        assert not failed and record['ranOnHardware'] is True and 'coldUsefulDraw' not in record['metrics']
        metric = record['metrics']['coldLaunch']
        assert metric['samplesMs'] == [653.0] and metric['budget']['budget'] == 1000 and metric['exportAttempts'] == 5
        assert metric['startBoundary'] == "Initializing - Process Creation" and "presented" in metric['endBoundary']
        assert record['acceptance']['verdict'] == 'NOT VERIFIED'
        why = " ".join(record['acceptance']['why'])
        assert "configuration is unknown" in why and "no warm return distribution" in why and "below the PRD" in why
        assert json.load(open(os.path.join(d, "series.json")))["class"] == "cold"
        assert not perfcore.check_record(record), perfcore.check_record(record)


@case("I17 --reparse re-reads a retained series with its recorded device and build, capturing nothing")
def _():
    good = launch_tables()
    def exporter(cmd, **kwargs):
        assert cmd[:3] == ["xcrun", "xctrace", "export"], cmd  # nothing records, lists or launches
        table = cmd[cmd.index("--xpath") + 1].split('"')[-2]
        return subprocess.CompletedProcess(cmd, 0, good[table], "")
    with tempfile.TemporaryDirectory() as d:
        for n in (1, 2):
            os.makedirs(os.path.join(d, f"launch-000{n}.trace"))
        with open(os.path.join(d, "series.json"), "w") as f:
            json.dump({"class": "cold", "device": {"kind": "physical", "udid": "u", "model": "iPhone SE", "os": "iOS 26.3.1"},
                       "build": {"bundle": ios.BUNDLE, "commit": "c" * 40, "dirty": False, "configuration": "release"}}, f)
        record, failed = ios.run_ios(ios_args(device=None, reparse=d), runner=exporter)
        assert not failed and record['metrics']['coldLaunch']['samplesMs'] == [653.0, 653.0]
        assert record['device']['model'] == "iPhone SE" and record['ranOnHardware'] is True
        assert "not a release" not in " ".join(record['acceptance']['why'])


@case("P1 pacing waits for four quiet seconds under 1.5 cores on the emulator's host process, gives up at 30 s, says so")
def _():
    with tempfile.TemporaryDirectory() as cache:
        assert perf.emulator_pacer(cache) == (None, [])  # no emulator record: no pacing, no guess
        with open(os.path.join(cache, "emulator.json"), "w") as f:
            json.dump({"pid": 4242, "serial": "emulator-5580"}, f)
        now = [0.0]

        def sleep(s):
            now[0] += s
        cpu = iter([0.0, 6.5, 9.0, 9.4, 9.8, 10.2, 10.6])  # 6.5 cores, 2.5, then 0.4 for four seconds
        pace, waits = perf.emulator_pacer(cache, sleep=sleep, clock=lambda: now[0], cpu_seconds=lambda: next(cpu))
        pace()
        assert waits == [{"waitedSeconds": 6.0, "cores": 0.4, "quiet": True}], waits
        cpu = iter([0.0, 0.4, 0.8, 3.8, 4.2, 4.6, 5.0, 5.4])  # quiet twice, busy, then quiet four times
        pace, waits = perf.emulator_pacer(cache, sleep=sleep, clock=lambda: now[0], cpu_seconds=lambda: next(cpu))
        pace()
        assert waits[0]["waitedSeconds"] == 7.0 and waits[0]["quiet"], waits  # a busy second restarts the count
        busy = iter([float(i * 5) for i in range(100)])  # always 5 cores
        pace, waits = perf.emulator_pacer(cache, sleep=sleep, clock=lambda: now[0], cpu_seconds=lambda: next(busy))
        pace()
        assert waits[0]["quiet"] is False and waits[0]["waitedSeconds"] >= 30, waits


@case("M1 merge: parts of one build (same bytes) on one device become one record; twice-measured, other bytes or dirty refused")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        first, _ = perf.run_android(android_args(tmp, only="seed,cold"), runner=FakeAdb(), sleep=lambda s: None, host=lambda: {}, log=quiet)
        second, _ = perf.run_android(android_args(tmp, only="seed,warm"), runner=FakeAdb(), sleep=lambda s: None, host=lambda: {}, log=quiet)
        first["phases"]["warm"] = "NOT RUN: the device went away"
        first["notMeasured"].append({"what": "warm", "why": "not run: the device went away"})
        merged = perf.merge_records([first, second])
        assert set(merged["metrics"]) == {"coldLaunch", "warmResume"} and merged["metrics"]["warmResume"]["part"] == 2
        assert merged["phases"]["warm"] == "measured (part 2)" and not any(g["what"] == "warm" for g in merged["notMeasured"])
        assert len(merged["parts"]) == 2 and not perfcore.check_record(merged), perfcore.check_record(merged)
        assert "measured in two parts" in raises(perfcore.Refused, perf.merge_records, [first, first])
        other = json.loads(json.dumps(second))
        other["build"]["installedSha256"] = "f" * 64
        assert "build installedSha256 differs" in raises(perfcore.Refused, perf.merge_records, [first, other])
        later = json.loads(json.dumps(second))
        later["build"]["commit"] = "c" * 40  # same bytes, stamped at a later commit: one build
        assert perf.merge_records([first, later])["build"]["commits"] == sorted({first["build"]["commit"], "c" * 40})
        later["build"]["dirty"] = True
        assert "uncommitted" in raises(perfcore.Refused, perf.merge_records, [first, later])
        # idle frames merge per screen; the same screen twice is refused
        a, b = json.loads(json.dumps(first)), json.loads(json.dumps(second))
        a["metrics"]["idleFrames"] = {"method": "m", "screens": {"conversation": {"framesRendered": 0}}, "zeroFrames": True}
        b["metrics"]["idleFrames"] = {"method": "m", "screens": {"pairing": {"framesRendered": 3}}, "zeroFrames": False}
        idle = perf.merge_records([a, b])["metrics"]["idleFrames"]
        assert set(idle["screens"]) == {"conversation", "pairing"} and idle["zeroFrames"] is False, idle
        assert idle["screens"]["pairing"]["part"] == 2
        b["metrics"]["idleFrames"]["screens"] = {"conversation": {"framesRendered": 0}}
        assert "measured in two parts" in raises(perfcore.Refused, perf.merge_records, [a, b])


BASELINES = os.path.abspath(os.path.join(HERE, "..", "..", "..", "docs", "verification"))


@case("B1 every committed baseline record is sound, and its record.json is exactly the merge of its parts")
def _():
    found = 0
    for name in sorted(os.listdir(BASELINES)):
        if not name.endswith("-perf-baseline"):
            continue
        folder = os.path.join(BASELINES, name)
        parts_dir = os.path.join(folder, "parts")
        parts = [os.path.join(parts_dir, p) for p in sorted(os.listdir(parts_dir))] if os.path.isdir(parts_dir) else []
        for path in [os.path.join(folder, "record.json")] + parts:
            with open(path) as f:
                problems = perfcore.check_record(json.load(f))
            assert not problems, (path, problems)
            found += 1
        if parts:
            loaded = []
            for p in parts:
                with open(p) as f:
                    loaded.append(json.load(f))
            with open(os.path.join(folder, "record.json")) as f:
                committed = json.load(f)
            again = perf.merge_records(loaded)
            assert again["metrics"] == committed["metrics"] and again["build"] == committed["build"], name
            assert committed["acceptance"]["verdict"] == "NOT VERIFIED" or committed["device"]["kind"] == "physical", name
    assert found, "no committed baseline found under docs/verification"


# ---------------------------------------------------------------------------------------------
# the mobile CLIs hand the tool what makes a measurement trustworthy
# ---------------------------------------------------------------------------------------------

MOBILE = os.path.abspath(os.path.join(PERF, ".."))


@case("W1 randroid stamps the APK it installs and hands emu perf its recorded serial, lease and that stamp")
def _():
    with open(os.path.join(MOBILE, "native-android", "bin", "randroid")) as f:
        script = f.read()
    install = script[script.index("emu_install() {"):script.index("emu_command() {")]
    assert install.index("perf.py\" stamp") < install.index("install -r -t"), "the stamp must be written before the install"
    assert '> "$apk.stamp.json"' in install
    perf_verb = script[script.index("    perf)"):script.index(";;", script.index("    perf)"))]
    for needle in ('s="$(serial)"', '--serial "$s"', "--kind emulator", "--owned-by randroid", '--lease "$CACHE"',
                   '--stamp "$OUT/app/outputs/apk/debug/app-debug.apk.stamp.json"'):
        assert needle in perf_verb, needle
    adb_verb = script[script.index("    adb)"):script.index(";;", script.index("    adb)"))]
    assert 'adb_s "$@"' in adb_verb, adb_verb  # the recorded serial only, never a bare adb


@case("W2 rios perf goes to perf.py ios before any Swift build")
def _():
    with open(os.path.join(MOBILE, "native-ios", "bin", "rios")) as f:
        script = f.read()
    assert script.index('= "perf" ]') < script.index("swift build"), "perf must not wait on the core's build"
    assert 'perf.py" ios "$@"' in script


if __name__ == "__main__":
    total = sum(1 for line in open(__file__) if line.startswith("@case("))
    if failures:
        print(f"mobile-perf: {len(failures)} of {total} FAILED: {', '.join(failures)}")
        sys.exit(1)
    print(f"mobile-perf: {total} cases passed")
