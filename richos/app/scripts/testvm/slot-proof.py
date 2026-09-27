#!/usr/bin/env python3
"""slot-proof.py — measure the guest slots on real guests: nobody waits between runs, and two run at once when they fit.

  slot-proof.py --bundle ZIP --engine ENGINE --out DIR [--observe SECONDS]

The CEO, 2026-09-27: *"do I want the work to be BLOCKED AND PISSED AWAY like this because the
current worker might need the VM for a 5-second-long fart?"* His acceptance measurement: a second
caller that arrives while the first is between runs gets a slot immediately. This runs it on the
real harness (run-walk.py + smoke-walk.py, each a real guest booting the real app), in two parts:

  PART 1, ONE slot (TESTVM_SLOTS=1), so nothing but the release rule can explain the result. Run
  A1 ends and its caller is "between runs" (thinking). Caller D arrives 5 s later and must be
  admitted with no wait. A's next run, A2, arrives 10 s after A1 ended and waits for D's run,
  not the other way round.

  PART 2, two slots. Run A starts; run B arrives while A executes. B must never wait for a slot
  (the second one is free); it is admitted at once when the Mac's CPU and memory allow a second
  guest, or it waits on that named reason and runs when they do. Both runs boot the app to a
  window and clean up; when they overlapped, the host samples taken with two guests running are
  recorded.

Every run is run-walk.py's own: one slot for its run, the app quit by pid, the clone deleted.
Each run's output goes to a FILE (never a pipe this script reads), so stopping this script can
never break a run's cleanup. Writes DIR/slot-proof.json and prints one line per measured fact.
Exit 0 when every fact holds. It takes real slots on this Mac: run it when the guests are free.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
HELD = re.compile(r'slot held: (\S+) \(waited (\d+)s')
WAITING = re.compile(r'slot waiting: (.*); up to')


class Run:
    """One owned run-walk.py; its output goes to a file, read back line by line when asked."""

    def __init__(self, name, argv, log, env=None):
        self.name, self.log, self.started = name, log, time.time()
        self.seen, self.at = [], {}
        with open(log, 'w') as out:
            self.proc = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT,
                                         env=dict(os.environ, **(env or {})), start_new_session=True)

    def lines(self):
        """Every line so far; a line's time is when this script first saw it (polled at 0.5 s)."""
        text = self.log.read_text(errors='replace') if self.log.exists() else ''
        for line in text.splitlines()[len(self.seen):]:
            self.seen.append(line)
            self.at[len(self.seen) - 1] = time.time()
        return list(enumerate(self.seen))

    def first(self, pattern):
        for i, line in self.lines():
            m = pattern.search(line)
            if m:
                return self.at[i], m
        return None, None

    def held(self):
        at, m = self.first(HELD)
        return {'at': at, 'slot': Path(m.group(1)).name, 'waited_s': int(m.group(2))} if m else None

    def waits(self):
        return [WAITING.search(line).group(1) for _, line in self.lines() if WAITING.search(line)]

    def released_at(self):
        for i, line in self.lines():
            if line.startswith('slot released'):
                return self.at[i]
        return None

    def poll_until(self, test, timeout):
        deadline = time.monotonic() + timeout
        while not test() and self.proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.5)
            self.lines()
        return test()

    def finish(self, timeout=1800):
        while self.proc.poll() is None:
            self.lines()
            time.sleep(0.5)
        self.proc.wait(timeout=timeout)
        self.lines()
        return self.proc.returncode


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--bundle', required=True)
    p.add_argument('--engine', required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--observe', type=float, default=90, help='seconds each part-2 run stays and samples (default 90)')
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    facts, observed = [], {}

    def fact(name, ok, detail):
        facts.append({'fact': name, 'held': bool(ok), 'detail': detail})
        print(('HOLDS  ' if ok else 'FAILS  ') + name + ' — ' + json.dumps(detail, default=str), flush=True)

    with tempfile.TemporaryDirectory(prefix='slot-proof-home-', dir=os.environ.get('TMPDIR')) as home:
        def walk(name, observe, env=None):
            argv = [str(HERE / 'run-walk.py'), '--wait', '1800', '--bundle', a.bundle,
                    '--home', home, '--engine', a.engine, '--report', str(a.out / f'{name}-run.json'), '--',
                    str(HERE / 'smoke-walk.py'), '--out', str(a.out / name), '--observe', str(observe)]
            return Run(name, argv, a.out / f'{name}.log', env)

        # PART 1: ONE slot, so only the release rule can admit D between A's runs.
        one = {'TESTVM_SLOTS': '1'}
        run_a1 = walk('A1', 0, one)
        rc_a1 = run_a1.finish()
        ended = run_a1.released_at() or time.time()
        time.sleep(max(0, ended + 5 - time.time()))
        run_d = walk('D', 30, one)
        run_d.poll_until(run_d.held, 1800)
        held_d = run_d.held()
        fact('with ONE slot, D arriving while A is between runs is admitted with no wait',
             rc_a1 == 0 and held_d and held_d['waited_s'] == 0,
             {'A1_exit': rc_a1, 'D': held_d, 'D_arrived_after_A1_released_s': round(run_d.started - ended, 1),
              'D_waits': run_d.waits()})
        time.sleep(max(0, ended + 10 - time.time()))
        run_a2 = walk('A2', 0, one)
        rc_d, rc_a2 = run_d.finish(), run_a2.finish()
        held_a2 = run_a2.held()
        d_released = run_d.released_at()
        fact("A's next run waits for D's run, then gets the slot within 5 s of its release",
             rc_d == 0 and rc_a2 == 0 and held_a2 and d_released and 0 <= held_a2['at'] - d_released <= 5,
             {'D_exit': rc_d, 'A2_exit': rc_a2, 'A2': held_a2, 'A2_waits': run_a2.waits()[:1],
              'A2_admitted_after_D_released_s': round(held_a2['at'] - d_released, 1) if held_a2 and d_released
              else None})

        # PART 2: two slots.
        run_a = walk('A', a.observe)
        run_a.poll_until(run_a.held, 1800)
        held_a = run_a.held()
        time.sleep(20)
        run_b = walk('B', a.observe)
        run_b.poll_until(lambda: run_b.held() or run_b.waits(), 60)
        rc_a, rc_b = run_a.finish(), run_b.finish()
        held_b, b_waits = run_b.held(), run_b.waits()
        a_released = run_a.released_at()
        overlapped = bool(held_b and a_released and held_b['at'] < a_released)
        fact('B, arriving while A executes, never waits for a slot: only on a named CPU or memory reason',
             held_a and held_b and not [w for w in b_waits if w.startswith('every slot is executing')],
             {'A': held_a, 'B': held_b, 'B_waits': b_waits[:3], 'ran_at_once': overlapped})
        smoke = {n: json.loads((a.out / n / 'smoke.json').read_text()) for n in ('A', 'B')
                 if (a.out / n / 'smoke.json').exists()}
        fact('A and B each booted the app to a window and ended cleanly',
             rc_a == 0 and rc_b == 0 and len(smoke) == 2
             and all(smoke[n]['app_alive'] and smoke[n]['windows'] >= 1 for n in smoke),
             {'exits': [rc_a, rc_b], 'windows': {n: smoke[n]['windows'] for n in smoke}})
        both = [dict(s, run=n) for n in smoke for s in smoke[n]['host'] if len(s['running_guests']) == 2]
        observed['two_guests_at_once'] = {'overlapped': overlapped, 'samples': both}

    status = subprocess.run([sys.executable, str(HERE / 'slots.py'), 'status'], capture_output=True, text=True).stdout
    root = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm')))
    mine = [json.loads((a.out / f'{n}-run.json').read_text()) for n in ('A1', 'D', 'A2', 'A', 'B')
            if (a.out / f'{n}-run.json').exists()]
    listing = subprocess.run(['bash', '-c', '. "$1/lib.sh"; preflight_tart >/dev/null; tart list --format json',
                              'proof', str(HERE)], capture_output=True, text=True, timeout=60)
    clones = [r.get('Name') for r in json.loads(listing.stdout or '[]') if r.get('Source') == 'local']
    left = [r['vm'] for r in mine if (root / 'run' / r['vm']).exists() or r['vm'] in clones]
    fact('nothing is left behind: every run reported its cleanup complete, and no clone or run state remains',
         len(mine) == 5 and all(r.get('cleanup_complete') for r in mine) and not left and listing.returncode == 0,
         {'runs': [(r['vm'], r.get('cleanup_complete'), round(r.get('cleanup_seconds', 0), 1)) for r in mine],
          'left': left, 'slots_now': status.strip().splitlines()})
    (a.out / 'slot-proof.json').write_text(json.dumps({'facts': facts, 'observed': observed}, indent=2,
                                                      default=str) + '\n')
    return 0 if all(f['held'] for f in facts) else 1


if __name__ == '__main__':
    sys.exit(main())
