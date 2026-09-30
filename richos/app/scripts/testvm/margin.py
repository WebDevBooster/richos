"""Fixed readiness margins that stop charging for time that already passed (hunt part 2, finding
41, recheck R41). Standard library only; no guest is needed to test any of it.

A margin written as time.sleep(N) is paid in full even when the thing it waits for is already
ready. Two observable conditions replace the unconditional part, and the margin stays as the cap,
so a slow run waits exactly as long as it always did:

  remaining_since_start   the margin is measured from the app's own start (its process age in the
                          guest), so what the fixture staging and the boot already spent is not
                          spent again. The reason for the margin is unchanged: the splash curtain
                          holds for a fixed time from the app's start and a walk has no DOM to read.
  wait_change_then_still  after an action, the screen changes and then stops changing. Waits for
                          the frame to differ from the frame before the action, and then to repeat
                          itself once; the old margin is the cap. A frame that never repeats (a
                          clock tick, an animation) simply runs to the cap, as before.

An unknown is never a shortcut: an age that cannot be read, or a frame that cannot be taken, leaves
the whole margin in force.
"""
import re
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

_ETIME = re.compile(r'^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$')


def parse_etime(text):
    """ps -o etime= output ([[dd-]hh:]mm:ss) -> seconds, or None when it is not that."""
    m = _ETIME.match((text or '').strip())
    if not m:
        return None
    days, hours, minutes, seconds = (int(g or 0) for g in m.groups())
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def app_age_seconds(vm, pid, run=None):
    """How long process `pid` has been running in the guest, or None when that cannot be read."""
    run = run or (lambda argv: subprocess.run(argv, capture_output=True, text=True, timeout=30))
    try:
        r = run([str(HERE / 'guest.sh'), vm, 'ps -o etime= -p %d' % int(pid)])
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return parse_etime(r.stdout) if r.returncode == 0 else None


def remaining_since_start(margin, age):
    """Seconds still to wait for a margin counted from the app's start; the whole margin when the
    age is unknown."""
    if age is None:
        return float(margin)
    return max(0.0, float(margin) - age)


def wait_since_start(vm, pid, margin, age_of=app_age_seconds, sleep=time.sleep):
    """Sleep only what is left of `margin` seconds since the app started. Returns the record of it."""
    age = age_of(vm, pid)
    left = remaining_since_start(margin, age)
    if left:
        sleep(left)
    return {'margin_s': margin, 'app_age_s': age, 'slept_s': round(left, 2)}


def wait_change_then_still(shoot, before, cap, interval=1.0, clock=time.monotonic, sleep=time.sleep):
    """Poll `shoot()` (bytes of the current frame, or None when one cannot be taken) until a frame
    differs from `before` and is then followed by an identical one, or `cap` seconds have passed.
    Returns {'outcome': 'settled' | 'cap', 'waited_s': n, 'frames': n}."""
    began = clock()
    previous, changed, frames = before, False, 0
    while True:
        frame = shoot()
        frames += 1
        if frame is not None:
            if frame != before:
                changed = True
            if changed and frame == previous:
                return {'outcome': 'settled', 'waited_s': round(clock() - began, 2), 'frames': frames}
            previous = frame
        left = cap - (clock() - began)
        if left <= 0:
            return {'outcome': 'cap', 'waited_s': round(clock() - began, 2), 'frames': frames}
        sleep(min(interval, left))
