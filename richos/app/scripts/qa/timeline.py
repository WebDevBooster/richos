#!/usr/bin/env python3
"""timeline.py — how long did the app take to respond, measured off one clock.

  timeline.py capture <outdir> <seconds> --region x,y,w,h
                      [--also-region x,y,w,h]
                      [--click X,Y | --native-click X,Y | --key CODE | --wait-only]
                      [--baseline SECONDS] [--interval SECONDS]
  timeline.py report  <outdir> [--tol N] [--step N]
  timeline.py at      <outdir> <frame> [<frame> ...]
  timeline.py stats   <label=ms> [<label=ms> ...]
  timeline.py bounds <outdir> <last-absent-frame> <first-present-frame> <limit-ms>
  timeline.py --help

Exit 0 on an answer, 1 when there is no answer to give (no repaint, no
frames), 2 when the tool could not run.

===========================================================================
ONE CLOCK, OR THE NUMBER IS FICTION
===========================================================================
This is the most-rewritten job of the eight walks — `send.sh`, `mac2phone.sh`,
`phone2mac.sh`, `timesend.py`, `capture-loop.sh`, `run-send.sh`, `install.py`,
`measure.py`/`analyze.py` and `measure2.py`/`analyze2.py`, ten versions across
six walks. The early ones timestamped the press on the HOST and the frames on
the GUEST, over ssh, and the round trip is tens of milliseconds of unknown
sign — on a measurement whose interesting range starts at about 200 ms.

So `capture` does the press and the frames IN ONE PROCESS. It starts the
capture loop first, holds a baseline stretch, then acts, and records the
instant either side of the action. `t_action_before` and `t_action_after`
are both written, because the truth is somewhere between them and a single
number would hide that.

===========================================================================
THE BASELINE IS THE LAST FRAME BEFORE THE ACTION, NOT THE FIRST FRAME
===========================================================================
`report` finds the first frame after the action whose pixels differ from the
frame immediately BEFORE it. Comparing against frame 0 makes any drift in
the first second — a cursor, a clock, a settling animation — read as the
response. It also prints how many consecutive frames the new state held, so
a one-frame flicker is visible as a one-frame flicker rather than as an
answer.

===========================================================================
TWO REGIONS, ONE ACTION, ONE CLOCK — `--also-region`
===========================================================================
A phone walk asks one question of two screens: the press happens on the Mac,
and the answer is wanted BOTH on the Mac and on the phone page beside it.
Two separate `capture` runs cannot answer it, because each stamps its own
action instant and the gap between two processes starting is unknown in
size and in sign — on a leg whose claim is single-digit milliseconds.

So `--also-region` captures a SECOND rectangle from the SAME process, in a
second thread, around the SAME action. Its frames land in `<outdir>/b/`
with their own `meta.tsv`, whose `t_action_before`/`t_action_after` are
**the same two numbers** as the primary's — one press, one clock, two
answers. `report <outdir>` and `report <outdir>/b` then read normally.

Both loops call `screencapture` concurrently, so the per-loop frame gap is
wider than a single loop's. `capture` prints the median gap of each, and
that number is the resolution of the answer — quote it beside the answer.

===========================================================================
`at` — DATING A FRAME SOMETHING ELSE CHOSE
===========================================================================
`report` answers "when did this region first change". It cannot answer "when
did Rich's words appear", because a counter ticking in the same region
changes the pixels every second. That frame is found by reading — usually
`ocr-find.sh <text> <dir> --first` — and then it has to be dated.

`at <outdir> <frame>` is that step: it turns a frame number, or the path
`ocr-find.sh` printed, into its offset from the action, off the same
meta.tsv clock. It was done by hand with awk in every walk that used OCR to
pick a frame, and a hand-rolled subtraction is exactly where an off-by-one
baseline creeps in.

===========================================================================
`bounds` — CONSERVATIVE VISIBLE-FEEDBACK INTERVALS
===========================================================================
Every new capture also writes bounds.json: monotonic nanoseconds before and
AFTER each screencapture command, plus the same bounds around input posting.
Select consecutive last-absent and first-present frames by reading the target
region, then use `bounds <outdir> <absent> <present> <limit-ms>`. It checks the
frame hashes and uses capture COMPLETION for the upper bound. The caller must
verify causal, event-specific presence; a sidebar label is not a new breadcrumb.

`--native-click` prepares Quartz before capture, then posts down/up without
AppleScript process startup inside the action window. The guest must already
have event-posting permission. It does not change permissions. Coordinates are
global display points, as for --click; calibrate the crop and display scale.

Posting is not app acquisition. A passing post-to-visible upper bound also
bounds acquisition-to-visible. A straddling interval is unproven; a slower
post-to-visible result cannot separate delivery delay from app response. Do not
combine monotonic origins across processes or treat legacy meta.tsv's point
offsets as these bounds. `bounds` exits 1 when acquisition timing is unproven.

===========================================================================
WHY `capture` REFUSES TO RUN WITHOUT BEING TOLD
===========================================================================
It takes a picture of a screen and it can synthesize a click. On the
operator's own Mac that is both an intrusion and a privacy problem (CEO
ruling: his Mac is never a test surface). It therefore runs only where it
has been told it is safe to: inside the test VM, or with
RICHOS_QA_CAPTURE=allow set deliberately by the caller.
"""

import getpass
import hashlib
import json
import math
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

import qaimg                                             # noqa: E402

GUEST_USER = os.environ.get("TESTVM_GUEST_USER", "admin")


def native_click(position):
    """Prepare a Quartz click before timing starts. Never grant permissions here.

    The returned operation posts down/up without starting an AppleScript process.
    Posting is not application acquisition: a passing post-to-visible upper bound
    also bounds acquisition-to-visible, but a slow post-to-visible result cannot
    establish that the application missed an acquisition-based target.
    """
    import ctypes
    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
    x, y = map(float, position.split(","))
    if not all(math.isfinite(v) for v in (x, y)):
        raise ValueError("click coordinates must be finite")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
    if not cg.CGPreflightPostEventAccess():
        raise ValueError("native click permission unavailable; no event posted")
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CGEventPost.restype = None
    cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
    cg.CGEventSetIntegerValueField.restype = None
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    cf.CFRelease.restype = None

    def post():
        events = []
        try:
            for kind in (1, 2):  # left down, left up, global display coordinates
                event = cg.CGEventCreateMouseEvent(None, kind, Point(x, y), 0)
                if not event:
                    raise RuntimeError("could not create native click event")
                events.append(event)
                cg.CGEventSetIntegerValueField(event, 1, 1)  # single click
            for event in events:
                cg.CGEventPost(0, event)
        finally:
            for event in events:
                cf.CFRelease(event)
    return post


def visibility_bounds(record, absent, present, limit):
    """Conservative intervals on one monotonic clock, never an OCR verdict.

    The caller must inspect consecutive frames in a stable region and establish
    event-specific absence/presence. Capture-start alone is not visibility time.
    """
    if record.get("clock") != "monotonic_ns" or not math.isfinite(limit) or limit <= 0:
        raise ValueError("monotonic capture and positive finite limit required")
    if record["action"]["kind"] == "none":
        raise ValueError("wait-only capture has no input action")
    frames = record["frames"]
    indexes = [i for i, f in enumerate(frames) if f["number"] == absent]
    if len(indexes) != 1 or indexes[0] + 1 >= len(frames):
        raise ValueError("last absent frame must have a following frame")
    a, b = frames[indexes[0]:indexes[0] + 2]
    if b["number"] != present or present != absent + 1:
        raise ValueError("absence and presence must be consecutive frames")
    start, end = record["action"]["before_ns"], record["action"]["after_ns"]
    values = [start, end, a["before_ns"], a["after_ns"], b["before_ns"], b["after_ns"]]
    if any(type(v) is not int or v < 0 for v in values):
        raise ValueError("invalid monotonic timestamp")
    if not (start <= end and a["before_ns"] <= a["after_ns"] <= b["before_ns"] <= b["after_ns"]):
        raise ValueError("capture/action timestamps are reversed")
    if b["after_ns"] < start:
        raise ValueError("visible event predates the input")
    low = max(0, a["before_ns"] - end) / 1e6
    high = (b["after_ns"] - start) / 1e6
    return {"milliseconds": [low, high], "limit_ms": limit,
            "post_to_visible": "PASS" if high <= limit else "over target" if low > limit else "unproven",
            "acquisition_to_visible": "PASS" if high <= limit else "unproven",
            "action_window_ms": (end - start) / 1e6,
            "note": "Input posting is bounded, application acquisition is not observed."}


def cmd_bounds(args):
    if len(args) != 4:
        qaimg.die("usage: timeline.py bounds <outdir> <last-absent> <first-present> <limit-ms>")
    out, absent, present, limit = args
    try:
        with open(os.path.join(out, "bounds.json")) as fh:
            record = json.load(fh)
        result = visibility_bounds(record, int(absent), int(present), float(limit))
        for n in (int(absent), int(present)):
            row = next(f for f in record["frames"] if f["number"] == n)
            with open(os.path.join(out, "%04d.png" % n), "rb") as fh:
                if hashlib.sha256(fh.read()).hexdigest() != row["sha256"]:
                    raise ValueError("frame bytes changed since capture")
    except (OSError, ValueError, KeyError, StopIteration) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["acquisition_to_visible"] == "PASS" else 1


# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------
def cmd_capture(args):
    region = None
    also = None
    action = None
    baseline = 1.2
    interval = 0.0
    rest = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--region":
            region = args[i + 1] if i + 1 < len(args) else None
            i += 2
        elif a == "--also-region":
            also = args[i + 1] if i + 1 < len(args) else None
            i += 2
        elif a == "--click":
            action = ("click", args[i + 1] if i + 1 < len(args) else "")
            i += 2
        elif a == "--native-click":
            action = ("native-click", args[i + 1] if i + 1 < len(args) else "")
            i += 2
        elif a == "--key":
            action = ("key", args[i + 1] if i + 1 < len(args) else "")
            i += 2
        elif a == "--wait-only":
            action = ("none", "")
            i += 1
        elif a == "--baseline":
            baseline = float(args[i + 1])
            i += 2
        elif a == "--interval":
            interval = float(args[i + 1])
            i += 2
        else:
            rest.append(a)
            i += 1

    if len(rest) != 2:
        qaimg.die("usage: timeline.py capture <outdir> <seconds> --region x,y,w,h ...")
    out, secs = rest[0], float(rest[1])
    if not all(math.isfinite(v) and v >= 0 for v in (secs, baseline, interval)):
        qaimg.die("capture durations must be finite and nonnegative")
    if not region or len(region.split(",")) != 4:
        qaimg.die("--region is required, as x,y,w,h")
    if also is not None and len(also.split(",")) != 4:
        qaimg.die("--also-region takes a rectangle, as x,y,w,h")
    if action is None:
        qaimg.die("say what the action is: --click X,Y, --key CODE, or --wait-only")

    allowed = os.environ.get("RICHOS_QA_CAPTURE") == "allow"
    in_guest = getpass.getuser() == GUEST_USER
    if not (allowed or in_guest):
        qaimg.die(
            "timeline.py capture will not photograph this screen.\n"
            "It runs inside the test VM (scripts/testvm/run.sh, then ax.sh/guest\n"
            "shell), where the app under test lives. The operator's own Mac is\n"
            "never a test surface.\n"
            "To override deliberately: RICHOS_QA_CAPTURE=allow")

    # Preparation stays outside the action interval and behind the screen guard.
    post = native_click(action[1]) if action[0] == "native-click" else None

    if not os.path.isdir(out):
        os.makedirs(out)
    out_b = os.path.join(out, "b")
    if also is not None and not os.path.isdir(out_b):
        os.makedirs(out_b)

    frames = []
    frames_b = []
    bounded = []
    bounded_b = []
    errors = []
    stop = threading.Event()

    def loop(rect, where, sink, bounds):
        n = 0
        while not stop.is_set():
            t = time.time()
            before = time.monotonic_ns()
            try:
                subprocess.run(["screencapture", "-x", "-o", "-R" + rect,
                                os.path.join(where, "%04d.png" % n)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               check=True, timeout=10)
            except (OSError, subprocess.SubprocessError) as exc:
                errors.append(str(exc))
                stop.set()
                return
            after = time.monotonic_ns()
            sink.append((n, t))
            bounds.append({"number": n, "before_ns": before, "after_ns": after})
            n += 1
            if interval:
                stop.wait(interval)

    th = threading.Thread(target=loop, args=(region, out, frames, bounded), daemon=True)
    th.start()
    th_b = None
    if also is not None:
        th_b = threading.Thread(target=loop, args=(also, out_b, frames_b, bounded_b), daemon=True)
        th_b.start()
    time.sleep(baseline)

    t0 = time.time()
    m0 = time.monotonic_ns()
    kind, arg = action
    try:
        if errors:
            raise RuntimeError(errors[0])
        if post:
            post()
        elif kind in ("click", "key"):
            script = ('click at {%s}' % arg.replace(",", ", ")) if kind == "click" else 'key code %s' % arg
            subprocess.run(["osascript", "-e", 'tell application "System Events" to ' + script],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=10)
        m1 = time.monotonic_ns()
        t1 = time.time()
        stop.wait(secs)
    finally:
        stop.set()
        th.join(timeout=15)
        if th_b is not None:
            th_b.join(timeout=15)
    if errors:
        qaimg.die("capture failed: " + errors[0])

    if not frames:
        qaimg.die("not one frame was captured — screencapture produced nothing")
    if also is not None and not frames_b:
        qaimg.die("--also-region captured not one frame — screencapture "
                  "produced nothing for %s" % also)

    def _median_gap(fr):
        gaps = sorted((fr[i + 1][1] - fr[i][1]) * 1000 for i in range(len(fr) - 1))
        return gaps[len(gaps) // 2] if gaps else -1.0

    def _write(where, rect, fr, bounds):
        with open(os.path.join(where, "meta.tsv"), "w") as fh:
            fh.write("action\t%s %s\n" % (kind, arg))
            fh.write("region\t%s\n" % rect)
            # THE SAME TWO NUMBERS in both files, deliberately: there was one
            # press, and both regions are answered against it.
            fh.write("t_action_before\t%.1f\n" % (t0 * 1000))
            fh.write("t_action_after\t%.1f\n" % (t1 * 1000))
            for n, t in fr:
                fh.write("frame\t%d\t%.1f\n" % (n, t * 1000))
        # Hash only after capture: no OCR/analysis competes with timing samples.
        for row in bounds:
            with open(os.path.join(where, "%04d.png" % row["number"]), "rb") as frame:
                row["sha256"] = hashlib.sha256(frame.read()).hexdigest()
        with open(os.path.join(where, "bounds.json"), "w") as fh:
            json.dump({"clock": "monotonic_ns", "region": rect,
                       "action": {"kind": kind, "before_ns": m0, "after_ns": m1},
                       "frames": bounds}, fh, indent=2)

    med = _median_gap(frames)
    _write(out, region, frames, bounded)
    print("frames %d   median gap %.1f ms   action window %.1f ms"
          % (len(frames), med, (t1 - t0) * 1000))
    print("wrote %s" % os.path.join(out, "meta.tsv"))
    if also is not None:
        _write(out_b, also, frames_b, bounded_b)
        print("also   %d   median gap %.1f ms   region %s"
              % (len(frames_b), _median_gap(frames_b), also))
        print("wrote %s" % os.path.join(out_b, "meta.tsv"))
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
def _read_meta(out):
    path = os.path.join(out, "meta.tsv")
    if not os.path.isfile(path):
        qaimg.die("no meta.tsv in %s — that directory was not written by "
                  "`timeline.py capture`, so its frames have no clock." % out)
    meta, frames = {}, []
    with open(path) as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if p[0] == "frame" and len(p) >= 3:
                frames.append((int(p[1]), float(p[2])))
            elif len(p) >= 2:
                meta[p[0]] = p[1]
    return meta, frames


def _digest(path, tol, step):
    """A frame's identity. Exact bytes when tol is 0, else a coarse grid."""
    if tol <= 0:
        with open(path, "rb") as fh:
            return hashlib.md5(fh.read()).hexdigest()
    img = qaimg.load(path)
    q = max(1, tol)
    acc = bytearray()
    for y in range(0, img.h, step):
        for x in range(0, img.w, step):
            r, g, b = img.at(x, y)
            acc += bytes((r // q, g // q, b // q))
    return hashlib.md5(bytes(acc)).hexdigest()


def cmd_report(args):
    tol = 0
    step = 4
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--tol":
            tol = int(args[i + 1]); i += 2
        elif args[i] == "--step":
            step = int(args[i + 1]); i += 2
        else:
            rest.append(args[i]); i += 1
    if len(rest) != 1:
        qaimg.die("usage: timeline.py report <outdir> [--tol N] [--step N]")
    out = rest[0]
    meta, frames = _read_meta(out)
    if not frames:
        qaimg.die("meta.tsv lists no frames")

    try:
        t_before = float(meta["t_action_before"])
        t_after = float(meta["t_action_after"])
    except (KeyError, ValueError):
        qaimg.die("meta.tsv has no action timestamps")

    rows = []
    for n, t in frames:
        p = os.path.join(out, "%04d.png" % n)
        if not os.path.isfile(p):
            continue
        try:
            rows.append((n, t, _digest(p, tol, step)))
        except qaimg.ImageError as exc:
            qaimg.die("frame %s: %s" % (p, exc))
    if not rows:
        qaimg.die("meta.tsv lists frames but none of them are on disk in %s" % out)

    print("action          : %s" % meta.get("action", "?"))
    print("region          : %s" % meta.get("region", "?"))
    print("frames on disk  : %d of %d listed" % (len(rows), len(frames)))
    print("action window   : %.1f ms (before -> after)" % (t_after - t_before))

    before = [r for r in rows if r[1] <= t_before]
    if not before:
        print("NO BASELINE: every frame was captured after the action, so there is")
        print("nothing to compare against. Re-run with a longer --baseline.")
        return 1
    base = before[-1]
    print("baseline frame  : %04d  (%.1f ms before the action)"
          % (base[0], t_before - base[1]))

    after = [r for r in rows if r[1] > t_before]
    first = next((r for r in after if r[2] != base[2]), None)
    if first is None:
        print("NO CHANGE in the region across %d frame(s) after the action."
              % len(after))
        print("Either nothing happened, or the region is not where it happens.")
        return 1

    n, t, h = first
    print("first change    : frame %04d   +%.1f ms after the action started"
          % (n, t - t_before))
    print("                  (+%.1f ms after it finished)" % (t - t_after))

    held = 0
    for r in after:
        if r[1] < t:
            continue
        if r[2] == h:
            held += 1
        else:
            break
    print("that state held : %d consecutive frame(s)%s"
          % (held, "   <-- ONE FRAME: treat as a flicker, not a response"
             if held <= 1 else ""))

    distinct = []
    for r in after:
        if not distinct or distinct[-1][2] != r[2]:
            distinct.append(r)
    print("distinct states after the action: %d" % len(distinct))
    for n2, t2, h2 in distinct[:8]:
        print("   %04d  +%9.1f ms  %s" % (n2, t2 - t_before, h2[:12]))
    return 0


# ---------------------------------------------------------------------------
# at — what is this frame's offset from the action?
# ---------------------------------------------------------------------------
def cmd_at(args):
    if len(args) < 2:
        qaimg.die("usage: timeline.py at <outdir> <frame> [<frame> ...]\n"
                  "A frame is a number (139) or the path ocr-find.sh printed.")
    out, rest = args[0], args[1:]
    meta, frames = _read_meta(out)
    if not frames:
        qaimg.die("meta.tsv lists no frames")
    try:
        t_before = float(meta["t_action_before"])
        t_after = float(meta["t_action_after"])
    except (KeyError, ValueError):
        qaimg.die("meta.tsv has no action timestamps")
    by_n = dict(frames)

    print("action          : %s" % meta.get("action", "?"))
    print("region          : %s" % meta.get("region", "?"))
    for a in rest:
        stem = os.path.basename(a)
        if stem.endswith(".png"):
            stem = stem[:-4]
        try:
            n = int(stem)
        except ValueError:
            qaimg.die("%r is not a frame number and not a frame's filename" % a)
        if n not in by_n:
            qaimg.die("frame %04d is not in %s/meta.tsv — that clock does not "
                      "cover it, and a frame from another capture cannot be "
                      "dated against this one." % (n, out))
        t = by_n[n]
        print("frame %04d      : +%.1f ms after the action started "
              "(+%.1f ms after it finished)" % (n, t - t_before, t - t_after))
    return 0


# ---------------------------------------------------------------------------
# stats
# ---------------------------------------------------------------------------
def cmd_stats(args):
    if not args:
        qaimg.die("usage: timeline.py stats <label=ms> [<label=ms> ...]")
    vals = []
    for a in args:
        if "=" not in a:
            qaimg.die("%r is not <label>=<milliseconds>" % a)
        lab, v = a.split("=", 1)
        try:
            vals.append((lab, float(v)))
        except ValueError:
            qaimg.die("%r does not end in a number of milliseconds" % a)
    ms = sorted(v for _, v in vals)
    n = len(ms)
    med = ms[n // 2] if n % 2 else (ms[n // 2 - 1] + ms[n // 2]) / 2.0
    for lab, v in vals:
        print("  %-24s %8.1f ms" % (lab, v))
    print("  %-24s %8.1f ms" % ("min", ms[0]))
    print("  %-24s %8.1f ms" % ("median", med))
    print("  %-24s %8.1f ms" % ("max", ms[-1]))
    print("  n = %d" % n)
    if n < 3:
        print("  n < 3: report these as individual samples, never as a median.")
    return 0


COMMANDS = {"capture": cmd_capture, "report": cmd_report, "at": cmd_at,
            "stats": cmd_stats, "bounds": cmd_bounds}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv[0] not in COMMANDS:
        qaimg.die("timeline.py: no such command %r. One of: %s"
                  % (argv[0], ", ".join(sorted(COMMANDS))))
    try:
        return COMMANDS[argv[0]](list(argv[1:]))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
