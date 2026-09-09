#!/usr/bin/env python3
"""Exercise native registration transport and host budget with a scripted provider.

No model or network calls. Source/citation semantics are covered separately.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

app = Path(__file__).resolve().parents[1]
runner = app / 'target/debug/richos-run'
out = Path(tempfile.mkdtemp(prefix='richos-registration-protocol-'))
print(out, flush=True)
fake = out / 'native'
fake.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}}),flush=True)
 elif m.get('type')=='user':
  Path(os.environ['TEST_PROMPT']).write_text(json.dumps(m))
  print(json.dumps({'type':'result','subtype':'success','stop_reason':'end_turn','structured_output':{'result':json.loads(os.environ['TEST_VERDICT'])}}),flush=True)
''')
fake.chmod(0o700)
source = 'Repair the parser. Do not publish. Run the actual parser test.'
data = {'source_unavailable': False, 'messages': [{'source_id': 'u1', 'role': 'user',
        'provenance': 'native_human_typed_v1', 'text': source}]}
work = {'brief': 'Repair the parser. Do not publish. Run the actual parser test.',
        'citations': [{'source_id': 'u1', 'quote': 'Repair the parser.'}]}
cases = [('bounded', work, True), ('oversize', dict(work, brief='x' * 16384 + ' Do not publish.'), False),
         ('concise-repair', dict(work, brief='Fix parser; execute parser test. Do not publish.'), True)]
results = []
for name, entry, expected in cases:
    prompt = out / (name + '-prompt.json')
    verdict = {'work': [entry], 'pending': ['Publishing remains unapproved.']}
    env = dict(os.environ, RICHOS_CLAUDE_BIN=str(fake), TEST_PROMPT=str(prompt), TEST_VERDICT=json.dumps(verdict))
    run = subprocess.run([str(runner), 'register-native-work', str(out), '30'], input=json.dumps(data),
                         text=True, capture_output=True, env=env, timeout=60)
    row = {'name': name, 'exit': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr}
    try:
        assert (run.returncode == 0) == expected
        if expected: assert json.loads(run.stdout) == verdict
        else: assert 'host budget' in run.stderr
        sent = prompt.read_text()
        assert '16384 bytes' in sent and 'Never clip or omit prohibitions' in sent
        assert source in sent
        row['passed'] = True
    except (AssertionError, ValueError, OSError):
        row['passed'] = False
    results.append(row)
    (out / (name + '-result.json')).write_text(json.dumps(row, indent=2) + '\n')
    print(name, 'PASS' if row['passed'] else 'FAIL', flush=True)
identity = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [Path(__file__), runner, app / 'crates/richos-core/src/dispatch.rs']}
(out / 'result.json').write_text(json.dumps({'kind': 'scripted native protocol, not semantic model validation',
    'paid_calls': 0, 'source_sha256': identity, 'results': results}, indent=2) + '\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
