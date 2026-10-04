#!/usr/bin/env python3
"""A walk that finds every slot held by a run of the SAME owner refuses at once and names that pid;
it never queues behind its own walk. A different owner's hold is still waited for. No guest."""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import slots  # noqa: E402

tmp = tempfile.mkdtemp(prefix='slots-own.')
os.environ.update({'TESTVM_ROOT': tmp, 'TESTVM_SLOTS': '1', 'RICHOS_AGENT_OWNER': 'agent-x'})
holder_code = (f"import sys,time;sys.path.insert(0,{str(HERE)!r});import slots\n"
               "with slots.guest_slot(guests=lambda:[],admit=lambda:{},memory=lambda s,b:''):\n"
               "    print('held',flush=True);time.sleep(60)\n")
child = subprocess.Popen([sys.executable, '-c', holder_code], stdout=subprocess.PIPE, text=True)
failures = []
try:
    assert child.stdout.readline().strip() == 'held'
    t = time.monotonic()
    try:
        with slots.guest_slot(wait_seconds=30, guests=lambda: [], admit=lambda: {}, memory=lambda s, b: ''):
            failures.append('admitted behind own walk')
    except BlockingIOError as exc:
        quick = time.monotonic() - t < 5
        named = str(child.pid) in str(exc) and 'your own run' in str(exc)
        print(('  ok    ' if quick and named else '  FAIL  ') + 'same owner: refused at once, naming the pid', exc)
        if not (quick and named):
            failures.append('same owner')
    os.environ['RICHOS_AGENT_OWNER'] = 'agent-y'
    try:
        with slots.guest_slot(wait_seconds=2, guests=lambda: [], admit=lambda: {}, memory=lambda s, b: '',
                              sleep=lambda s: time.sleep(0.5)):
            failures.append('admitted behind another')
    except BlockingIOError as exc:
        waited = 'your own run' not in str(exc)
        print(('  ok    ' if waited else '  FAIL  ') + 'different owner: still waits its turn', exc)
        if not waited:
            failures.append('different owner')
finally:
    child.terminate()
    child.wait()
print(f'slots-own-holder.test.py: {len(failures)} failed')
sys.exit(1 if failures else 0)
