#!/usr/bin/env bash
# richos/mobile/native-android/bin/build-timing.py with a stand-in randroid: four builds in
# order, the Kotlin edit present for the incremental build only and ALWAYS taken out, a file
# with uncommitted changes refused untouched. No Gradle, no build, no device.
# run-tests: no-host-screen: a stand-in randroid and a temporary git repository; no window, no device
# run-tests: inputs richos/mobile/native-android/bin/build-timing.py richos/app/scripts/native-android-build-timing.test.sh
# run-tests: covers richos/mobile/native-android/bin/build-timing.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../../mobile/native-android/bin/build-timing.py"
export PYTHONDONTWRITEBYTECODE=1
python3 -B - "$TOOL" <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path

tool = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='build-timing-', dir=os.environ.get('TMPDIR')) as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    repo.mkdir()
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.invalid',
           'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'}
    source = repo / 'Marks.kt'
    original = b'object Marks\n'
    source.write_bytes(original)
    subprocess.run(['git', 'init', '-q', str(repo)], check=True, env=env)
    subprocess.run(['git', '-C', str(repo), 'add', '-A'], check=True, env=env)
    subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'fixture'], check=True, env=env)
    seen = root / 'seen'
    fake = root / 'randroid'
    fake.write_text('#!/bin/sh\n'
                    'echo "native-work: 1 core; stand-in (admitted after 0.5 s)" >&2\n'
                    'if grep -q BUILD_TIMING_PROBE "%s"; then echo edited >> "%s"; else echo clean >> "%s"; fi\n'
                    % (source, seen, seen))
    fake.chmod(0o755)
    run_env = {**env, 'BUILD_TIMING_RANDROID': str(fake), 'RICHOS_CPU_GUARD_STATE': str(root / 'no-guard')}
    result = subprocess.run([sys.executable, '-B', tool, '--edit', str(source)], capture_output=True, text=True,
                            env=run_env)
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert [b['build'] for b in report['builds']] == ['prime', 'no-op', 'incremental', 'revert'], report
    assert all(b['exit'] == 0 and b['native_work'] == ['native-work: 1 core; stand-in (admitted after 0.5 s)']
               and b['admitted_after'] == 0.5 and b['build_seconds'] == round(b['seconds'] - 0.5, 1)
               for b in report['builds']), report
    assert seen.read_text().split() == ['clean', 'clean', 'edited', 'clean'], seen.read_text()
    assert source.read_bytes() == original, 'the edit was left behind'
    source.write_bytes(original + b'// somebody else\n')
    refused = subprocess.run([sys.executable, '-B', tool, '--edit', str(source)], capture_output=True, text=True,
                             env=run_env)
    assert refused.returncode == 2 and 'uncommitted' in refused.stderr, refused
    assert source.read_bytes() == original + b'// somebody else\n', 'a dirty file was touched'
    assert seen.read_text().split() == ['clean', 'clean', 'edited', 'clean'], 'a refused run built'
print('build-timing: 6/6')
PY
