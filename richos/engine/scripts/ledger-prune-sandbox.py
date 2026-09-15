#!/usr/bin/env python3
"""Remove PROVABLY DEAD test-sandbox rows from the worktree ownership ledger.

===========================================================================
WHY THIS EXISTS
===========================================================================
`~/.claude/state/worktree-ledger.jsonl` is the durable ownership record named
in CLAUDE.md. It lives outside every repository and every session directory,
which is exactly what makes it authoritative -- and exactly what makes a test
suite's stray write permanent.

`worktree-ledger.py:184` resolves the ledger from `expanduser("~")`, and
`ledger_path()` honors ONE override, `RICHOS_WORKTREE_LEDGER`. It does NOT
read `CLAUDE_CONFIG_DIR` (demo.sh:139-142 records the experiment that proved
it: HOME and CLAUDE_CONFIG_DIR pointed at two different empty directories and
every file landed under HOME/.claude). So a suite that sandboxes itself with
`CLAUDE_CONFIG_DIR` alone, and then drives a real hook, appends fixture rows
to the OPERATOR'S OWN LEDGER.

Measured 2026-09-14 on this machine: 5,235 of 21,994 rows name a path under
the system temp directory. They were written by real engine hooks
(worker-ended-handoff.sh, teammate-idle-handoff.sh, task-completed-handoff.sh,
detect-nonnative-worktree.sh) driven by suites against mkdtemp repositories.

===========================================================================
WHAT IT WILL AND WILL NOT REMOVE  --  THE SAFETY IS THE POINT
===========================================================================
A row is removed ONLY when all four hold. Anything else stays, and the count
that stayed is reported rather than quietly absorbed:

  1. It parses as a JSON object.                  (an unparseable line STAYS)
  2. It names at least one path.                  (a path-less row STAYS)
  3. EVERY path it names is under a temp root.    (one real path -> STAYS)
  4. NONE of those paths exists on disk.          (a live sandbox -> STAYS)

And one belt-and-braces refusal on top: a row mentioning `codex` anywhere is
never removed, whatever else is true of it. ceo-decisions.md section 31 says a
Codex workspace is not touched without the CEO's express word, and a cleaner
is not the place to find out that rule has an edge.

Condition 3 is what makes this safe rather than merely careful. A row that
names a real workspace is a row some reader may still resolve, so it is not
this tool's business even if it also names a sandbox. Measured: 0 such rows
today, which is a fact worth re-measuring rather than assuming.

Condition 4 is deliberately generous to the file: a mkdtemp directory that
still exists might belong to a suite running RIGHT NOW. 163 rows stayed for
this reason on the first run.

===========================================================================
CONCURRENCY -- THE LEDGER IS APPENDED TO WHILE THIS RUNS
===========================================================================
Hooks append without taking a lock, so this tool cannot take one that would
stop them. Instead it preserves the tail: it records the byte offset it read
to, and before swapping the file in it copies any bytes that arrived past that
offset VERBATIM onto the end of the replacement, repeating until the file
stops growing. Rows that arrive in the final milliseconds before os.replace()
are the residual race; run this when the machine is idle. Nothing is ever
rewritten -- kept lines are copied byte-for-byte, so the append-only record
stays byte-identical for every row that survives.

Idempotent by construction: a second run finds nothing left that satisfies all
four conditions and rewrites nothing.

Usage:
    ledger-prune-sandbox.py                 # census only, changes nothing
    ledger-prune-sandbox.py --apply         # back up, then prune
    ledger-prune-sandbox.py --ledger PATH --backup-dir DIR
"""

import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone

DEFAULT_LEDGER = os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-ledger.jsonl")
DEFAULT_BACKUP_DIR = os.path.join(os.path.expanduser("~"), ".claude", "state", "ledger-backups")

# The system temp roots a mkdtemp sandbox lands in. macOS hands out
# /var/folders/<x>/<y>/T/... and reports it as /private/var/... once resolved;
# Linux and an explicit TMPDIR give /tmp/...
TEMP_ROOT_RE = re.compile(
    r"^(?:/private)?/var/folders/[^/]+/[^/]+/T/"
    r"|^(?:/private)?/tmp/"
)

PATH_FIELDS = ("repo", "worktree", "cwd")

# Never removed, whatever else is true. See module docstring.
PROTECTED_SUBSTRINGS = ("codex",)


def row_paths(row):
    """Every filesystem path this row names, in no particular order."""
    out = []
    for f in PATH_FIELDS:
        v = row.get(f)
        if isinstance(v, str) and v.strip():
            out.append(v)
    for w in row.get("workspaces") or []:
        if isinstance(w, str) and w.strip():
            out.append(w)
    return out


def is_temp_path(p):
    return bool(TEMP_ROOT_RE.match(p))


def classify(line):
    """(verdict, reason) for one raw ledger line.

    verdict is 'dead' only when every condition in the module docstring holds.
    Every other verdict keeps the line.
    """
    s = line.strip()
    if not s:
        return "blank", "empty line"
    try:
        row = json.loads(s)
    except Exception:
        return "keep", "unparseable - never removed"
    if not isinstance(row, dict):
        return "keep", "not a JSON object"
    low = s.lower()
    for tok in PROTECTED_SUBSTRINGS:
        if tok in low:
            return "keep", "protected: mentions %r" % tok
    paths = row_paths(row)
    if not paths:
        return "keep", "names no path"
    if not all(is_temp_path(p) for p in paths):
        return "keep", "names a real (non-temp) path"
    existing = [p for p in paths if os.path.exists(p)]
    if existing:
        return "keep", "sandbox still on disk: %s" % existing[0]
    return "dead", "all paths under a temp root and none exists"


def census(lines):
    kept, dead, reasons = [], 0, {}
    for ln in lines:
        v, why = classify(ln)
        if v == "dead":
            dead += 1
        else:
            if v != "blank":
                kept.append(ln)
            # a blank line is dropped silently; it carries no record
        if v == "keep":
            head = why.split(":")[0]
            reasons[head] = reasons.get(head, 0) + 1
    return kept, dead, reasons


def read_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = f.read()
    return data.splitlines(True), len(data.encode("utf-8", "replace"))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ledger", default=os.environ.get("RICHOS_WORKTREE_LEDGER") or DEFAULT_LEDGER)
    ap.add_argument("--backup-dir", default=DEFAULT_BACKUP_DIR)
    ap.add_argument("--apply", action="store_true",
                    help="actually rewrite the ledger (default: census only)")
    ap.add_argument("--no-backup", action="store_true",
                    help="skip the backup (refused on the operator's real ledger)")
    args = ap.parse_args(argv)

    path = args.ledger
    if not os.path.exists(path):
        print("ledger not found: %s" % path, file=sys.stderr)
        return 1
    if args.no_backup and os.path.realpath(path) == os.path.realpath(DEFAULT_LEDGER):
        print("refusing --no-backup on the operator's real ledger", file=sys.stderr)
        return 2

    lines, size = read_lines(path)
    kept, dead, reasons = census(lines)

    print("ledger       : %s" % path)
    print("rows before  : %d  (%d bytes)" % (len(lines), size))
    print("provably dead: %d" % dead)
    print("rows after   : %d" % len(kept))
    if reasons:
        print("kept because :")
        for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print("    %7d  %s" % (v, k))

    if not args.apply:
        print("\nCENSUS ONLY - nothing was changed. Re-run with --apply.")
        return 0
    if dead == 0:
        print("\nnothing to remove; ledger left untouched (idempotent).")
        return 0

    if not args.no_backup:
        os.makedirs(args.backup_dir, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = os.path.join(args.backup_dir, "worktree-ledger.%s.jsonl" % stamp)
        shutil.copy2(path, backup)
        with open(backup, "r", encoding="utf-8", errors="replace") as f:
            nb = sum(1 for _ in f)
        if nb < len(lines):
            print("BACKUP SHORT (%d < %d) - refusing to prune" % (nb, len(lines)), file=sys.stderr)
            return 3
        print("\nbackup       : %s  (%d rows)" % (backup, nb))

    tmp = path + ".prune.tmp"
    with open(tmp, "w", encoding="utf-8") as out:
        for ln in kept:
            out.write(ln if ln.endswith("\n") else ln + "\n")
        # Preserve anything appended while we worked, verbatim, until stable.
        offset = size
        for _ in range(5):
            now = os.path.getsize(path)
            if now <= offset:
                break
            with open(path, "rb") as src:
                src.seek(offset)
                tail = src.read()
            out.write(tail.decode("utf-8", "replace"))
            print("preserved %d bytes appended during the prune" % len(tail))
            offset = now
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)

    after, asize = read_lines(path)
    print("rows after   : %d  (%d bytes)  [verified on disk]" % (len(after), asize))
    return 0


if __name__ == "__main__":
    sys.exit(main())
