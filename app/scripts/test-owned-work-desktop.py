#!/usr/bin/env python3
"""Exercise actual desktop acceptance, restart, early stop and background completion.
Build the debug app first. All writes and native fixtures use a fresh test directory.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(__file__).resolve().parents[1]
native = "--native" in sys.argv[1:]
panel_only = "--panel-only" in sys.argv[1:]
args = [arg for arg in sys.argv[1:] if arg not in ("--native", "--panel-only")]
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
import json, sys, time, os
from pathlib import Path
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('type') == 'control_request':
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':msg['request_id'],'response':{}}}), flush=True)
    elif msg.get('type') == 'user':
        content = msg.get('message', {}).get('content', '')
        text = content if isinstance(content, str) else ''.join(item.get('text', '') for item in content if item.get('type') == 'text')
        structured = None
        if text.startswith("Transcribe Rich's completed conversation."):
            data = json.loads(text.split('DATA:\n',1)[1]); ceo = data['ceo_message']; reply = data['rich_reply']
            base = Path(os.environ['RICHOS_FIXTURE_ROOT'])
            with (base / 'registration-calls.jsonl').open('a') as log: log.write(json.dumps({'ceo':ceo,'args':sys.argv[1:],'cwd':str(Path.cwd())})+'\n')
            intent = 'amend' if ceo.startswith('Revise the assignment:') else 'work' if ceo.startswith('Handle') else 'discussion'
            target = data['assignments'][0]['id'] if intent == 'amend' else None
            if ceo.startswith('Handle slow registration:'):
                (base / 'registration-started').write_text('started'); time.sleep(8)
            structured = {'intent':intent,'rich_committed':intent!='discussion','request_quote':ceo,'reply_quote':' '.join(reply.split()),'scope_complete':True,'target_run_id':target}
            if ceo.startswith('Handle malformed:'): structured = None
            if ceo.startswith('Question inconsistent:'): structured.update(intent='work',rich_committed=False)
        elif text.startswith(('Handle', 'Revise the assignment:', 'How is work going?', 'Question inconsistent:')):
            reply = 'There is no action requested.' if text.startswith(('How','Question')) else 'I will deliver this.\n\n**Deliverable:**\n- '+text
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':reply}]}}), flush=True)
        elif text.startswith('Report this durable work update'):
            failed = 'Automatic attempts have stopped.' in text
            if failed:
                assert 'Registration failed after' not in text and 'must quote' not in text and 'previous_error' not in text
            response = "I couldn't start the work. Your request is saved and unfinished. You can send it again if you want another attempt." if failed else 'Finished and checked: the deliverable is ready.'
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':response}]}}), flush=True)
        elif text.startswith('Independently audit'):
            exists = (Path('revised.txt').exists() and not Path('original.txt').exists()) if 'revised.txt' in text else Path('original.txt').exists() if 'original.txt' in text else (Path('deliverable.txt').exists() and Path('deliverable.txt').read_text() == 'Finished.\n')
            structured = {'kind':'complete','evidence':'I read deliverable.txt and matched its exact content.'} if exists else {'kind':'incomplete','remaining':'The actual deliverable is absent. Write it before finishing.'}
        elif text.startswith('Work on this task within the authorized run.'):
            if 'Revise the assignment:' in text:
                Path('revised.txt').write_text('Revised.')
            elif 'Handle correction test:' in text:
                Path('correction-worker-started').write_text('started')
                time.sleep(8)
            counter = Path('attempts')
            attempts = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(attempts))
            if attempts >= 2: Path('deliverable.txt').write_text('Finished.\n')
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'All done.'}]}}), flush=True)
        result = {'type':'result','subtype':'success','stop_reason':'end_turn','is_error':False}
        if structured is not None: result['structured_output'] = {'result': structured}
        print(json.dumps(result), flush=True)
''')
fake.chmod(0o700)
env = dict(os.environ, RICHOS_TEST_DATA_DIR=str(data), RICHOS_ENTITY="fixture",
           RICHOS_ENGINE_DIR=str(workspace), RICHOS_CLAUDE_BIN=str(fake), RICHOS_FIXTURE_ROOT=str(root))
if native: env.pop("RICHOS_CLAUDE_BIN", None)
phases = ("panel-decisions",) if panel_only else (("native-handoff",) if native else ("enqueue", "resume", "recover-notice", "correct-live", "slow-registration", "independent-work", "registration-failures", "registration-failures-restart", "end-live", "panel-decisions"))
for phase in phases:
    if phase == "recover-notice":
        # Simulate the crash window after verified completion was committed to
        # the job but before its conversation notice was written.
        ledger = data / "conversation-ledger.jsonl"
        events = [json.loads(line) for line in ledger.read_text().splitlines()]
        ledger.write_text(''.join(json.dumps(e) + '\n' for e in events if not str(e.get("turn_id", "")).startswith("finished-")))
    env["RICHOS_OWNED_SELFTEST"] = phase
    with (root / f"{phase}.log").open("w") as log:
        result = subprocess.run([str(binary.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300 if native else 120)
    report_path = data / f"selftest-{phase}.json"
    if result.returncode != 0 or not report_path.exists():
        sys.exit(f"FAIL {phase}: exit {result.returncode}; inspect {root / (phase + '.log')}")
    report = json.loads(report_path.read_text())
    if "error" in report:
        sys.exit(f"FAIL {phase}: {report['error']}")
    if native:
        assert report["nativeHandoffCompleted"], report
        assert (workspace / "hello.txt").read_bytes() == b"Hello Rich"
        assert sum(m["role"] == "user" for m in report["messages"]) == 1
        assert any(m["turn_id"].startswith("finished-") for m in report["messages"])
    elif phase in ("slow-registration", "independent-work", "registration-failures", "registration-failures-restart", "end-live"):
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
    print("PASS", phase, flush=True)
print(f"PASS actual desktop: {len(phases)} exercised phase(s): {', '.join(phases)}.")
