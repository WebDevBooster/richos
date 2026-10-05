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
          shorter than MIN_LEN, or no entries), or a staged blob the scan could
          not read. The caller refuses.

MATCH RULE. Case-insensitive substring, over the file's text AND its path. An
identifier shorter than MIN_LEN (8) is BROKEN rather than matched, because a
three-letter entry would refuse half the tree and the guard would be turned off.

OUTPUT NEVER QUOTES AN IDENTIFIER. The preview keeps the first two characters and
masks the rest: a refusal that printed the serial would be a second copy of it in
terminal scrollback.

Usage:
  device-identifiers.py --scan-manifest <manifest-file>   rows: label<TAB>blobpath[<TAB>...]
  device-identifiers.py --scan-tree <repo>                 the whole INDEX of <repo>, text and paths
  device-identifiers.py --list-path

--scan-tree is the merge gate's check (autocheck land_check): the commit-time scan above
sees only what a commit ADDS, so an identifier that reached a branch before the list
existed, or that a merge carried in, was never looked at. This one reads the tree being
landed, and each row is `path:line<TAB>masked preview` (a path match has no line).
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
    unread = []
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
                # Hunt P5-08 (v3): a blob that could not be read was not checked, so
                # the scan cannot say CLEAN; its path is still matched below.
                unread.append(label)
                raw = b''
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
    elif unread:
        print('BROKEN\t%d staged file(s) could not be read, so they were not checked: %s'
              % (len(unread), ', '.join(unread[:5])))
    else:
        print('CLEAN')
    return 0


def scan_tree(repo):
    verdict, payload = load()
    if verdict in ('ABSENT', 'BROKEN'):
        print('%s\t%s' % (verdict, payload))
        return 0
    found = []
    try:
        listing = subprocess.run(['git', '-C', repo, 'ls-files', '-z'], capture_output=True,
                                 timeout=120, check=True).stdout.decode('utf-8', 'ignore')
        for ident in payload:
            low = ident.lower()
            for name in listing.split('\0'):
                if name and low in name.lower():
                    found.append((name, mask(ident)))
            # The same case-insensitive substring rule as the commit scan; -a reads binary files too.
            out = subprocess.run(['git', '-C', repo, 'grep', '--cached', '-a', '-n', '-i', '-F', '-z',
                                  '-e', ident], capture_output=True, timeout=300)
            if out.returncode not in (0, 1):
                print('BROKEN\tthe index could not be searched (exit %d)' % out.returncode)
                return 0
            for hit in out.stdout.split(b'\n'):
                parts = hit.split(b'\0')
                if len(parts) >= 3 and parts[0]:
                    found.append(('%s:%s' % (parts[0].decode('utf-8', 'replace'),
                                             parts[1].decode('ascii', 'replace')), mask(ident)))
    except (OSError, subprocess.SubprocessError) as err:
        print('BROKEN\tthe tree scan could not run (%s)' % type(err).__name__)
        return 0
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
    if len(argv) == 3 and argv[1] == '--scan-tree':
        return scan_tree(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
