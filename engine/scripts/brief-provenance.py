#!/usr/bin/env python3
"""brief-provenance.py — separate what a brief CITES from what it merely ASSERTS, and
tell the agent which is which, before the agent builds on either.

===========================================================================================
WHAT THIS IS FOR — type W, richos-hq docs/verification/lifecycle-failure-record-2026-09-13.md
===========================================================================================
The CEO, 2026-09-14:

    "That's not a 'hand-off'. That's a BRIEF to a newly spawned agent. A BRIEF that
     contains shitloads of not just unnecessary garbage but factually wrong and harmful
     garbage."

The brief that spawned `zach-opus-n3` carried roughly fourteen load-bearing statements: six
verified quotations, four unverified narratives asserted as observed fact, two factually
wrong, one distorted quotation, and two prescriptions built on an architecture the author had
read one code comment of.

`CLAUDE.md` already carries the rule — *"A NUMBER IN A BRIEF CARRIES THE COMMAND THAT PRODUCED
IT, OR IT CARRIES THE WORD UNVERIFIED. There is no third setting."* It was broken by its own
author one turn after he wrote up its sibling failure. The same page records a DELIBERATE
decision not to enforce it with a hook, because a blocking guard over prose has a large
false-positive class and habitual waiving kills a guard. That reasoning is sound and this file
does not overturn it.

===========================================================================================
THE ONE IDEA
===========================================================================================
THIS DOES NOT JUDGE WHETHER A CLAIM IS TRUE, AND IT NEVER REFUSES A SPAWN. It separates the
statements that carry a source from the statements that do not, and it hands that separation
to the READER WHO IS HARMED BY IT — the agent.

`CLAUDE.md` supplies the evidence that this works, from the day the rule was written:

    "The marked form works and I know it works: three times that day I wrote 'confirm this
     yourself, I derived it with a two-condition grep', and all three times the agent
     re-derived it and was right."

Marking worked 3/3. It failed only because it was applied by hand, by the one person who
cannot see his own recollection as a recollection. So the mark is generated instead.

WHY NON-BLOCKING IS NOT A WEAKER VERSION OF BLOCKING. A blocking guard over prose dies the way
g11/g12/g13 died: false positive -> waive -> habitual waive -> dead guard. This has no waiver
to grant. A false positive costs the agent one re-derivation of a fact that turns out to be
true, which is the cheapest possible failure and leaves no habit behind. That asymmetry, not
optimism about precision, is what makes the non-blocking form viable where the blocking form
was rejected.

===========================================================================================
THE THREE CHECKS, IN DESCENDING ORDER OF SOUNDNESS — and the order is the honest part
===========================================================================================
1. QUOTATION (exact, no judgment, no false positives). A blockquote presented as coming from
   a file is searched for in that file, byte for byte modulo whitespace. Either the string is
   there or it is not. This is the only check that can prove a defect rather than name a
   risk. It catches the distorted quotation.

2. RESTATEMENT (structural). A prose reference to a numbered point of a document the brief
   itself names — "Point 5 then guarantees...", "Point 7: both endings delete" — is a
   PARAPHRASE of a citable source. The record's own words: "every paraphrase is a fresh
   surface for distortion - one of them distorted. A brief that says *read points 4, 5, 7 and
   11 of <path>* carries the same authority and cannot drift from it."

3. PROVENANCE (heuristic, and the only check that can be noisy). A statement is listed when it
   carries a COUNT, an assertion of CERTAINTY, or a claim about the BEHAVIOR OF A NAMED CODE
   ENTITY, and no command, captured output, commit, file:line or re-derive instruction sits in
   scope with it.

WHAT THIS CANNOT DO, STATED HERE SO IT IS NOT DISCOVERED LATER:
  - It cannot tell a true account from a false one. Nothing textual can.
  - It cannot catch a bare prescription that names no code entity — "do not build a second
    reaper". That sentence is formally identical to a legitimate constraint ("do not weaken
    the guard"), which good briefs carry. It catches such a prescription only through the
    account it rests on, which is usually in the same sentence and usually is caught.
  - It cannot make the lead read its output. It does not need to: the annotation reaches the
    agent whether or not the lead reads a word of it.

===========================================================================================
SCOPE OF EVIDENCE — why "in scope" is the block, not the sentence
===========================================================================================
A brief that pastes a grep and then says "21 other sites" has sourced the 21. Evidence
therefore counts for a whole block (a paragraph, a list item, a table) and for a code block
directly adjacent to it. It does NOT count across a heading: a command in the problem
statement does not source a claim three sections later. That is the same scoping the
re-derive instruction gets, and it is what stops one "do not assume" at the bottom of a page
exempting everything above it.
"""
import argparse
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Sections that are pure instruction in every brief this project writes. They
# carry the stock "21-181 s, exit 3 is success" and "Report worktree path,
# branch and commit SHAs" lines, which are directions to the agent and not
# claims about the system. Reading them adds one identical finding to every
# brief ever written, which is how a report becomes wallpaper.
# ---------------------------------------------------------------------------
SKIP_SECTION = re.compile(
    r"(completion criterion|^\s*verify\b|out of scope|^\s*rules\b|^\s*deliverable)", re.I)

# ---------------------------------------------------------------------------
# EVIDENCE
# ---------------------------------------------------------------------------
EXEC_FIRST = (r"(?:git|grep|rg|ls|cat|sed|awk|find|head|tail|wc|diff|docker|npm|npx|node|"
              r"python3?|bash|sh|zsh|adb|xcrun|make|cargo|curl|jq|pgrep|ps|open|"
              r"\./[\w./-]+|[\w./-]+\.(?:sh|py|pl|rb))")
INLINE_CMD = re.compile(r"`([^`\n]+)`")
SHA = re.compile(r"(?<![0-9a-zA-Z/_-])[0-9a-f]{7,40}(?![0-9a-zA-Z/_-])")
FILE_LINE = re.compile(r"(?:line|lines|:)\s*\d{1,5}\b", re.I)
RUN_ID = re.compile(r"\b(?:run\s+)?\d{8,}\b", re.I)
URL = re.compile(r"https?://\S+")
UNVERIFIED = re.compile(r"\bunverified\b", re.I)
REDERIVE = re.compile(
    r"(re-?derive|derive (?:it|them|the list) yourself|confirm (?:this|it|or refute)|"
    r"prove it from|reproduce (?:it )?locally|do not assume|do not trust|rather than trusting|"
    r"check (?:this|it) yourself|verify (?:this|it) yourself|measure it|do not adopt|"
    r"read (?:them|it|that|this|those|the [\w' -]{2,30}) (?:first|yourself|in full)|"
    r"read (?:that|the) (?:commit|section|file|page|document|header|source)|"
    r"say so and stop|establish the real shape)", re.I)

# ---------------------------------------------------------------------------
# CLAIM TRIGGERS
# ---------------------------------------------------------------------------
COUNT_WORD = re.compile(
    r"\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twice|thrice|"
    r"both|neither|dozens|several|a handful|a couple)\b"
    # "three commits" is a count somebody had to derive. "three hours earlier" is a
    # duration, and reading it as a count put a row on a brief that had done nothing
    # wrong. Durations are excluded by the noun that follows them.
    r"(?!\s+(?:hours?|minutes?|seconds?|days?|weeks?|months?|years?|nights?|"
    r"o'clock|a\.?m\.?|p\.?m\.?)\b)", re.I)
# A digit is a count unless it is a pointer (point 11, line 229, exit 3), a date,
# a time, a version, or a duration in the stock instruction lines.
DIGIT = re.compile(r"(?<![\w./:-])(\d{1,3}(?:,\d{3})*|\d{4,})(?![\w./:-])")
POINTER_BEFORE = re.compile(
    r"(point|points|§|section|sections|clause|line|lines|row|rows|step|item|page|shard|"
    r"case|run|exit|port|v|version|figure|table|round|type|layer|chapter|no\.|#)\s*$", re.I)
UNIT_AFTER = re.compile(r"^\s*(?:-\s*\d+\s*)?(s|ms|sec|secs|seconds?|min|mins|minutes?|h|"
                        r"hours?|px|%)\b", re.I)
ISO_DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}")
CERTAIN = re.compile(
    r"\b(demonstrably|provably|clearly|obviously|evidently|certainly|definitely|undeniably|"
    r"in fact|of course|it is clear|needless to say|self-evident)\b", re.I)
# Protocol lines the spawn machinery reads, not statements the agent acts on. They are
# addressed to a guard; flagging them puts an identical row on briefs that share nothing.
MARKER_LINE = re.compile(
    r"^\s*(cross-repo-worktree|ceo-todos-deferred|main-checkout-run|resume-ack|inflight-ack|"
    r"no-inflight-ack|data-contract-bypass|model-ceiling-ack|model-downgrade-ack|"
    r"dialect-exempt|hardware-fixed)\s*:", re.I)
# A number inside somebody else's quoted words is THEIR number. The same exemption the
# dialect guard grants quoted external material, for the same reason.
QUOTED_RUN = re.compile(r"[\"“‘']([^\"“”‘’]{12,})[\"”’']")
ENTITY = re.compile(r"`([\w./-]+\.(?:sh|py|ts|js|tsx|svelte|kt|swift|json|md|yml|yaml|toml))`")
DEFINITE_ARCH = re.compile(
    r"\bthe (existing|current|same|only|whole|entire) [\w -]{2,40}?\b(path|code|logic|check|"
    r"signal|mechanism|reaper|guard|hook|flow|handler|branch|marker|record|registry|table|"
    r"list|field|function|script|suite|gate|step)\b", re.I)
BEHAVIOR = re.compile(
    r"\b(refus\w+|reject\w+|accept\w+|ask\w*|asks|read\w*|writ\w+|handl\w+|mark\w+|block\w+|"
    r"see\w*|saw|take\w*|took|exist\w*|remain\w*|pass\w+|fail\w+|convert\w+|print\w+|"
    r"delet\w+|reap\w+|fire\w*|record\w+|consum\w+|treat\w+|keep\w*|kept|know\w*|"
    r"is keyed|does not|do not see|did not|never (?:sees|fires|marks|runs))\b", re.I)

MAX_QUOTE = 220


# ---------------------------------------------------------------------------
# SEGMENTATION
# ---------------------------------------------------------------------------
def segment(text):
    """Blocks of one kind each, carrying the heading they sit under."""
    lines = text.split("\n")
    blocks = []
    section = ""
    i = 0
    buf, kind = [], None

    def flush():
        nonlocal buf, kind
        if buf and kind:
            blocks.append({"kind": kind, "text": "\n".join(buf), "section": section})
        buf, kind = [], None

    while i < len(lines):
        ln = lines[i]
        if ln.strip().startswith("```"):
            flush()
            fence = [ln]
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                fence.append(lines[i])
                i += 1
            if i < len(lines):
                fence.append(lines[i])
            blocks.append({"kind": "code", "text": "\n".join(fence), "section": section})
            i += 1
            continue
        if not ln.strip():
            flush()
            i += 1
            continue
        if ln.startswith("#"):
            flush()
            section = ln.lstrip("#").strip()
            blocks.append({"kind": "heading", "text": ln, "section": section})
            i += 1
            continue
        this = ("code" if re.match(r"^(?: {4,}|\t)", ln) else
                "quote" if ln.lstrip().startswith(">") else
                "table" if ln.lstrip().startswith("|") else "prose")
        if kind and this != kind:
            flush()
        kind = this
        buf.append(ln)
        i += 1
    flush()
    return blocks


SENT_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[\"'*`(A-Z0-9])")


def sentences(block_text):
    """Sentences, with list markers and table rows treated as their own units."""
    out = []
    for raw in block_text.split("\n"):
        s = raw.strip()
        if not s:
            continue
        s = re.sub(r"^(?:[-*+]|\d+\.)\s+", "", s)
        if s.startswith("|"):
            out.append(s.strip("|").strip())
            continue
        for part in SENT_SPLIT.split(s):
            part = part.strip()
            if len(part) > 2:
                out.append(part)
    return out


QUOTE_SPAN = re.compile(r"[\"“][^\"“”]{12,}?[\"”]", re.S)


def mask_quotes(block_text):
    """The same text with everything inside a quotation blanked out, LENGTH AND LINE
    BREAKS PRESERVED — so it splits into exactly the same sentences as the original and
    the two can be walked together.

    Why it has to happen before sentence splitting: a CEO quotation routinely wraps across
    two lines, and splitting first leaves each half holding one unbalanced quote mark. That
    is how 'it has been broken twice this week' — HIS words, HIS count — was read as the
    lead's unsourced claim."""
    out = list(block_text)
    for m in QUOTE_SPAN.finditer(block_text):
        for k in range(m.start(), m.end()):
            if out[k] not in "\n.!?":     # keep what the splitter keys on, so the masked
                out[k] = "x"              # text splits into the SAME sentences as the shown
    return "".join(out)


def plain(s):
    """Markdown emphasis removed; backticked spans KEPT, they carry the entities."""
    s = re.sub(r"\*\*|__|\*|_", "", s)
    return s.strip()


# ---------------------------------------------------------------------------
# EVIDENCE IN SCOPE
# ---------------------------------------------------------------------------
def is_command(span):
    span = span.strip()
    if " " not in span and not span.startswith("./"):
        return False
    if re.match(r"^" + EXEC_FIRST + r"\b", span):
        return True
    return bool(re.search(r"(?:^|\s)--?[a-zA-Z]", span))


def evidence_of(text):
    """Every kind of source a block can carry, as a set of labels."""
    got = set()
    for span in INLINE_CMD.findall(text):
        if is_command(span):
            got.add("command")
        elif SHA.fullmatch(span.strip()):
            got.add("commit")
    stripped = INLINE_CMD.sub(" ", text)
    if SHA.search(stripped):
        got.add("commit")
    if FILE_LINE.search(text):
        got.add("file:line")
    if RUN_ID.search(stripped) or URL.search(text):
        got.add("run")
    if UNVERIFIED.search(text):
        got.add("marked-unverified")
    if REDERIVE.search(text):
        got.add("re-derive instruction")
    return got


def scope_evidence(blocks, idx):
    """The block itself, plus a code block directly adjacent on either side — never
    across a heading."""
    got = evidence_of(blocks[idx]["text"])
    for j in (idx - 1, idx + 1):
        if 0 <= j < len(blocks) and blocks[j]["kind"] == "code":
            got.add("captured output")
            got |= evidence_of(blocks[j]["text"])
    return got


# ---------------------------------------------------------------------------
# CHECK 3 — PROVENANCE
# ---------------------------------------------------------------------------
def counts_in(sentence):
    bare = INLINE_CMD.sub(" ", sentence)
    bare = QUOTED_RUN.sub(" ", bare)
    hits = [m.group(0) for m in COUNT_WORD.finditer(bare)]
    bare = ISO_DATE.sub(" ", bare)
    bare = URL.sub(" ", bare)
    for m in DIGIT.finditer(bare):
        before, after = bare[:m.start()], bare[m.end():]
        if POINTER_BEFORE.search(before) or UNIT_AFTER.match(after):
            continue
        if re.match(r"^(?:19|20)\d\d$", m.group(0)):
            continue
        if len(m.group(0)) >= 4 and "," not in m.group(0):
            continue                      # ids, years, run numbers
        hits.append(m.group(0))
    return hits


def triggers(sentence):
    p = plain(sentence)
    out = []
    c = counts_in(p)
    if c:
        out.append("count(%s)" % ", ".join(sorted(set(c))[:3]))
    if CERTAIN.search(p):
        out.append("asserted as certain")
    ents = ENTITY.findall(p)
    arch = DEFINITE_ARCH.search(p)
    if (ents or arch) and BEHAVIOR.search(p):
        what = ents[0] if ents else arch.group(0)
        out.append(("what %s says" if what.endswith((".md", ".txt")) else "behavior of %s")
                   % what)
    return out


# ---------------------------------------------------------------------------
# CHECK 1 — QUOTATION, and CHECK 2 — RESTATEMENT
# ---------------------------------------------------------------------------
PATH_IN = re.compile(r"`?((?:[\w.-]+/)+[\w.-]+\.(?:md|py|sh|ts|js|json|txt))`?")
VERBATIM = re.compile(r"\b(verbatim|word for word|in (?:his|her|their|its) own words|quoted?)\b",
                      re.I)
POINT_REF = re.compile(r"\b(?:point|points|§|clause|section)\s*(\d+(?:\s*(?:,|and|-)\s*\d+)*)",
                       re.I)
# Referring to a numbered point is fine and is what a brief should do. RESTATING what it
# says is the laundering surface. The difference is an assertion verb or a colon after the
# reference, and it is the difference between "read point 11" and "point 7: both endings
# delete" — the second is a paraphrase the agent will believe instead of the source.
POINT_ASSERT = re.compile(
    r"\b(?:point|points|§|clause|section)\s*\d[\d,\s&and-]*\s*(?::|—|-\s|then\b|"
    r"(?:then\s+)?(?:guarantees?|says?|means?|requires?|states?|covers?|forbids?|makes?|"
    r"scopes?|applies|is\b|are\b|has\b|have\b))", re.I)
IMPERATIVE = re.compile(
    r"^(do|don't|make|find|report|read|run|keep|add|use|write|give|paste|prove|revert|never|"
    r"always|treat|start|state|update|fix|check|confirm|verify|work|commit|rewrite|take|"
    r"follow|put|push|send|ask|say|list|show|name|consider|escalate|deliver|include|avoid|"
    r"ensure|leave|change|remove|delete|stop|spawn|land|measure|enumerate|re-derive)\b", re.I)


def norm(s):
    """Whitespace, markdown emphasis and smart punctuation removed, so that a quotation
    the author re-bolded still matches the source it came from. A quotation check that
    fired on an added `**` would be noise pretending to be rigor."""
    s = plain(s)
    s = s.replace("’", "'").replace("‘", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = s.replace("—", "-").replace("–", "-")
    return re.sub(r"\s+", " ", s).strip().lower()


INLINE_QUOTE = re.compile(r"[\"“]([^\"“”]{40,})[\"”]")


def _body_of(path, repo, cache):
    if path in cache:
        return cache[path]
    full = os.path.join(repo, path) if repo else path
    body = ""
    if os.path.isfile(full):
        try:
            with open(full, encoding="utf-8", errors="replace") as fh:
                body = norm(fh.read())
        except OSError:
            body = ""
    cache[path] = body
    return body


def check_quotations(blocks, repo):
    """A quotation attributed to a file is either in that file or it is not. This is the
    only check here that PROVES a defect: no judgment, no threshold, no false positive."""
    findings = []
    cache = {}
    doc = ""
    for i, b in enumerate(blocks):
        m = PATH_IN.search(b["text"])
        if m:
            doc = m.group(1)
        if b["kind"] == "heading":
            continue
        intro = blocks[i - 1]["text"] if i else ""
        near = PATH_IN.search(b["text"]) or PATH_IN.search(intro)
        # A BLOCKQUOTE is formally attributed, so the document named anywhere above it is
        # its source. An INLINE quotation is only attributable when a source is named right
        # there — otherwise a quoted line of guard output gets checked against a spec
        # mentioned three sections earlier, and the mechanism invents a defect.
        path = (near.group(1) if near else doc) if b["kind"] == "quote" else (
            near.group(1) if near else "")
        if not path:
            continue
        body = _body_of(path, repo, cache)
        if not body:
            continue                      # a file this machine does not have is not evidence
        if b["kind"] == "quote":
            quoted = ["\n".join(re.sub(r"^\s*>\s?", "", l) for l in b["text"].split("\n"))]
        else:
            quoted = INLINE_QUOTE.findall(b["text"])
        for q in quoted:
            # An elision is the author's own admission that this is not the whole thing;
            # each surviving run is checked on its own.
            for run in re.split(r"\s*(?:\.\.\.|…|\[\.\.\.\])\s*", q):
                n = norm(plain(run))
                if len(n) < 40:
                    continue
                if n not in body:
                    findings.append({
                        "check": "quotation",
                        "detail": "presented as from %s; this run is NOT in that file" % path,
                        "text": run.strip()[:MAX_QUOTE],
                        "verbatim_claimed": bool(VERBATIM.search(intro)),
                    })
    return findings


def check_restatements(blocks):
    """Prose that restates a numbered point instead of quoting or pointing at it."""
    findings = []
    doc = ""
    for i, b in enumerate(blocks):
        m = PATH_IN.search(b["text"])
        if m:
            doc = m.group(1)
        if b["kind"] in ("code", "quote", "heading"):
            continue
        if SKIP_SECTION.search(b["section"] or ""):
            continue
        next_quote = i + 1 < len(blocks) and blocks[i + 1]["kind"] == "quote"
        for s in sentences(b["text"]):
            p = plain(s)
            if not POINT_REF.search(p) or not POINT_ASSERT.search(p):
                continue
            if next_quote and p.rstrip().endswith(":"):
                continue                  # this is the introduction to a quotation, not one
            if p.rstrip().endswith("?") or IMPERATIVE.match(p):
                continue                  # asking about a point, or aiming at it, is not
                                          # restating what it says
            # A sentence that is MOSTLY quotation is a quotation, and check 1 owns it. A
            # short quoted fragment inside a paraphrase is not: that is the shape that
            # dropped "Landed means" from point 4 while keeping five of its words.
            quoted_chars = sum(len(q) for q in INLINE_QUOTE.findall(p)
                               + re.findall(r"[\"“]([^\"“”]+)[\"”]", p))
            if quoted_chars > 0.6 * len(p):
                continue
            findings.append({
                "check": "restatement",
                "detail": "restates %s in prose rather than quoting it or pointing at it"
                          % (doc or "a numbered source"),
                "text": p[:MAX_QUOTE],
            })
    return findings


def check_provenance(blocks):
    findings = []
    for i, b in enumerate(blocks):
        if b["kind"] in ("code", "heading"):
            continue
        if SKIP_SECTION.search(b["section"] or ""):
            continue
        if b["kind"] == "quote":
            continue                      # a quotation is check 1's business
        got = scope_evidence(blocks, i)
        sourced = got - {"marked-unverified"}
        shown = sentences(b["text"])
        masked = sentences(mask_quotes(b["text"]))
        if len(masked) != len(shown):
            masked = shown           # never analyze a sentence that is not the one shown
        for s, m in zip(shown, masked):
            if MARKER_LINE.match(s):
                continue
            t = triggers(m)
            # A table in these briefs is an ENUMERATION OF TARGETS with a pointer in every
            # row — line numbers, case names, counts of what is in each. Reading its cells
            # as claims puts a row on the report for every row of the table.
            if b["kind"] == "table":
                t = [x for x in t if not x.startswith("count(")]
            if not t:
                continue
            if "marked-unverified" in got:
                continue
            if sourced:
                # A COUNT is settled by something that can be counted again. A single
                # quoted instance evidences one occurrence and never a total, which is
                # exactly how "twice" survived a brief that quoted the guard once.
                countish = any(x.startswith("count(") for x in t)
                recountable = sourced & {"command", "re-derive instruction",
                                         "captured output", "run"}
                if not (countish and not recountable):
                    continue
            findings.append({
                "check": "provenance",
                "detail": "; ".join(t) + (" — in scope: %s" % ", ".join(sorted(sourced))
                                          if sourced else " — nothing in scope sources it"),
                "text": plain(s)[:MAX_QUOTE],
                "section": b["section"],
            })
    return findings


def dedupe(findings):
    """One statement, one row. A sentence that is both a restatement and an unsourced
    account is one thing to go and check, not two."""
    out, seen = [], {}
    for f in findings:
        key = norm(f["text"])
        if key in seen:
            if f["detail"] not in seen[key]["detail"]:
                seen[key]["detail"] += "; " + f["detail"]
            continue
        seen[key] = dict(f)
        out.append(seen[key])
    return out


def review(prompt, repo=""):
    blocks = segment(prompt)
    return dedupe(check_quotations(blocks, repo) + check_restatements(blocks)
                  + check_provenance(blocks))


# ---------------------------------------------------------------------------
# WHAT THE AGENT IS TOLD — the only part that changes what anyone does
# ---------------------------------------------------------------------------
HEAD = "## Provenance of this brief — generated, not written by the lead"

BODY = """The statements below were written by your orchestrator without a command, a commit,
a captured output or a file:line beside them. They are its ACCOUNT of the system, and an
account is a recollection until you check it. Nothing here says any of them is wrong.

**Re-derive any of them you are about to build on, and say what you found.** If one of them is
the reason for an approach this brief prescribes, treat the approach as a hypothesis and not as
a constraint: a prescription resting on an unchecked account has already chosen your design for
you. If the code contradicts it, that is a finding — report it and stop rather than forcing the
brief's shape onto what is actually there."""


def annotation(findings):
    if not findings:
        return ""
    out = [HEAD, "", BODY, ""]
    for kind, title in (("quotation", "Presented as a quotation, and NOT found in the file named"),
                        ("restatement", "Restated from a source this brief names — read the "
                                        "source, not this"),
                        ("provenance", "Asserted without a source in this brief")):
        rows = [f for f in findings if f["check"] == kind]
        if not rows:
            continue
        out.append("**%s:**" % title)
        out.append("")
        for f in rows:
            out.append("- “%s”" % f["text"])
            out.append("  (%s)" % f["detail"])
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def annotate(prompt, repo=""):
    f = review(prompt, repo)
    if not f:
        return prompt, f
    return prompt.rstrip("\n") + "\n\n" + annotation(f), f


def report(findings, name="", out=sys.stderr):
    if not findings:
        print("  provenance:  nothing asserted without a source%s"
              % (" in %s's brief" % name if name else ""), file=out)
        return
    print("  provenance:  %d statement(s) carry no source; the brief now says so to the agent"
          % len(findings), file=out)
    for f in findings:
        print("    [%-11s] %s" % (f["check"], f["text"][:96]), file=out)
        print("                  %s" % f["detail"], file=out)


def main(argv):
    ap = argparse.ArgumentParser(
        description="Separate what a brief cites from what it asserts. Never refuses anything.")
    ap.add_argument("target", help="a brief file, or a spawn payload JSON")
    ap.add_argument("--repo", default="", help="repository the brief's paths are relative to; "
                                               "quotations are checked against it")
    ap.add_argument("--annotate", action="store_true", help="print the annotated brief")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    with open(a.target, encoding="utf-8") as fh:
        raw = fh.read()
    if a.target.endswith(".json"):
        try:
            raw = json.loads(raw)["prompt"]
        except (ValueError, KeyError, TypeError):
            pass
    findings = review(raw, a.repo)
    if a.json:
        print(json.dumps({"findings": findings, "annotation": annotation(findings)}, indent=2))
    elif a.annotate:
        print(annotate(raw, a.repo)[0], end="")
    else:
        report(findings, out=sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
