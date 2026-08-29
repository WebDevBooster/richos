#!/usr/bin/env python3
"""ceo-queue.py — THE PREDICATE, and the RENDERER that shares its parse.

Read scripts/lib/ceo-queue.sh first; it carries the rationale. This file carries
only the mechanism, because the mechanism has to be exact.

===========================================================================
WHY THE RENDERER IS IN HERE AND NOT IN THE REPOSITORY THAT OWNS THE RECORD
===========================================================================
The first version of the queue VIEW was a repo-local node script that parsed
the record a second time, with its own regexes for the item heading and the
four fields, and its own hard-coded knowledge of where the sibling repository
lives. That is two independent parsers of one file — the exact shape of the
defect this engine has now found in itself three times (a typed guard list, a
typed suite list, a typed count). Two parsers agree until they don't, and the
day they disagree the CEO reads a page the gate says is fine.

So there is ONE parse. The lint and the view are two outputs of it, and
"is the view current?" is answered by rendering from that same parse and
comparing bytes — never by trusting a generator the repository supplies.

INPUT   one JSON job, path given as argv[1] (or on stdin when argv[1] is "-"):

    {
      "mode":             "lint" | "render",
      "record_label":     "wiki/open-items.md",   # for messages only
      "text":             "<the whole record>",
      "ceo_sections":     ["1", "2"],
      "preparer_section": "3",
      "artifact_roots":   {"richos-hq": "/abs/path", ...},   # prefix -> root
      "root_specs":       {"richos-hq": ".", ...},           # prefix -> DECLARED
                                                             # root, verbatim
      "absent_roots":     {"richos": "../richos", ...},      # declared, not on
                                                             # this machine
      "ready_state":      "READY-FOR-CEO",
      "blocked_state":    "BLOCKED-ON-RICH",

      # --- the entry point ---
      "queue_view":       "CEO-QUEUE.md",     # repo-relative, top-level
      "view_text":        "<bytes on disk>",  # null when it is not there
      "root_readme":      "README.md",
      "readme_text":      "<bytes on disk>",  # null when it is not there
      "top_level_md":     [["OTHER.md", "<text>"], ...],   # every OTHER
                                                           # top-level *.md

      # --- the cold open ---
      "cold_open_dir":    "docs/cold-open",   # "" = not declared
      "cold_open_dir_present": true,
      "cold_open":        [["NAME.md", "<text>"], ...],
      "prompt_fingerprint": "<hex>"           # of the engine's current prompt
    }

OUTPUT  tab-separated lines on stdout. The first line is the verdict:

    CLEAN       <items-checked>  <skipped-count>
    VIOLATIONS  <count>  <items-checked>  <skipped-count>
    BROKEN      <reason>

followed, for VIOLATIONS, by one line per finding:

    V     <section>  <item-id>  <CODE>  <message>

and, always, by one line per artifact whose declared root is not on this
machine — never a violation, always named, so a verdict never overstates its
own coverage:

    SKIP  <section>  <item-id>  <path>  <reason>

and by two kinds of line that are not verdicts about the record at all:

    FP    <front-door-fingerprint>   always, so the cold-open harness and the
                                     gate use one number and nobody computes it
                                     a second way.
    NOTE  <CODE>  <message>          a stated LIMIT of this run. Never blocks.
                                     Exists so a clean verdict can never be
                                     read as "everything was checked" when
                                     something was not declared for checking.

In "render" mode stdout is the rendered view and nothing else; a BROKEN
condition prints a BROKEN line and exits 3, so a caller can never mistake a
diagnostic for the document.

EXIT    0 always in lint mode, unless the job itself is unreadable (2).
        In render mode: 0 rendered, 2 unreadable job, 3 record not renderable.
        The VERDICT is the product; a non-zero exit would make "the record is
        bad" and "the checker is bad" the same signal to every caller.
"""

import hashlib
import json
import os
import re
import sys

# --- Grammar ---------------------------------------------------------------
# Deliberately narrow. A heading in a CEO section that does not match is a
# VIOLATION, not a skip: the way this mechanism dies is by someone writing an
# item in a shape the parser does not recognise and the lint reporting CLEAN
# over it. There is no shape that is silently not-an-item.

SECTION_RE = re.compile(r"^##\s+(?P<num>\d+)\.\s+(?P<title>.*)$")
ANY_H2_RE = re.compile(r"^##\s+\S")
ANY_H3_RE = re.compile(r"^###\s+\S")

# `### 2.1 READY-FOR-CEO - Verify the podcast reference transcript`
# The dash may be em, en or ASCII: a rule that depends on typing a particular
# Unicode character is a rule a human gets wrong at 2 a.m.
ITEM_RE = re.compile(
    r"^###\s+(?P<id>\d+\.\d+[a-z]?)\s+(?P<state>[A-Z][A-Z-]+)\s*[—–-]\s*(?P<title>\S.*?)\s*$"
)

FIELD_RE = re.compile(
    r"^\s*[-*]\s+\*\*(?P<name>Open|Time|Done|Unblocks):\*\*\s*(?P<value>.*?)\s*$"
)

# A '- **Key:** value' line in a cold-open transcript. Same shape, different
# vocabulary, and deliberately not the same regex: FIELD_RE names the four
# fields of a queue item and must not quietly start matching something else.
META_RE = re.compile(r"^\s*[-*]\s+\*\*(?P<k>[A-Za-z][A-Za-z-]*):\*\*\s*(?P<v>.*?)\s*$")

BACKTICKED_RE = re.compile(r"`([^`]+)`")

# A duration, not a mood. "soon", "a while", "TBD" and "" all fail.
# Accepts: 5 min | 30 minutes | 1.5 hours | 10-15 minutes | 2-3 h
DURATION_RE = re.compile(
    r"^\s*\d+(?:\.\d+)?\s*(?:[-–—]\s*\d+(?:\.\d+)?\s*)?"
    r"(?:s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)\b",
    re.IGNORECASE,
)

# The same shape again, capturing, for the view's total. The UPPER bound of a
# range is used: a queue that under-promises the CEO's evening is the failure
# that matters.
DURATION_PARTS_RE = re.compile(
    r"^\s*(?P<lo>\d+(?:\.\d+)?)\s*(?:[-–—]\s*(?P<hi>\d+(?:\.\d+)?)\s*)?"
    r"(?P<unit>s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)\b",
    re.IGNORECASE,
)

_UNIT_MINUTES = {
    "s": 1.0 / 60, "sec": 1.0 / 60, "secs": 1.0 / 60,
    "second": 1.0 / 60, "seconds": 1.0 / 60,
    "m": 1.0, "min": 1.0, "mins": 1.0, "minute": 1.0, "minutes": 1.0,
    "h": 60.0, "hr": 60.0, "hrs": 60.0, "hour": 60.0, "hours": 60.0,
    "d": 480.0, "day": 480.0, "days": 480.0,   # a working day, not 24h
}

# Words that fill a field without answering it. Checked against the WHOLE
# stripped value, never as a substring: "done when the TBD list is empty" is a
# real criterion and must not be refused.
VACUOUS = {
    "tbd", "todo", "to do", "n/a", "na", "none", "unknown", "?", "??", "???",
    "-", "—", "see above", "see below", "as above", "pending", "later",
}

REQUIRED_FIELDS = ("Open", "Time", "Done", "Unblocks")

MIN_DONE_WORDS = 4
MIN_UNBLOCKS_WORDS = 3

# How much of the repo-root README counts as "the front door". A newcomer who
# must read to line 300 to discover where to start has not been given an entry
# point, he has been given a search. 40 lines is about one screen.
README_HEAD_LINES = 40

# The machine-readable provenance line the renderer stamps on the view. Two
# jobs: it tells a human the file is generated, and it lets the singularity
# check find a SECOND generated queue view that somebody copied.
GENERATED_SENTINEL = "GENERATED BY richos-engine ceo-queue-render"

# Every field a cold-open transcript must carry to count as one. A file that is
# not a transcript must never satisfy the obligation to produce one.
COLD_OPEN_FIELDS = ("Surface-fingerprint", "Prompt-fingerprint", "Reader", "Run-by", "Date")
COLD_OPEN_ANSWER_HEADING = "## What the reader answered"
COLD_OPEN_MIN_ANSWER_WORDS = 40


def words(value):
    return [w for w in re.split(r"\s+", re.sub(r"[`*_\[\]()]", " ", value)) if w]


def fail(reason):
    sys.stdout.write("BROKEN\t%s\n" % reason)
    sys.exit(0)


# ===========================================================================
# THE PARSE — one function, used by the lint and by the renderer
# ===========================================================================
def parse_record(text, ceo_sections):
    """-> (items, parse_violations, section_titles, seen_sections)

    items is in document order. Every '###' heading inside a CEO section is
    either an item or a recorded MALFORMED-HEADING violation; there is no third
    outcome, because a shape the parser silently ignores is a shape somebody
    will eventually write an unprepared item in.
    """
    lines = text.split("\n")
    seen_sections = {}
    section_titles = {}
    for idx, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if m:
            seen_sections.setdefault(m.group("num"), idx)
            section_titles.setdefault(m.group("num"), m.group("title").strip())

    items = []
    violations = []
    cur = [None]
    section = None
    in_ceo = False

    def close():
        if cur[0] is not None:
            items.append(cur[0])
            cur[0] = None

    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            close()
            section = m.group("num")
            in_ceo = section in ceo_sections
            continue
        if ANY_H2_RE.match(line):
            # An unnumbered '## ...' heading ends the numbered sections.
            close()
            section = None
            in_ceo = False
            continue

        if not in_ceo:
            continue

        if ANY_H3_RE.match(line):
            close()
            im = ITEM_RE.match(line)
            if not im:
                violations.append(
                    (section, "?", "MALFORMED-HEADING",
                     "heading is not '### <id> <STATE> - <title>': %s" % line.strip())
                )
                continue
            cur[0] = {
                "section": section,
                "id": im.group("id"),
                "state": im.group("state"),
                "title": im.group("title"),
                "fields": {},
                "dupes": [],
            }
            continue

        # A table row inside a CEO section. This is the escape hatch that would
        # otherwise reopen everything: revert the section to a markdown table
        # and every row becomes invisible to a parser that only reads '###'
        # blocks, so the lint reports clean over the exact format that failed.
        if line.lstrip().startswith("|"):
            violations.append(
                (section, cur[0]["id"] if cur[0] else "?", "TABLE-ROW-IN-CEO-SECTION",
                 "a table row in a CEO section is not a checkable item; every item "
                 "here is a '### <id> <STATE> - <title>' block")
            )
            continue

        if cur[0] is None:
            continue

        fm = FIELD_RE.match(line)
        if fm:
            name = fm.group("name")
            if name in cur[0]["fields"]:
                cur[0]["dupes"].append(name)
            else:
                cur[0]["fields"][name] = fm.group("value")

    close()
    return items, violations, section_titles, seen_sections


# ===========================================================================
# THE RENDERER
# ===========================================================================
# A PURE FUNCTION of (record text, declaration). Nothing in here may consult
# the filesystem. If the view depended on whether the sibling repository
# happens to be cloned, "is the view current?" would have a different answer on
# every machine and the staleness gate would be unusable — so the artifact
# check stays where it belongs, in the lint, which refuses the item outright.
# ===========================================================================
def duration_minutes(value):
    m = DURATION_PARTS_RE.match((value or "").strip())
    if not m:
        return None
    hi = m.group("hi") or m.group("lo")
    per = _UNIT_MINUTES.get(m.group("unit").lower())
    if per is None:
        return None
    return float(hi) * per


def artifact_link(open_field, root_specs):
    """`prefix/path` -> a clickable relative link when the DECLARED root of that
    prefix is this repository, and an explicit "not in this checkout" note when
    it is not. Declared, never resolved.

    THE NOTE IS NOT DECORATION. The first cold reading of a real queue found
    this, in these words: three of nine linked items "point at paths that don't
    exist anywhere in this checkout — not just missing files, but the whole
    `richos/` directory is absent. This directly contradicts the README's
    promise that 'the thing you open already exists on disk'. I had to guess
    these live in a sibling code repo not checked out here."

    The lint had been green the whole time, and correctly so: it resolves that
    prefix against a sibling repository that IS on the maintainer's machine. The
    checker was right and the page was still lying to its reader, which is the
    entire reason a surface gets read by somebody who is not its builder.
    """
    paths = BACKTICKED_RE.findall(open_field or "")
    raw = paths[0].strip() if paths else (open_field or "?").strip()
    if "/" in raw:
        prefix, remainder = raw.split("/", 1)
        spec = (root_specs or {}).get(prefix)
        if spec in (".", "./") and remainder:
            return "[`%s`](%s)" % (raw, remainder)
        if spec:
            return ("`%s` — _in the separate `%s` repository (`%s`), not in this one_"
                    % (raw, prefix, spec))
    return "`%s`" % raw


def render_view(items, section_titles, ceo_sections, record_label,
                preparer_section, blocked_state, root_specs):
    total = 0.0
    undated = 0
    for i in items:
        mins = duration_minutes(i["fields"].get("Time", ""))
        if mins is None:
            undated += 1
        else:
            total += mins

    out = []
    out.append("<!-- %s from %s. DO NOT EDIT: every change belongs in the record. -->"
               % (GENERATED_SENTINEL, record_label))
    out.append("")
    out.append("# Your queue")
    out.append("")
    if not items:
        out.append("**Nothing is waiting on you.**")
        out.append("")
    else:
        head = "**%d item%s %s waiting on you.**" % (
            len(items), "" if len(items) == 1 else "s",
            "is" if len(items) == 1 else "are")
        if total > 0:
            head += " They total about **%d minutes**." % int(round(total))
        out.append(head)
        out.append("")
        if undated:
            out.append("_%d of them carry no stated duration, so that total is a floor, not an estimate._"
                       % undated)
            out.append("")
        for sec in ceo_sections:
            n = len([i for i in items if i["section"] == sec])
            out.append("- **%d** — %s" % (n, section_titles.get(sec, "section %s" % sec)))
        out.append("")
    out.append("Everything that reaches this page is *prepared*: the thing you open already exists on")
    out.append("disk, and it says what \"done\" means. Anything not in that state is not here — it is unfinished")
    out.append("preparation, filed in section %s of the record as `%s`."
               % (preparer_section or "the preparer's", blocked_state))
    elsewhere = sorted({i["fields"].get("Open", "").strip().strip("`").split("/", 1)[0]
                        for i in items
                        if "/" in i["fields"].get("Open", "").strip().strip("`")
                        and (root_specs or {}).get(
                            i["fields"].get("Open", "").strip().strip("`").split("/", 1)[0])
                        not in (".", "./", None)})
    if elsewhere:
        out.append("")
        out.append("Some items live in a separate repository (%s) and are marked as such — this checkout"
                   % ", ".join("`%s`" % p for p in elsewhere))
        out.append("does not contain those files.")
    out.append("")
    out.append("> **Generated file — do not edit.** Source: [`%s`](%s)." % (record_label, record_label))
    # The path is qualified because the first cold reading of a real queue went
    # looking for `scripts/ceo-queue-render.sh` IN THE REPOSITORY, did not find
    # it, and concluded it could not tell whether the page it was reading was
    # trustworthy machine output or something hand-edited. A generated file that
    # cites a command its reader cannot find undermines its own provenance.
    out.append("> Regenerate it from the RichOS engine — which is installed outside this repository,")
    out.append("> normally at `~/.claude/richos-engine`: `scripts/ceo-queue-render.sh <this repo>`.")
    out.append("")

    for sec in ceo_sections:
        rows = [i for i in items if i["section"] == sec]
        out.append("---")
        out.append("")
        out.append("## %s" % section_titles.get(sec, "Section %s" % sec))
        out.append("")
        if not rows:
            out.append("_Nothing._")
            out.append("")
            continue
        for i in rows:
            out.append("### %s — %s" % (i["id"], i["title"]))
            out.append("")
            out.append("**%s** · open %s" % (
                (i["fields"].get("Time") or "?").strip(),
                artifact_link(i["fields"].get("Open") or "?", root_specs)))
            out.append("")
            out.append("- **Done when:** %s" % (i["fields"].get("Done") or "?").strip())
            out.append("- **Unblocks:** %s" % (i["fields"].get("Unblocks") or "?").strip())
            out.append("")

    return "\n".join(out).rstrip("\n") + "\n"


def front_door_fingerprint(view_name, rendered, readme_text):
    """The identity of what a newcomer meets, and nothing else.

    THREE PARTS, and the exclusion is the design:
      * the view's FILE NAME — rename it and every existing transcript
        describes a door that is no longer there;
      * the view's NAVIGATIONAL SHAPE — everything before the first item, plus
        the section headings. The counts, the total, the explanation of what
        the page is and how it is organised: exactly the material a cold reader
        uses to answer "what am I supposed to do, where do I start, how long";
      * the head of the repo-root README — the front door itself.

    NOT included: the per-item detail. Rewording item 1.3's criterion does not
    change what a stranger concludes about where to start, and a fingerprint
    that churned on every copy edit would be a gate people learn to satisfy
    mechanically — which is worse than no gate.
    """
    shape = []
    for line in (rendered or "").split("\n"):
        if line.startswith("### "):
            break
        shape.append(line)
    shape += [l for l in (rendered or "").split("\n") if l.startswith("## ")]
    head = "\n".join((readme_text or "").split("\n")[:README_HEAD_LINES])
    blob = "view-name:%s\n--\nview-shape:\n%s\n--\nreadme-head:\n%s\n" % (
        view_name or "", "\n".join(shape), head)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ===========================================================================
def main():
    if len(sys.argv) < 2:
        sys.stderr.write("ceo-queue.py: expected a job file path (or '-')\n")
        return 2
    try:
        if sys.argv[1] == "-":
            job = json.load(sys.stdin)
        else:
            with open(sys.argv[1], encoding="utf-8") as fh:
                job = json.load(fh)
    except Exception as exc:  # unreadable job = broken CHECKER, not a verdict
        sys.stderr.write("ceo-queue.py: unreadable job: %s\n" % exc)
        return 2

    text = job.get("text")
    if not isinstance(text, str):
        fail("job carries no record text")

    mode = job.get("mode") or "lint"
    label = job.get("record_label") or "<record>"
    ceo_sections = [str(s) for s in (job.get("ceo_sections") or [])]
    preparer_section = str(job.get("preparer_section") or "")
    roots = job.get("artifact_roots") or {}
    root_specs = job.get("root_specs") or {}
    absent_roots = job.get("absent_roots") or {}
    ready_state = job.get("ready_state") or "READY-FOR-CEO"
    blocked_state = job.get("blocked_state") or "BLOCKED-ON-RICH"

    def broken(msg):
        if mode == "render":
            sys.stdout.write("BROKEN\t%s\n" % msg)
            sys.exit(3)
        fail(msg)

    if not ceo_sections:
        broken("no CEO sections declared - a lint with nothing to check is not a pass")

    items, violations, section_titles, seen_sections = parse_record(text, ceo_sections)

    # Every declared section must EXIST. Renaming or deleting section 2 must
    # not be a way to make this lint quietly have nothing to say; that is the
    # same defect as a suite that no-ops when its subject is absent.
    for want in ceo_sections:
        if want not in seen_sections:
            broken("%s declares CEO section %s, and no '## %s.' heading exists in the record. "
                   "The lint would have had nothing to check and would have reported clean."
                   % (label, want, want))
    if preparer_section and preparer_section not in seen_sections:
        broken("%s declares preparer section %s, and no '## %s.' heading exists. "
               "There would be nowhere to move an unprepared item to."
               % (label, preparer_section, preparer_section))

    # The view shows every item that is IN a CEO section, whatever its state: a
    # page that quietly dropped a wrongly-stated row would hide the thing the
    # lint is about to refuse.
    rendered = render_view(items, section_titles, ceo_sections, label,
                           preparer_section, blocked_state, root_specs)

    if mode == "render":
        sys.stdout.write(rendered)
        return 0

    skips = []
    seen_ids = {}
    unreachable = []
    for item in items:
        check_item(item, violations, skips, seen_ids, roots, absent_roots,
                   ready_state, blocked_state, preparer_section, unreachable)
    checked = len(items)

    notes = []
    # NOT A VIOLATION, and never will be: a private artifact prepared for the
    # CEO is very often deliberately gitignored, and that is its correct home.
    # But it means the link on his page is dead for everybody who is not on this
    # machine — in a fresh clone, and on the repository's web view. The first
    # cold reading found exactly this and reported the whole directory absent.
    # The lint cannot fix it and must not block it; it can refuse to be quiet.
    if unreachable:
        notes.append(("ARTIFACT-NOT-IN-THE-REPOSITORY",
                      "%d item(s) point at a file that exists on this machine but is NOT "
                      "committed (git-ignored): %s. Correct for private preparation, and "
                      "the link is dead in a fresh clone and on the web view — so the page "
                      "only works for whoever prepared it."
                      % (len(unreachable), ", ".join(unreachable))))
    check_entry_point(job, rendered, violations, notes)
    fp = front_door_fingerprint(job.get("queue_view") or "", rendered,
                                job.get("readme_text") or "")
    check_cold_open(job, fp, violations, notes)

    out = []
    for v in violations:
        out.append("V\t%s\t%s\t%s\t%s" % v)
    for s in skips:
        out.append("SKIP\t%s\t%s\t%s\t%s" % s)
    out.append("FP\t%s" % fp)
    for n in notes:
        out.append("NOTE\t%s\t%s" % n)

    if violations:
        sys.stdout.write("VIOLATIONS\t%d\t%d\t%d\n"
                         % (len(violations), checked, len(skips)))
    else:
        sys.stdout.write("CLEAN\t%d\t%d\n" % (checked, len(skips)))
    sys.stdout.write("\n".join(out) + "\n")
    return 0


# ===========================================================================
# REACHABLE, NOT MERELY PREPARED
# ===========================================================================
# The first version of this contract enforced that every item waiting on the
# CEO was prepared, and shipped with nowhere for him to look. Nine prepared
# items lived inside a 173-line record mixed with everything else, and the only
# new artifact was a dotfile. The landing report said "the contract is live, 9
# prepared items" — true of the record, false of his experience.
#
# The reason that half fell out silently is the general case and worth stating:
# EVERY acceptance criterion in that landing was INTERNAL. Lint exit codes,
# guard tests, probe layers, git state. A view has no exit code, so it had no
# test that could fail, so it was never in scope and nothing said so.
#
# These checks give the outside half an exit code too.
def check_entry_point(job, rendered, violations, notes):
    view = (job.get("queue_view") or "").strip()
    sec = "-"
    iid = "entry"

    def bad(code, message):
        violations.append((sec, iid, code, message))

    if not view:
        # Not "no view declared, nothing to check". A queue with no entry point
        # IS the defect, so an undeclared view is the defect written as config.
        bad("NO-ENTRY-POINT-DECLARED",
            "no QUEUE_VIEW in the declaration. A queue nobody can find is a queue "
            "nobody has. Declare QUEUE_VIEW=<TOP-LEVEL-FILE.md> and render it with "
            "the engine's scripts/ceo-queue-render.sh.")
        return

    if "/" in view or view.startswith(".."):
        bad("ENTRY-POINT-NOT-TOP-LEVEL",
            "QUEUE_VIEW '%s' is not at the repository root. The entry point is the "
            "first thing a stranger sees in a directory listing, or it is not an "
            "entry point." % view)
    if view.startswith("."):
        bad("ENTRY-POINT-IS-A-DOTFILE",
            "QUEUE_VIEW '%s' is a dotfile. `ls` does not show it and a file browser "
            "hides it. The CEO's words were: why am I not IMMEDIATELY seeing my "
            "queue in the repo." % view)

    view_text = job.get("view_text")
    if view_text is None:
        bad("ENTRY-POINT-MISSING",
            "QUEUE_VIEW '%s' is declared and is not on disk. Render it: "
            "scripts/ceo-queue-render.sh <repo>." % view)
    elif view_text != rendered:
        # The staleness gate. Bytes, not a heuristic: a projection that is
        # ALMOST current is a page telling the CEO something the record does
        # not say, and there is no version of that which is acceptable.
        bad("ENTRY-POINT-STALE",
            "QUEUE_VIEW '%s' is not what the record renders to. It is a projection, "
            "not a second copy — regenerate it: scripts/ceo-queue-render.sh <repo>. "
            "(%s)" % (view, _first_difference(view_text, rendered)))

    readme = (job.get("root_readme") or "README.md").strip()
    readme_text = job.get("readme_text")
    if readme_text is None:
        bad("ROOT-README-MISSING",
            "the repository root has no %s, so nothing at the front door names the "
            "queue. The entry point has to be reachable from the first page a "
            "stranger opens." % readme)
    else:
        head = "\n".join(readme_text.split("\n")[:README_HEAD_LINES])
        if view not in head:
            where = "it appears further down" if view in readme_text else "it appears nowhere in the file"
            bad("ENTRY-POINT-NOT-DISCOVERABLE",
                "%s does not name '%s' in its first %d lines (%s). An entry point a "
                "newcomer has to search for is a search, not an entry point."
                % (readme, view, README_HEAD_LINES, where))

    # SINGULAR. The realistic drift is not a rival page written from scratch —
    # it is a COPY of this one that then stops being regenerated, so two pages
    # both look authoritative and disagree.
    others = sorted(name for name, body in (job.get("top_level_md") or [])
                    if name != view and GENERATED_SENTINEL in (body or ""))
    if others:
        bad("MULTIPLE-ENTRY-POINTS",
            "these top-level file(s) also carry the generated-queue marker: %s. One "
            "queue, one page. Two pages that both look authoritative is how a stale "
            "one gets read." % ", ".join(others))


def _first_difference(a, b):
    al, bl = a.split("\n"), b.split("\n")
    for n in range(max(len(al), len(bl))):
        x = al[n] if n < len(al) else "<end of file>"
        y = bl[n] if n < len(bl) else "<end of file>"
        if x != y:
            return ("first difference at line %d: on disk %r, the record renders %r"
                    % (n + 1, x[:110], y[:110]))
    return "the files differ only in trailing bytes"


# ===========================================================================
# THE COLD OPEN — and the exact line between machine and judgment
# ===========================================================================
# THE MACHINE ENFORCES THAT A COLD READER WAS CONSULTED. IT NEVER ENFORCES WHAT
# THE COLD READER SAID.
#
# That line is the whole design. A gate that could only be satisfied by a
# favourable transcript is a gate that teaches people to produce favourable
# transcripts, and the FINDING — the thing the exercise exists to surface —
# would be the one output that costs its author a blocked commit.
#
# So: a transcript must EXIST for the front door as it currently stands, and it
# must structurally be a transcript. That is the end of the machine's opinion.
# What the reader concluded is for a human to read, and the harness prints it.
def check_cold_open(job, fp, violations, notes):
    sec = "-"
    iid = "cold-open"
    d = (job.get("cold_open_dir") or "").strip()

    if not d:
        # Never silent. A clean verdict that did not check this must say so, or
        # "clean" quietly grows to mean something it never checked.
        notes.append(("COLD-OPEN-NOT-DECLARED",
                      "no COLD_OPEN_DIR in the declaration, so nothing has ever read "
                      "this repository's CEO surface from outside. The queue is "
                      "verified by the people who built it and by nobody else."))
        return

    def bad(code, message):
        violations.append((sec, iid, code, message))

    how = ("Run it: scripts/cold-open.sh --run <repo>   (or --brief for the verbatim "
           "prompt to hand to a person, then --record). Front door now: %s" % fp[:16])

    if not job.get("cold_open_dir_present"):
        bad("COLD-OPEN-DIR-MISSING",
            "COLD_OPEN_DIR '%s' is declared and is not on disk. %s" % (d, how))
        return

    transcripts = job.get("cold_open") or []
    if not transcripts:
        bad("COLD-OPEN-NEVER-RUN",
            "no transcript in '%s'. Nobody without the builders' knowledge has ever "
            "been asked what this repository wants from the CEO. %s" % (d, how))
        return

    want_prompt = (job.get("prompt_fingerprint") or "").strip()
    malformed = []
    surfaces = []
    match = None
    for name, body in transcripts:
        fields = {}
        for line in (body or "").split("\n"):
            m = META_RE.match(line)
            if m:
                fields.setdefault(m.group("k"), m.group("v").strip().strip("`"))
        missing = [f for f in COLD_OPEN_FIELDS if not fields.get(f)]
        if missing:
            malformed.append("%s (no %s)" % (name, ", ".join(missing)))
            continue
        answer = _section_body(body or "", COLD_OPEN_ANSWER_HEADING)
        if len(words(answer)) < COLD_OPEN_MIN_ANSWER_WORDS:
            malformed.append("%s ('%s' is under %d words — a transcript with no "
                             "answers in it is not evidence that anybody read anything)"
                             % (name, COLD_OPEN_ANSWER_HEADING, COLD_OPEN_MIN_ANSWER_WORDS))
            continue
        surface = fields.get("Surface-fingerprint", "").replace("sha256:", "")
        prompt = fields.get("Prompt-fingerprint", "").replace("sha256:", "")
        surfaces.append("%s=%s" % (name, surface[:16] or "?"))
        if surface == fp and (not want_prompt or prompt == want_prompt):
            match = name
            break

    if match:
        if malformed:
            notes.append(("COLD-OPEN-MALFORMED-IGNORED",
                          "a current transcript exists (%s); these file(s) in '%s' are not "
                          "transcripts and were ignored: %s"
                          % (match, d, "; ".join(malformed))))
        return

    if malformed and not surfaces:
        bad("COLD-OPEN-TRANSCRIPT-MALFORMED",
            "'%s' contains no usable transcript: %s. %s" % (d, "; ".join(malformed), how))
        return

    bad("COLD-OPEN-STALE",
        "the CEO-facing front door has changed and no cold reader has seen the one "
        "that exists now. wanted %s; transcripts on file describe %s. %s"
        % (fp[:16], ", ".join(surfaces) or "nothing", how))


def _section_body(text, heading):
    """Everything after <heading>, to the end of the file.

    TO THE END, not to the next '## ' — and that was learned the hard way on the
    first real run. The prompt asks its six questions as headings, so a genuine
    answer is FULL of '## ' lines; stopping at the first one measured an empty
    string and called a long, careful reading malformed. The answer is written
    last in the transcript for exactly this reason.
    """
    out = []
    on = False
    for line in text.split("\n"):
        if not on and line.strip() == heading:
            on = True
            continue
        if on:
            out.append(line)
    return "\n".join(out)


def _git_ignored(root, relpath):
    """True when <root>/<relpath> is tracked-by-nobody because git ignores it.
    Unknown (no git, not a repo, anything at all goes wrong) -> False: this
    feeds a NOTE, and a note that fires on uncertainty is a note people learn
    to ignore.
    """
    try:
        import subprocess
        return subprocess.call(
            ["git", "-C", root, "check-ignore", "-q", relpath],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
    except Exception:
        return False


def check_item(item, violations, skips, seen_ids, roots, absent_roots,
               ready_state, blocked_state, preparer_section, unreachable=None):
    sec = item["section"]
    iid = item["id"]

    def bad(code, message):
        violations.append((sec, iid, code, message))

    # 1. State. BLOCKED-ON-RICH is a legitimate, useful state - in the
    #    preparer's own section. In a CEO section it is a claim that the CEO is
    #    blocked by something nobody has prepared, which is the whole defect.
    if item["state"] == blocked_state:
        bad("BLOCKED-IN-CEO-SECTION",
            "state is %s, so it is NOT waiting on the CEO. Move it to section %s."
            % (blocked_state, preparer_section or "the preparer's"))
    elif item["state"] != ready_state:
        bad("UNKNOWN-STATE",
            "state '%s' is neither %s nor %s" % (item["state"], ready_state, blocked_state))

    # 2. Filed under the right number, and only once.
    if not iid.startswith(sec + "."):
        bad("WRONG-SECTION", "item %s is filed under section %s" % (iid, sec))
    if iid in seen_ids:
        bad("DUPLICATE-ID", "item id %s is used more than once" % iid)
    seen_ids[iid] = True

    for name in item["dupes"]:
        bad("DUPLICATE-FIELD", "field **%s:** appears more than once" % name)

    # 3. The four fields.
    for name in REQUIRED_FIELDS:
        value = item["fields"].get(name)
        if value is None:
            bad("MISSING-FIELD",
                "no **%s:** line. Every item in a CEO section carries all four: %s."
                % (name, ", ".join(REQUIRED_FIELDS)))
            continue
        if not value.strip():
            bad("EMPTY-FIELD", "**%s:** is empty" % name)
            continue
        if value.strip().lower().strip(".") in VACUOUS:
            bad("VACUOUS-FIELD",
                "**%s:** says '%s', which fills the field without answering it"
                % (name, value.strip()))

    # 4. Time must be a duration.
    t = item["fields"].get("Time", "")
    if t.strip() and not DURATION_RE.match(t.strip()):
        bad("TIME-NOT-A-DURATION",
            "**Time:** '%s' is not a duration (e.g. '30 minutes', '1.5 hours')" % t.strip())

    # 5. Done / Unblocks must say something.
    d = item["fields"].get("Done", "")
    if d.strip() and len(words(d)) < MIN_DONE_WORDS:
        bad("DONE-TOO-VAGUE",
            "**Done:** '%s' is under %d words - it has to be checkable by the "
            "person handing the work back" % (d.strip(), MIN_DONE_WORDS))
    u = item["fields"].get("Unblocks", "")
    if u.strip() and len(words(u)) < MIN_UNBLOCKS_WORDS:
        bad("UNBLOCKS-TOO-VAGUE",
            "**Unblocks:** '%s' is under %d words" % (u.strip(), MIN_UNBLOCKS_WORDS))

    # 6. THE ARTIFACT. The heart of the mechanism: an item may not claim to be
    #    waiting on the CEO unless the thing he touches already exists on disk.
    open_field = item["fields"].get("Open")
    if open_field is None or not open_field.strip():
        return
    paths = BACKTICKED_RE.findall(open_field)
    if not paths:
        bad("NO-ARTIFACT-PATH",
            "**Open:** carries no `backticked/path` - the CEO needs exactly one "
            "thing to open, named exactly")
        return
    if len(paths) > 1:
        bad("MULTIPLE-ARTIFACT-PATHS",
            "**Open:** names %d paths. One item, one thing to open; if he must "
            "read several, prepare the one page that gathers them." % len(paths))
        return
    rel = paths[0].strip()
    if rel.startswith("/") or rel.startswith("~"):
        bad("ABSOLUTE-ARTIFACT-PATH",
            "**Open:** `%s` is an absolute path; it would be wrong on any other "
            "machine. Use a declared <prefix>/... path." % rel)
        return

    prefix = rel.split("/", 1)[0]
    remainder = rel.split("/", 1)[1] if "/" in rel else ""

    if prefix in absent_roots:
        # Declared, and simply not on this machine. Never a violation - and
        # never invisible either.
        skips.append((sec, iid, rel,
                      "declared root '%s' (%s) is not on this machine, so the "
                      "artifact could not be checked"
                      % (prefix, absent_roots[prefix])))
        return

    if prefix not in roots:
        bad("UNKNOWN-ARTIFACT-PREFIX",
            "**Open:** `%s` starts with '%s', which is not a declared artifact "
            "root. Declared: %s." % (rel, prefix, ", ".join(sorted(roots)) or "<none>"))
        return

    if not remainder:
        bad("ARTIFACT-IS-A-BARE-ROOT",
            "**Open:** `%s` names a repository, not a thing to open" % rel)
        return

    target = os.path.join(roots[prefix], remainder)
    if not os.path.exists(target):
        bad("ARTIFACT-MISSING",
            "**Open:** `%s` does not exist (%s). An item may not claim to be "
            "waiting on the CEO until the thing he touches is on disk - this is "
            "unfinished preparation, so mark it %s and move it to section %s."
            % (rel, target, blocked_state, preparer_section or "the preparer's"))
        return

    # It exists here. Does it exist for anyone else? See the NOTE in main().
    if unreachable is not None and _git_ignored(roots[prefix], remainder):
        unreachable.append(rel)


if __name__ == "__main__":
    sys.exit(main())
