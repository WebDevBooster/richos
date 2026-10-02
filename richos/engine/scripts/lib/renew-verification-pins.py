#!/usr/bin/env python3
"""Renew the sha256 pins the verification maps hold for files you changed.

    renew-verification-pins.py [--map FILE] PATH [PATH ...]

The maps (both, unless --map names one): richos/engine/scripts/lib/verification-dependencies.json
(the engine's dependency map) and docs/development/verification-input-qualifications.json (the
reviewed checks' qualified readers; the commit and the merge refuse a stale pin there).

PATH is a file in this repository (absolute, or relative to the current directory). Every
pin in verification-dependencies.json that names that file (a `path`/`source` entry with a
`sha256`, or a `sources` map entry) is set to the file's CURRENT content hash, and each change
is printed. Nothing else in the map is touched, and a PATH no pin names is reported, not
added: adding a pin is a review decision (its `evidence`), renewing one after an edit is not.

scripts/verification-inputs.test.sh is the check that the pins are current; this is the
mechanical half of keeping it green after an edit (until 2026-10-02 every engineer did it
by hand).
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

MAP = Path(__file__).resolve().with_name('verification-dependencies.json')
QUALIFICATIONS = Path(__file__).resolve().parents[4] / 'docs/development/verification-input-qualifications.json'


def repository_root(map_path):
    return Path(subprocess.run(['git', '-C', str(map_path.parent), 'rev-parse', '--show-toplevel'],
                               capture_output=True, text=True, check=True).stdout.strip()).resolve()


ENGINE = 'richos/engine/'


def names(pin, relative):
    """A pin path is repository-relative (richos/engine/...) or engine-relative (scripts/...).
    Never a suffix match: richos/app/scripts/lib/X is not the engine's scripts/lib/X."""
    return relative in (pin, ENGINE + pin)


def renew(document, relative, digest, changes):
    def walk(node, where):
        if isinstance(node, dict):
            for key in ('path', 'source'):
                pin = node.get(key)
                if isinstance(pin, str) and 'sha256' in node and names(pin, relative):
                    if node['sha256'] != digest:
                        changes.append('%s %s: %s -> %s' % (where, pin, node['sha256'][:12], digest[:12]))
                        node['sha256'] = digest
                    else:
                        changes.append('%s %s: already current' % (where, pin))
                    break
            sources = node.get('sources')
            if isinstance(sources, dict):
                for pin, value in list(sources.items()):
                    if isinstance(value, str) and names(pin, relative):
                        if value != digest:
                            changes.append('%s sources[%s]: %s -> %s' % (where, pin, value[:12], digest[:12]))
                            sources[pin] = digest
                        else:
                            changes.append('%s sources[%s]: already current' % (where, pin))
            for key, value in node.items():
                walk(value, '%s/%s' % (where, key))
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, '%s[%d]' % (where, index))
    walk(document, '')


def renew_map(map_path, paths):
    root = repository_root(map_path)
    document = json.loads(map_path.read_text())
    unpinned = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        changes = []
        renew(document, relative, digest, changes)
        if not changes:
            unpinned.append(relative)
        for line in changes:
            print('%s: %s' % (map_path.name, line))
    map_path.write_text(json.dumps(document, indent=2) + '\n')
    for relative in unpinned:
        print('%s: not pinned (left alone): %s' % (map_path.name, relative))


def main(argv):
    maps = [MAP, QUALIFICATIONS]
    if argv[:1] == ['--map'] and len(argv) > 1:
        maps, argv = [Path(argv[1]).resolve()], argv[2:]
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    paths = [Path(raw).resolve() for raw in argv]
    for map_path in maps:
        if map_path.is_file():
            renew_map(map_path, paths)
        else:
            print('no map at %s (left alone)' % map_path)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
