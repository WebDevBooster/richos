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

import hashlib
import json
import os
import re
import sys

SCRIPT_SUFFIXES = (".sh", ".py", ".js", ".applescript")

# The conversation rows of a Claude Code transcript; a file with none of them is not one.
TRANSCRIPT_TYPES = {"user", "assistant", "system", "summary"}

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


def _sha(text):
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()


_HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def _bash_sig(lines, i, start):
    """The content signature of a shell write whose content is in the command, else None.

    Hunt P5-30 (v3): only Write events carried content, so two shell-written
    scripts of the same basename always folded into one. Content is known when
    `cat`/`tee` writes a heredoc (signed like a Write of that body) or when
    `printf`/`echo` writes a literal straight into the file. A write fed from
    another file or a decoder (`cat a > b`, `base64 -d > x.py`) stays unknown,
    so the transfer of an existing helper is still a copy."""
    line = lines[i]
    hd = _HEREDOC_RE.search(line)
    if hd:
        if not re.match(r"\s*(?:cat|tee)\b", line):
            return None
        body = []
        for later in lines[i + 1:]:
            if later.strip() == hd.group(2):
                return _sha("\n".join(body) + "\n")
            body.append(later)
        return None
    head = line[:start].strip()
    if re.match(r"(?:printf|echo)\s", head) and not re.search(r"[|<`]|\$\(", head):
        return _sha(head)
    return None


def _bash_targets(command):
    """Every (script path, content signature or None) this shell command WRITES. Order preserved."""
    out = []
    lines = command.split("\n")
    for i, line in enumerate(lines):
        for m in REDIRECT_RE.finditer(line):
            out.append((m.group(2), _bash_sig(lines, i, m.start())))
        for m in TEE_RE.finditer(line):
            out.append((m.group(2), _bash_sig(lines, i, m.start())))
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
            # Hunt P5-29: only a row with a transcript "type" counts as recognized, so a
            # file of `{}` and noise is "not a transcript", never a confident zero.
            # v3: a type key is not enough; {"type": "garbage"} is not a transcript row.
            if row.get("type") in TRANSCRIPT_TYPES:
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
                        body = ti.get("content")
                        sig = hashlib.sha1(body.encode("utf-8", "replace")).hexdigest() \
                            if isinstance(body, str) else None
                        events.append({"path": p, "how": "Write", "row": rows, "sig": sig})
                elif name == "Bash":
                    for p, sig in _bash_targets(str(ti.get("command") or "")):
                        events.append({"path": p, "how": "Bash", "row": rows, "sig": sig})
    if rows and not parsed:
        raise CannotAnswer("%s has %d lines and not one of them is a transcript row — this is not a transcript"
                           % (path, rows))
    return events, rows


def classify(events):
    """Fold write events into scripts, copies and toolkit additions.

    Basename, not path, is the identity of a script: a walk that moves its own
    helper into the guest has one helper, and the transfer is recorded as a
    copy rather than counted again."""
    tail = _toolkit_tail()
    scripts = []
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
        # Hunt P5-30: a same-named script is a copy only when its content is not known to
        # differ; two Writes of different content are two scripts.
        sig = ev.get("sig")
        # v3: a write to a path the script already has is a REWRITE of it, whatever
        # the content; only a same-named file at another path is judged by content.
        rec = next((r for r in scripts if p == r["path"] or p in r["copies"]), None) or \
            next((r for r in scripts if r["basename"] == base
                  and (sig is None or r["sig"] is None or sig == r["sig"])), None)
        if rec is None:
            rec = {"basename": base, "path": p, "events": 0, "rows": [], "copies": [],
                   "sig": sig}
            scripts.append(rec)
        elif rec["sig"] is None or (p == rec["path"] and sig is not None):
            rec["sig"] = sig  # the script's content is now what was last written to it
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
