#!/usr/bin/env bash
# Terminal entrypoint authorization and state-path tests. No live account access.
# run-tests: inputs richos/app/scripts/terminal-quota.test.sh richos/app/Cargo.toml richos/app/Cargo.lock richos/app/crates/richos-core richos/engine/scripts/quota-reset.sh
# run-tests: covers richos/app/crates/richos-core/src/bin/richos-quota.rs richos/app/crates/richos-core/examples/terminal_quota_proof.rs richos/app/crates/richos-core/src/quota/terminal.rs
# run-tests: no-host-screen: richos-quota and terminal_quota_proof are command-line binaries, and the "RichOS.app" it runs is a two-line shell stand-in in a temporary HOME that prints its arguments and exits; nothing is drawn
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
build=subprocess.run(['cargo','build','--quiet','-p','richos-core','--bin','richos-quota',
    '--example','terminal_quota_proof','--message-format=json'],capture_output=True,text=True,timeout=240,check=True)
exe={r['target']['name']:r['executable'] for line in build.stdout.splitlines()
     if (r:=json.loads(line)).get('reason')=='compiler-artifact' and r.get('executable')}
with tempfile.TemporaryDirectory(prefix='terminal-quota-cli-') as d:
    root=pathlib.Path(d)
    env={**os.environ,'HOME':d,'ANTHROPIC_API_KEY':'fixture-auth-override'}
    def call(*args):
        return subprocess.run([exe['richos-quota'],*args],env=env,stdin=subprocess.DEVNULL,
            capture_output=True,text=True,timeout=10)
    for args in [('approve','offer'),('approve','offer','--yes'),('--unknown',)]:
        r=call(*args);assert r.returncode==2,(args,r)
    assert not list(root.iterdir()),'refused approvals wrote state'
    r=call('status');assert r.returncode==2 and 'overrides' in r.stderr,r
    assert not list(root.iterdir()),'refused connection wrote state'
    r=call('revoke');assert r.returncode==0,r
    assert json.loads(r.stdout)['protocol']=='--richos-quota-v1'
    assert b'--richos-quota-v1' in pathlib.Path(exe['richos-quota']).read_bytes()
    record=root/'Library/Application Support/com.richos.app/claude-reset-offers.json' if os.uname().sysname=='Darwin' else root/'.local/share/com.richos.app/claude-reset-offers.json'
    assert json.loads(record.read_text())['view']['approval'] is None
    r=subprocess.run([exe['terminal_quota_proof']],env=env,capture_output=True,text=True,timeout=10)
    assert r.returncode!=0 and 'Requires --live-no-redemption' in r.stderr
    fakebin=root/'bin';fakebin.mkdir()
    cargo=fakebin/'cargo'
    cargo.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n');cargo.chmod(0o700)
    wrapper=pathlib.Path('../engine/scripts/quota-reset.sh').resolve()
    r=subprocess.run([str(wrapper),'tick'],env={**env,'PATH':str(fakebin)+':/usr/bin:/bin'},capture_output=True,text=True,timeout=10)
    assert r.returncode==0 and r.stdout.splitlines()[-2:]==['--','tick'],r
    import shutil
    installed=root/'installed/engine/scripts';installed.mkdir(parents=True)
    shutil.copy(wrapper,installed/'quota-reset.sh')
    app=root/'Applications/RichOS.app/Contents/MacOS/richos-tauri';app.parent.mkdir(parents=True)
    app.write_text('#!/bin/sh\necho GUI-WAS-LAUNCHED\n');app.chmod(0o700)
    r=subprocess.run([str(installed/'quota-reset.sh'),'tick'],env=env,capture_output=True,text=True,timeout=10)
    assert 'GUI-WAS-LAUNCHED' not in r.stdout,'old app was launched'
    app.write_text('#!/bin/sh\n# --richos-quota-v1\nprintf "%s\\n" "$@"\n')
    r=subprocess.run([str(installed/'quota-reset.sh'),'tick'],env=env,capture_output=True,text=True,timeout=10)
    assert r.returncode==0 and r.stdout.splitlines()==['--richos-quota-v1','tick'],r
print('  PASS  noninteractive approval refusal, no yes flag, no credential read on refusal, shared desktop state path, revoke, live-proof opt-in and headless wrapper')
PY
