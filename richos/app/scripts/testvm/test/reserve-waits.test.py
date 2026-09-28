#!/usr/bin/env python3
"""reserve.py records a CPU-admission wait for exactly as long as it lasts.

The lead's turn-end gate (engine scripts/hooks/guard-resource-waits.sh) refuses the turn
once any job has waited more than ten minutes on a shared resource, and it can only see a
wait that is recorded. These cases prove the recording, with no real sample and no sleep:
`host_sample` and `time.sleep` are replaced, and the records go to a temporary directory,
never to the operator's.

  1. a wait that is admitted: recorded from the first refusal, gone once admitted
  2. a wait that ends refused: gone after the final refusal
  3. --wait 0 (the default): refused at once, and nothing is ever recorded
  4. a walk holding guest.lock while it waits: the record names the lock it holds
"""
import json
import os
from pathlib import Path
import sys
import tempfile

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
WAITS = tempfile.mkdtemp(prefix='reserve-waits-test.')
os.environ['RICHOS_WAITS_DIR'] = WAITS
import reserve  # noqa: E402

failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


def sample(cpu_user):
    return {'cpu_user_percent': cpu_user, 'cpu_system_percent': 2.0, 'cpu_idle_percent': 100 - cpu_user - 2.0,
            'swapout_mb_per_s': 0.0, 'memory_pressure': 'normal', 'memory_free_percent': 80, 'swap_used_mb': 0.0}


def records():
    out = []
    for name in sorted(os.listdir(WAITS)):
        if name.endswith('.json'):
            with open(os.path.join(WAITS, name)) as fh:
                out.append(json.load(fh))
    return out


class Script(object):
    """host_sample returns the scripted samples in order; sleep records what is on disk."""

    def __init__(self, cpus):
        self.cpus = list(cpus)
        self.during = []

    def host_sample(self):
        return sample(self.cpus.pop(0))

    def sleep(self, seconds):
        self.during.append(records())


def run(cpus, **kw):
    s = Script(cpus)
    real_sample, real_sleep = reserve.host_sample, reserve.time.sleep
    reserve.host_sample, reserve.time.sleep = s.host_sample, s.sleep
    try:
        try:
            result = reserve.cpu_admission(**kw)
        except BlockingIOError as exc:
            result = exc
    finally:
        reserve.host_sample, reserve.time.sleep = real_sample, real_sleep
    return s, result


try:
    s, result = run([95.0, 95.0, 10.0], wait_seconds=600)
    first = s.during[0] if s.during else []
    check('1 a refused sample with time left is recorded as a CPU-admission wait, and it is gone once admitted',
          isinstance(result, dict) and len(s.during) == 2 and len(first) == 1
          and first[0]['resource'] == 'cpu-admission' and 'total CPU' in first[0]['reason']
          and first[0]['pid'] == os.getpid() and not records(),
          (result, s.during, records()))

    clock = [0.0]
    real_monotonic = reserve.time.monotonic
    reserve.time.monotonic = lambda: clock[0]
    try:
        s = Script([95.0, 95.0, 95.0])

        def advance(seconds):
            s.during.append(records())
            clock[0] += seconds
        real_sample, real_sleep = reserve.host_sample, reserve.time.sleep
        reserve.host_sample, reserve.time.sleep = s.host_sample, advance
        try:
            reserve.cpu_admission(wait_seconds=60)
            refused = None
        except BlockingIOError as exc:
            refused = exc
        finally:
            reserve.host_sample, reserve.time.sleep = real_sample, real_sleep
    finally:
        reserve.time.monotonic = real_monotonic
    check('2 a wait that ends REFUSED was recorded while it lasted and leaves nothing behind',
          refused is not None and s.during and all(len(d) == 1 for d in s.during) and not records(),
          (refused, s.during, records()))

    s, result = run([95.0], wait_seconds=0)
    check('3 --wait 0 refuses at once and never records a wait',
          isinstance(result, BlockingIOError) and s.during == [] and not records(), (result, s.during))

    lock = Path(WAITS) / 'guest.lock'
    s = Script([95.0, 10.0])
    real_sample, real_sleep = reserve.host_sample, reserve.time.sleep
    reserve.host_sample, reserve.time.sleep = s.host_sample, s.sleep
    try:
        with reserve.reservation(lock=lock, wait_seconds=600):
            pass
    finally:
        reserve.host_sample, reserve.time.sleep = real_sample, real_sleep
    held = s.during[0][0]['holding'] if s.during and s.during[0] else None
    check('4 a walk that holds guest.lock while it waits for CPU says so in its record',
          held == [str(lock.resolve())] and not records(), (held, records()))
finally:
    for name in os.listdir(WAITS):
        os.unlink(os.path.join(WAITS, name))
    os.rmdir(WAITS)

if failures:
    print('reserve waits: %d failed' % len(failures))
    sys.exit(1)
print('reserve waits: all passed')
