#!/usr/bin/env python3
"""ceo-queue.py — THE PREDICATE. Is a "waiting on the CEO" claim actually ready?

Read scripts/lib/ceo-queue.sh first; it carries the rationale. This file carries
only the mechanism, because the mechanism has to be exact.

INPUT   one JSON job, path given as argv[1] (or on stdin when argv[1] is "-"):

    {
      "record_label":     "wiki/open-items.md",   # for messages only
      "text":             "<the whole record>",
      "ceo_sections":     ["1", "2"],
      "preparer_section": "3",
      "artifact_roots":   {"richos-hq": "/abs/path", ...},   # prefix -> root
      "absent_roots":     {"richos": "../richos", ...},      # declared, not on
                                                             # this machine
      "ready_state":      "READY-FOR-CEO",
      "blocked_state":    "BLOCKED-ON-RICH"
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

EXIT    0 always, unless the job itself is unreadable (2). The VERDICT is the
        product; a non-zero exit would make "the record is bad" and "the
        checker is bad" the same signal to every caller.
"""

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

BACKTICKED_RE = re.compile(r"`([^`]+)`")

# A duration, not a mood. "soon", "a while", "TBD" and "" all fail.
# Accepts: 5 min | 30 minutes | 1.5 hours | 10-15 minutes | 2-3 h
DURATION_RE = re.compile(
    r"^\s*\d+(?:\.\d+)?\s*(?:[-–—]\s*\d+(?:\.\d+)?\s*)?"
    r"(?:s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)\b",
    re.IGNORECASE,
)

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


def words(value):
    return [w for w in re.split(r"\s+", re.sub(r"[`*_\[\]()]", " ", value)) if w]


def fail(reason):
    sys.stdout.write("BROKEN\t%s\n" % reason)
    sys.exit(0)


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

    label = job.get("record_label") or "<record>"
    ceo_sections = [str(s) for s in (job.get("ceo_sections") or [])]
    preparer_section = str(job.get("preparer_section") or "")
    roots = job.get("artifact_roots") or {}
    absent_roots = job.get("absent_roots") or {}
    ready_state = job.get("ready_state") or "READY-FOR-CEO"
    blocked_state = job.get("blocked_state") or "BLOCKED-ON-RICH"

    if not ceo_sections:
        fail("no CEO sections declared - a lint with nothing to check is not a pass")

    lines = text.split("\n")

    # --- Pass 1: the section map ------------------------------------------
    # Every declared section must EXIST. Renaming or deleting section 2 must
    # not be a way to make this lint quietly have nothing to say; that is the
    # same defect as a suite that no-ops when its subject is absent.
    seen_sections = {}
    for idx, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if m:
            seen_sections.setdefault(m.group("num"), idx)

    for want in ceo_sections:
        if want not in seen_sections:
            fail(
                "%s declares CEO section %s, and no '## %s.' heading exists in the record. "
                "The lint would have had nothing to check and would have reported clean."
                % (label, want, want)
            )
    if preparer_section and preparer_section not in seen_sections:
        fail(
            "%s declares preparer section %s, and no '## %s.' heading exists. "
            "There would be nowhere to move an unprepared item to."
            % (label, preparer_section, preparer_section)
        )

    # --- Pass 2: walk the record ------------------------------------------
    violations = []
    skips = []
    state = {"checked": 0, "item": None}
    seen_ids = {}

    section = None           # current section number, or None
    in_ceo = False

    def close_item():
        item = state["item"]
        if item is None:
            return
        state["checked"] += 1
        check_item(item, violations, skips, seen_ids, roots, absent_roots,
                   ready_state, blocked_state, preparer_section)
        state["item"] = None

    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            close_item()
            section = m.group("num")
            in_ceo = section in ceo_sections
            continue
        if ANY_H2_RE.match(line):
            # An unnumbered '## ...' heading ends the numbered sections.
            close_item()
            section = None
            in_ceo = False
            continue

        if not in_ceo:
            continue

        if ANY_H3_RE.match(line):
            close_item()
            im = ITEM_RE.match(line)
            if not im:
                violations.append(
                    (section, "?", "MALFORMED-HEADING",
                     "heading is not '### <id> %s - <title>': %s"
                     % (ready_state, line.strip()))
                )
                continue
            state["item"] = {
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
            item = state["item"]
            violations.append(
                (section, item["id"] if item else "?", "TABLE-ROW-IN-CEO-SECTION",
                 "a table row in a CEO section is not a checkable item; every item "
                 "here is a '### <id> %s - <title>' block" % ready_state)
            )
            continue

        item = state["item"]
        if item is None:
            continue

        fm = FIELD_RE.match(line)
        if fm:
            name = fm.group("name")
            if name in item["fields"]:
                item["dupes"].append(name)
            else:
                item["fields"][name] = fm.group("value")

    close_item()

    # --- Verdict -----------------------------------------------------------
    out = []
    for v in violations:
        out.append("V\t%s\t%s\t%s\t%s" % v)
    for s in skips:
        out.append("SKIP\t%s\t%s\t%s\t%s" % s)

    if violations:
        sys.stdout.write("VIOLATIONS\t%d\t%d\t%d\n"
                         % (len(violations), state["checked"], len(skips)))
    else:
        sys.stdout.write("CLEAN\t%d\t%d\n" % (state["checked"], len(skips)))
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


def check_item(item, violations, skips, seen_ids, roots, absent_roots,
               ready_state, blocked_state, preparer_section):
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


if __name__ == "__main__":
    sys.exit(main())
