#!/usr/bin/env python3
"""slot-proof.py — measure the guest slots on real guests: two at once, and nobody waits between runs.

  slot-proof.py --bundle ZIP --engine ENGINE --out DIR [--observe SECONDS]

The CEO, 2026-09-27: *"do I want the work to be BLOCKED AND PISSED AWAY like this because the
current worker might need the VM for a 5-second-long fart?"* His acceptance measurement: a second
caller that arrives while the first is between runs gets a slot immediately. This runs it on the
real harness (run-walk.py + smoke-walk.py, each a real guest booting the real app), in two parts:

  PART 1, two slots. Run A starts; run B arrives while A executes and must be admitted at once
  (waited 0 s) into the second slot, so two guests run side by side, each sampling the host.
  Caller C arrives while both execute and waits; it must be admitted within a few seconds of the
  first of A and B ending.

  PART 2, ONE slot (TESTVM_SLOTS=1), so nothing but the release rule can explain the result. Run
  A1 ends and its caller is "between runs" (thinking). Caller D arrives 5 s later and must be
  admitted at once. A's next run, A2, arrives 10 s after A1 ended and waits for D's run, not the
  other way round.

Every run is run-walk.py's own: one slot for its run, the app quit by pid, the clone deleted.
Writes DIR/slot-proof.json and prints one line per measured fact. Exit 0 when every fact holds.
Uses the Mac's real test VM root, so it takes real slots: run it when the guests are free.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
HELD = re.compile(r'slot held: (\S+) \(waited (\d+)s')


class Run:
    """One owned child process; its stderr lines are timestamped as they arrive."""

    def __init__(self, name, argv, log, env=None):
        self.name, self.lines, self.started = name, [], time.time()
        self.log = open(log, 'w')
        self.proc = subprocess.Popen(argv, stdout=self.log, stderr=subprocess.PIPE, text=True,
                                     env=dict(os.environ, **(env or {})), start_new_session=True)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.proc.stderr:
            self.lines.append((time.time(), line.rstrip('\n')))
            self.log.write(line)
            self.log.flush()

    def held(self):
        for at, line in self.lines:
            m = HELD.search(line)
            if m:
                return {'at': at, 'slot': Path(m.group(1)).name, 'waited_s': int(m.group(2))}
        return None

    def released_at(self):
        for at, line in self.lines:
            if line.startswith('slot released'):
                return at
        return None

    def wait_held(self, timeout):
        deadline = time.monotonic() + timeout
        while self.held() is None and self.proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.5)
        return self.held()

    def finish(self, timeout=1200):
        rc = self.proc.wait(timeout=timeout)
        self.reader.join(timeout=30)
        self.log.close()
        return rc


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--bundle', required=True)
    p.add_argument('--engine', required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--observe', type=float, default=60, help='seconds each part-1 run stays and samples (default 60)')
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    facts, runs = [], {}

    def fact(name, ok, detail):
        facts.append({'fact': name, 'held': bool(ok), 'detail': detail})
        print(('HOLDS  ' if ok else 'FAILS  ') + name + ' — ' + json.dumps(detail), flush=True)

    with tempfile.TemporaryDirectory(prefix='slot-proof-home-', dir=os.environ.get('TMPDIR')) as home:
        def walk(name, observe, env=None):
            argv = [str(HERE / 'run-walk.py'), '--wait', '900', '--bundle', a.bundle,
                    '--home', home, '--engine', a.engine, '--report', str(a.out / f'{name}-run.json'), '--',
                    str(HERE / 'smoke-walk.py'), '--out', str(a.out / name), '--observe', str(observe)]
            runs[name] = Run(name, argv, a.out / f'{name}.log', env)
            return runs[name]

        def caller(name, env=None):
            argv = [sys.executable, str(HERE / 'slots.py'), 'run', '--wait', '900', '--purpose', 'caller ' + name,
                    '--', '/bin/sh', '-c', 'exit 0']
            runs[name] = Run(name, argv, a.out / f'{name}.log', env)
            return runs[name]

        # PART 1: two slots.
        run_a = walk('A', a.observe)
        held_a = run_a.wait_held(900)
        run_b = walk('B', a.observe)
        held_b = run_b.wait_held(900)
        fact('B, arriving while A executes, is admitted at once into the other slot',
             held_a and held_b and held_b['waited_s'] == 0 and held_b['slot'] != held_a['slot'],
             {'A': held_a, 'B': held_b})
        time.sleep(5)
        run_c = caller('C')
        time.sleep(3)
        fact('C, arriving while A and B both execute, waits', run_c.proc.poll() is None and run_c.held() is None,
             {'C_lines': [line for _, line in run_c.lines][-2:]})
        rc_a, rc_b, rc_c = run_a.finish(), run_b.finish(), run_c.finish()
        first_release = min(t for t in (run_a.released_at(), run_b.released_at()) if t)
        held_c = run_c.held()
        fact('C is admitted within 5 s of the first of A and B releasing its slot',
             held_c and 0 <= held_c['at'] - first_release <= 5,
             {'C_admitted_after_release_s': round(held_c['at'] - first_release, 1) if held_c else None})
        smoke = {n: json.loads((a.out / n / 'smoke.json').read_text()) for n in ('A', 'B')
                 if (a.out / n / 'smoke.json').exists()}
        both = [s for n in smoke for s in smoke[n]['host'] if len(s['running_guests']) == 2]
        fact('A and B each booted the app to a window, and two guests ran at once',
             rc_a == 0 and rc_b == 0 and all(smoke[n]['app_alive'] and smoke[n]['windows'] >= 1 for n in ('A', 'B'))
             and len(both) > 0,
             {'exits': [rc_a, rc_b, rc_c], 'samples_with_two_guests': len(both),
              'host_with_two_guests': both[:1] + both[-1:]})

        # PART 2: one slot, so only the release rule can admit D between A's runs.
        one = {'TESTVM_SLOTS': '1'}
        run_a1 = walk('A1', 0, one)
        rc_a1 = run_a1.finish()
        ended = run_a1.released_at() or time.time()
        time.sleep(max(0, ended + 5 - time.time()))
        run_d = walk('D', 20, one)
        held_d = run_d.wait_held(900)
        fact('with ONE slot, D arriving while A is between runs is admitted at once',
             rc_a1 == 0 and held_d and held_d['waited_s'] == 0,
             {'A1_exit': rc_a1, 'D': held_d, 'D_arrived_after_A1_released_s': round(run_d.started - ended, 1)})
        time.sleep(max(0, ended + 10 - time.time()))
        run_a2 = walk('A2', 0, one)
        rc_d = run_d.finish()
        rc_a2 = run_a2.finish()
        held_a2 = run_a2.held()
        fact("A's next run waits for D's run and then gets the slot",
             rc_d == 0 and rc_a2 == 0 and held_a2 and held_a2['waited_s'] > 0 and held_a2['at'] >= run_d.released_at(),
             {'D_exit': rc_d, 'A2_exit': rc_a2, 'A2': held_a2})

    status = subprocess.run([sys.executable, str(HERE / 'slots.py'), 'status'], capture_output=True, text=True).stdout
    root = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm')))
    mine = [json.loads((a.out / f'{n}-run.json').read_text()) for n in ('A', 'B', 'A1', 'D', 'A2')
            if (a.out / f'{n}-run.json').exists()]
    listing = subprocess.run(['bash', '-c', '. "$1/lib.sh"; preflight_tart >/dev/null; tart list --format json',
                              'proof', str(HERE)], capture_output=True, text=True, timeout=60)
    clones = [r.get('Name') for r in json.loads(listing.stdout or '[]') if r.get('Source') == 'local']
    left = [r['vm'] for r in mine if (root / 'run' / r['vm']).exists() or r['vm'] in clones]
    fact('nothing is left behind: every run reported its cleanup complete, and no clone or run state remains',
         len(mine) == 5 and all(r.get('cleanup_complete') for r in mine) and not left and listing.returncode == 0,
         {'runs': [(r['vm'], r.get('cleanup_complete'), round(r.get('cleanup_seconds', 0), 1)) for r in mine],
          'left': left, 'slots_now': status.strip().splitlines()})
    (a.out / 'slot-proof.json').write_text(json.dumps({'facts': facts}, indent=2) + '\n')
    return 0 if all(f['held'] for f in facts) else 1


if __name__ == '__main__':
    sys.exit(main())
