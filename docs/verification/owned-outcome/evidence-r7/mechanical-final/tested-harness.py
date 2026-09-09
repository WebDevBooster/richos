#!/usr/bin/env python3
"""Independent recovery acceptance with real disposable processes and hook CLIs.

The executable named claude below is a tiny process-identity fixture, not Claude
Code. Its leader actions and inspector verdicts are scripted. No provider calls,
native model behavior claims, adapter imports or mocked process tables.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
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
def run_hook(command):
    start=time.monotonic()
    process=subprocess.Popen(command['argv'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    provenance={'hook_pid':process.pid,'hook_pgid':os.getpgid(process.pid),'supervisor_pid':os.getpid(),
                'supervisor_pgid':os.getpgrp(),'caller_owner_pid':command['caller_owner_pid'],'caller_driver_pid':command['caller_driver_pid']}
    ready=Path(command['ready_path']); temporary=ready.with_suffix('.tmp'); temporary.write_text(json.dumps(provenance)); temporary.replace(ready)
    try:
        stdout,stderr=process.communicate(json.dumps(command['payload']),timeout=command['timeout'])
        response={'exit':process.returncode,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':False}
    except subprocess.TimeoutExpired:
        process.kill()
        stdout,stderr=process.communicate()
        response={'exit':None,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':True}
    response.update(provenance=provenance,elapsed=time.monotonic()-start,
        raw_stdout_sha256=hashlib.sha256(stdout.encode()).hexdigest(),raw_stderr_sha256=hashlib.sha256(stderr.encode()).hexdigest(),
        private_raw=retain_private({'command':command,'stdout':stdout,'stderr':stderr,'exit':response['exit']}),
        public_output_policy='User-scope permission observations redacted; original hook bytes retained privately.')
    result=Path(command['result_path']); temporary=result.with_suffix('.tmp'); temporary.write_text(json.dumps(response)); temporary.replace(result)
if len(sys.argv)>1 and sys.argv[1]=='--hook':
    run_hook(json.loads(sys.argv[2]))
    raise SystemExit(0)
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
    command.update(caller_owner_pid=os.getppid(),caller_driver_pid=os.getpid())
    process=subprocess.Popen([sys.executable,__file__,'--hook',json.dumps(command)],stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    deadline=time.monotonic()+3
    while not Path(command['ready_path']).exists() and time.monotonic()<deadline: time.sleep(.01)
    provenance=json.loads(Path(command['ready_path']).read_text())
    if command['kind']=='detach':
        print(json.dumps({'detached':True,'provenance':provenance,'result_path':command['result_path']}),flush=True)
    else:
        process.wait(timeout=command['timeout']+3)
        print(Path(command['result_path']).read_text(),flush=True)

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
    log.write(json.dumps({'argv':sys.argv[1:],'payload':payload,'at':time.time(),'inspector_pid':os.getpid(),'hook_pid':os.getppid(),'pgid':os.getpgrp(),
        'public_payload_policy':'User-scope permission observations redacted; original input retained privately.',
        'private_raw':{'path':str(path),'sha256':hashlib.sha256(raw).hexdigest()}})+'\n')
invocation=len((root.parent/'inspector.jsonl').read_text().splitlines())
while (root.parent/'hold-inspector').exists() or (root.parent/('hold-inspector-'+str(invocation))).exists(): time.sleep(.05)
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
        self.hooks = []
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
        if 'provenance' in response:
            self.hooks.append(response['provenance'])
        return response

    def hook(self, mode, event, timeout=4, detached=False):
        payload = {'session_id': self.session, 'transcript_path': str(self.transcript),
                   'cwd': str(self.case/'workspace'), 'hook_event_name': event}
        receipt = self.case/('hook-' + str(time.time_ns()))
        return self.command({'kind': 'detach' if detached else 'hook', 'argv': [sys.executable, str(self.adapter), mode],
                             'payload': payload, 'timeout': timeout, 'ready_path': str(receipt)+'.ready.json', 'result_path': str(receipt)+'.result.json'})

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
        for hook in self.hooks:
            members = owned_group_members({hook['hook_pgid']})
            if members:
                # Every group was created by this fixture and recorded before use.
                os.killpg(hook['hook_pgid'], signal.SIGCONT)
                os.killpg(hook['hook_pgid'], signal.SIGTERM)
                for member in members:
                    wait_absent(member['pid'])
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise TimeoutError('Fixture condition did not become true within acceptance deadline')


def await_hook(hook, timeout=12):
    path = Path(hook['result_path'])
    wait_until(path.exists, timeout)
    return json.loads(path.read_text())


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
        orphan = None
        if kind.startswith('orphan-'):
            orphan = old.hook('audit', 'Stop', timeout=30, detached=True)
            hook_pid = orphan['provenance']['hook_pid']
            lock_path = path.with_suffix('.audit-lock')
            def held():
                with lock_path.open('a') as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return False
                    except BlockingIOError:
                        return True
            wait_until(held)
            checks['old_hook_detached_and_sleeping_under_lock'] = orphan['provenance']['hook_pgid'] != old.process.pid and not rows(case/'inspector.jsonl')
            # Deterministic scheduling barrier only. No runtime clock or process table is mocked.
            barrier_deadline = time.monotonic() + 3
            while True:
                os.kill(hook_pid, signal.SIGSTOP)
                wait_until(lambda: 'T' in subprocess.run(['ps', '-p', str(hook_pid), '-o', 'stat='], text=True, capture_output=True).stdout)
                free = True
                for other in (case/'state').glob('*.lock'):
                    with other.open('a') as lock:
                        try:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            free = False
                if free:
                    break
                os.kill(hook_pid, signal.SIGCONT)
                if time.monotonic() >= barrier_deadline:
                    raise TimeoutError('Could not isolate sleeping audit from source-capture locks')
                time.sleep(.1)
            checks['barrier_holds_only_old_audit_lock'] = held()
            old.record({'kind':'fixture-scheduling-barrier','hook_pid':hook_pid,'signal':'SIGSTOP'})
        old.stop_owner()
        if orphan:
            checks['pid_only_death_leaves_old_audit_alive'] = process_identity(hook_pid) is not None and held()

        checks['real_old_owner_dead'] = process_identity(old.process.pid) is None
        session = 'old' if kind in ('resume', 'orphan-resume') else 'replacement'
        replacement_transcript = transcript if kind in ('resume', 'orphan-resume') else case/'replacement-transcript.jsonl'
        if kind not in ('resume', 'orphan-resume'):
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
        elif orphan:
            pending = replacement.hook('audit', 'SessionStart', timeout=10, detached=True)
            time.sleep(.25)
            if kind == 'orphan-resume':
                checks['replacement_waits_for_held_audit_lock'] = not Path(pending['result_path']).exists()
            os.kill(hook_pid, signal.SIGCONT)
            orphan_result = await_hook(orphan)
            audited = await_hook(pending)
            old.record({'kind':'orphan-hook-result','response':orphan_result})
            replacement.record({'kind':'replacement-startup-hook-result','response':audited})
            checks['orphan_cannot_wake_or_inspect'] = orphan_result['exit'] == 0 and not orphan_result['stderr'] and all(r['hook_pid'] != hook_pid for r in rows(case/'inspector.jsonl'))
            checks['only_replacement_hook_inspects_and_wakes'] = audited['exit'] == 2 and all(r['hook_pid'] == pending['provenance']['hook_pid'] for r in rows(case/'inspector.jsonl')) and pending['provenance']['caller_owner_pid'] == replacement.process.pid
        elif kind in ('interrupted', 'interrupted-limit'):
            hold = case/'hold-inspector'
            hold.write_text('Fixture inspector deliberately holds inherited inference lease.\n')
            first = replacement.hook('audit', 'SessionStart', timeout=20, detached=True)
            wait_until(lambda: len(rows(case/'inspector.jsonl')) == 1)
            first_hook = first['provenance']['hook_pid']
            first_inspector = rows(case/'inspector.jsonl')[0]['inspector_pid']
            first_identity = process_identity(first_hook)
            inspector_identity = process_identity(first_inspector)
            assert first_identity and inspector_identity and inspector_identity['ppid'] == first_hook
            _, in_flight = saved_state(case, session)
            write_json(case/'interrupted-in-flight-state.json', in_flight)
            os.kill(first_hook, signal.SIGKILL)
            time.sleep(.1)
            checks['leader_and_inspector_survive_hook_only_signal'] = process_identity(replacement.process.pid) == replacement.identity and process_identity(first_inspector) is not None
            retry = replacement.hook('audit', 'Stop', timeout=12, detached=True)
            time.sleep(.35)
            checks['surviving_inspector_lease_prevents_duplicate_inference'] = len(rows(case/'inspector.jsonl')) == 1 and not Path(retry['result_path']).exists()
            _, held_state = saved_state(case, session)
            checks['waiting_retry_does_not_spend_budget'] = held_state['audit_attempts'] == 6
            if kind == 'interrupted-limit':
                (case/'hold-inspector-2').write_text('Second interrupted attempt barrier.\n')
            hold.unlink()
            first_result = await_hook(first)
            checks['only_hook_was_killed'] = first_result['exit'] == -signal.SIGKILL
            if kind == 'interrupted-limit':
                wait_until(lambda: len(rows(case/'inspector.jsonl')) == 2)
                os.kill(retry['provenance']['hook_pid'], signal.SIGKILL)
                (case/'hold-inspector-2').unlink()
                second_result = await_hook(retry)
                assert second_result['exit'] == -signal.SIGKILL
                with replacement_transcript.open('a') as history:
                    history.write(json.dumps({'uuid':'assistant-chatter','type':'assistant','message':{'content':'Still working on the original task.'}})+'\n')
                replacement.hook('capture', 'Stop')
                third = replacement.hook('audit', 'Stop', timeout=.6)
                _, final = saved_state(case, session)
                write_json(case/'interrupted-limit-state.json', final)
                checks['assistant_chatter_cannot_refill_interrupted_retry'] = third['timed_out'] and len(rows(case/'inspector.jsonl')) == 2 and final['audit_attempts'] == 7 and final['interrupted_audit_retries'] == 1
                checks['unpublished_interruption_has_no_delivery_ack'] = not final.get('audit_wake', {}).get('delivered_at') and final.get('recovery_requires_review')
                checks['original_authority_survives_chatter'] = any(m.get('source_id') == 'original-human-source' and m['text'] == original for m in final['messages'])
                report['passed'] = all(checks.values())
                return report
            audited = await_hook(retry)
            checks['interrupted_hook_cannot_publish_or_wake'] = not first_result['stderr'] and in_flight.get('audit_inference', {}).get('phase') == 'started'
            checks['one_bounded_immediate_retry_after_child_exit'] = len(rows(case/'inspector.jsonl')) == 2 and rows(case/'inspector.jsonl')[1]['hook_pid'] == retry['provenance']['hook_pid'] and audited['exit'] == 2
            replacement.record({'kind':'hook-only-interruption','first':first,'first_result':first_result,'inspector_identity':inspector_identity,'retry':retry,'retry_result':audited})
        else:
            audited = replacement.hook('audit', 'SessionStart')
        deadline = STRAGGLER_DEADLINE_SECONDS if kind == 'straggler' else DIRECT_RESTART_DEADLINE_SECONDS
        report['reconciliation_timing'] = {'elapsed_seconds': audited['elapsed'], 'deadline_seconds': deadline,
                                          'straggler_poll_contract_seconds': STRAGGLER_POLL_SECONDS if kind == 'straggler' else None}
        checks['one_immediate_reconciliation_without_hour_sleep'] = audited['exit'] == 2 and not audited['timed_out'] and audited['elapsed'] < deadline and len(rows(case/'inspector.jsonl')) == (2 if kind == 'interrupted' else 1)
        path, reconciled = saved_state(case, session)
        write_json(case/'reconciled-state.json', reconciled)
        if orphan:
            checks['orphan_cannot_reserve_or_publish_reconciliation'] = reconciled.get('audit_inference', {}).get('hook_pid') == pending['provenance']['hook_pid'] and reconciled['audit_attempts'] == 6
        claims = reconciled.get('recovery_checkpoints', [])
        checks['wake_ack_follows_actual_cli_output'] = bool(reconciled.get('audit_wake', {}).get('delivered_at')) and audited['exit'] == 2 and bool(audited['stderr'])
        checks['transfer_credit_durably_claimed_once'] = len(claims) == 1 and bool(claims[0].get('claimed_at'))
        checks['same_replacement_owns_assignment'] = reconciled['ownership']['process']['pid'] == replacement.process.pid and ownership(case)['sessions']['old']['owner'] == session
        checks['inspection_budget_not_refilled'] = reconciled['audit_attempts'] == (7 if kind == 'interrupted' else 6) and reconciled['retry_at'] > time.time() + 2500
        checks['reconciliation_gate_cleared'] = not reconciled.get('recovery_requires_review')
        sources = [m for m in reconciled['messages'] if m.get('role') == 'user']
        checks['original_source_and_constraints_retained'] = len(sources) == 1 and sources[0]['text'] == original and sources[0]['source_id'] == 'original-human-source' and sources[0]['provenance'] == 'native_human_typed_v1'
        for event in ('SessionStart', 'Stop'):
            replacement.hook('capture', event)
            replacement.hook('audit', event, timeout=0.6)
        _, repeated = saved_state(case, session)
        write_json(case/'repeated-hooks-state.json', repeated)
        checks['repeated_start_stop_cannot_buy_inspection_credit'] = len(rows(case/'inspector.jsonl')) == (2 if kind == 'interrupted' else 1) and repeated['audit_attempts'] == (7 if kind == 'interrupted' else 6) and repeated.get('recovery_checkpoints') == claims
        hook_payloads = [e['command']['payload'] for e in rows(case/'events.jsonl') if e.get('kind') == 'scripted-driver-command' and e['command']['kind'] == 'hook']
        checks['no_human_assignment_resent'] = all('prompt' not in p and p['hook_event_name'] != 'UserPromptSubmit' for p in hook_payloads) and hashlib.sha256(transcript.read_bytes()).hexdigest() == original_hash
        checks['replacement_transcript_has_no_synthetic_assignment'] = kind in ('resume', 'orphan-resume') or replacement_transcript.read_text() == ''
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
        remaining = owned_group_members({owner.process.pid for owner in owners} | {h['hook_pgid'] for owner in owners for h in owner.hooks})
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
               [('interrupted-retry-limit', 'interrupted-limit'), ('hook-only-mid-inference', 'interrupted'), ('detached-orphan-fresh', 'orphan-fresh'), ('detached-orphan-resume', 'orphan-resume'), ('fresh-exhausted-budget', 'fresh'), ('resume-exhausted-budget', 'resume'), ('live-straggler-recovery', 'straggler')]]
    unchanged = identity == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    result = {'passed': all(r['passed'] for r in results) and unchanged, 'provider_calls': 0,
              'boundary': 'Actual OS processes and shipped hook CLI; scripted leader/operator and fake inspector. This does not prove live model autonomous recovery.',
              'source_sha256': identity, 'source_unchanged': unchanged, 'cases': results}
    write_json(out/'result.json', result)
    print('PASS' if result['passed'] else 'FAIL', 'actual-process recovery acceptance; no provider calls', flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
