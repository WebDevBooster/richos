#!/usr/bin/env python3
"""Verify indexed artifact bytes and R6 source identity in this checkout."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[4])
parser.add_argument('--public-only', action='store_true', help='Explicitly skip private local originals.')
args = parser.parse_args()
repo = args.repo.resolve(strict=True)
root = repo / 'docs/verification/owned-outcome/evidence-r6'
index = json.loads((root / 'artifact-index.json').read_text())
known = {'artifact-index.json', 'source-identity.json', '.gitattributes'}
verified = skipped = 0
for item in index['records']:
    if 'copy' in item:
        path = repo / item['copy']
        known.add(str(path.relative_to(root)))
    elif args.public_only:
        skipped += 1
        continue
    else:
        path = Path(item['private_copy'])
    raw = path.read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256'], path
    verified += 1
actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
assert actual == known, {'unexpected': sorted(actual - known), 'missing': sorted(known - actual)}
identity = json.loads((root / 'source-identity.json').read_text())
for name, digest in identity['files'].items():
    assert hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest, name
print(json.dumps({'verified_artifacts': verified, 'explicitly_skipped_private': skipped,
                  'source_files': len(identity['files']), 'unexpected_files': 0}))
