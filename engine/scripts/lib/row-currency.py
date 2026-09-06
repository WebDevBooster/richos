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
THREE CHECKS, AND WHY EACH
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

CHECK 3 — HEADLINE (added 2026-09-06). A row's first sentence is the part that
gets quoted into briefs, and CHECK 1 has no opinion about it: eleven of the
sixteen rows found overtaken that day had MATCHING pins. So a governed row
carries a `**Headline:**` warrant — a digest of its own body, plus either the
command that settles the headline and that command's output, or the word
`unverified` and what would settle it. When the body moves, the digest stops
matching and the headline is handed back to a human.

  It cannot tell whether a sentence is true. It can tell that the row moved
  underneath one, and it can make an unverifiable claim VISIBLE and counted.
  Declaration-gated (ROW_HEADLINE_SECTIONS); silent where nobody adopted it,
  and the HC census says which of those two silences you are looking at.

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
      "premise_sections": ["1", "2"],  # the CEO sections, from .ceo-todos;
                                       # [] = the premise warrant is not adopted
      "premise_required": false,       # true = an item with no **Premise:**
                                       # line is a violation rather than a note
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

and, ALWAYS, whether or not premise sections are declared:

    PC    sections=<list|->  items=<n>  evaluated=<n>  pinned=<n>  stamps=<n>
          moved=<n>  unobservable=<n>  broken=<n>  skipped=<n>  unstated=<n>

          The premise census. On every verdict, clean or not, for the reason
          ceo-todos.py's DC line is: the right outcome for an unobservable
          premise is silence, and silence is what a checker that never ran
          produces too.

EXIT  0 always, unless the job itself is unreadable (2). The VERDICT is the
      product: a non-zero exit would make "the record is stale" and "the
      checker is broken" the same signal to every caller.
"""

import hashlib
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

# THE WARRANT. One construct, one regex builder, in both row shapes and in both
# KINDS of warrant - a table cell, a `- **State:**` line and a `- **Premise:**`
# line all parse identically, because two parsers of one grammar is the defect
# this engine keeps finding in itself.
def field_re(name):
    return re.compile(r"\*\*%s:\*\*\s*(?P<body>.*?)\s*$" % re.escape(name))


WARRANT_RE = field_re("State")
STATUS_RE = re.compile(r"^\s*`(?P<tok>[A-Z][A-Z0-9-]*)`")
STAMP_RE = re.compile(r"`(?P<path>[^`\s]+)`\s*@\s*`(?P<oid>[0-9a-f]{6,40}|-)`")

ROW_DECLARATION_LABEL = ".row-currency"

STAMP_LEN = 12          # how much of the object id a warrant carries
ABSENT = "-"            # the stamp for "this path does not exist"

# ===========================================================================
# THE SECOND WARRANT - a CEO item's PREMISE
# ===========================================================================
# A section-3 row answers "is this work still what the row says it is?". A CEO
# item's Done-check answers "is this already finished?". NEITHER of them
# answers the question that rotted item 1.8:
#
#     IS THE REASON FOR ASKING HIM THIS STILL TRUE?
#
# 1.8 asked "should this repository enforce its own rules?", resting on a
# measurement taken on 2026-08-30: the two declarations were committed and
# "nothing reads either of them". Three days later that was false - scope is
# declared by the destination, both guards had been refusing commits into that
# repository all day - and the item was NEVER FINISHED, so its Done-check was
# correctly unsatisfied and correctly silent. The item was not stale. Its
# PREMISE was, and no machinery had an opinion about premises.
#
# So a CEO item may state the observable fact its question rests on, pinned the
# way a section-3 row pins work:
#
#     - **Premise:** `richos/engine/scripts/hooks/guard-x.sh`@`4f2a9c1e83bd` -
#       the guard exits before reading this repository's declaration
#
# and when that object id moves, the next landing is refused until somebody
# re-reads the item and decides whether the question survives. Same identity
# rule, same refusal, same no-re-stamp-command rule. The only new thing is WHICH
# sentence the pin is attached to.
#
# THE STATED FACT IS PART OF THE WARRANT, not decoration. A pin with no sentence
# beside it can be re-stamped mechanically, which is the original defect wearing
# a fix's clothes - and it is precisely what 1.8 had: its premise sentence lived
# thirty lines below in prose, connected to nothing.
PREMISE_RE = field_re("Premise")

# The escape hatch, and it is the DONE-CHECK-MANUAL precedent exactly: not every
# question rests on something a machine can see. "Run `railway login`" rests on
# no artifact at all, and forcing a pin onto it would produce fiction. So an
# item may declare its premise unobservable - and must say WHY, in words, or it
# is a way to switch the check off while looking like a considered decision.
#
# WHY `unobservable` AND NOT `manual`. Done-check's `manual` means "a human must
# look". This means "there is nothing to look AT". Reusing the word would make
# the census read as though somebody had undertaken to check something.
PREMISE_UNOBSERVABLE_RE = re.compile(
    r'^\s*`?\s*unobservable\s+"(?P<why>[^"]*)"\s*`?\s*$')
MIN_PREMISE_WORDS = 4      # the stated fact, matching Done's own floor
MIN_UNOBSERVABLE_WORDS = 3  # matching Done-check's MIN_MANUAL_WORDS


def _words(value):
    return [w for w in re.split(r"\s+", re.sub(r"[`*_\[\]()@]", " ", value or ""))
            if w]


def fail(reason):
    sys.stdout.write("BROKEN\t%s\n" % reason)
    sys.exit(0)


# ===========================================================================
# THE PARSE - one function; the lint, the claim check and the FIX line all
# use its output, so there is no second reading of the record anywhere.
# ===========================================================================
def parse_record(text, row_sections, premise_sections=(), headline_sections=()):
    """-> (items, violations, seen_sections)

    items: [{"section", "id", "span": [line...], "line0", "governed",
             "premised", "headlined", "shape"}] in document order.

    "governed" is section-3's warrant; "premised" is the CEO sections';
    "headlined" is the row's own first sentence. They are three flags on ONE
    parse rather than three parses, for the reason stated at the top of this
    file and in ceo-todos.py: two readings of one record agree until they
    don't, and the day they disagree somebody reads a page a gate called fine.
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
                          "governed": section in row_sections,
                          "premised": section in premise_sections,
                          "headlined": section in headline_sections,
                          "shape": "block"}
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
                              "premised": section in premise_sections,
                              "headlined": section in headline_sections,
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


def warrant_of(item, regex=WARRANT_RE):
    for line in item["span"]:
        m = regex.search(line)
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
# A section-3 `**State:**` warrant and a CEO item's `**Premise:**` warrant pin
# artifacts in exactly the same way, so they resolve them with exactly the same
# code. The only thing that differs is what a mismatch MEANS, which is a table
# of sentences and three violation codes rather than a second walk.
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

PREMISE_STAMP_CODES = {
    "unknown_prefix": "PREMISE-UNKNOWN-PREFIX",
    "bare_root": "PREMISE-BARE-ROOT",
    "stale": "PREMISE-MOVED",
    "skip": "declared root '%s' (%s) is not on this machine, so the fact this "
            "question rests on could not be identified",
    "vanished": "`%s` is pinned @`%s` and no longer exists. The fact this "
                "question rests on has changed; re-read the item before it "
                "reaches him again.",
    "appeared": "`%s` is pinned @`-` (absent) and now EXISTS as %s. The fact "
                "this question rests on has changed; re-read the item before "
                "it reaches him again.",
    "moved": "`%s` is pinned @`%s` and is now %s. The fact this question rests "
             "on has changed; re-read the item and decide whether the question "
             "survives before it reaches him again.",
    "bare_root_msg": "`%s` names a repository, not the fact",
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
# CHECK 1b - IS THE REASON FOR ASKING HIM THIS STILL TRUE?
# ===========================================================================
# Same identity rule as CHECK 1, attached to a different sentence. See the
# PREMISE_RE block at the top for the argument and for item 1.8, the case that
# produced it.
#
# THE CENSUS IS NOT OPTIONAL. It rides on every verdict, clean or not, for the
# reason ceo-todos.py's DC line rides on every verdict: the correct outcome for
# an item whose premise is unobservable is SILENCE, and silence is also exactly
# what a checker that never ran produces. `PC evaluated=0` and no PC line at all
# are two very different facts and a reader must be able to tell them apart.
def check_premises(items, premise_sections, premise_required, roots,
                   absent_roots, revs, violations, skips, notes, fixes, pc):
    for it in items:
        if not it.get("premised"):
            continue
        iid = it["id"]
        pc["items"] += 1
        body = warrant_of(it, PREMISE_RE)

        if body is None or not body.strip():
            pc["unstated"].append(iid)
            if premise_required:
                violations.append((
                    iid, "PREMISE-MISSING",
                    "this item states no `**Premise:**`, and this record declares "
                    "PREMISE_REQUIRED=1. Every item in a CEO section must either "
                    "pin the observable fact its question rests on, or say "
                    "`unobservable \"<why not>\"`. An item whose premise nothing "
                    "watches goes on asking him a question that has already "
                    "answered itself - which is what item 1.8 did for three days."))
            continue

        um = PREMISE_UNOBSERVABLE_RE.match(body)
        if um:
            why = um.group("why").strip()
            if len(_words(why)) < MIN_UNOBSERVABLE_WORDS:
                pc["broken"] += 1
                violations.append((
                    iid, "PREMISE-UNOBSERVABLE-NO-REASON",
                    "`unobservable` must say WHY this question rests on nothing a "
                    "machine can see, in at least %d words. A bare marker exempts "
                    "nothing - it is a way to switch the check off while looking "
                    "like a considered decision." % MIN_UNOBSERVABLE_WORDS))
                continue
            pc["evaluated"] += 1
            pc["unobservable"] += 1
            pc["unobservable_items"].append((iid, why))
            continue

        stamps = STAMP_RE.findall(body)
        if not stamps:
            pc["broken"] += 1
            violations.append((
                iid, "PREMISE-UNPINNED",
                "the premise names no `<prefix>/path`@`<oid>` pin and does not "
                "declare itself unobservable, so nothing can tell when the fact "
                "it rests on stops being true. Either pin the artifact, or write "
                "`unobservable \"<why not>\"`: %s" % body[:110]))
            continue

        # THE STATED FACT. Its absence is the whole of item 1.8's defect: a pin
        # with no sentence beside it re-stamps mechanically, and 1.8's premise
        # sentence lived thirty lines below in prose, attached to nothing.
        fact = STAMP_RE.sub(" ", body)
        fact = fact.strip().lstrip("-\u2013\u2014").strip().strip(",;").strip()
        if len(_words(fact)) < MIN_PREMISE_WORDS:
            pc["broken"] += 1
            violations.append((
                iid, "PREMISE-NO-FACT",
                "the premise pins an artifact and states no fact about it. Say, in "
                "at least %d words, WHAT is true of that artifact that makes this "
                "question worth his time - otherwise a mismatch can be cleared by "
                "re-typing an object id, which is the original defect wearing a "
                "fix's clothes." % MIN_PREMISE_WORDS))
            continue

        pc["evaluated"] += 1
        pc["pinned"] += 1
        pc["stamps"] += len(stamps)
        before = len(skips)
        wanted, moved = walk_stamps(iid, stamps, roots, absent_roots, revs,
                                    skips, violations, PREMISE_STAMP_CODES)
        pc["skipped"] += len(skips) - before
        if moved:
            pc["moved"] += 1
            fixes.append((iid, "**Premise:** %s - %s"
                          % (", ".join("`%s`@`%s`" % (path, oid)
                                       for path, oid in wanted), fact)))

    if pc["unstated"] and not premise_required:
        notes.append((
            "PREMISE-NOT-STATED",
            "%d item(s) in the CEO sections state no `**Premise:**`, so nothing "
            "can tell whether the reason for asking has stopped being true: %s. "
            "On 2026-09-02 an item in this state had been asking the CEO to "
            "decide something that had already resolved itself. Declare "
            "PREMISE_REQUIRED=1 in the CEO-TODOs declaration to make this a "
            "refusal." % (len(pc["unstated"]), ", ".join(pc["unstated"]))))
    if pc["unobservable_items"]:
        notes.append((
            "PREMISE-UNOBSERVABLE",
            "%d item(s) declare that their question rests on nothing observable "
            "and are deliberately NOT checked: %s. This is a stated decision, "
            "not a gap - and the PC line proves the evaluator ran."
            % (len(pc["unobservable_items"]),
               "; ".join("%s (%s)" % (i, r) for i, r in pc["unobservable_items"]))))


# ===========================================================================
# CHECK 3 - THE ROW'S OWN FIRST SENTENCE
# ===========================================================================
# CHECK 1 answers "is this row still describing the same work?". CHECK 1b
# answers "is the reason for asking him this still true?". On 2026-09-06
# sixteen rows of one record were re-derived against the code and OVERTAKEN,
# and neither check had anything to say about eleven of them:
#
#     ELEVEN OF THE SIXTEEN OVERTAKEN ROWS HAD A MATCHING BLOB PIN.
#
# A pin proves a file has not moved. It cannot prove the SENTENCE about the
# file is still true. And rows here are written finding-first - a bold,
# present-tense headline stating the finding as filed, with corrections
# appended underneath - so a row can be entirely current in its body and still
# hand a false first sentence to anybody who quotes it. That is not
# carelessness; it is the shape of the page. Row 3.34 named cases `54` and
# `IN2` as the red ones in one suite; both pass, and the suite is red at 27
# other cases. A brief quoting that headline sent an engineer at two green
# tests. Four other briefs the same night carried premises that measurement
# refuted, every one taken from a headline rather than from a run.
#
# THE PROPERTY, and it is the CEO's own rule about briefs applied to the record
# those briefs are quoted from:
#
#     A ROW'S HEADLINE CARRIES THE COMMAND THAT SETTLES IT AND THAT COMMAND'S
#     OUTPUT, OR IT CARRIES THE WORD `unverified` AND WHAT WOULD SETTLE IT.
#     THERE IS NO THIRD SETTING.
#
#   - **Headline:** `4f2a9c1e83bd` - `./scripts/provision-claude-md.test.sh` -> `37 passed, 0 failed`
#   - **Headline:** `4f2a9c1e83bd` - unverified "one uninterrupted run of contract-integrity.test.sh, read at its final counts line"
#
# THE HEX IS THE ROW'S OWN DIGEST, and it is the half that fires. It is
# sha256/12 of everything else in this row - the prose, the corrections, the
# State warrant and its pins - normalized for formatting. So the moment
# anybody appends a correction underneath the headline, or re-stamps a pin, the
# digest stops matching and the next landing is refused until a person looks at
# the first sentence and decides whether it survived. That is the exact gap the
# eleven fell through: RE-STAMPING IS NOT RE-READING, and now a re-stamp cannot
# happen without the headline being handed back to a human in the same breath.
#
# WHY THE DIGEST COVERS THE `State:` PIN TOO, deliberately. The eleven rows had
# pins that MATCHED, so including the pin is not what catches them - the
# correction text is. But when a pin DOES move, the row is being re-stamped by
# somebody who has just been told the work changed, and that is the single best
# moment to ask whether the headline about that work is still true. Excluding
# the pin would buy a little less ceremony at the cost of the one moment the
# mechanism is most likely to be right.
#
# WHY NOT PARSE THE PROSE. Because it cannot be done. Nothing here has an
# opinion about whether an English sentence is true; it has an opinion about
# whether a human has looked since the row last moved, and about whether the
# row states something a machine can re-run. The re-running is
# scripts/row-headline-verify.sh's job, and it deliberately never happens in a
# hook: a record file is not a trusted script, and a check that took the 2,168
# seconds one of the suites in this record takes would be waived on its first
# land.
#
# WHY `unverified` IS A FIRST-CLASS ANSWER AND NOT AN ESCAPE HATCH. The
# alternative to a cheap honest answer is a check nobody can satisfy without
# hand-writing prose at every land, and a check like that is waived into
# uselessness inside a week. `unverified` costs one line, and it is COUNTED AND
# NAMED on every run by the HC census - so a record that answers `unverified`
# to everything prints a number saying so, at every landing, to everybody.
# Visible is the whole point: an unverifiable headline is not a defect, an
# unverifiable headline that reads as checked is.
#
# WHAT THIS CANNOT SEE, stated here rather than discovered later:
#   * Whether the stated command actually settles the headline, or whether the
#     recorded output was ever produced by it. `true` -> `` satisfies the
#     grammar. The verifier can re-run it; nothing can tell you it was the
#     right question to ask.
#   * A headline that goes false because THE WORLD moved while the row sat
#     still. No check that does not execute can see that, which is why the
#     verifier exists and why it is a separate, on-demand tool.
#   * A human who pastes the printed digest without re-reading the sentence.
#     Same limit CHECK 1 has, same answer: there is no re-stamp command, the
#     digest has to be retyped, and the refusal prints the command to re-run
#     beside it.
HEADLINE_MARKER_RE = re.compile(r"\*\*Headline:\*\*")
HEADLINE_RE = field_re("Headline")
# Where a warrant field ends when another one follows it on the same line. A
# table row carries all of its warrants in one cell, so `**Headline:**` cannot
# simply run to end of line the way `**State:**` does in the block shape.
FIELD_MARKER_RE = re.compile(r"\*\*[A-Z][A-Za-z-]*:\*\*")
HEADLINE_DIGEST_LEN = 12
HEADLINE_DIGEST_RE = re.compile(
    r"^\s*`(?P<digest>[0-9a-f]{%d})`\s*(?P<rest>.*)$" % HEADLINE_DIGEST_LEN)
# The evidence: a command and the output it produced, both backticked, with an
# arrow between them. Both arrow spellings are accepted because the record is
# written by hand and `->` is what a keyboard produces.
HEADLINE_EVIDENCE_RE = re.compile(
    r"`(?P<cmd>[^`]+)`\s*(?:→|->|=>)\s*`(?P<out>[^`]*)`")
HEADLINE_UNVERIFIED_RE = re.compile(r'^\s*unverified\s+"(?P<why>[^"]*)"\s*$')
MIN_UNVERIFIED_WORDS = 4
# Formatting, not content. Emphasis, code fences and table cell separators are
# removed before digesting, so that re-bolding a phrase or reflowing a cell
# does not demand a re-read while changing a WORD does.
_HEADLINE_NORM_DROP = re.compile(r"[*_`|]")


def _strip_headline_field(line):
    """The line with its `**Headline:**` field removed, whatever follows it."""
    m = HEADLINE_MARKER_RE.search(line)
    if not m:
        return line
    tail = line[m.end():]
    nxt = FIELD_MARKER_RE.search(tail)
    return line[:m.start()] + (tail[nxt.start():] if nxt else "")


def headline_body(item):
    """The `**Headline:**` body, truncated at the next warrant field."""
    for line in item["span"]:
        m = HEADLINE_RE.search(line)
        if not m:
            continue
        body = m.group("body")
        nxt = FIELD_MARKER_RE.search(body)
        if nxt:
            body = body[:nxt.start()]
        return body.strip().rstrip("|").strip()
    return None


def headline_digest(item):
    """sha256/12 of everything in the row EXCEPT the headline warrant itself."""
    body = "\n".join(_strip_headline_field(l) for l in item["span"])
    norm = re.sub(r"\s+", " ", _HEADLINE_NORM_DROP.sub("", body)).strip()
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:HEADLINE_DIGEST_LEN]


def check_headlines(items, terminal, headline_required, violations, notes,
                    fixes, hc):
    """CHECK 3 - the row's first sentence is re-derivable, or says it is not.

    THE CENSUS RIDES ON EVERY VERDICT, clean or not, declared or not, for the
    reason the PC line does: "every headline is current" and "no headline was
    ever checked" both produce silence, and a reader has to be able to tell
    them apart at a glance.
    """
    for it in items:
        if not it.get("headlined"):
            continue
        iid = it["id"]

        # A CLOSED row is exempt exactly as it is exempt from the pin: further
        # changes to finished work cannot falsify "this closed", and the row is
        # supposed to have left the page. Counted, never silent.
        state = warrant_of(it)
        if state:
            sm = STATUS_RE.match(state)
            if sm and sm.group("tok") in terminal:
                hc["terminal"] += 1
                continue

        hc["rows"] += 1
        body = headline_body(it)
        if body is None or not body.strip():
            hc["missing"].append(iid)
            if headline_required:
                violations.append((
                    iid, "HEADLINE-UNDERIVABLE",
                    "this row states a finding in its first sentence and carries "
                    "no `**Headline:**` warrant, and this record declares "
                    "ROW_HEADLINE_REQUIRED=1. Give it the command that settles it "
                    "and that command's output, or say `unverified \"<what would "
                    "settle it>\"`. Eleven rows with MATCHING pins were found "
                    "carrying false headlines on 2026-09-06: a pin proves the "
                    "file has not moved, never that the sentence about it is "
                    "true."))
            continue

        hc["stated"] += 1
        dm = HEADLINE_DIGEST_RE.match(body)
        if not dm:
            hc["broken"] += 1
            violations.append((
                iid, "HEADLINE-MALFORMED",
                "the headline warrant does not begin with a backticked "
                "%d-character digest of this row: %s"
                % (HEADLINE_DIGEST_LEN, body[:110])))
            continue

        rest = dm.group("rest").strip().lstrip("-–—").strip()
        um = HEADLINE_UNVERIFIED_RE.match(rest)
        evidence = None
        if um:
            why = um.group("why").strip()
            if len(_words(why)) < MIN_UNVERIFIED_WORDS:
                hc["broken"] += 1
                violations.append((
                    iid, "HEADLINE-UNVERIFIED-NO-REASON",
                    "`unverified` must say WHAT WOULD SETTLE IT, in at least %d "
                    "words. A bare marker exempts nothing - it is a way to switch "
                    "the check off while looking like a considered decision."
                    % MIN_UNVERIFIED_WORDS))
                continue
            hc["unverified"] += 1
            hc["unverified_rows"].append((iid, why))
        else:
            em = HEADLINE_EVIDENCE_RE.search(rest)
            if not em or not em.group("cmd").strip():
                hc["broken"] += 1
                violations.append((
                    iid, "HEADLINE-NO-EVIDENCE",
                    "the headline warrant states neither a command and its output "
                    "(`<command>` -> `<what it printed>`) nor `unverified "
                    "\"<what would settle it>\"`. Those are the only two settings, "
                    "and a headline that is neither is a claim written in a voice "
                    "that sounds checked: %s" % rest[:110]))
                continue
            evidence = em
            hc["verified"] += 1

        want = headline_digest(it)
        if dm.group("digest") != want:
            hc["stale"] += 1
            violations.append((
                iid, "HEADLINE-STALE",
                "this row has changed since its headline was last read. The "
                "warrant carries `%s` and the row now digests to `%s`. Something "
                "was appended, corrected or re-stamped underneath a first "
                "sentence nobody has re-read - which is exactly how eleven rows "
                "with matching pins came to carry false headlines. %s"
                % (dm.group("digest"), want,
                   ("Re-run it: %s" % evidence.group("cmd").strip())
                   if evidence else
                   "This headline is declared unverified; decide whether that is "
                   "still the honest answer.")))
            fixes.append((iid, "**Headline:** `%s` - %s" % (want, rest)))

    # NAMED RATHER THAN REFUSED BY DEFAULT, and the argument is the same one
    # PREMISE_REQUIRED makes: a record adopts this contract with rows already on
    # it, and some of those rows are written BY A MACHINE. The mechanical sweep
    # appends rows to this record on its own, and a check that refused every
    # land the moment the declaration went in would be deleted the same day —
    # which is failure mode 1 exactly, and this engine has three recorded
    # instances of it in a single day. So adoption costs nothing on day one: a
    # row without a warrant is COUNTED and NAMED at every landing, a row WITH
    # one is held to it from the first character, and the teeth are one
    # declared key away when the page is ready for them.
    if hc["missing"] and not headline_required:
        notes.append((
            "HEADLINE-NOT-STATED",
            "%d governed row(s) carry no `**Headline:**` warrant, so nothing can "
            "tell when their first sentence stops being true: %s. On 2026-09-06 "
            "eleven rows in exactly this state had MATCHING pins and false "
            "headlines. Declare ROW_HEADLINE_REQUIRED=1 in %s to make this a "
            "refusal."
            % (len(hc["missing"]), ", ".join(hc["missing"]),
               ROW_DECLARATION_LABEL)))
    if hc["unverified_rows"]:
        notes.append((
            "HEADLINE-UNVERIFIED",
            "%d row(s) state a finding nothing here can re-derive, and say so: "
            "%s. That is the honest setting rather than a gap - and this line is "
            "the reason it cannot also be the quiet one."
            % (len(hc["unverified_rows"]),
               "; ".join("%s (%s)" % (i, r) for i, r in hc["unverified_rows"]))))


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

    premise_sections = [str(s) for s in (job.get("premise_sections") or [])]
    premise_required = bool(job.get("premise_required"))
    overlap = sorted(set(premise_sections) & set(row_sections))
    if overlap:
        fail("section(s) %s are declared BOTH as row sections (a `**State:**` "
             "warrant, in %s) and as premise sections (a `**Premise:**` warrant, "
             "in the CEO-TODOs declaration). One section cannot carry two "
             "warrants, and guessing which was meant is how the wrong one stays "
             "live." % (", ".join(overlap), ROW_DECLARATION_LABEL))

    # CHECK 3's jurisdiction. A headline warrant over a section that carries no
    # `**State:**` warrant would be a second contract with its own vocabulary,
    # so it is refused rather than half-adopted: the headline is a claim ABOUT
    # the work a governed row points at.
    headline_sections = [str(s) for s in (job.get("headline_sections") or [])]
    stray = sorted(set(headline_sections) - set(row_sections))
    if stray:
        fail("section(s) %s are declared in ROW_HEADLINE_SECTIONS and are not "
             "row sections. A headline warrant is a claim about the work a "
             "governed row points at, so it can only be asked of a section that "
             "carries a `**State:**` warrant. Declared row sections: %s."
             % (", ".join(stray), ", ".join(row_sections)))

    tokens = [str(t) for t in (job.get("status_tokens") or [])]
    if not tokens:
        fail("no ROW_STATUS_TOKENS declared - every warrant would be rejected")
    terminal = set(str(t) for t in (job.get("terminal_tokens") or []))
    roots = job.get("artifact_roots") or {}
    absent_roots = job.get("absent_roots") or {}
    revs = job.get("identity_revs") or {}

    items, violations, seen_sections = parse_record(text, row_sections,
                                                    premise_sections,
                                                    headline_sections)
    for want in row_sections:
        if want not in seen_sections:
            fail("%s declares row section %s and no '## %s.' heading exists in "
                 "the record. The check would have had nothing to look at and "
                 "would have reported clean." % (label, want, want))
    for want in premise_sections:
        if want not in seen_sections:
            fail("%s declares premise section %s and no '## %s.' heading exists "
                 "in the record. The premise check would have had nothing to "
                 "look at and would have reported clean." % (label, want, want))

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

    # --- CHECK 1b: PREMISE -------------------------------------------------
    pc = {"items": 0, "evaluated": 0, "pinned": 0, "stamps": 0, "moved": 0,
          "unobservable": 0, "broken": 0, "skipped": 0, "unstated": [],
          "unobservable_items": []}
    check_premises(items, premise_sections, premise_required, roots,
                   absent_roots, revs, violations, skips, notes, fixes, pc)

    # --- CHECK 3: HEADLINE -------------------------------------------------
    hc = {"rows": 0, "stated": 0, "verified": 0, "unverified": 0, "stale": 0,
          "broken": 0, "terminal": 0, "missing": [], "unverified_rows": []}
    check_headlines(items, terminal, bool(job.get("headline_required")),
                    violations, notes, fixes, hc)
    if not headline_sections and governed:
        # NOT a violation, and it is the only place in this file that argues for
        # its own adoption. A record with no headline warrant is not broken; it
        # is a record where the eleven-with-matching-pins failure has nothing
        # watching it, and the difference has to be visible at a landing rather
        # than in a document nobody opens.
        notes.append((
            "HEADLINE-NOT-ADOPTED",
            "%d governed row(s) state findings in their first sentence and no "
            "section declares ROW_HEADLINE_SECTIONS, so nothing can tell when a "
            "headline stops being true. On 2026-09-06, eleven of sixteen "
            "overtaken rows in a record of this shape had MATCHING pins. Add "
            "ROW_HEADLINE_SECTIONS to %s to switch CHECK 3 on."
            % (len(governed), ROW_DECLARATION_LABEL)))

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
    # ALWAYS emitted, clean or not, declared or not. A consumer that prints this
    # line cannot report a reassuring verdict over an evaluator that did not run.
    out.append("PC\tsections=%s\titems=%d\tevaluated=%d\tpinned=%d\tstamps=%d"
               "\tmoved=%d\tunobservable=%d\tbroken=%d\tskipped=%d\tunstated=%d"
               % (",".join(premise_sections) or "-", pc["items"], pc["evaluated"],
                  pc["pinned"], pc["stamps"], pc["moved"], pc["unobservable"],
                  pc["broken"], pc["skipped"], len(pc["unstated"])))
    # THE HEADLINE CENSUS, on the same terms and for the same reason. A record
    # that has adopted CHECK 3 and a record that has never heard of it both go
    # quiet when every row is fine; `HC sections=-` and `HC sections=3 rows=35`
    # are the two facts a reader must never have to guess between.
    out.append("HC\tsections=%s\trequired=%d\trows=%d\tstated=%d\tverified=%d"
               "\tunverified=%d\tstale=%d\tmissing=%d\tbroken=%d\tterminal=%d"
               % (",".join(headline_sections) or "-",
                  1 if job.get("headline_required") else 0,
                  hc["rows"], hc["stated"], hc["verified"], hc["unverified"],
                  hc["stale"], len(hc["missing"]), hc["broken"], hc["terminal"]))
    # THE VERIFIER'S INPUT. Emitted only when asked, because it is the one thing
    # here that names a command somebody is about to RUN, and a checker that
    # hands out executable strings by default is a checker whose output is a
    # weapon. scripts/row-headline-verify.sh asks; no hook ever does.
    if job.get("emit_headlines"):
        for it in items:
            if not it.get("headlined"):
                continue
            body = headline_body(it)
            if not body:
                continue
            dm = HEADLINE_DIGEST_RE.match(body)
            rest = (dm.group("rest") if dm else body).strip().lstrip("-–—").strip()
            um = HEADLINE_UNVERIFIED_RE.match(rest)
            state = warrant_of(it) or ""
            stamps = STAMP_RE.findall(state)
            prefix = stamps[0][0].split("/", 1)[0] if stamps else "-"
            if um:
                out.append("HL\t%s\tunverified\t%s\t%s\t"
                           % (it["id"], prefix, um.group("why").strip()))
                continue
            em = HEADLINE_EVIDENCE_RE.search(rest)
            if em:
                out.append("HL\t%s\tevidence\t%s\t%s\t%s"
                           % (it["id"], prefix, em.group("cmd").strip(),
                              em.group("out").strip()))
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
