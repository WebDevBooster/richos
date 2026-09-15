#!/usr/bin/env python3
"""premise-ask.py — what a question put to the CEO does and does not carry.

READ scripts/lib/premise-ask.sh FIRST. It holds the failure this exists for,
the corpus measurement, and — most importantly — the argument for why this file
DECIDES NOTHING. Everything here is a finding printed inside a check the
orchestrator answers; no output of this file refuses anything on its own.

WHY IT DECIDES NOTHING, IN ONE PARAGRAPH, BECAUSE IT IS THE WHOLE DESIGN.
Every predicate that could be built over question TEXT was measured against all
85 real AskUserQuestion questions on this machine (scripts/hooks/
premise-ask.corpus.md). The two questions of 2026-09-10 that had to be refused
sit in the TOP DECILE for premise richness — four and six declarative premise
sentences, a pinned host version, a measured latency. Every predicate that
refused them refused 11 to 21 genuine business decisions with them; every
predicate narrow enough to spare those missed both. A question's text does not
carry whether its premise MATTERS to him. So this file reports what is there
and what is not, and a human answers the question the report ends with.

MODES
    check   stdin is a JSON job:
                {"question": "<the question field, header included>",
                 "whole":    "<question + every option label and description>"}
            stdout is TSV, one record per line:
                MARKER   premise-unverified   <declared reason>
                FINDING  <CODE>               <detail for the reader>
                VERDICT  CHECK|SILENT
"""

import json
import re
import sys

# ---------------------------------------------------------------------------
# THE DECLARATION — the one thing here that is a decision rather than a finding
# ---------------------------------------------------------------------------
# `premise-unverified: <what is unknown and what would settle it>` on its own
# line. A BARE MARKER EXEMPTS NOTHING: the reason is length-checked, on the
# same argument `dialect-exempt:` and `conceal-ack:` use — a bare token is
# something a reflex types and a reason is something a person writes.
MARKER_RE = re.compile(
    r"^[ \t]*premise-unverified:[ \t]*(?P<reason>.+)$",
    re.IGNORECASE | re.MULTILINE,
)
MIN_MARKER_WORDS = 6

# A sentence, roughly. Deliberately crude: the finding it feeds is informational
# and a smarter splitter would buy precision nothing here can spend.
SENT_RE = re.compile(r"[^.!?\n]+[.!?\n]|[^.!?\n]+$")
MIN_DECLARATIVE_WORDS = 6

# EVIDENCE TOKENS — the shapes a fact carries when somebody measured it.
# Measured over the corpus: 53 of 85 questions carry at least one somewhere,
# 24 of 85 carry one in the question field itself.
EVIDENCE_RE = [
    (re.compile(r"\b20\d\d-\d\d-\d\d\b"), "a dated measurement"),
    (re.compile(r"\b\d{1,2}\s+(January|February|March|April|May|June|July|"
                r"August|September|October|November|December)\b", re.I), "a date"),
    (re.compile(r"\b\d[\d,.]*\s?(GB|MB|KB|GiB|MiB|B\b|%|ms\b|seconds|minutes|"
                r"min\b|hours|days|files|commits|lines|packages|records|runs|"
                r"tests|words)", re.I), "a quantity"),
    (re.compile(r"§\s?\d+|\brow \S+|\bitem \d+(\.\d+)?\b", re.I), "a citation"),
    (re.compile(r"\b[0-9a-f]{7,40}\b"), "an object id"),
    (re.compile(r"(^|\s)[~/][\w./-]{4,}", re.M), "a path"),
    (re.compile(r"\bmeasured\b|\bmeasurement\b", re.I), "the word measured"),
    (re.compile(r"#\d+\b"), "an issue reference"),
    (re.compile(r"\b\d+\.\d+(\.\d+)+\b"), "a version"),
]

# OCCURRENCE CLAIMS — a premise that asserts something HAPPENS or CAN HAPPEN.
# This is the class the 2026-09-10 pair rested on, and the class the brief's
# rule is about: when the premise is a claim about something that happened, the
# question carries the evidence it happened. A probe constructing it in a
# sandbox is not evidence that it occurs.
OCCURRENCE_RE = [
    (re.compile(r"\bwhen\s+(?:a|an|the|it|something|anything|you|your)?\s*[\w-]+"
                r"(?:\s+\w+)?\s+(?:fails|failed|times out|is disabled|is switched off|"
                r"breaks|crashes|exits|quits|dies|goes wrong)\b", re.I), "when-it-fails"),
    (re.compile(r"\bif\s+(?:a|an|the|it|something|anything|you|your|anyone|someone)?\s*[\w-]+"
                r"(?:\s+\w+)?\s+(?:fails|failed|is disabled|breaks|crashes|exits|quits|"
                r"goes wrong|turns out|notices|gains)\b", re.I), "if-it-fails"),
    (re.compile(r"\bsituations where\b|\bcases where\b", re.I), "situations-where"),
    (re.compile(r"\b(?:unknown|undetermined|unmeasured|never been measured|"
                r"has never happened|no evidence either way)\b", re.I), "stated-unknown"),
]

# OBSERVATION EVIDENCE — the shapes an answer to "has it ever actually happened?"
# takes. Present here ONLY to make the finding specific; its absence refuses
# nothing, because the corpus proved it cannot (see the corpus page's table).
OBSERVATION_RE = [
    re.compile(r"\b(?:never|not once|zero times|no session has|has not happened)\b", re.I),
    re.compile(r"\b(?:observed|happened|occurred|reported|already has|hit this)\b", re.I),
    re.compile(r"\b\d[\d,]*\s?(?:times|occurrences|sessions|runs|instances)\b", re.I),
    re.compile(r"\b20\d\d-\d\d-\d\d\b"),
    re.compile(r"\b(?:the log says|logged|transcripts?|the record says|the logs)\b", re.I),
]


def words(text):
    return [w for w in re.split(r"\s+", text.strip()) if w]


def declaratives(text):
    """Sentences that ASSERT rather than ask. The premise, if there is one."""
    out = []
    for s in SENT_RE.findall(text or ""):
        s = s.strip()
        if not s or s.endswith("?"):
            continue
        if len(words(s)) < MIN_DECLARATIVE_WORDS:
            continue
        out.append(s)
    return out


def hits(patterns, text):
    found = []
    for entry in patterns:
        pat, label = entry if isinstance(entry, tuple) else (entry, "")
        m = pat.search(text or "")
        if m:
            found.append((label, m.group(0).strip()))
    return found


def check(job):
    question = job.get("question") or ""
    whole = job.get("whole") or question
    out = []

    m = MARKER_RE.search(whole)
    if m:
        reason = m.group("reason").strip()
        if len(words(reason)) >= MIN_MARKER_WORDS:
            out.append(("MARKER", "premise-unverified", reason))
            out.append(("VERDICT", "SILENT", ""))
            return out
        out.append(("FINDING", "MARKER-WITHOUT-REASON",
                    "a `premise-unverified:` line is present and says almost nothing "
                    "(%d word(s); %d are required). A bare marker exempts nothing: say "
                    "what is unknown AND what would settle it."
                    % (len(words(reason)), MIN_MARKER_WORDS)))

    decl_q = declaratives(question)
    decl_all = declaratives(whole)
    if not decl_all:
        out.append(("FINDING", "NO-PREMISE-ANYWHERE",
                    "neither the question nor any option states a fact. He is being "
                    "asked to choose with nothing on the record about why the choice "
                    "exists."))
    elif not decl_q:
        out.append(("FINDING", "PREMISE-ONLY-IN-OPTIONS",
                    "the question itself states no fact; %d are in the options. He "
                    "reads the question first, and an option's job is the trade rather "
                    "than the reason." % len(decl_all)))

    occ = hits(OCCURRENCE_RE, whole)
    if occ:
        observed = any(p.search(whole) for p in OBSERVATION_RE)
        detail = "; ".join('%s: "%s"' % (label, phrase) for label, phrase in occ[:3])
        if observed:
            out.append(("FINDING", "OCCURRENCE-CLAIMED-WITH-EVIDENCE",
                        "this question rests on something happening (%s) and does cite "
                        "observation. CHECK IT IS OBSERVATION OF THE THING: on 2026-09-10 "
                        "a question carried a pinned version, a measured latency and four "
                        "reproduced failure paths, and still nobody had asked how often "
                        "the failure occurs. The answer was zero." % detail))
        else:
            out.append(("FINDING", "OCCURRENCE-CLAIMED-UNMEASURED",
                        "this question rests on something happening (%s) and says nothing "
                        "about it ever having happened. If a probe constructed it in a "
                        "sandbox, that is not evidence it occurs." % detail))

    ev_q = hits(EVIDENCE_RE, question)
    if decl_q and not ev_q:
        out.append(("FINDING", "PREMISE-UNSOURCED",
                    "the question states a fact and cites nothing for it — no date, "
                    "count, measurement, citation or path. Either put the command's "
                    "output where he can re-run it, or mark it `unverified:`."))

    out.append(("VERDICT", "CHECK", ""))
    return out


def main(argv):
    mode = argv[1] if len(argv) > 1 else "check"
    if mode != "check":
        sys.stderr.write("premise-ask.py: unknown mode %r\n" % mode)
        return 2
    try:
        job = json.load(sys.stdin)
    except Exception as exc:                      # noqa: BLE001 - reported, never raised
        sys.stderr.write("premise-ask.py: unreadable job: %s\n" % exc)
        return 2
    if not isinstance(job, dict):
        sys.stderr.write("premise-ask.py: job is not an object\n")
        return 2
    for rec in check(job):
        fields = [str(f).replace("\t", " ").replace("\n", " ") for f in rec]
        sys.stdout.write("\t".join(fields) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
