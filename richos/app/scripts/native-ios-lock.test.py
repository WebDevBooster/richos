#!/usr/bin/env python3
"""Exercise the built CLI's real file lock, including a dead legacy owner."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='rios-lock.') as tmp:
    cache = Path(tmp)
    env = {**os.environ, 'RICHOS_NATIVE_IOS_CACHE': tmp}
    def run(ok):
        r = subprocess.run([binary, 'headless', 'state'], env=env, capture_output=True, text=True, timeout=10)
        assert (r.returncode == 0) == ok, r.stdout + r.stderr
        return r
    run(True)
    lock = cache / 'headless.lock.flock'
    assert lock.exists(), 'CLI did not create the persistent kernel lock'
    with lock.open('a') as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert 'Another rios command owns' in run(False).stderr
    run(True)
    ready = cache / 'ready'
    code = ('import fcntl,sys,time; f=open(sys.argv[1],"a");fcntl.flock(f,fcntl.LOCK_EX);'
            'open(sys.argv[2],"w").write("ready");time.sleep(60)')
    owner = subprocess.Popen([sys.executable, '-c', code, str(lock), str(ready)])
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        assert ready.exists(), 'lock holder did not start'
        run(False)
        owner.kill()
        owner.wait(timeout=5)
        run(True)
        legacy = cache / 'headless.lock'
        legacy.mkdir()
        (legacy / 'owner.json').write_text(json.dumps({'pid': owner.pid}))
        run(True)
        assert not legacy.exists(), 'dead legacy owner was not recovered'
        legacy.mkdir()
        (legacy / 'owner.json').write_text(json.dumps({'pid': os.getpid()}))
        assert 'live or unverified' in run(False).stderr
        assert legacy.exists(), 'live legacy owner was removed'
        (legacy / 'owner.json').write_text('broken')
        run(False)
        assert legacy.exists(), 'unverified legacy owner was removed'
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=5)
print('7 command-lock checks passed: exclusion, release, crash recovery and conservative legacy migration')
