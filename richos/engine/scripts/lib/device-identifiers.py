#!/usr/bin/env python3
"""device-identifiers.py — the deny-list of the owner's OWN test devices.

WHAT IT REFUSES. A staged file whose text, or whose path, contains an identifier of
a known test device: an Android serial, an iPhone hardware UDID, a CoreDevice UUID,
a tailnet hostname. Four public audit files carried an Android serial for two
weeks (2026-09-19 to 2026-10-02) because nothing looked for one: a serial is not a
secret to a secret scanner, and not a person's name to the named-person list.

WHERE THE LIST LIVES. `~/.richos-privacy/device-identifiers`, operator scope, next
to `named-persons`; `RICHOS_DEVICE_IDENTIFIERS_FILE` overrides it (tests, an
encrypted volume). One identifier per line; `#` starts a comment. It is NEVER in a
repository, and a list that resolves inside a git work tree is BROKEN, because the
file is a roster of the owner's hardware and publishing it is the leak.

THE FOUR VERDICTS (first line of output, tab-separated):
  CLEAN   nothing matched.
  FOUND   one or more matches; following lines are `<label>\t<masked preview>`.
  ABSENT  no list on this machine. This is "nothing was checked", NOT "clean": the
          caller announces it. A public clone has no list and must not be blocked
          by that, but must be told.
  BROKEN  a list that cannot be trusted (inside a work tree, unreadable, entry
          shorter than MIN_LEN, or no entries). The caller refuses.

MATCH RULE. Case-insensitive substring, over the file's text AND its path. An
identifier shorter than MIN_LEN (8) is BROKEN rather than matched, because a
three-letter entry would refuse half the tree and the guard would be turned off.

OUTPUT NEVER QUOTES AN IDENTIFIER. The preview keeps the first two characters and
masks the rest: a refusal that printed the serial would be a second copy of it in
terminal scrollback.

Usage:
  device-identifiers.py --scan-manifest <manifest-file>   rows: label<TAB>blobpath[<TAB>...]
  device-identifiers.py --list-path
"""
import os
import subprocess
import sys

MIN_LEN = 8


def list_path():
    env = os.environ.get('RICHOS_DEVICE_IDENTIFIERS_FILE')
    if env:
        return env
    return os.path.join(os.path.expanduser('~'), '.richos-privacy', 'device-identifiers')


def _inside_work_tree(path):
    folder = os.path.dirname(os.path.realpath(path)) or '.'
    try:
        out = subprocess.run(['git', '-C', folder, 'rev-parse', '--is-inside-work-tree'],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return out.returncode == 0 and out.stdout.strip() == 'true'


def load():
    """(verdict, identifiers-or-reason). verdict is OK, ABSENT or BROKEN."""
    path = list_path()
    if not os.path.exists(path):
        return 'ABSENT', path
    if _inside_work_tree(path):
        return 'BROKEN', ('the device-identifier list at %s is inside a git work tree; it is a '
                          'roster of the owner\'s hardware and must live outside every repository' % path)
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError) as err:
        return 'BROKEN', 'the device-identifier list at %s is unreadable (%s)' % (path, err)
    ids = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if len(line) < MIN_LEN:
            return 'BROKEN', ('an entry in %s is shorter than %d characters; a short entry would '
                              'match half the tree. Remove or lengthen it' % (path, MIN_LEN))
        ids.append(line)
    if not ids:
        return 'BROKEN', 'the device-identifier list at %s has no entries' % path
    return 'OK', ids


def mask(value):
    return value[:2] + '*' * max(len(value) - 2, 4)


def scan_manifest(manifest):
    verdict, payload = load()
    if verdict == 'ABSENT':
        print('ABSENT\t%s' % payload)
        return 0
    if verdict == 'BROKEN':
        print('BROKEN\t%s' % payload)
        return 0
    wanted = [(i, i.lower()) for i in payload]
    found = []
    with open(manifest, encoding='utf-8') as fh:
        for row in fh:
            row = row.rstrip('\n')
            if not row:
                continue
            parts = row.split('\t')
            label, blob = parts[0], parts[1]
            try:
                with open(blob, 'rb') as bh:
                    raw = bh.read()
            except OSError:
                continue
            haystacks = [label.lower(), raw.decode('utf-8', 'ignore').lower(),
                         raw.decode('utf-16', 'ignore').lower() if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else '']
            for original, low in wanted:
                if any(low in h for h in haystacks if h):
                    found.append((label, mask(original)))
                    break
    if found:
        print('FOUND')
        for label, preview in found:
            print('%s\t%s' % (label, preview))
    else:
        print('CLEAN')
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == '--list-path':
        print(list_path())
        return 0
    if len(argv) == 3 and argv[1] == '--scan-manifest':
        return scan_manifest(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
