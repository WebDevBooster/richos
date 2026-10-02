#!/usr/bin/env python3
"""qualification-pins.py — renew the SHA-256 pins in docs/development/verification-input-qualifications.json.

WHY (2026-10-01): every handoff that changes a file a reviewed check reads has to renew that
file's pin in the qualification record. The commit hook refuses the commit and says how; a
night of thirteen handoffs hand-edited those pins with sed, and one agent wrote a throwaway
helper. This is that helper, committed (a helper you needed and did not find is added to the
toolkit). It is the qualification-record twin of dependency-pins.py --renew.

  qualification-pins.py --renew [PATH..]  set every "sources" pin of each repository-relative
                                          PATH to the working-tree bytes. With no PATH: every
                                          pinned file that differs from its pin (so it also
                                          covers a file changed in an earlier commit). Prints
                                          each pin it moved. A pinned file that no longer
                                          exists is refused, never silently dropped.
  qualification-pins.py --all             list every stale pin; exit 1 when there is one
                                          (read-only)

Only the 64-hex digest after the path is rewritten, in place, so the file's formatting, key
order and every "review" text stay byte-identical. A changed file's unit "review" text still
has to be re-read by a human: renewing the pin does not say the review is still true.

The hash is `shasum -a 256 <file>` over the raw bytes, which is what the commit hook compares.
The repository root is the current directory's Git top (override: QUALIFICATION_PINS_TOP).
"""
import hashlib
import json
import os
import re
import subprocess
import sys

RECORD = "docs/development/verification-input-qualifications.json"


def top():
    if os.environ.get("QUALIFICATION_PINS_TOP"):
        return os.path.abspath(os.environ["QUALIFICATION_PINS_TOP"])
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                         stdin=subprocess.DEVNULL)
    if out.returncode:
        raise SystemExit("qualification-pins: not inside a Git repository")
    return out.stdout.strip()


def sha(root, path):
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return None
    with open(full, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def pins(data):
    """[(unit, path, pinned digest)]."""
    return [(unit, path, pin)
            for unit, body in sorted((data.get("units") or {}).items())
            for path, pin in sorted((body.get("sources") or {}).items())]


def stale(root, data):
    return [(u, p, pin, sha(root, p)) for u, p, pin in pins(data) if sha(root, p) != pin]


def renew(root, wanted):
    record = os.path.join(root, RECORD)
    with open(record, encoding="utf-8", newline="") as handle:
        text = handle.read()
    data = json.loads(text)
    targets = sorted(set(wanted) if wanted else {p for _, p, _, _ in stale(root, data)})
    known = {p for _, p, _ in pins(data)}
    for path in targets:
        if path not in known:
            print(f"qualification-pins: {path} is not pinned in {RECORD}; nothing to renew")
    moved = 0
    for path in sorted(set(targets) & known):
        now = sha(root, path)
        if now is None:
            raise SystemExit(f"qualification-pins: pinned file {path} no longer exists; "
                             f"remove its pin by hand after reading the unit's review text")
        pattern = re.compile(r'("' + re.escape(path) + r'"\s*:\s*")([0-9a-f]{64})(")')
        def swap(match):
            nonlocal moved
            if match.group(2) != now:
                moved += 1
                print(f"renewed {path}: {match.group(2)[:12]} -> {now[:12]}")
            return match.group(1) + now + match.group(3)
        text = pattern.sub(swap, text)
    with open(record, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    json.loads(text)
    left = stale(root, json.loads(text))
    print(f"qualification-pins: {moved} pin(s) renewed; stale now: {len(left)}")
    for unit, path, _, _ in left:
        print(f"  still stale: {path} (unit \"{unit}\")")
    return 0


def main(argv):
    root = top()
    if argv[:1] == ["--all"] and len(argv) == 1:
        with open(os.path.join(root, RECORD), encoding="utf-8") as handle:
            found = stale(root, json.load(handle))
        for unit, path, pin, now in found:
            print(f"{path} (unit \"{unit}\"): pinned {pin[:12]}, now {(now or '(removed)')[:12]}")
        return 1 if found else 0
    if argv[:1] == ["--renew"]:
        return renew(root, argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
