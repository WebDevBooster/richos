#!/usr/bin/env python3
"""Hold an owned, booted test guest open for hand-driven steps, then hand it back for cleanup.

Run by run-walk.py, which boots the guest, holds <TESTVM_ROOT>/guest.lock and removes the clone:

  run-walk.py --bundle ZIP --home FIXTURE --engine ENGINE --report REPORT -- \\
      hold-walk.py --out DIR [--minutes N]

run-walk.py passes the owned VM name as the first argument.

WHY IT EXISTS. A walk script is written once its steps are known, and on a surface nobody has
walked yet (a first run from an empty home, a new sheet) they are not known: the steps are found
with ax.sh, shot.sh and guest.sh by hand, against a live guest. Until this existed the only way
to keep a guest up for that was to boot it with run.sh outside run-walk.py, which holds no guest
lock and leaves the clone's cleanup to whoever remembers. Here the guest stays under run-walk.py's
lock and cleanup the whole time.

It writes <out>/vm (the guest's name, for ax.sh/shot.sh/guest.sh), then waits until <out>/release
exists or --minutes pass, whichever is first, and exits 0. run-walk.py then quits the app by its
pid, stops the guest and deletes the clone (CEO §54). Nothing here touches the host's screen.
"""
import argparse
from pathlib import Path
import sys
import time


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--minutes', type=float, default=30, help='the most the guest is held (default 30)')
    a = p.parse_args()
    if not 0 < a.minutes <= 120:
        p.error('--minutes must be more than 0 and at most 120')
    a.out.mkdir(parents=True, exist_ok=True)
    release = a.out / 'release'
    if release.exists():
        p.error(f'{release} already exists; remove it or use a new --out')
    (a.out / 'vm').write_text(a.vm + '\n')
    print(f'holding {a.vm} for at most {a.minutes:g} min; touch {release} to hand it back', flush=True)
    deadline = time.monotonic() + a.minutes * 60
    while time.monotonic() < deadline:
        if release.exists():
            print('released by hand', flush=True)
            return 0
        time.sleep(2)
    print('held for the whole --minutes; handing the guest back', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
