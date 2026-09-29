#!/usr/bin/env python3
"""speckle-walk.py's measurement against synthetic frames: speckle counts, text and edges do not."""
import importlib.util
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'qa' / 'lib'))
import qaimg  # noqa: E402

spec = importlib.util.spec_from_file_location('speckle_walk', HERE.parent / 'speckle-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


GROUND = (12, 19, 34)


def frame(w=200, h=120):
    return qaimg.Img(w, h, bytearray(GROUND * (w * h)))


def put(img, x, y, rgb):
    i = (y * img.w + x) * 3
    img.px[i:i + 3] = bytes(rgb)


# A plain ground: nothing isolated.
img = frame()
n, seen = walk.isolated_points(img, 0, 0, img.w, img.h)
check('a plain ground has no isolated points', n == 0, n)
check('every interior pixel is examined', seen == (img.w - 2) * (img.h - 2), seen)

# Speckle: 300 single points at least 3 px apart, each a few levels off the ground.
rng = random.Random(15061)
img = frame()
placed = set()
while len(placed) < 300:
    x, y = rng.randrange(2, img.w - 2), rng.randrange(2, img.h - 2)
    if any(abs(x - a) < 3 and abs(y - b) < 3 for a, b in placed):
        continue
    placed.add((x, y))
    put(img, x, y, (GROUND[0] + 9, GROUND[1] + 10, GROUND[2] + 12))
n, _ = walk.isolated_points(img, 0, 0, img.w, img.h)
check('each single speckle point is counted once', n == 300, n)

# A point under the delta (2 levels) is not a point.
img = frame()
put(img, 50, 50, (GROUND[0] + 2, GROUND[1] + 2, GROUND[2] + 2))
check('a difference under the delta is not counted', walk.isolated_points(img, 0, 0, img.w, img.h)[0] == 0)

# Text-like strokes and a border: connected runs, never isolated.
img = frame()
for x in range(20, 180):
    put(img, x, 30, (223, 228, 238))          # a 1 px horizontal rule
for y in range(40, 100):
    put(img, 60, y, (223, 228, 238))          # a vertical stroke
for y in range(60, 70):
    for x in range(100, 108):
        put(img, x, y, (194, 163, 92))        # a filled glyph box
n, _ = walk.isolated_points(img, 0, 0, img.w, img.h)
check('rules, strokes and filled shapes are not isolated points', n == 0, n)

# The region bounds are honored.
img = frame()
put(img, 10, 10, (60, 70, 90))
put(img, 150, 100, (60, 70, 90))
check('only points inside the region are counted', walk.isolated_points(img, 0, 0, 100, 60)[0] == 1)

# The guest reads, as ax.sh prints them.
check('a window line parses to (w, h, x, y)',
      walk.parse_window('RichOS 1400x900 at (140,75)\n') == (1400, 900, 140, 75))
check('no window line is None, never a zero box', walk.parse_window('') is None)
check('a menu bar size {1680, 24} prints as "1680, 24" and parses to its width',
      walk.parse_width('1680, 24') == 1680)
check('an empty menu bar read is None', walk.parse_width('') is None)

# The verdict, per theme: enough points AND the lamp's top third well over the bottom third.
check('a lit top third passes', walk.verdict({'top_third_isolated': 900, 'bottom_third_isolated': 100}, 500, 5.0) == (True, 9.0))
check('too few points fails even at a high ratio',
      walk.verdict({'top_third_isolated': 400, 'bottom_third_isolated': 0}, 500, 5.0)[0] is False)
check('points spread evenly (no lamp) fail on the ratio',
      walk.verdict({'top_third_isolated': 900, 'bottom_third_isolated': 400}, 500, 5.0)[0] is False)

# No Apple Event to anything but System Events: the guest grants nothing else, and the first
# version's Finder read died at the deadline before a single photograph (exit 124, twice).
src = (HERE.parent / 'speckle-walk.py').read_text()
targets = set(__import__('re').findall(r'tell application \\?"([^"\\]+)', src))
check('every Apple Event goes to System Events', targets == {'System Events'}, targets)

print('%d failure(s)' % len(failures))
sys.exit(1 if failures else 0)
