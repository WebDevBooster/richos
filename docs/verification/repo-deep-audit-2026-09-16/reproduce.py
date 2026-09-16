#!/usr/bin/env python3
"""Reproduce audit findings against an isolated, pinned source archive.

This asserts the defective behavior observed by the audit. It is not a passing
regression suite for a repaired product. No real provider or account is used.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=HERE.parents[2])
parser.add_argument('--revision', default='ef2f0c87f808951e1fd2da3802accb2c17ebc4c2')
args = parser.parse_args()
node = shutil.which('node')
cargo = shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
if not node or not Path(cargo).is_file():
    raise SystemExit('Node and Cargo are required.')
root = Path(tempfile.mkdtemp(prefix='richos-audit-reproduce-')).resolve()
archive = root / 'source.tar'
subprocess.run(['git', '-C', str(args.repo), 'archive', args.revision, '-o', str(archive)], check=True)
with tarfile.open(archive) as source:
    source.extractall(root, filter='data')
archive.unlink()
print(f'Isolated source and logs: {root}', flush=True)

def run(command, name, cwd):
    with (root / name).open('w') as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    print((root / name).read_text(), flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)

run([node, str(HERE / 'loro-probes.mjs'), str(root)], 'loro-results.log', root)
native = root / 'richos/app/crates/richos-core/src/native.rs'
original = native.read_text()
marker = '    #[test]\n    fn nested_worker_text_and_results_never_become_the_leads_conversation()'
if original.count(marker) != 1:
    raise SystemExit('Native test insertion point changed. Review the probe before adapting it.')
native.write_text(original.replace(marker, (HERE / 'native-probe.rs').read_text() + '\n' + marker, 1))
try:
    run([cargo, 'test', '--locked', '-p', 'richos-core', '--lib',
         'audit_damaged_worker_evidence', '--', '--nocapture'], 'native-results.log', root / 'richos/app')
finally:
    native.write_text(original)
