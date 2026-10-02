#!/usr/bin/env python3
"""mobile-blank.test.py — the no-blank-screen checks (CEO, 2026-10-02) answer from what the screen showed.

The frame analyzer (richos/mobile/perf/blank.py) on SYNTHETIC frames only: phone recordings are
private and never enter this repository. A launch is built frame by frame: a still home screen, the
home screen reacting to the tap, then whatever the app shows. Then the series verdict, the phone
glue (blankstart.py) against a scripted phone, and the static launch-surface check
(launchscreen.py) on synthetic trees and on this tree. Nothing boots, builds, records or decodes.
"""
import os
import re
import shutil
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PERF = os.path.abspath(os.path.join(HERE, "..", "..", "mobile", "perf"))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, PERF)

import blank  # noqa: E402
import blankstart  # noqa: E402
import launchscreen  # noqa: E402
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


def raises(exc, fn, *a, **kw):
    try:
        fn(*a, **kw)
    except exc as e:
        return str(e)
    raise AssertionError(f"{fn.__name__} did not raise {exc.__name__}")


# ------------------------------------------------------------------------------------------------
# synthetic frames: 36 x 80, so the analyzed rows (system bars left out) are 4..75
# ------------------------------------------------------------------------------------------------

W, H = 36, 80
WALLPAPER, ICON = (40, 90, 120), (230, 200, 40)
WHITE, LIGHT_GROUND, DARK_GROUND, INK = (255, 255, 255), (234, 230, 221), (12, 19, 34), (30, 30, 30)
LIMIT = blank.BLANK_LIMIT_MS / 1000.0


def paint(ground, rects=()):
    buf = bytearray(bytes(ground) * (W * H))
    for x0, y0, x1, y1, c in rects:
        for y in range(y0, y1):
            for x in range(x0, x1):
                buf[(y * W + x) * 3:(y * W + x) * 3 + 3] = bytes(c)
    return bytes(buf)


ICONS = [(x, y, x + 6, y + 6, ICON) for x in range(3, 33, 9) for y in range(8, 70, 12)]
HOME = paint(WALLPAPER, ICONS)
HOME_PRESSED = paint(WALLPAPER, ICONS[:1] + [(3, 8, 9, 14, (120, 100, 20))] + ICONS[1:])  # the tapped icon darkens


def lines(ground, y0, y1):
    """Text-like content: a line of ink every 4 rows from y0 to y1."""
    return paint(ground, [(4, y, 32, y + 2, INK) for y in range(y0, y1, 4)])


def logo(ground):
    return paint(ground, [(13, 35, 23, 45, (200, 160, 60))])            # a 10 x 10 mark: 3.9% of the screen


def spinner(ground):
    return paint(ground, [(17, 39, 19, 41, INK)])                       # 2 x 2: 0.15% of the screen


FINAL = lines(LIGHT_GROUND, 40, 72)                                      # the conversation, newest at the bottom


def launch(after_tap, end=3.0, tap_at=None):
    """A still home screen from 0 s, the tap's visible reaction at 1 s, then (seconds after the tap, frame)."""
    frames = [blank.Frame(0.0, W, H, HOME), blank.Frame(1.0, W, H, HOME_PRESSED)]
    frames += [blank.Frame(1.0 + t, W, H, f) for t, f in after_tap]
    return blank.analyze(frames, duration=end, tap_at=tap_at)


# ------------------------------------------------------------------------------------------------
# the brief's cases
# ------------------------------------------------------------------------------------------------

@case("a 600 ms white stretch fails")
def _():
    r = launch([(0.05, paint(WHITE)), (0.65, FINAL)])
    assert r["verdict"] == "FAIL", r
    (s,) = r["blankStretches"]
    assert s["startMs"] == 50.0 and s["lengthMs"] == 600.0 and s["colors"] == ["#FFFFFF"], s
    assert "blank for 600 ms" in r["why"][0], r["why"]


@case("a 600 ms flat-color stretch fails (the launch ground, light and dark)")
def _():
    for ground in (LIGHT_GROUND, DARK_GROUND):
        r = launch([(0.05, paint(ground)), (0.65, lines(ground, 40, 72))])
        assert r["verdict"] == "FAIL" and r["longestBlankMs"] == 600.0, r


@case("a 50 ms blank stretch passes")
def _():
    r = launch([(0.05, paint(WHITE)), (0.10, FINAL)])
    assert r["verdict"] == "PASS" and r["longestBlankMs"] == 50.0, r


@case("content that jumps fails: drawn at the top, then moved to the bottom")
def _():
    r = launch([(0.05, lines(LIGHT_GROUND, 8, 40)), (0.65, FINAL)])
    assert r["verdict"] == "FAIL" and not r["blankStretches"], r
    (j,) = r["jumps"]
    assert j["startMs"] == 50.0 and j["lengthMs"] == 600.0, j
    assert "moved" in r["why"][0], r["why"]


@case("content that appears in place passes, including rows added in place")
def _():
    r = launch([(0.05, lines(LIGHT_GROUND, 56, 72)), (0.30, FINAL)])
    assert r["verdict"] == "PASS" and not r["jumps"] and not r["blankStretches"], r


@case("a 600 ms logo on the ground passes: a screen showing the app's logo is not blank")
def _():
    for ground in (LIGHT_GROUND, DARK_GROUND):
        r = launch([(0.05, logo(ground)), (0.65, lines(ground, 40, 72))])
        assert r["verdict"] == "PASS" and not r["blankStretches"], r


# ------------------------------------------------------------------------------------------------
# what else the rule says
# ------------------------------------------------------------------------------------------------

@case("an empty white window framed by a sliver of home screen is blank (the iPhone's opening animation)")
def _():
    framed = paint(WALLPAPER, [(2, 6, 34, 74, WHITE)])                   # 11% of the screen is still home screen
    r = launch([(0.05, framed), (0.65, FINAL)])
    assert r["verdict"] == "FAIL" and r["longestBlankMs"] == 600.0, r
    # a logo window framed the same way is not
    logo_framed = paint(WALLPAPER, [(2, 6, 34, 74, LIGHT_GROUND), (13, 35, 23, 45, (200, 160, 60))])
    r = launch([(0.05, logo_framed), (0.65, lines(LIGHT_GROUND, 40, 72))])
    assert r["verdict"] == "PASS" and not r["blankStretches"], r


@case("a spinner on an empty screen is blank")
def _():
    r = launch([(0.05, spinner(LIGHT_GROUND)), (0.65, FINAL)])
    assert r["verdict"] == "FAIL" and r["longestBlankMs"] == 600.0, r


@case("the limit is one named number, and a stretch exactly at it passes while one past it fails")
def _():
    assert blank.thresholds()["limitMs"] == blank.BLANK_LIMIT_MS
    at = launch([(0.05, paint(WHITE)), (0.05 + LIMIT, FINAL)])
    over = launch([(0.05, paint(WHITE)), (0.05 + LIMIT + 0.017, FINAL)])
    assert at["verdict"] == "PASS" and abs(at["longestBlankMs"] - blank.BLANK_LIMIT_MS) < 0.5, at
    assert over["verdict"] == "FAIL", over


@case("the opening animation of a blank window counts: the stretch starts when the empty window starts growing")
def _():
    growing = paint(WALLPAPER, ICONS + [(9, 20, 27, 60, WHITE)])          # an empty white window over the home screen
    r = launch([(0.03, growing), (0.06, paint(WHITE)), (0.66, FINAL)])
    (s,) = r["blankStretches"]
    assert s["startMs"] == 30.0 and s["openingAnimationFrames"] == 1 and s["lengthMs"] == 630.0, s


@case("a logo window growing over the home screen is not the opening of a blank stretch")
def _():
    growing = paint(WALLPAPER, ICONS + [(6, 16, 30, 64, LIGHT_GROUND), (13, 35, 23, 45, (200, 160, 60))])
    r = launch([(0.03, growing), (0.06, logo(LIGHT_GROUND)), (0.40, paint(LIGHT_GROUND)), (0.60, FINAL)])
    (s,) = r["blankStretches"]
    assert s["startMs"] == 400.0 and s["openingAnimationFrames"] == 0 and s["lengthMs"] == 200.0, s
    assert r["verdict"] == "PASS", r


@case("a recording still blank when it ends fails, and says so")
def _():
    r = launch([(0.05, paint(WHITE))], end=3.0)
    assert r["verdict"] == "FAIL" and r["blankStretches"][0]["open"], r
    assert "still blank when the recording ended" in r["why"][0]


@case("the tap given on the recording's clock is used as it is")
def _():
    frames = [blank.Frame(0.0, W, H, HOME), blank.Frame(0.1, W, H, HOME_PRESSED), blank.Frame(0.2, W, H, paint(WHITE)),
              blank.Frame(0.8, W, H, FINAL)]
    r = blank.analyze(frames, duration=2.0, tap_at=0.1)
    assert r["tap"].startswith("given") and r["blankStretches"][0]["startMs"] == 100.0, r


@case("cannot answer: no still home screen before the tap, no tap at all, an unsettled end")
def _():
    moving = [blank.Frame(0.0, W, H, HOME), blank.Frame(0.1, W, H, HOME_PRESSED), blank.Frame(1.0, W, H, FINAL)]
    assert "still screen" in raises(blank.CannotAnswer, blank.analyze, moving, duration=3.0)
    still = [blank.Frame(0.0, W, H, HOME), blank.Frame(2.0, W, H, HOME)]
    assert "no tap" in raises(blank.CannotAnswer, blank.analyze, still, duration=3.0)
    assert "still changing" in raises(blank.CannotAnswer, launch, [(0.05, FINAL), (1.95, lines(LIGHT_GROUND, 36, 72))], end=3.0)
    # a FAIL seen before an unsettled end still fails
    r = launch([(0.05, paint(WHITE)), (0.65, FINAL), (1.95, lines(LIGHT_GROUND, 36, 72))], end=3.0)
    assert r["verdict"] == "FAIL", r


@case("the decoder's stream is read exactly, and a short one is refused")
def _():
    a, b = paint(WHITE), FINAL
    data = b"RFD1 36 80 720 1600 2 2.5\n" + struct.pack("<d", 0.0) + a + struct.pack("<d", 0.5) + b
    frames, meta = blank.parse_dump(data)
    assert [f.t for f in frames] == [0.0, 0.5] and frames[1].rgb == b and meta["durationS"] == 2.5, meta
    assert "promised" in raises(blank.CannotAnswer, blank.parse_dump, data[:-10])
    assert "header" in raises(blank.CannotAnswer, blank.parse_dump, b"nope\n")


@case("a recording that does not decode cannot be answered (the decoder's own sentence is kept)")
def _():
    class P:
        returncode, stdout, stderr = 2, b"", b"framedump: the file has no video track: x.mp4"
    with tempfile.NamedTemporaryFile(suffix=".mp4") as f:
        msg = raises(blank.CannotAnswer, blank.decode, f.name, runner=lambda *a, **k: P())
    assert "no video track" in msg, msg
    assert "no such recording" in raises(blank.CannotAnswer, blank.decode, "/nonexistent.mp4")


# ------------------------------------------------------------------------------------------------
# a series of starts
# ------------------------------------------------------------------------------------------------

def start(ms, name):
    r = launch([(0.05, paint(LIGHT_GROUND)), (0.05 + ms / 1000.0, FINAL)])
    return {"recording": name, "result": r}


@case("a series under 20 starts is judged by its median, and every start over the limit is listed")
def _():
    starts = [start(250, f"s{i}") for i in range(13)] + [start(864, "outlier")]
    v = blank.judge_series(starts)
    assert v["statistic"] == "median" and v["verdict"] == "PASS", v
    assert [o["recording"] for o in v["overLimit"]] == ["outlier"] and v["maxMs"] == 864.0, v
    slow = blank.judge_series([start(600, f"s{i}") for i in range(8)] + [start(250, f"t{i}") for i in range(6)])
    assert slow["verdict"] == "FAIL" and "median" in slow["why"][0] and len(slow["overLimit"]) == 8, slow


@case("a series of 20 or more is judged by its p95: one slow start in 20 passes, two fail")
def _():
    one = blank.judge_series([start(250, f"s{i}") for i in range(19)] + [start(864, "outlier")])
    two = blank.judge_series([start(250, f"s{i}") for i in range(18)] + [start(864, "a"), start(864, "b")])
    assert one["statistic"] == "p95" and one["verdict"] == "PASS" and len(one["overLimit"]) == 1, one
    assert two["verdict"] == "FAIL" and len(two["overLimit"]) == 2, two


@case("a start nobody could judge fails the series")
def _():
    v = blank.judge_series([start(250, "a"), {"recording": "b", "error": "the recording did not decode"}])
    assert v["verdict"] == "FAIL" and v["unanswered"][0]["recording"] == "b", v


# ------------------------------------------------------------------------------------------------
# the phones
# ------------------------------------------------------------------------------------------------

class ScriptedPhone:
    """A Measure and Device for blankstart: a launcher with the RichConnect icon, adb commands kept."""

    def __init__(self, icon=True):
        self.calls, self.icon = [], icon
        self.d = self
        self.adb, self.serial = "/fake/adb", "PHONE1"

    def sh(self, command, check=True):
        self.calls.append(("sh", command))
        return ""

    def run(self, *args, check=True):
        self.calls.append(("run",) + args)
        if args[0] == "pull":
            with open(args[2], "wb") as f:
                f.write(b"mp4")
        return ""

    def sleep(self, s):
        self.calls.append(("sleep", s))

    def dump_ui(self):
        nodes = [{"text": "Phone", "desc": "", "bounds": (0, 0, 100, 100)}]
        if self.icon:
            nodes.append({"text": "RichConnect", "desc": "", "bounds": (200, 1500, 300, 1600)})
        return nodes


class Recorder:
    started = []

    def __init__(self, argv, **kw):
        Recorder.started.append(argv)
        self.returncode = 0

    def communicate(self, timeout=None):
        return b"", b""


@case("Android: each start is a force-stop, Home, a tap on the icon while screenrecord runs, then the judged recording")
def _():
    phone, judged = ScriptedPhone(), []
    Recorder.started = []

    def analyze(path):
        judged.append(path)
        return launch([(0.05, paint(LIGHT_GROUND)), (0.30, FINAL)])
    with tempfile.TemporaryDirectory() as tmp:
        m = blankstart.android_cold_blank(phone, 3, tmp, popen=Recorder, analyze=analyze)
        assert sorted(os.listdir(os.path.join(tmp, "cold-blank"))) == ["start-001.mp4", "start-002.mp4", "start-003.mp4"]
    argv = Recorder.started[0]
    assert len(Recorder.started) == 3 and argv[:5] == ["/fake/adb", "-s", "PHONE1", "shell", "screenrecord"], argv
    assert argv[argv.index("--time-limit") + 1] == str(blankstart.RECORD_S), argv
    shells = [c[1] for c in phone.calls if c[0] == "sh"]
    assert shells[:3] == ["am force-stop dev.richos.connect", "input keyevent KEYCODE_HOME", "input keyevent KEYCODE_HOME"], shells
    assert "input tap 250 1550" in shells and shells.count("input tap 250 1550") == 3, shells
    assert m["verdict"] == "PASS" and m["samplesMs"] == [250.0] * 3 and m["limitMs"] == blank.BLANK_LIMIT_MS, m
    assert m["method"] and m["stats"]["n"] == 3 and len(judged) == 3


@case("Android: no icon on the launcher's first page refuses with that sentence, and recordings without --out are deleted")
def _():
    msg = raises(perfcore.Unmeasurable, blankstart.android_cold_blank, ScriptedPhone(icon=False), 1, None, popen=Recorder,
                 analyze=lambda p: None)
    assert "first page" in msg, msg
    kept = []
    m = blankstart.android_cold_blank(ScriptedPhone(), 1, None, popen=Recorder,
                                      analyze=lambda p: kept.append(p) or launch([(0.05, paint(WHITE)), (0.65, FINAL)]))
    assert not os.path.exists(os.path.dirname(kept[0])), "the scratch recordings were left behind"
    assert m["verdict"] == "FAIL" and m["recordingsKept"] is False and m["overLimit"][0]["worstMs"] == 600.0, m


@case("perf.py android: --blank-starts defaults to a series, a cold run includes the blank check, 0 skips it")
def _():
    base = ["android", "--adb", "/fake/adb", "--serial", "P", "--kind", "physical"]
    assert perf.parse_args(base).blank_starts == 10
    assert perf.parse_args(base + ["--blank-starts", "0"]).blank_starts == 0
    with open(os.path.join(PERF, "perf.py")) as f:
        text = f.read()
    assert 'only.add("cold-blank")' in text and 'record["metrics"]["coldBlank"] = cb' in text
    assert 'failures += cb["verdict"] != "PASS"' in text, "a failing blank check must fail the run"
    # perf.py and the phone glue judge with blank.py's limit, never a copy of it
    assert "blankstart.android_cold_blank" in text and blankstart.blank is blank
    assert "BLANK_LIMIT_MS" not in text and "400" not in open(os.path.join(PERF, "blankstart.py")).read()


@case("iPhone: one session recording, each tap judged in its own window, placed by the recording's start on the phone's clock")
def _():
    # The recording began at 1000.0 on the phone's clock. Before the first tap the session shows the
    # app, then swipes across the Home Screen (so the video's first change is NOT the tap); the Home
    # Screen is still from 1 s before each tap. Three launches, each sent Home 2.9 s after its tap.
    started_at = 1000.0
    launches = [(1002.0, 1004.9), (1006.0, 1008.9), (1010.0, 1012.9)]
    seq = [(0.0, FINAL), (0.4, HOME_PRESSED), (0.7, HOME)]
    for k, video_tap in enumerate((2.0, 6.0, 10.0)):
        if k:
            seq.append((video_tap - 1.05, HOME))
        seq += [(video_tap, HOME_PRESSED), (video_tap + 0.05, paint(WHITE)), (video_tap + 0.05 + (0.6 if k == 1 else 0.2), FINAL)]
    frames = [blank.Frame(t, W, H, f) for t, f in seq]
    m = blankstart.iphone_cold_blank("/phone/session.mp4", started_at, launches, decode=lambda p: (frames, {"durationS": 14.0}))
    assert m["samplesMs"] == [200.0, 600.0, 200.0], m
    assert m["verdict"] == "PASS" and [o["recording"] for o in m["overLimit"]] == ["/phone/session.mp4#5.000-8.900"], m
    assert "no tap moments" in raises(perfcore.Unmeasurable, blankstart.iphone_cold_blank, "/x.mp4", 0.0, [], decode=None)


@case("iPhone: a phone-ios.py run directory gives the taps (tapAt), the leaves (next Home or terminate) and the recording's start")
def _():
    import json
    steps = [{"do": "home", "start": 999.0, "ok": True, "detail": {}},
             {"do": "tap", "start": 1001.5, "ok": True, "detail": {"label": "RichConnect", "tapAt": 1002.0}},
             {"do": "sleep", "start": 1003.0, "ok": True, "detail": {}},
             {"do": "home", "start": 1004.9, "ok": True, "detail": {}},
             {"do": "tap", "start": 1005.0, "ok": True, "detail": {"label": "Settings", "tapAt": 1005.2}},
             {"do": "tap", "start": 1005.5, "ok": False, "detail": {"label": "RichConnect", "tapAt": 1006.0}},
             {"do": "tap", "start": 1009.5, "ok": True, "detail": {"label": "RichConnect", "tapAt": 1010.0}}]
    lines = [json.dumps(s) + "\n" for s in steps]
    assert blankstart.launches_from_steps(lines) == [(1002.0, 1004.9), (1010.0, None)], blankstart.launches_from_steps(lines)
    with tempfile.TemporaryDirectory() as run:
        os.makedirs(os.path.join(run, "attachments"))
        with open(os.path.join(run, "steps.jsonl"), "w") as f:
            f.writelines(lines[:4])
        manifest = [{"attachments": [{"exportedFileName": "a.txt", "timestamp": 1.0},
                                     {"exportedFileName": "REC.mp4", "timestamp": 1000.0}]}]
        with open(os.path.join(run, "attachments", "manifest.json"), "w") as f:
            json.dump(manifest, f)
        assert blankstart.recording_from_run(run) == (os.path.join(run, "attachments", "REC.mp4"), 1000.0)
        frames = [blank.Frame(t, W, H, f) for t, f in [(0.0, FINAL), (0.4, HOME_PRESSED), (0.7, HOME), (2.0, HOME_PRESSED),
                                                        (2.05, paint(WHITE)), (2.65, FINAL)]]
        starts = blankstart.iphone_run(run, decode=lambda p: (frames, {"durationS": 6.0}))
        assert len(starts) == 1 and starts[0]["result"]["longestBlankMs"] == 600.0, starts
        manifest[0]["attachments"].append({"exportedFileName": "TWO.mov", "timestamp": 2.0})
        with open(os.path.join(run, "attachments", "manifest.json"), "w") as f:
            json.dump(manifest, f)
        assert "expected one screen recording" in raises(perfcore.Unmeasurable, blankstart.recording_from_run, run)


# ------------------------------------------------------------------------------------------------
# the static check: the launch surfaces the apps declare
# ------------------------------------------------------------------------------------------------

def tree(ios_project, ios_files=(), theme_bg="@color/launch_ground", splash_icon=None, min_sdk=29, icon=True, drawables=()):
    root = tempfile.mkdtemp()
    def put(rel, text):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    put(launchscreen.IOS + "/project.yml", ios_project)
    for rel, text in ios_files:
        put(launchscreen.IOS + "/" + rel, text)
    put(launchscreen.ANDROID + "/build.gradle.kts", f"android {{ defaultConfig {{ minSdk = {min_sdk} }} }}")
    put(launchscreen.ANDROID + "/src/main/AndroidManifest.xml",
        '<manifest><application ' + ('android:icon="@mipmap/ic_launcher" ' if icon else '') + 'android:theme="@style/Theme.RichOS"></application></manifest>')
    put(launchscreen.ANDROID_RES + "/mipmap-anydpi/ic_launcher.xml", '<adaptive-icon><foreground android:drawable="@mipmap/fg"/></adaptive-icon>')
    item = f'<item name="android:windowSplashScreenAnimatedIcon">{splash_icon}</item>' if splash_icon else ""
    put(launchscreen.ANDROID_RES + "/values/themes.xml",
        f'<resources><style name="Theme.RichOS" parent="x"><item name="android:windowBackground">{theme_bg}</item>{item}</style></resources>')
    for rel, text in drawables:
        put(launchscreen.ANDROID_RES + "/" + rel, text)
    return root


GENERATED = 'settings:\n  INFOPLIST_KEY_UILaunchScreen_Generation: "YES"\n'


@case("static: a generated iPhone launch screen with no image is EMPTY; an image or a storyboard with a view SHOWS")
def _():
    roots = []
    try:
        roots.append(tree(GENERATED))
        assert launchscreen.iphone(roots[-1])["empty"]
        roots.append(tree(GENERATED + "info:\n  properties:\n    UILaunchScreen:\n      UIImageName: LaunchMark\n",
                          [("App/Assets.xcassets/LaunchMark.imageset/Contents.json", "{}")]))
        assert not launchscreen.iphone(roots[-1])["empty"]
        roots.append(tree(GENERATED + "info:\n  properties:\n    UILaunchScreen:\n      UIImageName: Missing\n"))
        assert launchscreen.iphone(roots[-1])["empty"], "an image name with no image set is still empty"
        roots.append(tree("settings:\n  INFOPLIST_KEY_UILaunchStoryboardName: Launch\n",
                          [("App/Launch.storyboard", '<document><scenes><view><subviews><imageView/></subviews></view></scenes></document>')]))
        assert not launchscreen.iphone(roots[-1])["empty"]
        roots.append(tree("settings:\n  INFOPLIST_KEY_UILaunchStoryboardName: Launch\n", [("App/Launch.storyboard", "<document><view/></document>")]))
        assert launchscreen.iphone(roots[-1])["empty"], "a storyboard with no image view or label is empty"
    finally:
        for r in roots:
            shutil.rmtree(r)


@case("static: Android 12+ shows the launcher icon unless the theme hides it; Android 10-11 need a picture in windowBackground")
def _():
    roots = []
    try:
        roots.append(tree(GENERATED))
        s = launchscreen.android(roots[-1])
        assert not s["android-31+"]["empty"] and s["android-pre31"]["empty"], s
        roots.append(tree(GENERATED, splash_icon="@android:color/transparent"))
        assert launchscreen.android(roots[-1])["android-31+"]["empty"]
        roots.append(tree(GENERATED, icon=False))
        assert launchscreen.android(roots[-1])["android-31+"]["empty"]
        roots.append(tree(GENERATED, theme_bg="@drawable/launch",
                          drawables=[("drawable/launch.xml", '<layer-list><item android:drawable="@color/g"/><item><bitmap android:src="@mipmap/m"/></item></layer-list>')]))
        assert not launchscreen.android(roots[-1])["android-pre31"]["empty"]
        roots.append(tree(GENERATED, min_sdk=31))
        assert "android-pre31" not in launchscreen.android(roots[-1])
    finally:
        for r in roots:
            shutil.rmtree(r)


@case("static: a moved source is a broken check (exit 2), never a pass")
def _():
    import contextlib
    import io
    root, said = tempfile.mkdtemp(), io.StringIO()
    try:
        with contextlib.redirect_stderr(said):
            assert launchscreen.main(["--root", root]) == 2
        assert "cannot answer" in said.getvalue() and "project.yml is missing" in said.getvalue(), said.getvalue()
    finally:
        shutil.rmtree(root)


# The launch surfaces of THIS tree that are empty today, each with who owns it. A surface that turns
# empty and is not listed fails; a listed one that now shows something fails until its line is removed
# here, so the list never outlives the defect.
KNOWN_OPEN = {
    "iphone": "the generated launch screen is one flat color; isaac-opus-white1 is fixing the iPhone's blank start "
              "(2026-10-02): remove this line in the land that makes it show something",
    "android-pre31": "Android 10 and 11 (minSdk 29) show the flat launch ground with no logo before the first frame; "
                     "reported by quint-opus-blank1 on 2026-10-02 (Android 12+, where the CEO's phone is, shows the icon)",
}


@case("static: this tree's launch surfaces: nothing empty beyond the declared open list")
def _():
    found = launchscreen.surfaces(REPO)
    empty = {k for k, v in found.items() if v["empty"]}
    new = empty - set(KNOWN_OPEN)
    fixed = set(KNOWN_OPEN) - empty
    assert not new, "launch surface(s) now EMPTY: " + ", ".join(k + ": " + found[k]["why"] for k in sorted(new))
    assert not fixed, f"no longer empty, remove from KNOWN_OPEN in {os.path.basename(__file__)}: {', '.join(sorted(fixed))}"


if __name__ == "__main__":
    total = sum(1 for line in open(__file__) if line.startswith("@case("))
    if failures:
        print(f"mobile-blank: {len(failures)} of {total} FAILED: {', '.join(failures)}")
        sys.exit(1)
    print(f"mobile-blank: {total} cases passed")
