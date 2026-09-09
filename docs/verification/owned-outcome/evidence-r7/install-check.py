#!/usr/bin/env python3
"""Run the actual installer in a disposable engine copy, never a live install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[4])
args = parser.parse_args()
repo = args.repo.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix='richos-r7-install-'))
engine = root / 'engine'
shutil.copytree(repo / 'engine', engine, ignore=shutil.ignore_patterns('*.sha256', '__pycache__'))
config = root / 'config'
config.mkdir()
pointer = Path.home() / '.claude/richos-engine'
before = os.readlink(pointer) if pointer.is_symlink() else None
env = {**os.environ, 'CLAUDE_CONFIG_DIR': str(config), 'RICHOS_LAUNCH_AGENTS_DIR': str(root / 'plists')}
# Inherited test overrides must not opt this disposable check into launchctl.
env.pop('RICHOS_LAUNCHD_LABEL', None)
argv = ['bash', str(engine / 'scripts/hooks/install.sh')]
result = subprocess.run(argv, cwd=engine, env=env, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
(root / 'install.log').write_text(result.stdout)
checks = {}
hashes = {}
for name in ('owned-work-policy.sh', 'owned-dispatch.py', 'owned-session.py'):
    source = engine / 'scripts/lib' / name
    sidecar = Path(str(source) + '.sha256')
    hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    checks[name] = sidecar.is_file() and sidecar.read_text().split()[0] == hashes[name]
after = os.readlink(pointer) if pointer.is_symlink() else None
record = {'argv': argv, 'exit': result.returncode, 'checks': checks,
          'production_pointer_unchanged': before == after, 'production_activation': False,
          'source_hashes': hashes}
record['passed'] = result.returncode == 0 and all(checks.values()) and before == after
(root / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'directory': str(root), **record}))
raise SystemExit(0 if record['passed'] else 1)
