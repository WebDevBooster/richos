#!/usr/bin/env python3
"""speckle-walk.py — is the speckled ground on screen in the real app, in a guest?

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      speckle-walk.py --out DIR

run-walk.py passes the owned VM name as the first argument.

WHAT IT ANSWERS. The design system's speckled ground (CEO, 2026-09-29) is one canvas of single
device-pixel points behind the desktop shell, and never on the splash or home screen. The
browser suite (`ui/tests/speckled-ground.js`) proves that in WebKit with the DOM in hand; this
walk asks the SHIPPED bundle the one question a DOM cannot answer: do the points reach the
screen through the real WKWebView. It photographs the home screen as the app opens, presses
Return (the home screen's own key for the door, `aria-keyshortcuts="Enter"`), photographs the
shell, and counts ISOLATED POINTS inside the window: pixels that differ from each of their four
neighbors while those neighbors agree with one another. A speckle point is exactly that; text,
borders and antialiased edges are connected runs and almost never are. The count is taken in the
top third of the window, where the field's lamp is, and the bottom third, where it has thinned to
nothing, so one frame carries its own control.

It quits nothing itself: run-walk.py quits the app by its pid, stops the guest and deletes the
clone (CEO §54). Nothing here touches the host's screen.

Writes <out>/home.png, <out>/shell.png and <out>/speckle.json. Exit 0 when the shell's top third
carries at least --min-points isolated points and at least --min-ratio times its bottom third's,
else 1; 2 when the guest could not be read.
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
import qaimg  # noqa: E402


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def run(*argv):
    r = subprocess.run([str(a) for a in argv], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write('%s exited %d: %s\n' % (Path(str(argv[0])).name, r.returncode, (r.stderr or r.stdout)[-400:]))
        raise SystemExit(2)
    return r.stdout.strip()


def window_box(vm):
    """The app's first window in points, and the screen's width in points."""
    out = run(HERE / 'ax.sh', vm, '--windows')
    m = re.search(r'(\d+)x(\d+) at \((-?\d+),(-?\d+)\)', out)
    if not m:
        sys.stderr.write('no window geometry from ax.sh --windows: %s\n' % out[:200])
        raise SystemExit(2)
    w, h, x, y = (int(v) for v in m.groups())
    desk = run(HERE / 'ax.sh', vm, 'tell application "Finder" to get bounds of window of desktop')
    nums = [int(n) for n in re.findall(r'-?\d+', desk)]
    if len(nums) < 4:
        sys.stderr.write('no desktop bounds: %s\n' % desk[:200])
        raise SystemExit(2)
    return {'x': x, 'y': y, 'w': w, 'h': h, 'screen_w': nums[2] - nums[0]}


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


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--min-points', type=int, default=500)
    p.add_argument('--min-ratio', type=float, default=5.0)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / a.vm
    record = {'vm': a.vm, 'started': utc(), 'app_pid': int((state / 'app.pid').read_text().strip())}

    # The opening curtain holds for 3 s and fades; the home screen is under it. A walk has no DOM
    # to wait on, so it waits on the clock here, once, and the record says so.
    time.sleep(8)
    box = window_box(a.vm)
    record['window_points'] = box
    run(HERE / 'shot.sh', a.vm, a.out / 'home.png')
    run(HERE / 'ax.sh', a.vm, '--key', '36')  # Return: the home screen's door
    # The field is built on an idle moment after load, under the home screen; the door is a
    # 200 ms fade. Four seconds is the margin, recorded, not a verdict.
    time.sleep(4)
    run(HERE / 'shot.sh', a.vm, a.out / 'shell.png')

    result = {}
    for name in ('home', 'shell'):
        img = qaimg.load(str(a.out / (name + '.png')))
        s = img.w / box['screen_w']
        wx0, wy0 = int(box['x'] * s), int(box['y'] * s)
        wx1, wy1 = int((box['x'] + box['w']) * s), int((box['y'] + box['h']) * s)
        third = (wy1 - wy0) // 3
        top = isolated_points(img, wx0 + 4, wy0 + int(40 * s), wx1 - 4, wy0 + third)
        bottom = isolated_points(img, wx0 + 4, wy1 - third, wx1 - 4, wy1 - 4)
        result[name] = {'scale': round(s, 3), 'window_px': [wx0, wy0, wx1, wy1],
                        'top_third_isolated': top[0], 'top_third_examined': top[1],
                        'bottom_third_isolated': bottom[0], 'bottom_third_examined': bottom[1]}
    record['frames'] = result
    shell = result['shell']
    ratio = shell['top_third_isolated'] / max(1, shell['bottom_third_isolated'])
    record['shell_top_to_bottom_ratio'] = round(ratio, 2)
    record['verdict'] = 'PASS' if shell['top_third_isolated'] >= a.min_points and ratio >= a.min_ratio else 'FAIL'
    record['thresholds'] = {'min_points': a.min_points, 'min_ratio': a.min_ratio}
    record['ended'] = utc()
    (a.out / 'speckle.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'verdict': record['verdict'], 'shell': shell, 'home': result['home'],
                      'ratio': record['shell_top_to_bottom_ratio']}))
    return 0 if record['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
