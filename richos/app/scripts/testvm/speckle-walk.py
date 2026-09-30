#!/usr/bin/env python3
"""speckle-walk.py — is the speckled ground on screen in the real app, in a guest, in BOTH themes?

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      speckle-walk.py --out DIR

run-walk.py passes the owned VM name as the first argument.

WHAT IT ANSWERS. The design system's speckled ground (CEO, 2026-09-29) is one canvas of single
device-pixel points behind the desktop shell, in both themes, and never on the splash or home
screen. The browser suite (`ui/tests/speckled-ground.js`) proves that in WebKit with the DOM in
hand; this walk asks the SHIPPED bundle the one question a DOM cannot answer: do the points reach
the screen through the real WKWebView. It photographs the home screen as the app opens, presses
Return (the home screen's own key for the door, `aria-keyshortcuts="Enter"`), photographs the
shell in the guest's lighting, flips the guest's OS appearance (a fresh install's theme is
`system`, so the shell follows the OS live, appearance.js check 1b) and photographs the shell in
the other theme. In each frame it counts ISOLATED POINTS inside the window: pixels that differ
from each of their four neighbors while those neighbors agree with one another. A speckle point
is exactly that; text, borders and antialiased edges are connected runs and almost never are.
The count is taken in the top third of the window, where the field's lamp is, and the bottom
third, where it has thinned to nothing, so one frame carries its own control.

EVERY GUEST CALL GOES THROUGH SYSTEM EVENTS, and that is not style. The guest grants the ssh
session Apple Events for `com.apple.systemevents` and nothing else (provision-guest.sh:105-110),
so an Apple Event to any other application waits on a consent prompt nobody can answer and dies
at ax.sh's deadline. The first version of this walk read the screen width from Finder and ended
exactly that way, twice, exit 124, before a single photograph (2026-09-29). The screen width is
now the width of the app's own menu bar, which spans the screen, read through System Events.

WHAT THE FIRST RUN THAT GOT THIS FAR SHOWED (2026-09-29, bundle 1.2.0-dev.6c4f82b0, EMPTY
--home), so the next reader does not rediscover it:
  * a fresh install does NOT open on the home screen: it opens on the shell with the first-run
    "Your memory folder" notice over a scrim, so `home.png` is the shell's first frame and the
    "never on the home screen" half is not observed by this walk with an empty home
    (`ui/tests/speckled-ground.js` check 7 holds it in WebKit);
  * the verdict's --min-ratio premise, that the lamp has thinned to nothing in the bottom third,
    is false for the shipped field: isolated points per 1000 px were 38.98 (light) and 19.23
    (dark) low on the stage against 88.65 and 57.54 high on it, so the ratio came out 2.34 and
    3.29 and the verdict FAIL, while opaque surfaces in the same frames (the notice's panel,
    the composer field) counted 0.00 per 1000 in both themes. The points are on screen in both
    themes; the ratio is the wrong control. Its thresholds are left as they were, not tuned to
    the frames they would then be judged by.

It quits nothing itself: run-walk.py quits the app by its pid, stops the guest and deletes the
clone (CEO §54). The appearance it flips is the GUEST's; nothing here touches the host's screen.

Writes <out>/home.png, <out>/shell-<theme>.png for each theme and <out>/speckle.json. Exit 0 when
the shell's top third carries at least --min-points isolated points and at least --min-ratio
times its bottom third's IN BOTH THEMES, else 1; 2 when the guest could not be read (the failing
step is named).
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'qa' / 'lib'))
sys.path.insert(0, str(HERE))
import margin  # noqa: E402
import qaimg  # noqa: E402


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def run(step, *argv):
    """Run one guest step. A failure names the STEP and the command, so exit 2 says which read
    of the guest could not be made rather than only which program printed the error."""
    r = subprocess.run([str(a) for a in argv], capture_output=True, text=True)
    if r.returncode != 0:
        shown = ' '.join(str(a) if len(str(a)) < 80 else str(a)[:77] + '...' for a in argv[1:])
        sys.stderr.write('step "%s" failed: %s %s exited %d: %s\n' % (
            step, Path(str(argv[0])).name, shown, r.returncode, (r.stderr or r.stdout)[-400:]))
        raise SystemExit(2)
    return r.stdout.strip()


def parse_window(out):
    """`ax.sh --windows` output -> (w, h, x, y) of the first window, or None."""
    m = re.search(r'(\d+)x(\d+) at \((-?\d+),(-?\d+)\)', out)
    return tuple(int(v) for v in m.groups()) if m else None


def parse_width(out):
    """The first integer AppleScript printed for a `size` ({w, h} prints as "w, h"), or None."""
    m = re.search(r'-?\d+', out)
    return int(m.group(0)) if m else None


def window_box(vm, pid):
    """The app's first window in points, and the screen's width in points."""
    out = run('window geometry', HERE / 'ax.sh', vm, '--windows')
    win = parse_window(out)
    if not win:
        sys.stderr.write('step "window geometry": no window in ax.sh --windows: %s\n' % out[:200])
        raise SystemExit(2)
    w, h, x, y = win
    bar = run('screen width', HERE / 'ax.sh', vm,
              'tell application "System Events" to get size of menu bar 1 of '
              '(first process whose unix id is %d)' % pid)
    screen_w = parse_width(bar)
    # A menu bar narrower than the window cannot be the screen's width: refuse rather than scale
    # every count by a wrong number.
    if not screen_w or screen_w < w:
        sys.stderr.write('step "screen width": menu bar width %r is not a screen width (window %d wide): %s\n'
                         % (screen_w, w, bar[:200]))
        raise SystemExit(2)
    return {'x': x, 'y': y, 'w': w, 'h': h, 'screen_w': screen_w}


def guest_dark(vm):
    out = run('read the guest appearance', HERE / 'ax.sh', vm,
              'tell application "System Events" to tell appearance preferences to get dark mode')
    if out not in ('true', 'false'):
        sys.stderr.write('step "read the guest appearance": %r\n' % out[:200])
        raise SystemExit(2)
    return out == 'true'


def isolated_points(img, x0, y0, x1, y1, delta=3):
    """Pixels that differ by >= delta (any channel) from each of their 4 neighbors, where the
    4 neighbors agree with each other within delta. Returns (count, pixels examined)."""
    def px(x, y):
        return img.at(x, y)[:3]

    def near(a, b):
        return all(abs(a[i] - b[i]) < delta for i in range(3))

    count = seen = 0
    for y in range(max(1, y0), min(img.h - 1, y1)):
        for x in range(max(1, x0), min(img.w - 1, x1)):
            seen += 1
            c = px(x, y)
            n = (px(x - 1, y), px(x + 1, y), px(x, y - 1), px(x, y + 1))
            if all(near(n[0], q) for q in n[1:]) and not near(c, n[0]):
                count += 1
    return count, seen


def measure(path, box):
    img = qaimg.load(str(path))
    s = img.w / box['screen_w']
    wx0, wy0 = int(box['x'] * s), int(box['y'] * s)
    wx1, wy1 = int((box['x'] + box['w']) * s), int((box['y'] + box['h']) * s)
    third = (wy1 - wy0) // 3
    top = isolated_points(img, wx0 + 4, wy0 + int(40 * s), wx1 - 4, wy0 + third)
    bottom = isolated_points(img, wx0 + 4, wy1 - third, wx1 - 4, wy1 - 4)
    return {'scale': round(s, 3), 'window_px': [wx0, wy0, wx1, wy1],
            'top_third_isolated': top[0], 'top_third_examined': top[1],
            'bottom_third_isolated': bottom[0], 'bottom_third_examined': bottom[1]}


def verdict(frame, min_points, min_ratio):
    ratio = frame['top_third_isolated'] / max(1, frame['bottom_third_isolated'])
    ok = frame['top_third_isolated'] >= min_points and ratio >= min_ratio
    return ok, round(ratio, 2)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--min-points', type=int, default=500)
    p.add_argument('--min-ratio', type=float, default=5.0)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / a.vm
    pid = int((state / 'app.pid').read_text().strip())
    record = {'vm': a.vm, 'started': utc(), 'app_pid': pid}

    # The opening curtain holds for 3 s and fades; the home screen is under it. A walk has no DOM
    # to wait on, so it waits on the clock, counted from the app's own start so that what the boot
    # already spent is not spent again (R41); the record says how long it slept.
    record['waits'] = {'curtain': margin.wait_since_start(a.vm, pid, 8)}
    box = window_box(a.vm, pid)
    record['window_points'] = box
    run('photograph the home screen', HERE / 'shot.sh', a.vm, a.out / 'home.png')
    run('press Return on the home screen', HERE / 'ax.sh', a.vm, '--key', '36')
    # The field is built on an idle moment after load, under the home screen; the door is a
    # 200 ms fade. The frame has to change from the home screen and then hold still; four seconds
    # is the cap, recorded, not a verdict.
    record['waits']['door'] = margin.wait_change_then_still(
        lambda: shoot_bytes(a.vm, a.out / 'settle.png'), (a.out / 'home.png').read_bytes(), 4)

    frames = {'home': measure_after(a, 'home', box)}
    themes = []
    first_dark = guest_dark(a.vm)
    first_frame = None
    for flip in (False, True):
        dark = (not first_dark) if flip else first_dark
        if flip:
            run('flip the guest appearance', HERE / 'ax.sh', a.vm,
                'tell application "System Events" to tell appearance preferences to set dark mode to %s'
                % ('true' if dark else 'false'))
            # The shell follows the OS live and the engine re-solves the field for the new theme
            # (speckled-ground.js check 6); the frame has to change from the first theme's and
            # then hold still, four seconds at most, recorded, not a verdict.
            record['waits']['theme'] = margin.wait_change_then_still(
                lambda: shoot_bytes(a.vm, a.out / 'settle.png'), first_frame, 4)
            if guest_dark(a.vm) != dark:
                sys.stderr.write('step "flip the guest appearance": the guest did not change appearance\n')
                raise SystemExit(2)
        theme = 'dark' if dark else 'light'
        name = 'shell-' + theme
        run('photograph the shell (%s)' % theme, HERE / 'shot.sh', a.vm, a.out / (name + '.png'))
        first_frame = first_frame or (a.out / (name + '.png')).read_bytes()
        frames[name] = measure_after(a, name, box)
        ok, ratio = verdict(frames[name], a.min_points, a.min_ratio)
        frames[name]['top_to_bottom_ratio'] = ratio
        frames[name]['pass'] = ok
        themes.append(theme)

    (a.out / 'settle.png').unlink(missing_ok=True)
    record['frames'] = frames
    record['themes'] = themes
    record['verdict'] = 'PASS' if all(frames['shell-' + t]['pass'] for t in themes) else 'FAIL'
    record['thresholds'] = {'min_points': a.min_points, 'min_ratio': a.min_ratio}
    record['ended'] = utc()
    (a.out / 'speckle.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'verdict': record['verdict'], 'frames': frames}))
    return 0 if record['verdict'] == 'PASS' else 1


def shoot_bytes(vm, path):
    """The guest's screen as PNG bytes, or None when a frame could not be taken (an unknown never
    shortens a wait)."""
    r = subprocess.run([str(HERE / 'shot.sh'), vm, str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return Path(path).read_bytes()
    except OSError:
        return None


def measure_after(a, name, box):
    return measure(a.out / (name + '.png'), box)


if __name__ == '__main__':
    sys.exit(main())
