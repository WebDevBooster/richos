#!/usr/bin/env python3
"""A caller waiting for a test VM slot is RECORDED, and past ten minutes it refuses the lead's turn.

The lead's ruling on esc-20260927T192047Z-fb31d4e2: a wait is recorded, never inferred from
process names. So slots.py records its caller's wait through the engine's resource_waits.py,
and the engine's Stop gate (scripts/hooks/guard-resource-waits.sh) reads that record. This runs
both for real, end to end, with no guest and no real clock:

  1. both slots are held by this process; a real `guest_slot(wait_seconds=8)` in a child
     process waits, and its wait is on disk as a test-VM wait naming why it waits
  2. the real gate, its clock moved 11 minutes on, REFUSES the turn and names the waiter,
     the resource and the holder (and that the holder has no guest booted)
  3. the same gate at 9 minutes lets the turn end
  4. when the child's wait ends (refused after 8 s), the record is gone and the gate at
     11 minutes lets the turn end

Every path is temporary: TESTVM_ROOT, the waits directory, the escalation ledger, the workspace
registry and the seated repository. The child is started and stopped by its own pid.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parents[1]
GATE = HERE.parents[2] / 'engine' / 'scripts' / 'hooks' / 'guard-resource-waits.sh'
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)[:1500]))
    if not cond:
        failures.append(name)


tmp = Path(tempfile.mkdtemp(prefix='slots-wait-gate.')).resolve()
env = dict(os.environ)
env.update({
    'TESTVM_ROOT': str(tmp / 'testvm'),
    'TESTVM_SLOTS': '2',
    'RICHOS_WAITS_DIR': str(tmp / 'waits'),
    'RICHOS_ESCALATION_LEDGER': str(tmp / 'escalations.jsonl'),
    'RICHOS_WORKSPACES_DIR': str(tmp / 'workspaces'),
})
env.pop('RICHOS_RESOURCE_WAITS_NOW', None)
env.pop('RICHOS_RESOURCE_WAIT_MINUTES', None)
(tmp / 'escalations.jsonl').write_text('')
child = None
held = []


def records():
    d = tmp / 'waits'
    return [json.loads(p.read_text()) for p in sorted(d.glob('*.json'))] if d.is_dir() else []


def gate(now_offset):
    seat = tmp / 'seat'
    payload = json.dumps({'hook_event_name': 'Stop', 'session_id': 'aaaa0002-0000-4000-8000-000000000000',
                          'cwd': str(seat), 'prompt_id': 'bbbb0002-0000-4000-8000-000000000000',
                          'transcript_path': str(seat / 'none.jsonl'), 'stop_hook_active': False,
                          'last_assistant_message': 'Done.'})
    e = dict(env, RICHOS_ENTITY_ROOT=str(seat), RICHOS_RESOURCE_WAITS_NOW='%.0f' % (time.time() + now_offset))
    return subprocess.run(['bash', str(GATE)], input=payload, capture_output=True, text=True, env=e,
                          cwd=str(seat), timeout=60)


try:
    seat = tmp / 'seat'
    seat.mkdir()
    for args in (['init', '-q', '-b', 'main'], ['config', 'user.email', 't@example.invalid'],
                 ['config', 'user.name', 't'], ['config', 'core.hooksPath', str(tmp / 'nohooks')]):
        subprocess.run(['git', '-C', str(seat), *args], check=True, capture_output=True)
    (seat / 'orchestration.config').write_text('')
    subprocess.run(['git', '-C', str(seat), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(seat), 'commit', '-qm', 'seed'], check=True, capture_output=True)

    # Both slots held by THIS process, each with the holder record slots.py writes.
    root = tmp / 'testvm'
    root.mkdir()
    for name in ('guest.lock', 'guest-2.lock'):
        fh = (root / name).open('a+')
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fh.seek(0)
        fh.truncate()
        fh.write(json.dumps({'pid': os.getpid(), 'since': time.time() - 300, 'purpose': 'test holder ' + name,
                             'slot': name, 'state': 'running'}) + '\n')
        fh.flush()
        held.append(fh)

    code = ('import sys; sys.path.insert(0, %r); import slots\n'
            'with slots.guest_slot(wait_seconds=8, purpose="slot-wait-gate child"):\n'
            '    pass\n' % str(HERE))
    child = subprocess.Popen([sys.executable, '-c', code], env=env, stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, text=True)
    deadline = time.time() + 6
    while not records() and time.time() < deadline and child.poll() is None:
        time.sleep(0.1)
    recs = records()
    check('1 a caller waiting for a slot is recorded as a test-VM wait, with why it waits',
          len(recs) == 1 and recs[0]['resource'] == 'testvm-slot' and recs[0]['pid'] == child.pid
          and 'every slot is executing a run' in recs[0]['reason'], recs)

    r = gate(660)
    check('2 at 11 minutes the real gate REFUSES the lead\'s turn, naming the waiter, the VM and its holders',
          r.returncode == 2 and 'the test VM' in r.stderr and 'every slot is executing a run' in r.stderr
          and 'held by pid %d' % os.getpid() in r.stderr and 'IN USE RIGHT NOW: NO' in r.stderr,
          (r.returncode, r.stderr))

    r = gate(540)
    check('3 at 9 minutes the same gate lets the turn end', r.returncode == 0 and not r.stderr.strip(),
          (r.returncode, r.stderr))

    try:
        child.wait(timeout=20)
    except subprocess.TimeoutExpired:
        pass
    r = gate(660)
    check('4 once the wait ends (refused after 8 s) its record is gone and the turn may end',
          child.returncode not in (None, 0) and 'guest slot refused' in (child.stderr.read() or '')
          and not records() and r.returncode == 0, (child.returncode, records(), r.returncode, r.stderr))
finally:
    if child is not None and child.poll() is None:
        child.kill()
        child.wait()
    for fh in held:
        fh.close()
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    print('slots wait gate: %d failed' % len(failures))
    sys.exit(1)
print('slots wait gate: all passed')
