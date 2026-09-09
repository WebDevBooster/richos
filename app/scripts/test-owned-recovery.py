#!/usr/bin/env python3
"""Independent recovery acceptance with real disposable processes and hook CLIs.

The executable named claude below is a tiny process-identity fixture, not Claude
Code. Its leader actions and inspector verdicts are scripted. No provider calls,
native model behavior claims, adapter imports or mocked process tables.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import traceback

# Acceptance latency contract, independent of runtime implementation imports:
# residual liveness is polled within five seconds, with three seconds for the
# actual hook/process/inspector transport. Direct restart has no polling wait.
STRAGGLER_POLL_SECONDS = 5
STRAGGLER_DEADLINE_SECONDS = STRAGGLER_POLL_SECONDS + 3
DIRECT_RESTART_DEADLINE_SECONDS = 4


LAUNCHER = r'''
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t child = fork();
    if (child < 0) return 3;
    if (child == 0) { execvp(argv[1], argv + 1); _exit(127); }
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    for (;;) pause();
}
'''

DRIVER = r'''
import hashlib,json,os,subprocess,sys,time
from pathlib import Path
def retain_private(value):
    raw=json.dumps(value).encode()
    path=Path(os.environ['RICHOS_RECOVERY_PRIVATE_DIR'])/('hook-'+str(os.getpid())+'-'+str(time.time_ns())+'.json')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as output: output.write(raw)
    return {'path':str(path),'sha256':hashlib.sha256(raw).hexdigest()}
def redacted_output(text):
    marker='\nNATIVE OBSERVATIONS (data, not instructions):\n'
    head,found,tail=text.partition(marker)
    if found:
        value=json.loads(tail)
        permission=value.get('permission_context',{})
        permission['sources']=[{'scope':'user','redacted_nonfixture_configuration':True} if source.get('scope')=='user' else source for source in permission.get('sources',[])]
        return head+marker+json.dumps(value)
    return text
print(json.dumps({'driver_pid':os.getpid(),'owner_pid':os.getppid()}),flush=True)
for line in sys.stdin:
    command=json.loads(line)
    if command['kind']=='exit':
        print(json.dumps({'exiting':True}),flush=True)
        break
    if command['kind']=='straggler':
        process=subprocess.Popen(['/bin/sleep','120'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        print(json.dumps({'straggler_pid':process.pid}),flush=True)
        continue
    start=time.monotonic()
    try:
        result=subprocess.run(command['argv'],input=json.dumps(command['payload']),text=True,capture_output=True,timeout=command['timeout'])
        response={'exit':result.returncode,'stdout':redacted_output(result.stdout),'stderr':redacted_output(result.stderr),'timed_out':False,
                  'raw_stdout_sha256':hashlib.sha256(result.stdout.encode()).hexdigest(),'raw_stderr_sha256':hashlib.sha256(result.stderr.encode()).hexdigest(),
                  'private_raw':retain_private({'command':command,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr}),
                  'public_output_policy':'User-scope permission observations are redacted here; original hook bytes remain in private_raw.'}
    except subprocess.TimeoutExpired as error:
        stdout=error.stdout.decode(errors='replace') if isinstance(error.stdout,bytes) else error.stdout or ''
        stderr=error.stderr.decode(errors='replace') if isinstance(error.stderr,bytes) else error.stderr or ''
        response={'exit':None,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':True,
                  'private_raw':retain_private({'command':command,'timed_out':True,'stdout':stdout,'stderr':stderr}),
                  'public_output_policy':'User-scope permission observations are redacted here; original hook bytes remain in private_raw.'}
    response['elapsed']=time.monotonic()-start
    print(json.dumps(response),flush=True)
'''

INSPECTOR = r'''#!/usr/bin/env python3
import hashlib,json,os,sys,time
from pathlib import Path
raw=sys.stdin.buffer.read()
path=Path(os.environ['RICHOS_RECOVERY_PRIVATE_DIR'])/('inspector-'+str(time.time_ns())+'.json')
fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'wb') as output: output.write(raw)
payload=json.loads(raw)
root=Path(sys.argv[2])
permission=payload.get('permission_context',{})
permission['sources']=[{'scope':'user','redacted_nonfixture_configuration':True} if source.get('scope')=='user' else source for source in permission.get('sources',[])]
with (root.parent/'inspector.jsonl').open('a') as log:
    log.write(json.dumps({'argv':sys.argv[1:],'payload':payload,'at':time.time(),
        'public_payload_policy':'User-scope permission observations redacted; original input retained privately.',
        'private_raw':{'path':str(path),'sha256':hashlib.sha256(raw).hexdigest()}})+'\n')
if sys.argv[1]!='audit-session':
    raise SystemExit('Unexpected inspector operation')
print(json.dumps({'kind':'incomplete','remaining':'Scripted inspection: original local repair remains unfinished. Continue within its retained constraints.'}))
'''


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,ppid=,pgid=,lstart=,comm='],
                            text=True, capture_output=True, env={**os.environ, 'TZ': 'UTC'})
    fields = result.stdout.strip().split(None, 8)
    if len(fields) != 9:
        return None
    return {'pid': int(fields[0]), 'ppid': int(fields[1]), 'pgid': int(fields[2]),
            'started': ' '.join(fields[3:8]), 'command': fields[8]}


def wait_absent(pid, seconds=3):
    deadline = time.monotonic() + seconds
    while process_identity(pid) is not None and time.monotonic() < deadline:
        time.sleep(0.05)
    return process_identity(pid) is None


def owned_group_members(pgids):
    result = subprocess.run(['ps', '-axo', 'pid=,pgid=,comm='], text=True, capture_output=True, check=True)
    members = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and int(fields[1]) in pgids:
            members.append({'pid': int(fields[0]), 'pgid': int(fields[1]), 'command': fields[2]})
    return members


class ScriptedOwner:
    def __init__(self, case, binary, driver, adapter, session, transcript, env):
        self.case, self.adapter, self.session, self.transcript = case, adapter, session, transcript
        self.process = subprocess.Popen([str(binary), sys.executable, str(driver)], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.ready = self.read(5)
            self.identity = process_identity(self.process.pid)
            assert self.ready['owner_pid'] == self.process.pid and self.identity['pgid'] == self.process.pid
            assert Path(self.identity['command']).name == 'claude', self.identity
        except Exception:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=3)
            raise
        self.driver_exited = False
        self.record({'kind': 'owner-start', 'session': session, 'identity': self.identity, 'argv': self.process.args,
                     'driver': self.ready, 'assignment_sent_to_replacement': False})

    def record(self, event):
        with (self.case/'events.jsonl').open('a') as log:
            log.write(json.dumps({'at': time.time(), **event}) + '\n')

    def read(self, timeout):
        if not select.select([self.process.stdout], [], [], timeout)[0]:
            raise TimeoutError('Scripted owner protocol did not respond')
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Scripted owner exited without protocol response')
        return json.loads(line)

    def command(self, command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()
        response = self.read(command.get('timeout', 1) + 5)
        self.record({'kind': 'scripted-driver-command', 'session': self.session, 'command': command, 'response': response})
        return response

    def hook(self, mode, event, timeout=4):
        payload = {'session_id': self.session, 'transcript_path': str(self.transcript),
                   'cwd': str(self.case/'workspace'), 'hook_event_name': event}
        return self.command({'kind': 'hook', 'argv': [sys.executable, str(self.adapter), mode],
                             'payload': payload, 'timeout': timeout})

    def retire_driver(self):
        if not self.driver_exited:
            assert self.command({'kind': 'exit'})['exiting']
            self.driver_exited = True
            assert wait_absent(self.ready['driver_pid'])

    def stop_owner(self):
        self.retire_driver()
        observed = process_identity(self.process.pid)
        assert observed == self.identity, (observed, self.identity)
        os.kill(self.process.pid, signal.SIGTERM)
        self.process.wait(timeout=3)
        assert process_identity(self.process.pid) is None
        self.record({'kind': 'owned-leader-stopped', 'identity': self.identity, 'signal': 'SIGTERM'})

    def close(self):
        if self.process.poll() is None:
            try:
                self.stop_owner()
            except Exception as error:
                current = process_identity(self.process.pid)
                if current and all(current[k] == self.identity[k] for k in ('pid', 'pgid', 'started', 'command')):
                    os.killpg(self.process.pid, signal.SIGTERM)
                    self.process.wait(timeout=3)
                self.record({'kind': 'fixture-cleanup-after-protocol-error', 'error': str(error)})
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def saved_state(case, session):
    matching = [(p, json.loads(p.read_text())) for p in (case/'state').glob('*.json')]
    matching = [(p, state) for p, state in matching if state.get('session_id') == session and 'source_ids' in state]
    assert len(matching) == 1, (session, matching)
    return matching[0]


def ownership(case):
    paths = list((case/'state').glob('*.ownership.json'))
    assert len(paths) == 1
    return json.loads(paths[0].read_text())


def run_case(out, name, binary, driver, adapter, runner, kind):
    case = out/name
    (case/'workspace/.claude').mkdir(parents=True)
    (case/'state').mkdir()
    (case/'private').mkdir(mode=0o700)
    workspace = (case/'workspace').resolve()
    write_json(workspace/'.claude/owned-work.json', {'version': 1, 'enabled': True,
        'decision_policy': 'dependency', 'permission_policy': 'native', 'runner': str(runner)})
    original = 'Repair the local parser and verify its tests. Do not publish or install dependencies.'
    transcript = case/'old-transcript.jsonl'
    transcript.write_text(json.dumps({'uuid': 'original-human-source', 'type': 'user', 'origin': {'kind': 'human'},
        'promptSource': 'typed', 'promptId': 'original-human-prompt', 'message': {'content': original}}) + '\n')
    original_hash = hashlib.sha256(transcript.read_bytes()).hexdigest()
    env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE') and k != 'RICHOS_OWNED_WORK_HOST'}
    env.update(RICHOS_OWNED_STATE_DIR=str(case/'state'), CLAUDE_PROJECT_DIR=str(workspace), CLAUDE_CONFIG_DIR=str(case/'native-config'), RICHOS_RECOVERY_PRIVATE_DIR=str(case/'private'))
    owners, checks, straggler = [], {}, None
    report = {'case': name, 'kind': kind, 'provider_calls': 0, 'checks': checks}
    try:
        old = ScriptedOwner(case, binary, driver, adapter, 'old', transcript, env); owners.append(old)
        captured = old.hook('capture', 'SessionStart')
        assert captured['exit'] == 0 and not captured['timed_out'], captured
        path, state = saved_state(case, 'old')
        assert state['ownership']['process']['pid'] == old.process.pid
        # Persisted initial condition from review F1. Runtime code and clocks are
        # untouched; the actual replacement hook must bypass this real deadline.
        state.update(audit_attempts=5, retry_at=time.time() + 3000, failures=2,
                     verdict={'kind': 'incomplete', 'remaining': 'Original fixture work remains unfinished.'})
        write_json(path, state)
        write_json(case/'exhausted-original-state.json', state)
        if kind == 'straggler':
            pid = old.command({'kind': 'straggler'})['straggler_pid']
            straggler = process_identity(pid)
            assert straggler and straggler['pgid'] == old.process.pid and Path(straggler['command']).name == 'sleep'
        old.stop_owner()
        checks['real_old_owner_dead'] = process_identity(old.process.pid) is None
        session = 'old' if kind == 'resume' else 'replacement'
        replacement_transcript = transcript if kind == 'resume' else case/'replacement-transcript.jsonl'
        if kind != 'resume':
            replacement_transcript.write_text('')
        replacement = ScriptedOwner(case, binary, driver, adapter, session, replacement_transcript, env); owners.append(replacement)
        captured = replacement.hook('capture', 'SessionStart')
        assert captured['exit'] == 0 and not captured['timed_out'], captured
        if kind == 'straggler':
            _, blocked = saved_state(case, session)
            write_json(case/'withheld-state.json', blocked)
            withheld = [item for item in blocked.get('withheld_recoveries', []) if item.get('session') == 'old']
            checks['live_straggler_prevents_transfer'] = ownership(case)['sessions']['old']['owner'] == 'old' and not blocked['messages']
            checks['withheld_state_records_exact_live_process'] = len(withheld) == 1 and withheld[0]['reason'] == 'residual_process_group' and any(p['pid'] == straggler['pid'] and p['pgid'] == straggler['pgid'] for p in withheld[0]['live_processes'])
            output = json.loads(captured['stdout'])
            checks['withheld_notice_visible_on_both_channels'] = all(str(straggler['pid']) in text and str(straggler['pgid']) in text and 'old' in text
                for text in [output.get('systemMessage', ''), output.get('hookSpecificOutput', {}).get('additionalContext', '')])
            wake = replacement.hook('audit', 'SessionStart')
            checks['empty_replacement_gets_host_only_wake'] = wake['exit'] == 2 and str(straggler['pid']) in wake['stderr'] and not rows(case/'inspector.jsonl')
            repeated_start = replacement.hook('capture', 'SessionStart')
            assert repeated_start['exit'] == 0
            _, before_wait = saved_state(case, session)
            with ThreadPoolExecutor(max_workers=1) as executor:
                waiting = executor.submit(replacement.hook, 'audit', 'Stop', STRAGGLER_DEADLINE_SECONDS)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    _, watching = saved_state(case, session)
                    if watching['revision'] > before_wait['revision'] or waiting.done():
                        break
                    time.sleep(0.05)
                checks['unchanged_blocker_does_not_repeat_wake'] = not waiting.done() and not rows(case/'inspector.jsonl')
                checks['outstanding_hook_waits_without_transfer'] = watching['revision'] > before_wait['revision'] and ownership(case)['sessions']['old']['owner'] == 'old' and not watching['messages']
                assert checks['unchanged_blocker_does_not_repeat_wake'] and checks['outstanding_hook_waits_without_transfer']
                observed = process_identity(straggler['pid'])
                checks['scripted_recovery_uses_exact_live_identity'] = bool(observed and all(observed[k] == straggler[k] for k in ('pid', 'pgid', 'started', 'command')) and observed['pgid'] == old.process.pid)
                assert checks['scripted_recovery_uses_exact_live_identity']
                # Deliberately scripted operator action, never an adapter/model
                # kill. The already outstanding hook must notice disappearance.
                os.kill(straggler['pid'], signal.SIGTERM)
                assert wait_absent(straggler['pid'])
                replacement.record({'kind': 'scripted-operator-reaped-only-fixture-straggler', 'verified_identity': observed, 'signal': 'SIGTERM'})
                straggler = None
                audited = waiting.result(timeout=10)
            checks['same_outstanding_stop_hook_picks_up_after_exit'] = not audited['timed_out'] and audited['exit'] == 2
        else:
            audited = replacement.hook('audit', 'SessionStart')
        deadline = STRAGGLER_DEADLINE_SECONDS if kind == 'straggler' else DIRECT_RESTART_DEADLINE_SECONDS
        report['reconciliation_timing'] = {'elapsed_seconds': audited['elapsed'], 'deadline_seconds': deadline,
                                          'straggler_poll_contract_seconds': STRAGGLER_POLL_SECONDS if kind == 'straggler' else None}
        checks['one_immediate_reconciliation_without_hour_sleep'] = audited['exit'] == 2 and not audited['timed_out'] and audited['elapsed'] < deadline and len(rows(case/'inspector.jsonl')) == 1
        path, reconciled = saved_state(case, session)
        write_json(case/'reconciled-state.json', reconciled)
        claims = reconciled.get('recovery_checkpoints', [])
        checks['transfer_credit_durably_claimed_once'] = len(claims) == 1 and bool(claims[0].get('claimed_at'))
        checks['same_replacement_owns_assignment'] = reconciled['ownership']['process']['pid'] == replacement.process.pid and ownership(case)['sessions']['old']['owner'] == session
        checks['inspection_budget_not_refilled'] = reconciled['audit_attempts'] == 6 and reconciled['retry_at'] > time.time() + 2500
        checks['reconciliation_gate_cleared'] = not reconciled.get('recovery_requires_review')
        sources = [m for m in reconciled['messages'] if m.get('role') == 'user']
        checks['original_source_and_constraints_retained'] = len(sources) == 1 and sources[0]['text'] == original and sources[0]['source_id'] == 'original-human-source' and sources[0]['provenance'] == 'native_human_typed_v1'
        for event in ('SessionStart', 'Stop'):
            replacement.hook('capture', event)
            replacement.hook('audit', event, timeout=0.6)
        _, repeated = saved_state(case, session)
        write_json(case/'repeated-hooks-state.json', repeated)
        checks['repeated_start_stop_cannot_buy_inspection_credit'] = len(rows(case/'inspector.jsonl')) == 1 and repeated['audit_attempts'] == 6 and repeated.get('recovery_checkpoints') == claims
        hook_payloads = [e['command']['payload'] for e in rows(case/'events.jsonl') if e.get('kind') == 'scripted-driver-command' and e['command']['kind'] == 'hook']
        checks['no_human_assignment_resent'] = all('prompt' not in p and p['hook_event_name'] != 'UserPromptSubmit' for p in hook_payloads) and hashlib.sha256(transcript.read_bytes()).hexdigest() == original_hash
        checks['replacement_transcript_has_no_synthetic_assignment'] = kind == 'resume' or replacement_transcript.read_text() == ''
        report['passed'] = all(checks.values())
    except Exception:
        report.update(passed=False, error=traceback.format_exc())
    finally:
        cleanup_pids = [pid for owner in owners for pid in (owner.process.pid, owner.ready['driver_pid'])]
        if straggler:
            cleanup_pids.append(straggler['pid'])
        if straggler:
            current = process_identity(straggler['pid'])
            if current and all(current[k] == straggler[k] for k in ('pid', 'pgid', 'started', 'command')):
                os.kill(straggler['pid'], signal.SIGTERM)
                wait_absent(straggler['pid'])
        for owner in reversed(owners):
            owner.close()
        remaining = owned_group_members({owner.process.pid for owner in owners})
        write_json(case/'cleanup.json', {'owned_pids': cleanup_pids, 'remaining_group_members': remaining})
        checks['no_owned_fixture_processes_remain'] = all(process_identity(pid) is None for pid in cleanup_pids) and not remaining
        if not checks['no_owned_fixture_processes_remain']:
            report['passed'] = False
        checks['private_raw_evidence_has_restricted_permissions'] = (case/'private').stat().st_mode & 0o777 == 0o700 and all(p.stat().st_mode & 0o777 == 0o600 for p in (case/'private').iterdir())
        if not checks['private_raw_evidence_has_restricted_permissions']:
            report['passed'] = False
        write_json(case/'result.json', report)
    print(name, 'PASS' if report['passed'] else 'FAIL', json.dumps(report), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New evidence directory; default creates and retains a disposable directory.')
    args = parser.parse_args()
    out = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='richos-owned-recovery-')).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if list(out.iterdir()):
        parser.error('Evidence directory must be empty; previous results are never overwritten')
    repo = Path(__file__).resolve().parents[2]
    adapter = repo/'engine/scripts/lib/owned-session.py'
    sources = [Path(__file__), adapter]
    identity = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (out/'tested-harness.py').write_bytes(Path(__file__).read_bytes())
    (out/'tested-adapter.py').write_bytes(adapter.read_bytes())
    snapshots_match = (hashlib.sha256((out/'tested-harness.py').read_bytes()).hexdigest() == identity[str(Path(__file__))] and
                       hashlib.sha256((out/'tested-adapter.py').read_bytes()).hexdigest() == identity[str(adapter)])
    if not snapshots_match:
        raise SystemExit('Source changed while snapshotting; no acceptance tests ran')
    print('Evidence directory:', out, flush=True)
    launcher, binary, driver, runner = out/'owner.c', out/'claude', out/'scripted-owner.py', out/'fake-inspector'
    launcher.write_text(LAUNCHER); driver.write_text(DRIVER); runner.write_text(INSPECTOR); runner.chmod(0o700)
    compile_result = subprocess.run(['cc', '-O0', '-o', str(binary), str(launcher)], text=True, capture_output=True)
    write_json(out/'compiler.json', {'exit': compile_result.returncode, 'stdout': compile_result.stdout, 'stderr': compile_result.stderr})
    if compile_result.returncode:
        raise SystemExit('Cannot build disposable process identity fixture; no acceptance tests ran')
    results = [run_case(out, name, binary, driver, adapter, runner, kind) for name, kind in
               [('fresh-exhausted-budget', 'fresh'), ('resume-exhausted-budget', 'resume'), ('live-straggler-recovery', 'straggler')]]
    unchanged = identity == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    result = {'passed': all(r['passed'] for r in results) and unchanged, 'provider_calls': 0,
              'boundary': 'Actual OS processes and shipped hook CLI; scripted leader/operator and fake inspector. This does not prove live model autonomous recovery.',
              'source_sha256': identity, 'source_unchanged': unchanged, 'cases': results}
    write_json(out/'result.json', result)
    print('PASS' if result['passed'] else 'FAIL', 'actual-process recovery acceptance; no provider calls', flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
