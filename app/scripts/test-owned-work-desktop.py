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
args = [arg for arg in sys.argv[1:] if arg != "--native"]
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
import json, sys, time
from pathlib import Path
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('type') == 'control_request':
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':msg['request_id'],'response':{}}}), flush=True)
    elif msg.get('type') == 'user':
        content = msg.get('message', {}).get('content', '')
        text = content if isinstance(content, str) else ''.join(item.get('text', '') for item in content if item.get('type') == 'text')
        structured = None
        if text.startswith('Register the assignment you just discussed.'):
            ceo = text.split('CEO message: ',1)[1].split('\nYour reply:',1)[0]
            if ceo.startswith('Revise the assignment:'):
                structured = {'kind':'amend','goal':'Write revised.txt instead of original.txt','tasks':[{'id':'revise','description':'Write revised.txt containing Revised. Do not produce original.txt.','depends_on':[],'criteria':'revised.txt contains Revised. and original.txt does not exist'}]}
            elif ceo.startswith('Handle correction test:'):
                structured = {'kind':'work','goal':'Write original.txt','tasks':[{'id':'original','description':'Write original.txt','depends_on':[],'criteria':'original.txt exists'}]}
            elif ceo.startswith('Handle this:'):
                structured = {'kind':'work','goal':'Produce the finished deliverable','tasks':[{'id':'deliver','description':'Write deliverable.txt containing Finished.','depends_on':[],'criteria':'deliverable.txt contains exactly Finished.'}]}
            else: structured = {'kind':'none'}
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':json.dumps(structured)}]}}), flush=True)
            structured = None
        elif text.startswith(('Handle this:', 'Handle correction test:', 'Revise the assignment:', 'How is work going?')):
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'I will handle the complete deliverable.'}]}}), flush=True)
        elif text.startswith('Report this durable work update'):
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Finished and checked: the deliverable is ready.'}]}}), flush=True)
        elif text.startswith('Independently audit'):
            exists = (Path('revised.txt').exists() and not Path('original.txt').exists()) if 'revised.txt' in text else Path('original.txt').exists() if 'original.txt' in text else (Path('deliverable.txt').exists() and Path('deliverable.txt').read_text() == 'Finished.\n')
            structured = {'kind':'complete','evidence':'I read deliverable.txt and matched its exact content.'} if exists else {'kind':'incomplete','remaining':'The actual deliverable is absent. Write it before finishing.'}
        elif text.startswith('Work on this task within the authorized run.'):
            if 'Write revised.txt instead of original.txt' in text:
                Path('revised.txt').write_text('Revised.')
            elif 'Goal: Write original.txt' in text or 'Intended outcome: Write original.txt' in text:
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
           RICHOS_ENGINE_DIR=str(workspace), RICHOS_CLAUDE_BIN=str(fake))
if native: env.pop("RICHOS_CLAUDE_BIN", None)
for phase in (("native-handoff",) if native else ("enqueue", "resume", "recover-notice", "correct-live")):
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
print("PASS installed-native desktop: Rich answered, registered work, verified delivery and reported completion." if native else "PASS actual desktop: restart, false completion rejection, scoped output, responsive conversation and live correction.")
