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


if __name__ == "__main__":
    total = sum(1 for line in open(__file__) if line.startswith("@case("))
    if failures:
        print(f"mobile-blank: {len(failures)} of {total} FAILED: {', '.join(failures)}")
        sys.exit(1)
    print(f"mobile-blank: {total} cases passed")
