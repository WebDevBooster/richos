#!/usr/bin/env python3
"""fill-first-walk.sh's exit status says whether the walk happened (hunt part 2 v3, R37).

No guest: the walk is copied into a box beside stand-in guest.sh, ax.sh, shot.sh and relaunch.py,
and `sleep` on PATH returns at once. Every guest operation failing must end the walk with a
nonzero status (it used to print "done" and exit 0 with no frame saved); a single failed capture
must too; when every stand-in succeeds the walk exits 0 with all seven frames."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WALK = Path(__file__).resolve().parents[1] / 'fill-first-walk.sh'
failed = 0


def check(ok, what, detail=''):
    global failed
    print(('  ok    ' if ok else '  FAIL  ') + what + ('' if ok else f'  {detail}'))
    failed += 0 if ok else 1


def box(root, guest_rc=0, ax_rc=0, shot_rc=0, failing_shot=''):
    d = Path(root)
    shutil.copy2(WALK, d / 'fill-first-walk.sh')
    (d / 'guest.sh').write_text(f'#!/bin/sh\necho /Users/admin/testvm/data\nexit {guest_rc}\n')
    (d / 'ax.sh').write_text(f'#!/bin/sh\nexit {ax_rc}\n')
    (d / 'shot.sh').write_text('#!/bin/sh\n'
                               f'case "$2" in *"{failing_shot or "no-such-frame"}"*) exit 1 ;; esac\n'
                               f'[ {shot_rc} -eq 0 ] && : > "$2"\nexit {shot_rc}\n')
    (d / 'relaunch.py').write_text('def relaunch(*a, **k):\n    return {"pid": 1}\n')
    bin_dir = d / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'sleep').write_text('#!/bin/sh\nexit 0\n')
    for f in ('guest.sh', 'ax.sh', 'shot.sh', 'bin/sleep'):
        (d / f).chmod(0o755)
    out = d / 'out'
    env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'PYTHONDONTWRITEBYTECODE': '1'}
    r = subprocess.run(['/bin/bash', str(d / 'fill-first-walk.sh'), 'fixture-vm', str(out)],
                       env=env, capture_output=True, text=True, timeout=60)
    return r, sorted(p.name for p in out.glob('*.png'))


with tempfile.TemporaryDirectory() as root:
    r, pngs = box(root, guest_rc=1, ax_rc=1, shot_rc=1)
    check(r.returncode != 0 and not pngs, 'every guest operation failing ends the walk nonzero, no frame claimed',
          f'exit {r.returncode}, frames {pngs}, stdout {r.stdout[-300:]!r}')
with tempfile.TemporaryDirectory() as root:
    r, pngs = box(root, failing_shot='4-panel-after-switch')
    check(r.returncode != 0 and 'capture 4-panel-after-switch' in r.stdout and len(pngs) == 6,
          'one failed capture is named and the walk exits nonzero', f'exit {r.returncode}, frames {pngs}')
with tempfile.TemporaryDirectory() as root:
    r, pngs = box(root)
    check(r.returncode == 0 and len(pngs) == 7 and r.stdout.rstrip().endswith('done'),
          'every step succeeding exits 0 with all seven frames', f'exit {r.returncode}, frames {pngs}, {r.stderr[-300:]!r}')
print(f'fill-first-walk.test.py: {failed} failed')
sys.exit(1 if failed else 0)
