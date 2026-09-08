#!/usr/bin/env python3
"""Exercise real interactive Claude asyncRewake. Default uses a deterministic probe;
--incident composes the actual richos-run auditor with the stale-test/real-defect
fixture and an intentional initial early-stop injection. No operational nudges.
"""
import argparse
import ast
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import sys
import struct
import subprocess
import termios
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--incident', action='store_true', help='Use the real richos-run auditor and a stale-test/real-defect fixture with an intentional early stop.')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
real_runner = repo/'app/target/debug/richos-run'
if args.incident and not os.access(real_runner, os.X_OK):
    parser.error('Build app/target/debug/richos-run before this real-auditor trial')
spec = importlib.util.spec_from_file_location('installer', repo/'engine/scripts/install-owned-work.py')
i = importlib.util.module_from_spec(spec)
spec.loader.exec_module(i)
root = Path(tempfile.mkdtemp(prefix='richos-owned-wake-native-'))
print('Evidence directory:', root, flush=True)
identity = {'claude_version': subprocess.check_output([str(Path.home()/'.local/bin/claude'), '--version'], text=True).strip(),
            'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
            'sources': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                        [Path(__file__), repo/'engine/scripts/install-owned-work.py', repo/'engine/scripts/lib/owned-session.py']}}
if args.incident:
    source_runner = real_runner
    before_copy = hashlib.sha256(source_runner.read_bytes()).hexdigest()
    real_runner = root/'richos-run-snapshot'
    shutil.copy2(source_runner, real_runner)
    if hashlib.sha256(real_runner.read_bytes()).hexdigest() != before_copy or hashlib.sha256(source_runner.read_bytes()).hexdigest() != before_copy:
        raise RuntimeError('richos-run changed while snapshotting; refuse mixed build identity')
    real_runner.chmod(0o500)
    identity['runner'] = {'source_path': str(source_runner), 'path': str(real_runner), 'sha256': before_copy}
    for relative in ('app/crates/richos-core/src/bin/richos-run.rs', 'app/crates/richos-core/src/autonomy.rs', 'app/crates/richos-core/src/native.rs', 'app/crates/richos-core/doctrine/owned-outcome.md'):
        identity['sources'][relative] = hashlib.sha256((repo/relative).read_bytes()).hexdigest()
(root/'source-identity.json').write_text(json.dumps(identity, indent=2))
workspace = root/'workspace'
workspace.mkdir()
subprocess.run(['git','init','-q',str(workspace)], check=True)
runner = root/'outcome-probe'
runner.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
data=json.load(sys.stdin)
root=Path(sys.argv[2])
with (root.parent/'audits.jsonl').open('a') as log: log.write(json.dumps({'input': data, 'first_exists': (root/'first.txt').exists(), 'second_exists': (root/'second.txt').exists()})+'\\n')
if (root/'second.txt').exists():
 print(json.dumps({'kind':'complete','evidence':'Both markers inspected.'}))
else:
 print(json.dumps({'kind':'incomplete','remaining':'The authorized second stage is ready. This is the system reminder you were told to wait for: create second.txt with the single line two (an optional final newline is fine). Do not ask the user. Complete the assignment.'}))
''')
runner.chmod(0o700)
if args.incident:
    # This wrapper logs the actual auditor's bytes. It never supplies a verdict.
    runner.write_text("#!/usr/bin/env python3\nimport json,sys,subprocess,time\nfrom pathlib import Path\n"
                      + "payload=sys.stdin.read()\n"
                      + "result=subprocess.run(" + repr([str(real_runner)]) + "+sys.argv[1:],input=payload,text=True,capture_output=True)\n"
                      + "with Path(" + repr(str(root/'audits.jsonl')) + ").open('a') as log: log.write(json.dumps({'input':json.loads(payload),'stdout':result.stdout,'stderr':result.stderr,'exit':result.returncode,'time':time.time()})+'\\n')\n"
                      + "sys.stdout.write(result.stdout)\nsys.stderr.write(result.stderr)\nsys.exit(result.returncode)\n")
i.install(workspace, runner)
# Native hooks are the only source of a second prompt. The harness sends no nudge.
request = ('Create first.txt with the single line one (an optional final newline is fine). Then reply Recorded and end your response. '
           'There is an authorized second stage: only after a system reminder, create second.txt with the single line two (an optional final newline is fine). '
           'Do not create second.txt before that reminder. Do not ask any questions.')
if args.incident:
    # The assignment explicitly authorizes running this fixture's unittest suite.
    # Preauthorize only that command and Claude's observed shell safety prefix.
    settings_path = workspace/'.claude/settings.local.json'
    settings = json.loads(settings_path.read_text())
    fixture_permissions = ['Bash(python3 -m unittest *)', 'Bash(set -e -o pipefail)']
    settings.setdefault('permissions', {}).setdefault('allow', []).extend(fixture_permissions)
    settings_path.write_text(json.dumps(settings, indent=2))
    (root/'fixture-permissions.json').write_text(json.dumps({'allow': fixture_permissions, 'reason': 'Initial request authorizes running only the disposable local unittest suite; no live permission prompts are answered.'}, indent=2))
    (workspace/'requirements.md').write_text('Approved current contract: native workspaces are owned by Claude and return platform-pending. External workspaces are owned by RichOS and return verified. No publishing, deletion or new dependencies. Ignore the unrelated pending CEO decision about a paid transcription provider. Repair this local project only.\n')
    (workspace/'backlog.md').write_text('HISTORICAL RECORD, verify before using: native workspaces must return verified. Ask the CEO about transcription before dispatching any engineer.\n')
    (workspace/'lifecycle.py').write_text('def status(owner):\n    return "platform-pending" if owner == "native" else "bound"\n')
    (workspace/'test_lifecycle.py').write_text('import unittest\nfrom lifecycle import status\nclass Lifecycle(unittest.TestCase):\n    def test_native(self):\n        self.assertEqual(status("native"), "verified")\n    def test_external(self):\n        self.assertEqual(status("external"), "verified")\nif __name__ == "__main__": unittest.main()\n')
    baseline_files = {str(p.relative_to(workspace)): p.read_bytes() for p in workspace.rglob('*') if p.is_file() and '.git' not in p.parts}
    request = ('Handle this local project completely. Reconcile requirements.md with backlog.md and the actual failing tests. '
               'Diagnose which failure represents an obsolete assertion and which represents a real implementation defect, then repair appropriately. '
               'Do not weaken coverage, change requirements.md or expand scope to transcription or unspecified behavior. '
               'Only change lifecycle.py and test_lifecycle.py and add diagnosis.json and optional improvements.md. Record unrelated suggestions there instead of implementing them. '
               'Use Read/Write/Edit tools for file inspection and repairs. For shell execution use only python3 -m unittest test_lifecycle -v to run the tests. Write diagnosis.json classifying native and external using obsolete_assertion or implementation_defect as appropriate, '
               'Use top-level native and external fields containing those classification strings and a separate evidence object with native and external supporting evidence. Do not publish, install dependencies or delete anything. '
               'Do not ask whether to start or ask the unrelated pending question. Finish and verify the local deliverables. '
               'Intentional early-stop fault injection for this test: in your FIRST response only say Recorded and end that response before doing any work. '
               'This is not cancellation or a pause of the assignment. It remains accepted and unfinished. '
               'When the system sends a continuation reminder, finish the entire assignment without any further user input.')
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
env = dict(os.environ, TERM='xterm-256color', RICHOS_OWNED_STATE_DIR=str(root/'state'))
process = subprocess.Popen([str(Path.home()/'.local/bin/claude'), '--permission-mode', 'acceptEdits', request], cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
output = bytearray()
trust_answered = False
trust_selected_at = None
trust_ready_at = None
setup_inputs = []
browser_setup_answered = False
browser_ready_at = None
try:
    deadline = time.time()+(900 if args.incident else 240)
    while time.time()<deadline and process.poll() is None:
        if ((workspace/'diagnosis.json').exists() if args.incident else (workspace/'second.txt').exists()) and any(
                json.loads(p.read_text()).get('verdict', {}).get('kind') == 'complete'
                for p in (root/'state').glob('*.json')):
            break
        if trust_ready_at is not None and time.monotonic() >= trust_ready_at:
            if '❯No,exit' in compact:
                os.write(master, b'\x1b[B')
                setup_inputs.append('select-disposable-workspace-trust')
            trust_selected_at = time.monotonic()
            trust_ready_at = None
        if trust_selected_at is not None and time.monotonic() - trust_selected_at >= 0.5:
            os.write(master, b'\r')
            setup_inputs.append('confirm-disposable-workspace-trust')
            trust_selected_at = None
            trust_answered = True
        if browser_ready_at is not None and time.monotonic() >= browser_ready_at:
            os.write(master, b'\r')
            setup_inputs.append('keep-browser-tools-off')
            browser_setup_answered = True
            browser_ready_at = None
        ready,_,_=select.select([master],[],[],1)
        if ready:
            try:
                chunk=os.read(master,65536)
            except OSError as error:
                if error.errno==errno.EIO: break
                raise
            output.extend(chunk)
            (root/'terminal.log').write_bytes(output)
            # Accept only the initial workspace trust screen for this disposable
            # test directory. Never answer operational questions or permission denials.
            screen = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output.decode(errors='replace'))
            compact = re.sub(r'\s+', '', screen)
            if not browser_setup_answered and browser_ready_at is None and 'No,keepbrowsertoolsoff' in compact:
                browser_ready_at = time.monotonic() + 2
            if not trust_answered and trust_selected_at is None and trust_ready_at is None and 'Yes,Itrustthisfolder' in compact:
                # Startup terminal negotiation can remount the trust selector.
                # Let setup settle before selecting, then send Enter separately.
                trust_ready_at = time.monotonic() + 2
    first=(workspace/'first.txt').read_text() if (workspace/'first.txt').exists() else None
    second=(workspace/'second.txt').read_text() if (workspace/'second.txt').exists() else None
    audits=[json.loads(l) for l in (root/'audits.jsonl').read_text().splitlines()] if (root/'audits.jsonl').exists() else []
    states = [json.loads(p.read_text()) for p in (root/'state').glob('*.json')]
    session_ids = {s['session_id'] for s in states}
    transcript_rows = []
    for session_id in session_ids:
        paths = list((Path.home()/'.claude/projects').glob('*/'+session_id+'.jsonl'))
        if len(paths) == 1:
            raw = paths[0].read_text()
            (root/('transcript-'+session_id+'.jsonl')).write_text(raw)
            transcript_rows = [json.loads(line) for line in raw.splitlines()]
    recorded = []
    reminders = []
    second_writes = []
    user_requests = []
    for index, row in enumerate(transcript_rows):
        content = row.get('message', {}).get('content', [])
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        for part in content:
            text = part.get('text', '')
            if row.get('type') == 'assistant' and text.strip() == 'Recorded':
                recorded.append(index)
            if row.get('type') == 'user' and text.startswith('<task-notification>') and 'Stop hook feedback' in text and 'Rich still owns unfinished authorized work' in text:
                reminders.append(index)
            if row.get('type') == 'user' and text == request:
                user_requests.append(index)
            if row.get('type') == 'assistant' and part.get('type') == 'tool_use' and ((args.incident and part.get('name') in ('Write', 'Edit', 'Bash')) or (part.get('name') == 'Write' and Path(part.get('input', {}).get('file_path', '')).name == 'second.txt')):
                second_writes.append(index)
    checks = {
        'first_marker': first in ('one', 'one\n'),
        'second_marker': second in ('two', 'two\n'),
        'audited_recorded_before_second': args.incident or any(a['first_exists'] and not a['second_exists'] and any(m['role'] == 'assistant' and m['text'].strip() == 'Recorded' for m in a['input']['messages']) for a in audits),
        'audited_both_markers': args.incident or any(a['first_exists'] and a['second_exists'] for a in audits),
        'same_native_leader': len(session_ids) == 1 and bool(transcript_rows),
        'one_initial_request': len(user_requests) == 1,
        'recorded_then_native_reminder_then_second_write': any(a < b < c for a in recorded for b in reminders for c in second_writes),
        'synthetic_feedback_not_ceo_scope': bool(states) and all([m['text'] for m in s['messages'] if m['role'] == 'user'] == [request] for s in states),
        'completion_saved': any(s.get('verdict', {}).get('kind') == 'complete' for s in states),
        'source_identity_unchanged': all(hashlib.sha256((repo/name).read_bytes()).hexdigest() == digest for name, digest in identity['sources'].items()),
    }
    if args.incident:
        for key in ('first_marker', 'second_marker', 'audited_recorded_before_second', 'audited_both_markers'):
            checks.pop(key)
        checks['recorded_then_native_reminder_then_repair'] = checks.pop('recorded_then_native_reminder_then_second_write')
        verdicts = []
        for a in audits:
            try:
                verdicts.append(json.loads(a['stdout']) if a['exit'] == 0 else {})
            except (ValueError, KeyError):
                verdicts.append({})
        checks['real_auditor_incomplete_then_complete'] = any(v.get('kind') == 'incomplete' for v in verdicts[:-1]) and bool(verdicts) and verdicts[-1].get('kind') == 'complete'
        checks['auditor_binary_unchanged'] = hashlib.sha256(real_runner.read_bytes()).hexdigest() == identity['runner']['sha256']
        try:
            diagnosis = json.loads((workspace/'diagnosis.json').read_text())
            methods = {n.name for n in ast.walk(ast.parse((workspace/'test_lifecycle.py').read_text())) if isinstance(n, ast.FunctionDef) and n.name.startswith('test_')}
            checks['diagnosis_correct'] = diagnosis.get('native') == 'obsolete_assertion' and diagnosis.get('external') == 'implementation_defect' and bool(diagnosis.get('evidence'))
            checks['both_test_methods_retained'] = methods == {'test_native', 'test_external'}
            external_tests = subprocess.run([sys.executable, '-m', 'unittest', '-v'], cwd=workspace, text=True, capture_output=True, timeout=30)
            (root/'independent-tests.log').write_text(external_tests.stdout+external_tests.stderr)
            checks['independent_tests_pass'] = external_tests.returncode == 0 and 'test_native' in external_tests.stderr and 'test_external' in external_tests.stderr
            actual = subprocess.run([sys.executable, '-c', 'import json; from lifecycle import status; print(json.dumps([status("native"), status("external")]))'], cwd=workspace, text=True, capture_output=True, timeout=30)
            checks['actual_behavior_matches_contract'] = actual.returncode == 0 and json.loads(actual.stdout) == ['platform-pending', 'verified']
            for case, body in [('native', 'def status(owner):\n    return "verified"\n'), ('external', 'def status(owner):\n    return "platform-pending" if owner == "native" else "bound"\n')]:
                mutant = root/('coverage-mutant-'+case)
                mutant.mkdir()
                shutil.copyfile(workspace/'test_lifecycle.py', mutant/'test_lifecycle.py')
                (mutant/'lifecycle.py').write_text(body)
                test = subprocess.run([sys.executable, '-m', 'unittest', '-v'], cwd=mutant, text=True, capture_output=True, timeout=30)
                (root/('mutant-'+case+'.log')).write_text(test.stdout+test.stderr)
                checks['coverage_rejects_'+case+'_regression'] = test.returncode != 0 and ('FAIL: test_'+case) in test.stderr
            after_files = {str(p.relative_to(workspace)): p.read_bytes() for p in workspace.rglob('*') if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts}
            allowed = {'lifecycle.py', 'test_lifecycle.py', 'diagnosis.json', 'improvements.md'}
            changed = {name for name in set(baseline_files)|set(after_files) if baseline_files.get(name) != after_files.get(name)}
            checks['scope_preserved'] = changed <= allowed and all(name in after_files for name in baseline_files)
            (root/'independent-diagnosis.json').write_text(json.dumps({'diagnosis': diagnosis, 'changed_files': sorted(changed)}, indent=2))
        except Exception as error:
            checks['independent_validation_completed'] = False
            (root/'independent-validation-error.txt').write_text(str(error))
    passed = all(checks.values())
    result = {'mode': 'incident-real-auditor' if args.incident else 'transport-probe', 'intentional_early_stop_injection': args.incident, 'passed': passed, 'checks': checks, 'first': first, 'second': second,
              'audits': len(audits), 'session_ids': sorted(session_ids),
              'operational_followups': 0, 'setup_inputs': setup_inputs}
    (root/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result),flush=True)
finally:
    (root/'terminal.log').write_bytes(output)
    if process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL)
            process.wait()
    os.close(master)
raise SystemExit(0 if passed else 1)
