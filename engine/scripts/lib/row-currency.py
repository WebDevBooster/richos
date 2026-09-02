#!/usr/bin/env python3
"""row-currency.py — THE PREDICATE: does the record still describe the work?

Read scripts/lib/row-currency.sh first; it carries the argument. This file
carries only the mechanism, because the mechanism has to be exact.

===========================================================================
THE ONE SENTENCE
===========================================================================
    A ROW THAT DESCRIBES OPEN WORK STATES THE IDENTITY OF THE WORK IT
    DESCRIBES. WHEN THAT IDENTITY CHANGES AND THE ROW DOES NOT, THE ROW IS
    A CLAIM ABOUT BYTES THAT NO LONGER EXIST, AND THE NEXT LANDING IS
    REFUSED UNTIL SOMEBODY REWRITES IT.

Everything here is that sentence plus the precision needed to make it fire on
the right commits and on no others.

===========================================================================
TWO CHECKS, AND WHY BOTH
===========================================================================
CHECK 1 — CURRENCY (primary). Every governed row carries a warrant: a status
token and one or more `<prefix>/path`@`<oid>` stamps. The oid is an object id
minted by the version-control system — the blob id of a file, the tree id of a
directory — read out of the tree this commit is about to create. Content
identity, never a timestamp, and it survives a history rewrite because a
rebase does not change what a file says.

  It needs no commit message, so it cannot be defeated by a message that says
  nothing. It needs nobody's memory. It fires the moment the work moves.

CHECK 2 — CLAIM (secondary). A commit or merge message that NAMES an item id
is claiming something about that item, so that item's row must be in hand.
This is the orchestrator's own proposal, and it catches the case Check 1
structurally cannot see: a landing that changes an item's truth WITHOUT
touching anything that item's row points at.

  It rests on the lander's own words, which are a claim rather than evidence.
  That is why it is second and not first.

===========================================================================
PRECISION IS THE CONTRACT
===========================================================================
A guard that fires on ordinary work gets switched off, and then it protects
nothing. Check 1 never reads prose at all, so it cannot misread any. Check 2
does read prose, so every rejection rule below was written against real commit
messages from the repositories this governs, not against imagination:

  `stage 3.7`      a PIPELINE STAGE. Shipped in a real subject line on the
                   same day item 3.7 was a real item about a different thing.
  section marks    `§3.3`, `§3.4a` — section references inside a measurement
                   brief. Extremely common in this record's own history.
  `1.3.4`,`0.70.0` version numbers.
  `3.15%`, `12.5x` measurements. Everywhere.
  `17/24`          a ratio.
  `docs/3.4/x`     a path component.
  a quoted span    a prior commit message quoted inside a new one.
  a `#` line       the trailer block a conflicted merge leaves behind.

Two filters do most of the work, and neither is a list anybody maintains:

  * a candidate must BE AN ID THE RECORD ACTUALLY DEFINES. That set is derived
    from the record on every run, and it eliminates every version number and
    measurement in one move.
  * a candidate must be introduced by a word that NAMES AN ITEM ("item 3.12",
    "open-items 3.6", "decision 1.6"). An allowlist, not a blocklist — the
    argument, and the 400-message sweep that produced it, is at CHECK 2 below.

===========================================================================
INPUT — one JSON job, path given as argv[1] (or "-" for stdin)
===========================================================================
    {
      "record_label":   "wiki/open-items.md",
      "record_text":    "<the record as it will be after this commit>",
      "baselines":      ["<record at HEAD>", "<record one commit earlier>"],
      "row_sections":   ["3"],
      "status_tokens":  ["OPEN", "BUILT", "BOUNDED", "BLOCKED-ON-RICH", "CLOSED"],
      "terminal_tokens":["CLOSED"],
      "claim_words":   ["item", "open-items", "decision"],  # the dialect
      "artifact_roots": {"richos": "/abs/path", ...},   # prefix -> root ON DISK
      "absent_roots":   {"prefix": "../declared"},      # declared, not here
      "identity_revs":  {"richos": "<tree-oid>|HEAD"},  # which tree to read
      "message":        "<commit or merge message>",    # null when unknown
      "message_source": "commit -m" | "merge -m" | "commit -F" | "unavailable",
      "action":         "commit" | "merge"
    }

OUTPUT — tab-separated lines on stdout. First line is the verdict:

    CLEAN       <rows-checked>  <skips>
    VIOLATIONS  <count>  <rows-checked>  <skips>
    BROKEN      <reason>

then one line per finding:

    V     <item-id>  <CODE>     <message>
    SKIP  <item-id>  <path>     <reason>
    NOTE  <CODE>     <message>
    FIX   <item-id>  <warrant>  the warrant this row should carry now

EXIT  0 always, unless the job itself is unreadable (2). The VERDICT is the
      product: a non-zero exit would make "the record is stale" and "the
      checker is broken" the same signal to every caller.
"""

import json
import re
import subprocess
import sys

# --- Grammar ---------------------------------------------------------------
# Deliberately narrow, and a shape the parser does not recognize inside a
# governed section is a VIOLATION rather than a skip. The way a mechanism like
# this dies is by somebody writing a row in an unrecognized shape and the lint
# reporting CLEAN over it.

SECTION_RE = re.compile(r"^##\s+(?P<num>\d+)\.\s+(?P<title>.*)$")
ANY_H2_RE = re.compile(r"^##\s+\S")
ANY_H3_RE = re.compile(r"^###\s+\S")

# `### 2.1 READY-FOR-CEO - title`  (the CEO-section shape, ceo-todos.py's own)
BLOCK_ITEM_RE = re.compile(r"^###\s+(?P<id>\d+\.\d+[a-z]?)\s")
# `| 3.7 | prose | warrant |`      (the working-section shape)
TABLE_ITEM_RE = re.compile(r"^\|\s*(?P<id>\d+\.\d+[a-z]?)\s*\|")
# `|---|---|---|` and `| # | Item | ... |` - structure, never an item.
TABLE_RULE_RE = re.compile(r"^\|[\s:|-]*\|\s*$")

# THE WARRANT. One construct, one regex, in both row shapes - a table cell and
# a `- **State:**` line under a heading parse identically, because two parsers
# of one grammar is the defect this engine keeps finding in itself.
WARRANT_RE = re.compile(r"\*\*State:\*\*\s*(?P<body>.*?)\s*$")
STATUS_RE = re.compile(r"^\s*`(?P<tok>[A-Z][A-Z0-9-]*)`")
STAMP_RE = re.compile(r"`(?P<path>[^`\s]+)`\s*@\s*`(?P<oid>[0-9a-f]{6,40}|-)`")

STAMP_LEN = 12          # how much of the object id a warrant carries
ABSENT = "-"            # the stamp for "this path does not exist"


def fail(reason):
    sys.stdout.write("BROKEN\t%s\n" % reason)
    sys.exit(0)


# ===========================================================================
# THE PARSE - one function; the lint, the claim check and the FIX line all
# use its output, so there is no second reading of the record anywhere.
# ===========================================================================
def parse_record(text, row_sections):
    """-> (items, violations, seen_sections)

    items: [{"section", "id", "span": [line...], "line0", "governed", "shape"}]
    in document order.
    """
    lines = text.split("\n")
    items = []
    violations = []
    seen_sections = {}
    section = None
    cur = [None]

    def close():
        if cur[0] is not None:
            items.append(cur[0])
            cur[0] = None

    for n, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if m:
            close()
            section = m.group("num")
            seen_sections.setdefault(section, n)
            continue
        if ANY_H2_RE.match(line):
            close()
            section = None
            continue

        if section is None:
            continue

        if ANY_H3_RE.match(line):
            close()
            bm = BLOCK_ITEM_RE.match(line)
            if bm:
                cur[0] = {"section": section, "id": bm.group("id"),
                          "span": [line], "line0": n + 1,
                          "governed": section in row_sections, "shape": "block"}
            continue

        if line.lstrip().startswith("|"):
            stripped = line.strip()
            if TABLE_RULE_RE.match(stripped):
                continue
            tm = TABLE_ITEM_RE.match(stripped)
            if tm:
                close()
                items.append({"section": section, "id": tm.group("id"),
                              "span": [line], "line0": n + 1,
                              "governed": section in row_sections,
                              "shape": "table"})
                continue
            # A table row inside a governed section that carries no item id in
            # its first cell is either the header or something nobody can
            # check. The header is legitimate; anything else is not.
            if section in row_sections and not _looks_like_header(line):
                violations.append((
                    "?", "ROW-UNIDENTIFIED",
                    "a table row in section %s carries no item id in its first "
                    "cell, so nothing can be said about it: %s"
                    % (section, stripped[:110])))
            continue

        if cur[0] is not None:
            cur[0]["span"].append(line)

    close()
    return items, violations, seen_sections


def _looks_like_header(line):
    first = line.strip().strip("|").split("|")[0].strip().lower()
    return first in ("#", "id", "item", "no", "no.", "")


def warrant_of(item):
    for line in item["span"]:
        m = WARRANT_RE.search(line)
        if m:
            return m.group("body")
    return None


def span_text(item):
    return "\n".join(l.rstrip() for l in item["span"]).strip()


# ===========================================================================
# IDENTITY - what the work IS, right now, in the tree about to be created
# ===========================================================================
def git_out(root, args):
    try:
        p = subprocess.run(["git", "-C", root] + args,
                           capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.strip()


def identity(root, rev, relpath):
    """The object id of <relpath> inside <rev>, or ABSENT, or None.

    None means "could not be determined" and is NEVER treated as a mismatch -
    a guard that refuses on its own inability to look is a guard that gets
    switched off within a day.
    """
    if not relpath:
        return None
    clean = relpath.rstrip("/")
    out = git_out(root, ["rev-parse", "--verify", "--quiet",
                         "%s:%s" % (rev, clean)])
    if out:
        return out
    # Distinguish "not there" from "cannot look": if the rev itself resolves,
    # the path is genuinely absent from it.
    if git_out(root, ["rev-parse", "--verify", "--quiet", "%s^{tree}" % rev]):
        return ABSENT
    return None


# ===========================================================================
# THE STAMP WALK - one implementation, both warrants
# ===========================================================================
# The stamp resolution is lifted out of CHECK 1 unchanged so that a SECOND
# warrant can pin artifacts through the same code rather than through a second
# staleness implementation - two of those is how one silently becomes the stale
# one. The only thing that will differ is what a mismatch MEANS, which is a
# table of sentences and three violation codes rather than a second walk.
#
# The section-3 sentences below are byte-identical to the ones this function
# was extracted from. That is deliberate and is asserted by the suite: a
# refactor that quietly reworded an existing refusal would be a change to a
# contract twenty governed rows are already written against.
ROW_STAMP_CODES = {
    "unknown_prefix": "ROW-UNKNOWN-PREFIX",
    "bare_root": "ROW-BARE-ROOT",
    "stale": "ROW-STALE",
    "skip": "declared root '%s' (%s) is not on this machine, so the work could "
            "not be identified",
    "vanished": "`%s` is stamped @`%s` and no longer exists. The row describes "
                "work that is not there.",
    "appeared": "`%s` is stamped @`-` (absent) and now EXISTS as %s. The row "
                "was written before the work was.",
    "moved": "`%s` is stamped @`%s` and is now %s. The work moved; this row "
             "still describes what it used to be.",
    "bare_root_msg": "`%s` names a repository, not the work",
}

def walk_stamps(iid, stamps, roots, absent_roots, revs, skips, violations,
                codes):
    """-> (wanted, moved) - the warrant this row should carry now, and whether
    anything under it moved."""
    wanted = []
    moved = False
    for path, oid in stamps:
        prefix = path.split("/", 1)[0]
        remainder = path.split("/", 1)[1] if "/" in path else ""
        if prefix in absent_roots:
            skips.append((iid, path, codes["skip"] % (prefix, absent_roots[prefix])))
            wanted.append((path, oid))
            continue
        if prefix not in roots:
            violations.append((
                iid, codes["unknown_prefix"],
                "`%s` starts with '%s', which is not a declared artifact "
                "root. Declared: %s." % (path, prefix,
                                         ", ".join(sorted(roots)) or "<none>")))
            wanted.append((path, oid))
            continue
        if not remainder:
            violations.append((iid, codes["bare_root"], codes["bare_root_msg"] % path))
            wanted.append((path, oid))
            continue
        rev = revs.get(prefix) or "HEAD"
        now = identity(roots[prefix], rev, remainder)
        if now is None:
            skips.append((iid, path,
                          "the path could not be identified in %s (%s) - "
                          "reported, never counted as a mismatch"
                          % (roots[prefix], rev)))
            wanted.append((path, oid))
            continue
        short = now if now == ABSENT else now[:STAMP_LEN]
        wanted.append((path, short))
        if now == ABSENT:
            if oid != ABSENT:
                moved = True
                violations.append((iid, codes["stale"], codes["vanished"] % (path, oid)))
        elif oid == ABSENT:
            moved = True
            violations.append((iid, codes["stale"], codes["appeared"] % (path, short)))
        elif not now.startswith(oid):
            moved = True
            violations.append((iid, codes["stale"], codes["moved"] % (path, oid, short)))
    return wanted, moved


# ===========================================================================
# CHECK 2 - WHICH ITEM IDS DOES THIS MESSAGE CLAIM?
# ===========================================================================
# AN ALLOWLIST OF LEAD-IN WORDS, NOT A BLOCKLIST OF EXCLUSIONS. That choice
# was made on measurement, not taste, and the measurement is worth recording
# because the first version got it the other way round.
#
# A blocklist ("3.7 is not an item when the word before it is `stage`") was
# built first and swept over 400 real commit messages from the repositories
# this governs. It claimed an id in 36 of them. Reading the 36 by hand, the
# majority were wrong, and they were wrong in ways no list could ever close:
#
#     P1.4 turn-boundary rotation          a PHASE label
#     P3.2 drill-down                      a phase label again
#     macOS ships bash 3.2                 a version of a tool
#     nemotron-3.5 under OpenMDW-1.1       a model name and a license
#     C - A = +1.2 points                  an arithmetic result
#     Freeze margin 1.5 with the gate      a tuning constant
#     8 words over 2.2 seconds             a measurement
#     -et 2.4 -lpt -1.0                    a decode argument
#     1.5-2.3x §2.3's estimate             a ratio against a section
#     Stages 3.5, 3.6 and 3.7 were missing pipeline stages - and note the
#                                          PLURAL, which the blocklist's
#                                          singular `stage` did not cover, and
#                                          the two ids after the comma, which
#                                          no preceding-word rule reaches at all
#
# The set of words that can precede a decimal number in English is unbounded.
# The set of ways this team NAMES AN ITEM is small, observed, and written down:
#
#     open-items 3.6      Item 3.12's engineering half      open 3.12
#     DECISION 1.6        CEO decision 1.3                  open item 1.1
#
# So a claim is a lead-in word from the allowlist, plus the id, plus any ids
# that continue the same list ("open-items 3.4 and 3.12"). Everything else is
# not a claim, and the reason is printed by --explain for every candidate.
#
# THE COST, stated: a real claim written in bare prose is missed. One of the
# four rows that rotted was named exactly that way - "that is what running 3.6
# AFTER the engineering cost" - and this check does not see it. It is caught by
# the CURRENCY check instead, which needs no words at all. A false negative
# here costs a second net; a false positive costs the whole guard.

DEFAULT_CLAIM_WORDS = (
    "item", "items", "open-item", "open-items", "decision", "decisions",
)

# Units that turn "3.7" into a measurement. Kept as a shape rule even though
# the allowlist mostly subsumes it: "item 3.5 dB" should still not be a claim.
UNIT_WORDS = (
    "s", "ms", "us", "ns", "m", "h", "hz", "khz", "mhz", "ghz", "db", "dbfs",
    "x", "kb", "mb", "gb", "tb", "b", "px", "pt", "kg", "g", "mm", "cm",
    "min", "mins", "sec", "secs", "hrs", "hours", "days",
)

CAND_RE = re.compile(r"\d+\.\d+[a-z]?")
LEAD_WORD_RE = re.compile(r"([A-Za-z][A-Za-z-]*)['’]?s?[\s:.,—–-]*$")
# What may sit between two ids and still be one list.
CHAIN_RE = re.compile(r"^\s*(?:,|,?\s*(?:and|&|\+|or)\s*|,\s*)\s*$")


def strip_uncountable(message):
    """Blank out the spans of a message where an id cannot be a claim.

    Replaced with spaces rather than deleted, so every surviving character
    keeps its original offset and the boundary tests below stay meaningful.
    """
    def blank(m):
        return " " * (m.end() - m.start())

    text = message
    # Fenced code, then inline code, then quoted spans (a quoted PRIOR COMMIT
    # MESSAGE is the case that motivated this), then comment lines - which is
    # where a conflicted merge writes its own trailer block.
    text = re.sub(r"```.*?```", blank, text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", blank, text)
    text = re.sub(r'"[^"\n]*"', blank, text)
    text = re.sub(r"'[^'\n]*'", blank, text)
    text = re.sub(u"[“‘][^”’\n]*[”’]", blank, text)
    text = "\n".join((" " * len(l)) if l.lstrip().startswith("#") else l
                     for l in text.split("\n"))
    return text


def claimed_ids(message, known_ids, claim_words=None):
    """-> (claimed set, rejected list of (token, reason)) - both reported.

    The rejected list is printed by the lint's --explain mode. A precision
    argument nobody can inspect is a precision argument nobody should believe.
    """
    words_ok = set(w.lower() for w in (claim_words or DEFAULT_CLAIM_WORDS))
    claimed = set()
    rejected = []
    if not message:
        return claimed, rejected
    text = strip_uncountable(message)

    prev_end = None          # end offset of the previous candidate
    prev_accepted = False    # ...and whether it was a claim, for list chaining

    for m in CAND_RE.finditer(text):
        tok = m.group(0)
        i, j = m.start(), m.end()
        prev = text[i - 1] if i else ""
        nxt = text[j] if j < len(text) else ""
        gap = text[prev_end:i] if prev_end is not None else None
        this_accepted = False

        def reject(why):
            rejected.append((tok, why))

        # --- SHAPE. Everything a decimal number can be that is not an id. ---
        if prev.isdigit() or prev == ".":
            reject("part of a longer number (preceded by %r)" % prev)
        elif nxt == "." and j + 1 < len(text) and text[j + 1].isdigit():
            reject("part of a longer number (a further .digit follows)")
        elif prev.isalpha():
            # P1.4, v3.7, R2.1 - a label, not an item.
            reject("preceded by the letter %r - a label such as P1.4, not an item"
                   % prev)
        elif prev and (prev in "-+" or prev in u"–—"):
            # nemotron-3.5, OpenMDW-1.1, +1.2 points, a 1.5-2.3 range.
            reject("preceded by %r - a hyphenated name, a signed number or a range"
                   % prev)
        elif (prev and prev in "/\\:") or (nxt and nxt in "/\\:"):
            reject("adjacent to %r - a path, a ratio or a file:line reference"
                   % (prev if (prev and prev in "/\\:") else nxt))
        elif prev and prev in u"§#":
            reject("preceded by %r - a section reference, not an item" % prev)
        elif nxt and (nxt in "-+" or nxt in u"–—×"):
            reject("followed by %r - a range or an arithmetic expression" % nxt)
        elif text[j:j + 1] == "%":
            reject("a percentage")
        elif tok not in known_ids:
            # THE FILTER THAT NEEDS NO MAINTENANCE: is this an id the record
            # actually defines? Every version number and measurement that gets
            # this far dies here.
            reject("no item %s exists in the record" % tok)
        else:
            um = re.match(r"\s?([A-Za-z%]+)", text[j:j + 10])
            if um and um.group(1).lower() in UNIT_WORDS:
                reject("followed by the unit %r - a measurement" % um.group(1))
            else:
                # --- THE ALLOWLIST, and list continuation ------------------
                lead = LEAD_WORD_RE.search(text[max(0, i - 24):i])
                if lead and lead.group(1).lower() in words_ok:
                    claimed.add(tok)
                    this_accepted = True
                elif prev_accepted and gap is not None and CHAIN_RE.match(gap):
                    claimed.add(tok)
                    this_accepted = True
                else:
                    reject("the word before it (%s) does not name an item. Write "
                           "'item %s' or 'open-items %s' to make this a claim."
                           % (("%r" % lead.group(1)) if lead else "nothing",
                              tok, tok))

        prev_end = j
        prev_accepted = this_accepted
    return claimed, rejected


# ===========================================================================
def main():
    if len(sys.argv) < 2:
        sys.stderr.write("row-currency.py: expected a job file path (or '-')\n")
        return 2
    try:
        if sys.argv[1] == "-":
            job = json.load(sys.stdin)
        else:
            with open(sys.argv[1], encoding="utf-8") as fh:
                job = json.load(fh)
    except Exception as exc:
        sys.stderr.write("row-currency.py: unreadable job: %s\n" % exc)
        return 2

    text = job.get("record_text")
    if not isinstance(text, str) or not text.strip():
        fail("job carries no record text - the checker cannot report a clean "
             "record it never read")

    label = job.get("record_label") or "<record>"
    row_sections = [str(s) for s in (job.get("row_sections") or [])]
    if not row_sections:
        fail("no ROW_SECTIONS declared. A currency check over no sections would "
             "report clean on every run, which is worse than no check at all.")

    tokens = [str(t) for t in (job.get("status_tokens") or [])]
    if not tokens:
        fail("no ROW_STATUS_TOKENS declared - every warrant would be rejected")
    terminal = set(str(t) for t in (job.get("terminal_tokens") or []))
    roots = job.get("artifact_roots") or {}
    absent_roots = job.get("absent_roots") or {}
    revs = job.get("identity_revs") or {}

    items, violations, seen_sections = parse_record(text, row_sections)
    for want in row_sections:
        if want not in seen_sections:
            fail("%s declares row section %s and no '## %s.' heading exists in "
                 "the record. The check would have had nothing to look at and "
                 "would have reported clean." % (label, want, want))

    by_id = {}
    dupes = []
    for it in items:
        if it["id"] in by_id:
            dupes.append(it["id"])
        else:
            by_id[it["id"]] = it
    for d in sorted(set(dupes)):
        violations.append((d, "DUPLICATE-ID",
                           "item id %s appears more than once in the record; "
                           "nothing can say which row describes the work" % d))

    known_ids = set(by_id)
    governed = [it for it in items if it["governed"]]

    skips = []
    notes = []
    fixes = []

    # --- CHECK 1: CURRENCY -------------------------------------------------
    for it in governed:
        iid = it["id"]
        body = warrant_of(it)
        if body is None:
            violations.append((
                iid, "ROW-UNWARRANTED",
                "this row carries no `**State:** ...` warrant, so it makes a "
                "claim nothing can check. Give it one: **State:** `%s` - "
                "`<prefix>/path/to/the/work`@`<oid>`" % tokens[0]))
            continue

        sm = STATUS_RE.match(body)
        if not sm:
            violations.append((
                iid, "ROW-NO-STATUS",
                "the warrant does not begin with a backticked status token "
                "(one of: %s): %s" % (", ".join(tokens), body[:110])))
            continue
        tok = sm.group("tok")
        if tok not in tokens:
            violations.append((
                iid, "ROW-BAD-STATUS",
                "status `%s` is not one of the declared tokens: %s"
                % (tok, ", ".join(tokens))))
            continue

        stamps = STAMP_RE.findall(body)

        if tok in terminal:
            # A finished row does not go stale: further changes to the work
            # cannot falsify "this closed". It is exempt from the stamp - and
            # named every run, because this record's own rule is that a closed
            # item leaves the page.
            notes.append(("ROW-TERMINAL-STILL-LISTED",
                          "%s is `%s` and still on the page. A closed row cannot "
                          "go stale, so it is exempt from the currency check - "
                          "and it is also not open work. Delete it; the history "
                          "is the archive." % (iid, tok)))
            continue

        if not stamps:
            violations.append((
                iid, "ROW-NO-STAMP",
                "status `%s` is open work and the warrant names no "
                "`<prefix>/path`@`<oid>` stamp. A row that points at nothing "
                "cannot be told when it goes stale - which is the entire "
                "defect this contract removes." % tok))
            continue

        wanted, stale_here = walk_stamps(
            iid, stamps, roots, absent_roots, revs, skips, violations,
            ROW_STAMP_CODES)
        if stale_here:
            fixes.append((iid, "**State:** `%s` - %s"
                          % (tok, ", ".join("`%s`@`%s`" % (p, o)
                                            for p, o in wanted))))

    # --- CHECK 2: CLAIM ----------------------------------------------------
    message = job.get("message")
    msource = job.get("message_source") or "unavailable"
    claim_words = [str(w) for w in (job.get("claim_words") or [])] or None
    claimed, rejected = claimed_ids(message, known_ids, claim_words)

    if message is None:
        notes.append(("CLAIM-MESSAGE-UNREADABLE",
                      "this %s carries no message this guard could read (%s), so "
                      "no claim could be checked. The currency check above is "
                      "unaffected - it never reads a message."
                      % (job.get("action") or "commit", msource)))

    baselines = [b for b in (job.get("baselines") or []) if isinstance(b, str)]
    in_hand = set()
    if baselines:
        for base in baselines:
            base_items, _, _ = parse_record(base, row_sections)
            base_by_id = {i["id"]: span_text(i) for i in base_items}
            for iid, it in by_id.items():
                if base_by_id.get(iid) != span_text(it):
                    in_hand.add(iid)
    elif claimed:
        notes.append(("CLAIM-NO-BASELINE",
                      "the record's previous state could not be read, so 'has "
                      "this row been touched?' has no answer and no claim was "
                      "refused on it."))

    if baselines:
        for iid in sorted(claimed):
            if iid in in_hand:
                continue
            violations.append((
                iid, "CLAIM-UNANSWERED",
                "this %s names item %s, and %s's row in %s is byte-identical to "
                "the one already committed. Naming an item is a claim that its "
                "truth changed; the row that states that truth did not. Rewrite "
                "the row, or do not name the item."
                % (job.get("action") or "commit", iid, iid, label)))

    # --- Output ------------------------------------------------------------
    out = []
    for v in violations:
        out.append("V\t%s\t%s\t%s" % v)
    for s in skips:
        out.append("SKIP\t%s\t%s\t%s" % s)
    for n in notes:
        out.append("NOTE\t%s\t%s" % n)
    for f in fixes:
        out.append("FIX\t%s\t%s" % f)
    if job.get("explain"):
        for tok, why in rejected:
            out.append("REJECTED\t%s\t%s" % (tok, why))
        for iid in sorted(claimed):
            out.append("CLAIMED\t%s\t%s" % (iid, "named by this message"))

    if violations:
        sys.stdout.write("VIOLATIONS\t%d\t%d\t%d\n"
                         % (len(violations), len(governed), len(skips)))
    else:
        sys.stdout.write("CLEAN\t%d\t%d\n" % (len(governed), len(skips)))
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
