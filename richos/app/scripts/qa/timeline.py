#!/usr/bin/env python3
"""timeline.py — how long did the app take to respond, measured off one clock.

  timeline.py capture <outdir> <seconds> --region x,y,w,h
                      [--also-region x,y,w,h]
                      [--click X,Y | --key CODE | --wait-only]
                      [--baseline SECONDS] [--interval SECONDS]
  timeline.py report  <outdir> [--tol N] [--step N]
  timeline.py stats   <label=ms> [<label=ms> ...]
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
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

import qaimg                                             # noqa: E402

GUEST_USER = os.environ.get("TESTVM_GUEST_USER", "admin")


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

    if not os.path.isdir(out):
        os.makedirs(out)
    out_b = os.path.join(out, "b")
    if also is not None and not os.path.isdir(out_b):
        os.makedirs(out_b)

    frames = []
    frames_b = []
    stop = threading.Event()

    def loop(rect, where, sink):
        n = 0
        while not stop.is_set():
            t = time.time()
            subprocess.run(["screencapture", "-x", "-o", "-R" + rect,
                            os.path.join(where, "%04d.png" % n)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=False)
            sink.append((n, t))
            n += 1
            if interval:
                time.sleep(interval)

    th = threading.Thread(target=loop, args=(region, out, frames), daemon=True)
    th.start()
    th_b = None
    if also is not None:
        th_b = threading.Thread(target=loop, args=(also, out_b, frames_b), daemon=True)
        th_b.start()
    time.sleep(baseline)

    t0 = time.time()
    kind, arg = action
    if kind == "click":
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to click at {%s}'
                        % arg.replace(",", ", ")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    elif kind == "key":
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to key code %s' % arg],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    t1 = time.time()

    time.sleep(secs)
    stop.set()
    th.join(timeout=15)
    if th_b is not None:
        th_b.join(timeout=15)

    if not frames:
        qaimg.die("not one frame was captured — screencapture produced nothing")
    if also is not None and not frames_b:
        qaimg.die("--also-region captured not one frame — screencapture "
                  "produced nothing for %s" % also)

    def _median_gap(fr):
        gaps = sorted((fr[i + 1][1] - fr[i][1]) * 1000 for i in range(len(fr) - 1))
        return gaps[len(gaps) // 2] if gaps else -1.0

    def _write(where, rect, fr):
        with open(os.path.join(where, "meta.tsv"), "w") as fh:
            fh.write("action\t%s %s\n" % (kind, arg))
            fh.write("region\t%s\n" % rect)
            # THE SAME TWO NUMBERS in both files, deliberately: there was one
            # press, and both regions are answered against it.
            fh.write("t_action_before\t%.1f\n" % (t0 * 1000))
            fh.write("t_action_after\t%.1f\n" % (t1 * 1000))
            for n, t in fr:
                fh.write("frame\t%d\t%.1f\n" % (n, t * 1000))

    med = _median_gap(frames)
    _write(out, region, frames)
    print("frames %d   median gap %.1f ms   action window %.1f ms"
          % (len(frames), med, (t1 - t0) * 1000))
    print("wrote %s" % os.path.join(out, "meta.tsv"))
    if also is not None:
        _write(out_b, also, frames_b)
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


COMMANDS = {"capture": cmd_capture, "report": cmd_report, "stats": cmd_stats}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv[0] not in COMMANDS:
        qaimg.die("timeline.py: no such command %r. One of: %s"
                  % (argv[0], ", ".join(sorted(COMMANDS))))
    return COMMANDS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
