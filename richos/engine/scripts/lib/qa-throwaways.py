#!/usr/bin/env python3
"""qa-throwaways.py — how many helper scripts did this walk write from scratch?

THE MEASUREMENT THE TOOLKIT EXISTS TO DRIVE TO ZERO.

`app/scripts/qa/README.md` records what it was built against: across the eight
walks of 2026-09-18 to 2026-09-20, 111 helper scripts were written from
scratch — 6, 3, 20, 7, 22, 21, 20 and 12 per run — and they were the same nine
or ten jobs every time. The contrast calculation alone was written ten times
across five walks, under five names, with five different rules for picking the
text color, which do not agree by more than a full ratio point on antialiased
type.

A toolkit nobody reaches for changes none of that, and NOTHING IN A TRANSCRIPT
SAYS "I IGNORED THE TOOLKIT". What a transcript does say, mechanically, is
which files a run created. So this counts the scripts a run wrote from scratch,
from its own tool calls, and prints them. Rich runs it at every QA land
(skills/rich-lander/SKILL.md step 2) and mega-lander/workspaces.py prints it
when a QA-type teammate lands. It is INFORMATION, never a refusal: a walk that
genuinely needed a one-off is not a defect, and a lander that refuses over a
count would be waived on its first true positive.

WHAT COUNTS, AND WHY EACH RULE IS HERE
--------------------------------------
Derived by reading a real walk end to end — ray-opus-vm8's phone-path run in
the test VM, agent ab5634d45f8c0eccb, 1091 rows, 181 Bash calls, 15 Write
calls — and checking every candidate by hand against what the run actually did.

  * Write  -> a `.sh`, `.py`, `.js` or `.applescript` path.
    14 of vm8's 15 Writes. The 15th wrote the audit's Markdown; documents are
    not helpers and are not counted.

  * Bash   -> a redirect into such a path: `cat > x.sh <<'EOF'`, `tee x.py`,
    `base64 -d > x.py`, or any other `>`/`>>` whose target carries one of those
    suffixes. 9 more in vm8, and they are NOT a rounding error — `click.sh`,
    `clickel.sh`, `clickxy.sh`, `find.sh`, `redact.py`, `wins.sh` and a second
    `guest.sh` were written as heredocs, and the last two were base64'd into
    the guest; a Write-only counter sees none of the nine. `python3 - <<PY`
    writes no file and is not matched: the rule is the redirect, not the
    heredoc.

  * A REPEAT OF A BASENAME IS A COPY, NOT A SECOND SCRIPT. vm8 wrote
    `measure.py` and `analyze.py` locally and then base64'd both into the VM
    guest at `/Users/admin/`. Counting those as new scripts inflates the number
    by exactly the thing the toolkit is meant to encourage — moving one script
    to where it has to run. Counted once, with the later paths listed as
    copies so the merge is visible rather than assumed.

  * A SCRIPT ADDED TO THE COMMITTED TOOLKIT IS NOT A THROWAWAY. It is the
    behavior the README asks for: "A walker who needs a helper that is not here
    ADDS it here and commits it." Counting it would punish the fix. Reported
    separately, under its own heading.

  * Edits are not authorship. An Edit presumes a file that some earlier call
    created, and that call is already counted.

THE COUNT THIS PRODUCES FOR vm8 IS 17, NOT 20. 23 write events (14 Writes, 9
shell redirects) over 17 distinct scripts, two of which were then copied into
the guest. 20 was an earlier hand count; the seventeen are listed by name at
every run, so the number can be argued with rather than believed.

Four of vm8's seventeen are `contrast.py`, `redact.py`, `ocrgate.py` and a
frame reader — four of the jobs the committed toolkit now does. That walk ran
two days before the toolkit landed, so it is the baseline this measures
against, not a violation of it.

Usage:
    qa-throwaways.sh <transcript.jsonl> [--json]

Exit: 0 nothing written from scratch; 1 at least one, listed; 2 it cannot
answer (no such transcript, unreadable, not a transcript) — never a silent 0.
"""

import json
import os
import re
import sys

SCRIPT_SUFFIXES = (".sh", ".py", ".js", ".applescript")

# A redirect into a file: `> x.sh`, `>> x.py`, with or without quotes. `tee`
# is matched by its own arm below because it takes its target as an argument.
# Deliberately permissive about what a path looks like — the walks write into
# scratch roots with long session-id segments — and strict about how it ends.
REDIRECT_RE = re.compile(r">>?\s*(['\"]?)([\w./~$@+-]+\.(?:sh|py|js|applescript))\1")
TEE_RE = re.compile(r"\btee\b\s+(?:-a\s+)?(['\"]?)([\w./~$@+-]+\.(?:sh|py|js|applescript))\1")

# The committed toolkit: a path under a `scripts/qa/` directory is an addition
# to it, not a throwaway. QA_TOOLKIT_DIR is declared in orchestration.config;
# only its tail matters here, because the walk's path may be absolute, may be
# inside a worktree, and may be inside the guest.
DEFAULT_TOOLKIT_DIR = "richos/app/scripts/qa"


def _toolkit_tail():
    d = (os.environ.get("QA_TOOLKIT_DIR") or "").strip() or DEFAULT_TOOLKIT_DIR
    parts = [p for p in d.strip("/").split("/") if p]
    if len(parts) >= 2:
        return "/" + "/".join(parts[-2:]) + "/"
    return "/" + "/".join(parts) + "/"


class CannotAnswer(Exception):
    """It could not measure, so it says so and prints no number."""


def _blocks(row):
    msg = row.get("message")
    if not isinstance(msg, dict):
        return []
    content = msg.get("content")
    return content if isinstance(content, list) else []


def _bash_targets(command):
    """Every script path this shell command WRITES. Order preserved."""
    out = []
    for line in command.split("\n"):
        for m in REDIRECT_RE.finditer(line):
            out.append(m.group(2))
        for m in TEE_RE.finditer(line):
            out.append(m.group(2))
    return out


def scan(path):
    """(events, rows_read) — one entry per write, oldest first."""
    if not os.path.exists(path):
        raise CannotAnswer("no transcript at %s" % path)
    if os.path.isdir(path):
        raise CannotAnswer("%s is a directory, not a transcript" % path)
    events = []
    rows = 0
    parsed = 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CannotAnswer("cannot read %s: %s" % (path, exc))
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rows += 1
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            parsed += 1
            if row.get("type") != "assistant":
                continue
            for b in _blocks(row):
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                name = b.get("name")
                ti = b.get("input") if isinstance(b.get("input"), dict) else {}
                if name == "Write":
                    p = str(ti.get("file_path") or "")
                    if p.endswith(SCRIPT_SUFFIXES):
                        events.append({"path": p, "how": "Write", "row": rows})
                elif name == "Bash":
                    for p in _bash_targets(str(ti.get("command") or "")):
                        events.append({"path": p, "how": "Bash", "row": rows})
    if rows and not parsed:
        raise CannotAnswer("%s has %d lines and not one of them is JSON — this is not a transcript"
                           % (path, rows))
    return events, rows


def classify(events):
    """Fold write events into scripts, copies and toolkit additions.

    Basename, not path, is the identity of a script: a walk that moves its own
    helper into the guest has one helper, and the transfer is recorded as a
    copy rather than counted again."""
    tail = _toolkit_tail()
    scripts = []
    by_base = {}
    toolkit = []
    for ev in events:
        p = ev["path"]
        base = os.path.basename(p)
        if tail in p or p.startswith(tail.lstrip("/")):
            hit = next((t for t in toolkit if t["path"] == p), None)
            if hit:
                hit["events"] += 1
            else:
                toolkit.append({"path": p, "basename": base, "events": 1, "row": ev["row"]})
            continue
        rec = by_base.get(base)
        if rec is None:
            rec = {"basename": base, "path": p, "events": 0, "rows": [], "copies": []}
            by_base[base] = rec
            scripts.append(rec)
        rec["events"] += 1
        rec["rows"].append(ev["row"])
        if p != rec["path"] and p not in rec["copies"]:
            rec["copies"].append(p)
    return scripts, toolkit


def report(path, scripts, toolkit, events, rows, out=sys.stdout):
    n = len(scripts)
    copies = sum(len(s["copies"]) for s in scripts)
    if n == 0:
        print("qa-throwaways: 0 helper scripts written from scratch  (%d rows, %s)"
              % (rows, os.path.basename(path)), file=out)
    else:
        print("qa-throwaways: %d helper script%s written from scratch  (%d write event%s "
              "over %d row%s, %s)"
              % (n, "" if n == 1 else "s", len(events), "" if len(events) == 1 else "s",
                 rows, "" if rows == 1 else "s", os.path.basename(path)), file=out)
        for s in sorted(scripts, key=lambda s: s["rows"][0]):
            extra = "  (written %dx)" % s["events"] if s["events"] > 1 else ""
            print("  %s%s" % (s["path"], extra), file=out)
            for c in s["copies"]:
                print("      copied to %s" % c, file=out)
    if copies:
        print("  %d later cop%s of an already-counted script, not counted again"
              % (copies, "y" if copies == 1 else "ies"), file=out)
    if toolkit:
        print("  %d addition%s to the committed toolkit, which is the wanted behavior:"
              % (len(toolkit), "" if len(toolkit) == 1 else "s"), file=out)
        for t in toolkit:
            print("      %s" % t["path"], file=out)


def main(argv):
    args = list(argv[1:])
    if not args:
        print("qa-throwaways.sh <transcript.jsonl> [--json]   (--help for the counting rules)",
              file=sys.stderr)
        return 2
    if "--help" in args or "-h" in args:
        print(__doc__.strip(), file=sys.stderr)
        return 0
    as_json = "--json" in args
    rest = [a for a in args if a != "--json"]
    if len(rest) != 1:
        print("qa-throwaways.sh: one transcript, please —  "
              "qa-throwaways.sh <transcript.jsonl> [--json]", file=sys.stderr)
        return 2
    path = rest[0]
    try:
        events, rows = scan(path)
    except CannotAnswer as exc:
        print("qa-throwaways: %s" % exc, file=sys.stderr)
        return 2
    scripts, toolkit = classify(events)
    if as_json:
        print(json.dumps({
            "transcript": os.path.abspath(path),
            "rows": rows,
            "write_events": len(events),
            "count": len(scripts),
            "scripts": [{"basename": s["basename"], "path": s["path"],
                         "events": s["events"], "copies": s["copies"]} for s in scripts],
            "toolkit_additions": [t["path"] for t in toolkit],
        }, indent=2))
    else:
        report(path, scripts, toolkit, events, rows)
    return 1 if scripts else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
