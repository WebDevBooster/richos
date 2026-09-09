#!/usr/bin/env python3
"""Verify the real Rust runner retains a passed inference lock FD; no model calls."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[4])
args = parser.parse_args()
repo = args.repo.resolve(strict=True)
runner = repo / 'app/target/debug/richos-run'
root = Path(tempfile.mkdtemp(prefix='richos-r7-runner-lease-'))
fake = root / 'native'
fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
root=Path(os.environ['RICHOS_LEASE_FIXTURE'])
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}}),flush=True)
 elif m.get('type')=='user':
  (root/'provider-started').write_text(str(os.getpid()))
  deadline=time.monotonic()+15
  while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(0.02)
  print(json.dumps({'type':'result','subtype':'success','stop_reason':'end_turn','structured_output':{'result':{'kind':'incomplete','remaining':'The fixture repair remains unfinished.'}}}),flush=True)
''')
fake.chmod(0o700)
lease = (root / 'inference.lock').open('a')
fcntl.flock(lease, fcntl.LOCK_EX)
checks = {}
process = None
try:
    env = {**os.environ, 'RICHOS_CLAUDE_BIN': str(fake), 'RICHOS_LEASE_FIXTURE': str(root)}
    with (root / 'stdout.json').open('w') as stdout, (root / 'stderr.log').open('w') as stderr:
        process = subprocess.Popen([str(runner), 'audit-session', str(root), '30'],
            stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, text=True, env=env,
            pass_fds=(lease.fileno(),))
        process.stdin.write(json.dumps({'messages': [{'role': 'user', 'text': 'Repair the local fixture.'}],
                                       'source_status': 'verified', 'execution_observations': []}))
        process.stdin.close()
        # Closing the parent's descriptor releases its reference, as hook death would.
        lease.close()
        deadline = time.monotonic() + 10
        while not (root / 'provider-started').exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        checks['actual_runner_started_scripted_provider'] = (root / 'provider-started').exists()
        with (root / 'inference.lock').open('a') as competitor:
            try:
                fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                checks['runner_retains_lease_after_parent_closes_fd'] = False
            except BlockingIOError:
                checks['runner_retains_lease_after_parent_closes_fd'] = process.poll() is None
        (root / 'release').touch()
        checks['runner_exits_successfully'] = process.wait(timeout=15) == 0
    with (root / 'inference.lock').open('a') as competitor:
        fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        checks['lease_released_after_completion'] = True
    checks['actual_runner_returned_verdict'] = json.loads((root / 'stdout.json').read_text()).get('kind') == 'incomplete'
finally:
    if not lease.closed:
        lease.close()
    (root / 'release').touch()
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
result = {'passed': all(checks.values()), 'provider_calls': 0, 'checks': checks,
          'boundary': 'Actual Rust runner with scripted native transport; parent FD closure, not a live model trial.',
          'source_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (runner, Path(__file__), fake)}}
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'directory': str(root), **result}))
raise SystemExit(0 if result['passed'] else 1)
