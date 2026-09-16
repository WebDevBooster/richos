#!/usr/bin/env python3
"""Reproduce audit findings in disposable fixtures. Requires macOS, Git, Node and cached Rust dependencies.
Usage: python3 reproduce.py [repository-root] [output-directory]
Only synthetic data and fixture-owned processes are used.
"""
import importlib.util, json, os, pathlib, shutil, struct, subprocess, sys, tempfile, threading
ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else pathlib.Path(tempfile.mkdtemp(prefix='richos-third-audit-results-'))
OUT.mkdir(parents=True, exist_ok=True)
results = {}
with tempfile.TemporaryDirectory(prefix='richos-third-probes-') as temp:
    base = pathlib.Path(temp).resolve()
    product = base/'product'
    service = product/'richos/tools/richos-service'
    service.mkdir(parents=True)
    src = ROOT/'richos/tools/richos-service'
    shutil.copytree(src/'lib', service/'lib')
    shutil.copytree(src/'host', service/'host')
    shutil.copytree(src/'bin', service/'bin')
    shutil.copy2(src/'package.json', service/'package.json')
    shutil.copytree(ROOT/'richos/tools/richos-extension/sync', product/'richos/tools/richos-extension/sync')
    shutil.copy2(ROOT/'richos/tools/richos-extension/package.json', product/'richos/tools/richos-extension/package.json')
    zone = base/'recordings'; zone.mkdir()
    for kind in ['traversal', 'symlink', 'normal']:
        target = product/'docs'/kind
        target.mkdir(parents=True)
        sid = '../product/docs/traversal' if kind == 'traversal' else kind
        if kind == 'symlink': (zone/sid).symlink_to(target, target_is_directory=True)
        messages = [dict(type='session-start',record=dict(sessionId=sid, status='open')), dict(type='audio-chunk',sessionId=sid,part=0,dataB64='c3ludGhldGljIGF1ZGlv')]
        raw = b''.join(struct.pack('<I',len(x))+x for x in (json.dumps(m).encode() for m in messages))
        env = dict(os.environ, RICHOS_DROP_ZONE=str(zone))
        p = subprocess.run(['node',str(service/'host/native-host.js')],input=raw,capture_output=True,env=env,timeout=20)
        responses=[]; data=p.stdout
        while len(data)>=4:
            n=struct.unpack('<I',data[:4])[0]; responses.append(json.loads(data[4:4+n])); data=data[4+n:]
        results['host_'+kind] = dict(exit=p.returncode,responses=responses, product_record=(target/'session.json').exists(),product_audio=(target/'audio-part-00.webm').exists(),audio_at_requested_path=(zone/sid/'audio-part-00.webm').exists())
    # Control: the host refuses the same product path as its configured zone.
    refused = subprocess.run(['node',str(service/'host/native-host.js')],input=b'',capture_output=True,env=dict(os.environ,RICHOS_DROP_ZONE=str(product/'docs/direct')),timeout=20)
    results['host_direct_zone_control'] = dict(exit=refused.returncode, privacy_refusal=b'privacy invariant' in refused.stderr)
    # An abandoned session left by a machine/host crash, then the actual reconcile CLI.
    stale = base/'stale-zone'; call=stale/'abandoned'; call.mkdir(parents=True)
    record = dict(sessionId='abandoned',status='open',startedAt=1,lastHeartbeat=1,audio={'bytesTotal':9,'parts':['audio-part-00.webm']})
    (call/'session.json').write_text(json.dumps(record)); (call/'audio-part-00.webm').write_bytes(b'synthetic')
    p = subprocess.run(['node',str(service/'bin/richos-service.js'),'reconcile','--zone',str(stale)],text=True,capture_output=True,timeout=20)
    results['abandoned_session']=dict(exit=p.returncode,stdout=p.stdout,stderr=p.stderr)
# Use the repository's isolated Git/session fixture and actual lifecycle implementation.
spec = importlib.util.spec_from_file_location('fixture',ROOT/'richos/engine/mega-lander/tests/workspaces.test.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
f = m.Base(); f.setUp(); child=None
try:
    name='echo-opus-audit'; work=f.make_cc(name)
    aid,native=f.spawn(name,work)
    code='''import signal,pathlib,time,sys
p=pathlib.Path('shutdown-result.txt')
def stop(s,f):
 p.write_text('unsaved result flushed during shutdown\\n')
 print('FLUSHED',flush=True)
 sys.exit(0)
signal.signal(signal.SIGTERM,stop)
print('READY',flush=True)
while True: time.sleep(.1)
'''
    child=subprocess.Popen([sys.executable,'-c',code],cwd=work,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert child.stdout.readline().strip()=='READY'
    before=m.ws.uncommitted(work)
    m.ws.record_end(f.sid,aid,'SubagentStop')
    # Reap the child normally as soon as SIGTERM finishes, so PID probing cannot confuse a zombie for a live process.
    waiter=threading.Thread(target=child.wait); waiter.start()
    answer=m.ws.land(name,f.sid)
    waiter.join(timeout=10)
    results['land_shutdown_write']=dict(before=before,answer=answer,child_exit=child.returncode,child_stdout=child.stdout.read(),worktree_exists=os.path.exists(work),result_exists=os.path.exists(os.path.join(work,'shutdown-result.txt')),main_result_exists=os.path.exists(os.path.join(f.other,'shutdown-result.txt')))
finally:
    if child and child.poll() is None: child.kill(); child.wait()
    f.tearDown()
# Compile a separate consumer of the real core crate. No product source edits.
with tempfile.TemporaryDirectory(prefix='richos-ledger-audit-build-') as temp:
    build = pathlib.Path(temp)
    (build/'src').mkdir()
    core = str(ROOT/'richos/app/crates/richos-core')
    (build/'Cargo.toml').write_text('[package]\nname="richos-third-audit-probe"\nversion="0.1.0"\nedition="2021"\n[dependencies]\nrichos-core={path='+json.dumps(core)+'}\n')
    shutil.copy2(pathlib.Path(__file__).with_name('ledger_probe.rs'),build/'src/main.rs')
    cargo = shutil.which('cargo') or str(pathlib.Path.home()/'.cargo/bin/cargo')
    env = dict(os.environ, CARGO_TARGET_DIR=str(build/'target'))
    env['PATH'] = str(pathlib.Path(cargo).parent)+os.pathsep+env.get('PATH','')
    p = subprocess.run([cargo,'run','--offline','--quiet','--manifest-path',str(build/'Cargo.toml')],capture_output=True,text=True,env=env,timeout=180)
    (OUT/'ledger-probe.log').write_text(p.stderr+p.stdout)
    results['torn_log_recovery'] = dict(exit=p.returncode, stdout=p.stdout)
(OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
