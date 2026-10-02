#!/usr/bin/env bash
# renew-verification-pins.py on a fixture repository and map: every pin naming the changed
# file is renewed, a same-named file elsewhere is not, an unpinned file is reported, not added.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -B - "$HERE/renew-verification-pins.py" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path

tool = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='renew-pins-', dir=os.environ.get('TMPDIR')) as tmp:
    root = Path(tmp)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    for rel in ('richos/engine/scripts/lib/a.py', 'richos/app/scripts/lib/a.py', 'richos/engine/scripts/lib/b.py'):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text('# %s\n' % rel)
    old = '0' * 64
    document = {
        'nodes': {'scripts/lib/a.py': {'source': 'scripts/lib/a.py', 'sha256': old, 'edges': [
                      {'root': 'repository', 'path': 'richos/engine/scripts/lib/a.py', 'sha256': old},
                      {'root': 'repository', 'path': 'richos/app/scripts/lib/a.py', 'sha256': old}]}},
        'hook_readers': {'x.test.sh': {'sources': {'scripts/lib/a.py': old, 'scripts/lib/c.py': old}}}}
    lib = root / 'richos/engine/scripts/lib'
    (lib / 'verification-dependencies.json').write_text(json.dumps(document, indent=2) + '\n')
    result = subprocess.run([sys.executable, '-B', tool, '--map', str(lib / 'verification-dependencies.json'),
                             str(lib / 'a.py'), str(lib / 'b.py')], capture_output=True, text=True, check=True)
    after = json.loads((lib / 'verification-dependencies.json').read_text())
    new = hashlib.sha256((lib / 'a.py').read_bytes()).hexdigest()
    node = after['nodes']['scripts/lib/a.py']
    assert node['sha256'] == new, node
    assert node['edges'][0]['sha256'] == new, node
    assert node['edges'][1]['sha256'] == old, 'the app file of the same name was renewed'
    assert after['hook_readers']['x.test.sh']['sources'] == {'scripts/lib/a.py': new, 'scripts/lib/c.py': old}
    assert 'not pinned (left alone): richos/engine/scripts/lib/b.py' in result.stdout, result.stdout
    assert 'b.py' not in json.dumps(after), 'an unpinned file was added'
print('renew-verification-pins: 5/5')
PY
