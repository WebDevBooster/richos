#!/usr/bin/env python3
"""Exercise actual desktop acceptance, restart, early stop and background completion.
Build the debug app first. All writes and native fixtures use a fresh test directory.
"""
import json
import hashlib
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(__file__).resolve().parents[1]
native = "--native" in sys.argv[1:]
panel_only = "--panel-only" in sys.argv[1:]
pending_only = "--pending-only" in sys.argv[1:]
disposition_only = "--disposition-only" in sys.argv[1:]
args = [arg for arg in sys.argv[1:] if arg not in ("--native", "--panel-only", "--pending-only", "--disposition-only")]
binary = Path(args[0]) if args else app / "src-tauri/target/debug/richos-tauri"
if not binary.is_file():
    sys.exit("Build the debug desktop binary first: cargo build --manifest-path app/src-tauri/Cargo.toml")
root = Path(tempfile.mkdtemp(prefix="richos-owned-desktop-"))
print("Evidence directory:", root, flush=True)
data = root / "data"
workspace = root / "company"
other = root / "other-company"
for p in (data, workspace, other):
    p.mkdir()
(data / "entities.json").write_text(json.dumps({"version": 1, "entities": [
    {"id": "fixture", "display_name": "Fixture", "status": "active", "roots": [str(workspace)]},
    {"id": "other", "display_name": "Other", "status": "active", "roots": [str(other)]},
]}))
fake = root / "native-fixture"
fake.write_text("#!/usr/bin/env python3\n" + r'''
import json, sys, time, os, subprocess
from pathlib import Path
base = Path(os.environ['RICHOS_FIXTURE_ROOT'])
def disposition(text):
    # Exercise actual MCP persistence. Corruption cases damage only disposable receipts afterward.
    spec = json.loads(sys.argv[sys.argv.index('--mcp-config')+1])['mcpServers']['richos_onboarding']
    kind = 'cancel' if text.startswith('Cancel pending assignment.') else 'amend' if text.startswith('Revise the assignment:') else 'work' if text.startswith('Handle') else 'discussion'
    frames = [
        {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'disposition-fixture','version':'1'}}},
        {'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'record_work_disposition','arguments':{'kind':kind,'reason':'This fixture turn has an explicit '+kind+' disposition.'}}}]
    result = subprocess.run([spec['command'],*spec['args']], input=''.join(json.dumps(f)+'\n' for f in frames), text=True, capture_output=True, timeout=20)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    with (base/'disposition-mcp-calls.jsonl').open('a') as log:
        log.write(json.dumps({'text':text,'kind':kind,'command':spec,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})+'\n')
    assert result.returncode == 0 and len(replies) == 2, (result.returncode,result.stdout,result.stderr)
    assert replies[1].get('result',{}).get('isError') is False, replies
    if text.startswith(('Handle corrupt receipt:', 'Handle stale receipt:', 'Handle invalid scope:')):
        scope = json.loads(Path(spec['args'][-1]).read_text())['work_disposition']
        receipt_path = Path(scope['receipt_path'])
        original = receipt_path.read_text()
        if text.startswith('Handle corrupt receipt:'):
            receipt_path.write_text('{damaged')
        elif text.startswith('Handle stale receipt:'):
            receipt = json.loads(original)
            receipt['scope']['nonce'] = 'stale-turn-nonce'
            receipt['disposition'] = {'kind':'discussion','reason':'Forged no-work claim.'}
            receipt_path.write_text(json.dumps(receipt))
        else:
            expected_path = receipt_path.with_suffix('.scope.json')
            expected = json.loads(expected_path.read_text())
            expected['workspace'] = str(base/'untrusted-workspace')
            expected_path.write_text(json.dumps(expected))
        with (base/'receipt-corruptions.jsonl').open('a') as log:
            log.write(json.dumps({'text':text,'path':str(receipt_path),'original':original})+'\n')
    # Normal native tool traffic is emitted too; persistence is the host's MCP receipt.
    call_id = 'disposition-'+str(time.time_ns())
    print(json.dumps({'type':'assistant','message':{'content':[{'type':'tool_use','id':call_id,'name':'mcp__richos_onboarding__record_work_disposition','input':frames[1]['params']['arguments']}]}}),flush=True)
    print(json.dumps({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':call_id,'content':replies[1]['result']['content'],'is_error':False}]}}),flush=True)
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('type') == 'control_request':
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':msg['request_id'],'response':{}}}), flush=True)
    elif msg.get('type') == 'user':
        print(json.dumps({'type':'system','subtype':'init','tools':['mcp__richos_onboarding__save_company_notes','mcp__richos_onboarding__decline_onboarding','mcp__richos_onboarding__record_work_disposition'],'plugins':[{'name':'rich-skills'}]}), flush=True)
        content = msg.get('message', {}).get('content', '')
        text = content if isinstance(content, str) else ''.join(item.get('text', '') for item in content if item.get('type') == 'text')
        structured = None
        if text.startswith("Transcribe Rich's completed conversation."):
            data = json.loads(text.split('DATA:\n',1)[1]); ceo = data['ceo_message']; reply = data['rich_reply']
            base = Path(os.environ['RICHOS_FIXTURE_ROOT'])
            with (base / 'registration-calls.jsonl').open('a') as log: log.write(json.dumps({'ceo':ceo,'args':sys.argv[1:],'cwd':str(Path.cwd()),'disposition':data.get('recorded_disposition')})+'\n')
            intent = 'cancel' if ceo.startswith('Cancel pending assignment.') else 'amend' if ceo.startswith('Revise the assignment:') else 'work' if ceo.startswith('Handle') else 'discussion'
            target = data['assignments'][0]['id'] if intent in ('amend','cancel') else None
            if ceo.startswith('Handle slow registration:'):
                (base / 'registration-started').write_text('started'); time.sleep(8)
            structured = {'intent':intent,'rich_committed':intent!='discussion' and bool(reply.strip()),'request_quote':ceo,'reply_quote':' '.join(reply.split()),'scope_complete':True,'target_run_id':target}
            if ceo.startswith('Handle malformed:') and not (base/'registration-recovered').exists(): structured = None
            if ceo.startswith('Question inconsistent:') and not (base/'registration-recovered').exists(): structured.update(intent='discussion',rich_committed=True)
        elif text.startswith(('Handle', 'Revise the assignment:', 'How is ', 'Question inconsistent:', 'Cancel pending assignment.')):
            reply = 'There is no action requested.' if text.startswith(('How','Question')) else 'I will deliver this.\n\n**Deliverable:**\n- '+text
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':reply}]}}), flush=True)
            if text.startswith('Handle interrupted disposition:'):
                (base/'disposition-turn-started').write_text('native request received before disposition')
                time.sleep(120)
                raise RuntimeError('The interruption harness did not stop the disposable app')
            if not text.startswith(('Handle missing disposition:', 'Question inconsistent:')):
                disposition(text)
        elif text.startswith('Report this durable work update'):
            failed = 'Automatic recovery remains scheduled' in text
            if failed:
                assert 'Registration failed after' not in text and 'must quote' not in text and 'previous_error' not in text
            response = "I couldn't start the work. Your request is saved and unfinished. Recovery remains scheduled; you do not need to resend it." if failed else 'Finished and checked: the deliverable is ready.'
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':response}]}}), flush=True)
        elif text.startswith('Independently audit'):
            special = next((name for name in ('missing-disposition.txt','interrupted-disposition.txt','corrupt-disposition.txt','stale-disposition.txt','unrelated-disposition.txt','invalid-scope.txt') if name in text),None)
            exists = (Path(special).exists() and Path(special).read_text() == 'Finished.\n') if special else (Path('revised.txt').exists() and not Path('original.txt').exists()) if 'revised.txt' in text else Path('original.txt').exists() if 'original.txt' in text else (Path('deliverable.txt').exists() and Path('deliverable.txt').read_text() == 'Finished.\n')
            structured = {'kind':'complete','evidence':'I read deliverable.txt and matched its exact content.'} if exists else {'kind':'incomplete','remaining':'The actual deliverable is absent. Write it before finishing.'}
        elif text.startswith('Work on this task within the authorized run.'):
            special = next((name for name in ('missing-disposition.txt','interrupted-disposition.txt','corrupt-disposition.txt','stale-disposition.txt','unrelated-disposition.txt','invalid-scope.txt') if name in text),None)
            if special: Path(special).write_text('Finished.\n')
            if 'Revise the assignment:' in text:
                Path('revised.txt').write_text('Revised.')
            elif 'Handle correction test:' in text:
                Path('correction-worker-started').write_text('started')
                time.sleep(8)
            counter = Path(special+'.attempts') if special else Path('attempts')
            attempts = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(attempts))
            if attempts >= 2 and not special: Path('deliverable.txt').write_text('Finished.\n')
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'All done.'}]}}), flush=True)
        result = {'type':'result','subtype':'success','stop_reason':'end_turn','is_error':False}
        if structured is not None: result['structured_output'] = {'result': structured}
        print(json.dumps(result), flush=True)
''')
fake.chmod(0o700)
identity_paths=[binary.resolve(),Path(__file__).resolve(),fake]
env = dict(os.environ, RICHOS_TEST_DATA_DIR=str(data), RICHOS_ENTITY="fixture",
           RICHOS_ENGINE_DIR=str(workspace), RICHOS_CLAUDE_BIN=str(fake), RICHOS_FIXTURE_ROOT=str(root))
if native:
    # Observe the actual provider without adding input, permissions or answers.
    provider=Path.home()/'.local/bin/claude'
    if not provider.is_file(): sys.exit(f"Installed native provider is unavailable: {provider}")
    trace=root/'provider-trace'; trace.mkdir()
    tracer=root/'native-passthrough'
    tracer.write_text("#!/usr/bin/env python3\n" + r'''import json,os,sys,uuid
from pathlib import Path
trace=Path(__TRACE_ROOT__)
call=str(uuid.uuid4())
(trace/(call+'.invocation.json')).write_text(json.dumps({'pid':os.getpid(),'cwd':os.getcwd(),'argv':sys.argv[1:],'provider':__PROVIDER__}))
# exec keeps the provider as the PID owned/canceled by NativeClient. Each tee
# child closes unused descriptors and exits on EOF; it never emits new bytes.
for channel,label in [(0,'stdin'),(1,'stdout'),(2,'stderr')]:
    read_fd,write_fd=os.pipe()
    if os.fork()==0:
        source,destination=(channel,write_fd) if channel==0 else (read_fd,channel)
        os.close(read_fd if channel==0 else write_fd)
        for unused in (0,1,2):
            if unused!=channel: os.close(unused)
        log=os.open(str(trace/(call+'.'+label)),os.O_CREAT|os.O_WRONLY,0o600)
        try:
            while True:
                chunk=os.read(source,65536)
                if not chunk: break
                for fd in (log,destination):
                    remaining=chunk
                    while remaining:
                        remaining=remaining[os.write(fd,remaining):]
        except (BrokenPipeError,OSError): pass
        finally: os._exit(0)
    owned=read_fd if channel==0 else write_fd
    os.close(write_fd if channel==0 else read_fd)
    os.dup2(owned,channel);os.close(owned)
os.execv(__PROVIDER__,[__PROVIDER__,*sys.argv[1:]])
'''.replace('__TRACE_ROOT__',repr(str(trace))).replace('__PROVIDER__',repr(str(provider))))
    tracer.chmod(0o700)
    env['RICHOS_CLAUDE_BIN']=str(tracer)
    identity_paths.extend([provider.resolve(),tracer])
identity={'kind':'real-provider actual desktop; byte-preserving observation only' if native else 'deterministic actual desktop with protocol fixture; no real-model acceptance',
          'sha256':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_paths}}
(root/'source-identity.json').write_text(json.dumps(identity,indent=2))
disposition_phases = ("disposition-corrupt", "disposition-discussion", "disposition-missing-enqueue", "disposition-missing-resume", "disposition-interrupted-enqueue", "disposition-interrupted-resume")
phases = ("pending-cancel",) if pending_only else ("panel-decisions",) if panel_only else (("native-handoff",) if native else (("enqueue","resume","slow-registration",*disposition_phases) if disposition_only else ("update-owned", "enqueue", "resume", "recover-notice", "correct-live", "slow-registration", "pending-cancel", "independent-work", "registration-failures", "registration-failures-restart", "registration-recovery", "end-live", "panel-decisions", *disposition_phases)))
def records(name):
    path=root/name
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
def measured_phase(phase, **result):
    with (root/'phase-results.jsonl').open('a') as log:
        log.write(json.dumps({'phase':phase,**result})+'\n')
for phase in phases:
    if phase == "registration-recovery":
        (root / 'registration-recovered').write_text('provider recovered')
        # Advance only the test fixture's persisted due times. Attempt counters,
        # requests and original user turns are unchanged across app restart.
        for path in (data/'requests').glob('*.json'):
            saved = json.loads(path.read_text())
            if saved['text'].startswith(('Handle malformed:', 'Question inconsistent:')):
                assert saved['attempts'] == 3 and not saved['done'] and saved['retry_at'] > 0
                saved['retry_at'] = 0
                path.write_text(json.dumps(saved))
    if phase == "recover-notice":
        # Simulate the crash window after verified completion was committed to
        # the job but before its conversation notice was written.
        ledger = data / "conversation-ledger.jsonl"
        events = [json.loads(line) for line in ledger.read_text().splitlines()]
        ledger.write_text(''.join(json.dumps(e) + '\n' for e in events if not str(e.get("turn_id", "")).startswith("finished-")))
    env["RICHOS_OWNED_SELFTEST"] = phase
    if phase == 'disposition-interrupted-enqueue':
        marker=root/'disposition-turn-started'
        with (root/f'{phase}.log').open('w') as log:
            process=subprocess.Popen([str(binary.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            deadline=time.monotonic()+60
            while not marker.exists() and process.poll() is None and time.monotonic()<deadline:
                time.sleep(.05)
            started=marker.exists()
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGKILL)
            code=process.wait(timeout=10)
        measured_phase(phase,passed=started,interruption_injected=True,exit=code)
        assert started, f'Native interruption marker absent; inspect {root/(phase+".log")}'
        assert code == -signal.SIGKILL, f'Disposable app was not interrupted as intended: {code}'
        print('PASS',phase,'(intentional app interruption before disposition)',flush=True)
        continue
    with (root / f"{phase}.log").open("w") as log:
        result = subprocess.run([str(binary.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300 if native else 120)
    report_path = data / f"selftest-{phase}.json"
    if result.returncode != 0 or not report_path.exists():
        measured_phase(phase,passed=False,exit=result.returncode,report_exists=report_path.exists())
        sys.exit(f"FAIL {phase}: exit {result.returncode}; inspect {root / (phase + '.log')}")
    report = json.loads(report_path.read_text())
    if "error" in report:
        measured_phase(phase,passed=False,exit=result.returncode,report=report)
        sys.exit(f"FAIL {phase}: {report['error']}")
    if phase.startswith('disposition-'):
        assert report['passed'],report
        calls=records('registration-calls.jsonl')
        if phase == 'disposition-corrupt':
            for prefix,artifact in [('Handle corrupt receipt:','corrupt-disposition.txt'),('Handle stale receipt:','stale-disposition.txt'),('Handle unrelated receipt:','unrelated-disposition.txt')]:
                matching=[c for c in calls if c['ceo'].startswith(prefix)]
                assert len(matching)==1, matching
                assert (matching[0]['disposition'] is None) == ('unrelated' not in prefix),matching
                assert (workspace/artifact).read_text()=='Finished.\n'
                assert (workspace/(artifact+'.attempts')).read_text()=='1'
            assert not any(c['ceo'].startswith('Handle invalid scope:') for c in calls),calls
            assert not (workspace/'invalid-scope.txt').exists()
            assert not (root/'untrusted-workspace').exists()
            assert report['recovered']==3 and report['parked']==1 and report['sourceTurns']==4,report
        elif phase == 'disposition-discussion':
            assert not any(c['ceo']=='How is disposition work going?' for c in calls),calls
            assert any(c['text']=='How is disposition work going?' and c['kind']=='discussion' for c in records('disposition-mcp-calls.jsonl'))
        elif phase.endswith('-resume'):
            prefix='Handle missing disposition:' if 'missing' in phase else 'Handle interrupted disposition:'
            matching=[c for c in calls if c['ceo'].startswith(prefix)]
            assert len(matching)==1 and matching[0]['disposition'] is None,matching
            artifact='missing-disposition.txt' if 'missing' in phase else 'interrupted-disposition.txt'
            assert (workspace/artifact).read_text()=='Finished.\n'
            assert (workspace/(artifact+'.attempts')).read_text()=='1','Restart duplicated worker execution'
            assert report['requests']==1 and report['runs']==1 and report['sourceTurns']==1,report
            if 'interrupted' in phase:
                assert 'send it again' not in report['interruptionReason']
                assert 'recover any unfinished assignment automatically' in report['interruptionReason']
    elif native:
        assert report["nativeHandoffCompleted"], report
        assert (workspace / "hello.txt").read_bytes() == b"Hello Rich"
        assert sum(m["role"] == "user" for m in report["messages"]) == 1
        assert any(m["turn_id"].startswith("finished-") for m in report["messages"])
    elif phase == "update-owned":
        assert report["updateOwned"] and report["checks"] == 12, report
    elif phase in ("slow-registration", "pending-cancel", "independent-work", "registration-failures", "registration-failures-restart", "registration-recovery", "end-live"):
        assert report["passed"], report
        calls = [json.loads(line) for line in (root / 'registration-calls.jsonl').read_text().splitlines()]
        for call in calls:
            argv = call['args']
            assert argv[argv.index('--model')+1] == env.get('RICHOS_REGISTRATION_MODEL', 'sonnet')
            assert argv[argv.index('--tools')+1] == ''
            assert argv[argv.index('--setting-sources')+1] == ''
            assert '--strict-mcp-config' in argv
            assert call['cwd'] not in (str(workspace), str(other))
        if phase == 'registration-failures-restart':
            for prefix in ('Handle malformed:', 'Question inconsistent:'):
                assert sum(c['ceo'].startswith(prefix) for c in calls) == 3, calls
    elif phase == "panel-decisions":
        assert report["panelActions"] == 3 and report["staleRejected"] == 3 and report["acknowledgments"] == 3 and report["writerBoundary"], report
    elif phase == "enqueue":
        assert report["requestPersisted"], report
        assert not (workspace / "deliverable.txt").exists(), "The restart fixture ran before the first app exited"
    elif phase == "correct-live":
        assert report["conversationResponsive"], report
        assert report["correctionApplied"], report
        assert (workspace / "revised.txt").read_text() == "Revised."
        assert not (workspace / "original.txt").exists()
    else:
        assert report["attempts"] == 2, report
        assert report["backgroundScopePreserved"], report
        assert report["snapshot"]["tasks"][0]["state"] == "passed", report
        assert sum(m["role"] == "user" for m in report["messages"]) == 1, "Restart duplicated the CEO request"
        assert (workspace / "deliverable.txt").read_text() == "Finished.\n"
        if phase == 'resume':
            registered=[c for c in records('registration-calls.jsonl') if c['ceo']=='Handle this: produce deliverable.txt containing Finished.']
            assert len(registered)==1 and registered[0]['disposition']['kind']=='work',registered
    if not native:
        assert not any(c['ceo'].startswith('How is ') for c in records('registration-calls.jsonl')),'Ordinary discussion invoked the registrar'
    measured_phase(phase,passed=True,exit=result.returncode,report=report)
    print("PASS", phase, flush=True)
print(f"PASS actual desktop: {len(phases)} exercised phase(s): {', '.join(phases)}.")
final_identity={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_paths}
(root/'final-identity.json').write_text(json.dumps({'sha256':final_identity,'unchanged':final_identity==identity['sha256']},indent=2))
assert final_identity==identity['sha256'],'The tested binary or fixture changed during acceptance'
