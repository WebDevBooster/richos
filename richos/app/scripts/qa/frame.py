#!/usr/bin/env python3
"""frame.py — measure a captured frame: pixels, boxes, edges, motion.

  frame.py px      <png> <x> <y> [<x> <y> ...]
  frame.py crop    <in.png> <out.png> <x> <y> <w> <h> [--scale N]
  frame.py extent  <png> <x0> <y0> <x1> <y1> [--tol N]
  frame.py box     <png> <x0> <y0> <x1> <y1> <color> [--tol N]
  frame.py inset   <png> <x0> <y0> <x1> <y1> [--tol N]
  frame.py edges   <png> --col <x> <y0> <y1> [--tol N]
  frame.py edges   <png> --row <y> <x0> <x1> [--tol N]
  frame.py motion  <a.png> <b.png> [more...] [--tol N] [--step N]
  frame.py --help

Every box is half-open. `--tol` (default 10) is the per-channel difference
at which two colors count as different. `--step` samples every Nth pixel
for motion (default 3), which is what makes a 1024x700 comparison instant.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
The 18/18 settings-button inset check, the "did the splash animate" check,
the "where does this control actually start" check and the "what color is
that pixel" check were rewritten as `px.py`, `analyze.py`, `analyze2.py`,
`band.py`, `firstink.py` and `r3analyze.py` across five walks. They are one
job: read the pixels and say where things are.

`inset` deserves a note, because it is the one that keeps being asked by
hand: given a box that contains a control on its own ground, it reports the
gap on each side between the box and the first non-ground pixel. That is
the measurement behind "the settings button sits 18px from the top and 18px
from the right", and doing it by eye on a scaled crop is how a 2px error
gets signed off.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

from collections import Counter                          # noqa: E402

import qaimg                                             # noqa: E402


def _diff(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def _int(v, what):
    try:
        return int(v)
    except (TypeError, ValueError):
        qaimg.die("%s must be an integer, got %r" % (what, v))


def _opt_int(args, flag, default):
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args):
            qaimg.die("%s needs a number" % flag)
        v = _int(args[i + 1], flag)
        del args[i:i + 2]
        return v
    return default


def _load(path):
    if not os.path.isfile(path):
        qaimg.die("no such frame: %s" % path)
    try:
        return qaimg.load(path)
    except qaimg.ImageError as exc:
        qaimg.die(str(exc))


def cmd_px(args):
    if len(args) < 3 or len(args) % 2 == 0:
        qaimg.die("usage: frame.py px <png> <x> <y> [<x> <y> ...]")
    img = _load(args[0])
    for i in range(1, len(args), 2):
        x, y = _int(args[i], "x"), _int(args[i + 1], "y")
        try:
            c = img.at(x, y)
        except qaimg.ImageError as exc:
            qaimg.die(str(exc))
        print("(%d,%d)  %s  rgb%s  luminance %.4f"
              % (x, y, qaimg.hexs(c), c, qaimg.luminance(c)))
    return 0


def cmd_crop(args):
    scale = _opt_int(args, "--scale", 1)
    if len(args) != 6:
        qaimg.die("usage: frame.py crop <in.png> <out.png> <x> <y> <w> <h> [--scale N]")
    img = _load(args[0])
    x, y, w, h = (_int(v, "geometry") for v in args[2:6])
    try:
        out = img.crop(x, y, x + w, y + h)
        if scale > 1:
            out = out.scale_nearest(scale)
    except qaimg.ImageError as exc:
        qaimg.die(str(exc))
    qaimg.save(out, args[1])
    print("wrote %s  %dx%d" % (args[1], out.w, out.h))
    return 0


def _ground(img, x0, y0, x1, y1):
    """The ground of a box: its most frequent color."""
    return Counter(img.region(x0, y0, x1, y1)).most_common(1)[0][0]


def cmd_extent(args):
    tol = _opt_int(args, "--tol", 10)
    if len(args) != 5:
        qaimg.die("usage: frame.py extent <png> <x0> <y0> <x1> <y1> [--tol N]")
    img = _load(args[0])
    x0, y0, x1, y1 = (_int(v, "geometry") for v in args[1:5])
    try:
        bg = _ground(img, x0, y0, x1, y1)
    except qaimg.ImageError as exc:
        qaimg.die(str(exc))
    xs, ys = [], []
    for y in range(max(0, y0), min(img.h, y1)):
        for x in range(max(0, x0), min(img.w, x1)):
            if _diff(img.at(x, y), bg) > tol:
                xs.append(x)
                ys.append(y)
    print("ground %s  tol %d" % (qaimg.hexs(bg), tol))
    if not xs:
        print("NO CONTENT: every pixel in the box is within %d of the ground." % tol)
        return 1
    print("content x %d..%d  (width %d)" % (min(xs), max(xs), max(xs) - min(xs) + 1))
    print("content y %d..%d  (height %d)" % (min(ys), max(ys), max(ys) - min(ys) + 1))
    print("ink pixels %d of %d" % (len(xs), (x1 - x0) * (y1 - y0)))
    return 0


def cmd_inset(args):
    tol = _opt_int(args, "--tol", 10)
    if len(args) != 5:
        qaimg.die("usage: frame.py inset <png> <x0> <y0> <x1> <y1> [--tol N]")
    img = _load(args[0])
    x0, y0, x1, y1 = (_int(v, "geometry") for v in args[1:5])
    try:
        bg = _ground(img, x0, y0, x1, y1)
    except qaimg.ImageError as exc:
        qaimg.die(str(exc))
    xs, ys = [], []
    for y in range(max(0, y0), min(img.h, y1)):
        for x in range(max(0, x0), min(img.w, x1)):
            if _diff(img.at(x, y), bg) > tol:
                xs.append(x)
                ys.append(y)
    print("box %d,%d..%d,%d  ground %s  tol %d"
          % (x0, y0, x1, y1, qaimg.hexs(bg), tol))
    if not xs:
        print("NO CONTENT in the box, so there is no inset to report.")
        return 1
    print("inset left   %d" % (min(xs) - x0))
    print("inset top    %d" % (min(ys) - y0))
    print("inset right  %d" % (x1 - 1 - max(xs)))
    print("inset bottom %d" % (y1 - 1 - max(ys)))
    return 0


def cmd_box(args):
    tol = _opt_int(args, "--tol", 10)
    if len(args) != 6:
        qaimg.die("usage: frame.py box <png> <x0> <y0> <x1> <y1> <color> [--tol N]")
    img = _load(args[0])
    x0, y0, x1, y1 = (_int(v, "geometry") for v in args[1:5])
    try:
        want = qaimg.parse_color(args[5])
    except qaimg.ImageError as exc:
        qaimg.die(str(exc))
    xs, ys = [], []
    for y in range(max(0, y0), min(img.h, y1)):
        for x in range(max(0, x0), min(img.w, x1)):
            if _diff(img.at(x, y), want) <= tol:
                xs.append(x)
                ys.append(y)
    if not xs:
        print("no pixel within %d of %s in that box" % (tol, qaimg.hexs(want)))
        return 1
    print("%s +/-%d : x %d..%d (w %d)  y %d..%d (h %d)  n=%d"
          % (qaimg.hexs(want), tol, min(xs), max(xs), max(xs) - min(xs) + 1,
             min(ys), max(ys), max(ys) - min(ys) + 1, len(xs)))
    return 0


def cmd_edges(args):
    tol = _opt_int(args, "--tol", 10)
    if len(args) < 5:
        qaimg.die("usage: frame.py edges <png> --col <x> <y0> <y1> | --row <y> <x0> <x1>")
    img = _load(args[0])
    mode = args[1]
    a, b, c = (_int(v, "geometry") for v in args[2:5])
    runs = []
    prev = None
    start = b
    span = range(b, c)
    for t in span:
        cur = img.at(a, t) if mode == "--col" else img.at(t, a)
        if prev is None:
            prev, start = cur, t
            continue
        if _diff(cur, prev) > tol:
            runs.append((start, t - 1, prev))
            prev, start = cur, t
    if prev is not None:
        runs.append((start, c - 1, prev))
    axis = "y" if mode == "--col" else "x"
    for s, e, col in runs:
        print("%s %d..%d  (%d px)  %s" % (axis, s, e, e - s + 1, qaimg.hexs(col)))
    return 0


def cmd_motion(args):
    tol = _opt_int(args, "--tol", 10)
    step = _opt_int(args, "--step", 3)
    if len(args) < 2:
        qaimg.die("usage: frame.py motion <a.png> <b.png> [more...]")
    imgs = [(p, _load(p)) for p in args]
    w, h = imgs[0][1].w, imgs[0][1].h
    for p, im in imgs:
        if (im.w, im.h) != (w, h):
            qaimg.die("%s is %dx%d but %s is %dx%d — frames of different sizes "
                      "cannot be compared" % (p, im.w, im.h, imgs[0][0], w, h))
    for i in range(len(imgs) - 1):
        (pa, a), (pb, b) = imgs[i], imgs[i + 1]
        changed = total = 0
        worst = 0
        for y in range(0, h, step):
            for x in range(0, w, step):
                total += 1
                d = _diff(a.at(x, y), b.at(x, y))
                if d > tol:
                    changed += 1
                worst = max(worst, d)
        print("%s -> %s : changed %d/%d (%.2f%%)  max channel delta %d"
              % (os.path.basename(pa), os.path.basename(pb), changed, total,
                 100.0 * changed / max(1, total), worst))
    return 0


COMMANDS = {
    "px": cmd_px, "crop": cmd_crop, "extent": cmd_extent, "inset": cmd_inset,
    "box": cmd_box, "edges": cmd_edges, "motion": cmd_motion,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd = argv[0]
    if cmd not in COMMANDS:
        qaimg.die("frame.py: no such command %r. One of: %s"
                  % (cmd, ", ".join(sorted(COMMANDS))))
    return COMMANDS[cmd](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
