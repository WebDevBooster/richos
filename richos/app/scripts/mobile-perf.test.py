#!/usr/bin/env python3
"""mobile-perf.test.py — the RichConnect measurement tool (richos/mobile/perf) answers from what the
platform printed, and refuses rather than measure the wrong build or the wrong device.

Parsers run against output captured from the API 34 emulator on 2026-09-24 (fixtures/android/),
the whole Android run against a scripted adb, and the iOS parsers against output SHAPED like the
tools' documented output (the iOS side has not run on hardware; ios.py says so). Nothing boots,
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
    assert android.parse_proc_stat_ticks("5911 (.richos connect) S 1 2 3 4 5 6 7 8 9 10 142 86 0 0") == 228
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
            out = f"{self.pid} (.richos.connect) S 1 2 3 4 5 6 7 8 9 10 142 86 0 0"
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
# iOS parsers (shaped like the tools' documented output; not captured — ios.py has not run)
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
