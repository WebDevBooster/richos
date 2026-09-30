#!/usr/bin/env python3
"""The phone walk presses a Safari button the moment it exists instead of sleeping 2 s first
(hunt part 2, finding 41), and the import walk's after-relaunch reading looks before it sleeps.

No guest: Walk.press is replaced by a stub that fails with 'notfound' a set number of times."""
import importlib.util
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('delta_walk', HERE / 'delta-walk.py')
delta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delta)
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


class Stub(delta.Walk):
    def __init__(self, misses):
        self.misses, self.calls = misses, 0

    def press(self, title, app=None, role='AXButton'):
        self.calls += 1
        if self.calls <= self.misses:
            raise delta.Failure('harness failure', 'notfound: ' + title)
        return 'pressed'


began = time.monotonic()
w = Stub(0)
check('a button that is already there is pressed on the first look', w.press_when_present('They match', 'Safari') == 'pressed' and w.calls == 1)
check('...with no fixed sleep before it', time.monotonic() - began < 1.0)

w = Stub(2)
check('a button that appears late is pressed once it does', w.press_when_present('They match', 'Safari') == 'pressed' and w.calls == 3, w.calls)

w = Stub(10 ** 6)
try:
    w.press_when_present('They match', 'Safari', budget=0)
    raised = False
except delta.Failure:
    raised = True
check('a button that never appears still fails, at the budget', raised)

src = (HERE / 'import-walk.py').read_text()
i = src.index("name_on_screen(vm, a.out, 'w6-after-%d' % attempt)")
check('import walk W6 looks before it sleeps', 'time.sleep(8)' not in src[src.rindex('while', 0, i):i])
sys.exit(1 if failures else 0)
