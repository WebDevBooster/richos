#!/usr/bin/env python3
"""ceo-ruled.py — HAS THE RECORD ALREADY RULED ON THIS QUESTION?

Read scripts/lib/ceo-ruled.sh first; it carries the rationale, the corpus
measurement and the fail-open argument. This file carries only the mechanism,
because the mechanism has to be exact and testable without a session.

===========================================================================
THE DEFECT
===========================================================================
2026-09-01. Three times in one evening the orchestrator put a question to the
CEO that the record already answered, and each answer had been written down by
the orchestrator itself hours or days earlier:

  1. What a customer installs. His standing instruction was already in
     open-items.md row 3.14, in his own words: "automatically download and
     install whatever the user needs."
  2. Whether the logo mark is one tone or two. Already approved.
  3. The splash screens. A palette approval had been laundered into "seven
     approved splash screens" and repeated back to him as fact.

His reply to the first: "HOW MANY TIMES DO I HAVE TO DISCUSS AND ANSWER THE
SAME IDENTICAL SHIT???"

The mechanism, in one line: THE ORCHESTRATOR WRITES TO THE RECORD CONSTANTLY
AND READS IT ALMOST NEVER. Every ruling is appended within minutes; nothing is
ever queried. There is no step between "this looks like a decision" and "ask
him". This file is that step.

===========================================================================
THE ONE PROPERTY THAT MATTERS: IT MUST NOT CRY WOLF
===========================================================================
A blocking gate with a false-positive class gets waived, and habitual waiving
is how a defense decays into a formality. So this matcher is deliberately
NARROW and deliberately dumb. It does not attempt to decide whether a ruling
ANSWERS a question — no text predicate can — it decides the much smaller
question:

    DOES THIS QUESTION'S SUBJECT MATTER APPEAR AS THE SUBJECT MATTER OF A
    RULING THE RECORD ALREADY CARRIES?

and when it does, it NAMES THE RULING AND QUOTES IT so the refusal is useful.
The orchestrator then answers from the record instead of asking. A refusal that
only said "already decided" would send him hunting and would be waived.

===========================================================================
ONE ANCHOR: THE RULING'S OWN TITLE, CARRIED WHOLE
===========================================================================
A question is refused only when it contains EVERY content word of a ruling's
title-subject — the part of its heading before the em dash. Nothing else
matches. That is the narrow version, and it is narrow because the alternative
was measured and was unusable.

TWO OTHER ANCHORS WERE BUILT, MEASURED AND DELETED. Against the 27 real
questions ever put to the CEO on this machine they fired on 18 — 67% — on
words like "days", "char", "walk", "much", "hole", "assets" and phrases like
"anything else", "per session", "all companies". A ruling's BODY cites half the
register; sharing words with it is not evidence of anything. Their remains are
the corroboration rule below, which is the only place a body word can still
count and which never fires on its own.

TWO CONDITIONS ON THE TITLE, each forced by a measured false positive:

  MULTI-WORD    a one-word title never fires alone, however rare the word looks
                here. "Surfaces" and "Pipeline" are rare in the CEO's register
                and ordinary everywhere else, and between them they refused
                three unrelated questions — about design-round surfaces and a
                prospects pipeline.

  DISTINCTIVE   at least one title word must appear in no more than
                RARE_FRACTION of the rulings. "start screen" is two words of
                pure register vocabulary, and it refused two questions about
                when to schedule a migration because one option said "It starts
                fresh" and another said "against your screen".

A title failing either condition may still match, but only WITH CORROBORATION:
a word or phrase from the question that is rare across the register (df <=
DF_MAX) AND REPEATED inside that one ruling (tf >= TF_TOKEN / TF_PHRASE).
Repetition is the whole defense — an incidental mention appears once and a
SUBJECT repeats. The register says "swoosh" five times inside the logo ruling
and nowhere else, so the question about the mark's second tone is refused and
cited. It says "monospaced" exactly once in its entirety, so the question
nobody ever ruled on is not.

SPECIFICITY IS MEASURED OVER TITLES FOR THE TITLE TEST AND OVER BODIES FOR THE
CORROBORATION TEST, and the split is deliberate: body frequency answers "does
the record talk about this", only title frequency answers "is this what a
ruling is ABOUT".

MATCHING IS EXACT, NOT PREFIX-TOLERANT. This is the opposite choice from
ceo-asks.py, whose job is to be SATISFIED by a good-faith rendering of an item
and which therefore lets "enroll" stand for "enrollment". Here a loose match
costs a refusal the operator did not deserve, and "monospace" standing for
"monospaced" would have cost exactly one: the positive control. Stated as a
divergence rather than left to be discovered.

===========================================================================
WHAT IS INDEXED, AND WHAT IS DELIBERATELY NOT
===========================================================================
Only RULINGS. An open question is not a ruling, and refusing a question about
genuinely open work is the false-positive class that would kill this gate:

  ceo-decisions.md   every numbered section and its sub-sections, EXCEPT any
                     whose title carries the standalone word OPEN (§6's
                     mechanism, §10's transcription model). Those are the
                     sections that say "not decided".
  open-items.md      only rows carrying a settled marker — RULED, CLOSED,
                     DECIDED, APPROVED, RATIFIED, NOT ADOPTED — or the phrase
                     "standing instruction". Section 3 is a work list, and most
                     of it is open by construction.
  CLAUDE.md          every heading. The whole file is standing rules.

===========================================================================
INPUT / OUTPUT
===========================================================================
INPUT   one JSON job, path as argv[1] (or on stdin when argv[1] is "-"):

    {
      "mode":     "check" | "rulings",
      "question": "<question + header + every option label and description>",
      "sources":  [{"path": "...", "label": "ceo-decisions.md"}, ...],
      "exempt":   ["<cite>", ...]        # cites declared not to cover this
    }

OUTPUT  tab-separated lines on stdout.

  mode "check":
      SCANNED  <n-rulings>  <n-sources>
      RULED    <label>  <cite>  <title>  <how>  <anchor>  <df>  <tf>  <line>
      QUOTE    <cite>  <the ruling's own words, one line>
      EXEMPT   <cite>                       (matched, but declared not to cover)
      VERDICT  RULED | CLEAR | ALL-EXEMPT

  mode "rulings":
      RULING   <label>  <cite>  <title>  <line>   (the whole index, for tests)

EXIT    0 with a verdict. 2 only when the JOB itself is unreadable, which is a
        broken CALLER and must never be mistaken for "the record rules nothing".
"""

import importlib.util
import json
import os
import re
import sys

# --- The knobs, named and in one place -------------------------------------
# Every one of these was set by MEASUREMENT against the real record and the
# real questions asked on this machine — see scripts/hooks/ceo-ruled.corpus.md,
# which states the corpus size and the rate. Changing one changes what gets
# refused, so they are named constants and not literals in an expression.
MIN_ALONE = 2       # title words needed before a title may fire without corroboration
RARE_FRACTION = 0.10  # a word in this share of the rulings is vocabulary, not identity
DF_MAX = 2          # a corroborating anchor may appear in at most this many rulings
TF_PHRASE = 2       # ...and this many times inside the ruling it hits
TF_TOKEN = 3        # a lone word has to be a SUBJECT, not a mention
MAX_N = 3           # longest phrase considered
QUOTE_CHARS = 400   # a refusal quotes; it does not paste a section

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_ceo_asks():
    """The tokenizer is ceo-asks.py's, loaded rather than re-written.

    THE SAME RECORD-READING VOCABULARY, ONE DEFINITION. A second stopword list
    and a second word-splitter would drift apart the first time either was
    tuned, and the two gates would then disagree about what a question SAYS
    while both claiming to read the CEO's record. The filename carries a hyphen
    and cannot be imported by name, which is the only reason this is not a
    plain `import`.
    """
    path = os.path.join(_LIB_DIR, "ceo-asks.py")
    spec = importlib.util.spec_from_file_location("_ceo_asks", path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    _CEO_ASKS = _load_ceo_asks()
    content_words = _CEO_ASKS.content_words
except Exception:  # pragma: no cover - exercised by the missing-sibling case
    # ceo-ruled.sh refuses to run without ceo-asks.py and says so, so reaching
    # here means the library was called directly. Fail LOUD rather than quietly
    # tokenize differently from the gate this shares a record with.
    sys.stderr.write(
        "ceo-ruled.py: scripts/lib/ceo-asks.py is missing or unloadable — its "
        "tokenizer is this file's tokenizer and there is no second copy.\n")
    raise

# `(CEO, 2026-08-30)`, `(CEO 2026-08-30)` — attribution, never subject matter.
ATTRIB_RE = re.compile(r"\((?:CEO|his|him)[^)]*\)", re.I)
LINK_RE = re.compile(r"\[[^\]]*\]\([^)]*\)")
# The em dash splits a heading into SUBJECT — VERDICT throughout this record.
DASH_RE = re.compile(r"\s+[—–]\s+|\s+--\s+")
SETTLED_RE = re.compile(
    r"\b(RULED|CLOSED|DECIDED|APPROVED|RATIFIED|NOT ADOPTED)\b"
    r"|standing instruction", re.I)
# A title that says the thing is not decided. Standalone word, capitalized as
# the record capitalizes a verdict, so "opening" and "opens" are untouched.
UNSETTLED_RE = re.compile(r"\bOPEN\b")
ROW_ID_RE = re.compile(r"^\|\s*(\d+\.\d+[a-z]?)\s*\|")
BOLD_ID_RE = re.compile(r"^\*\*(\d+\.\d+[a-z]?)\*\*\s*(\([^)]*\))?")
# The record's own voice: **His words:** *"..."* — the best possible quote.
HIS_WORDS_RE = re.compile(r"\*\*His words[^*]*\*\*[:,]?\s*(.*)", re.I)
# A standing order in his own words: the register marks them
# `standing instruction (*"..."*)` or quotes them in italics nearby.
INSTRUCTION_RE = re.compile(
    r"standing instruction[^\n]{0,120}?[*\"“]{1,2}([^\"”*]{20,200})[\"”*]", re.I)


def clean_title(text):
    """A heading, reduced to the thing it is about.

    LINKS GO FIRST, and the order is load-bearing rather than tidy. This record
    cites itself as [`ceo-decisions.md`](ceo-decisions.md), and the attribution
    stripper below matches any parenthesis opening with "ceo" — so stripping
    attributions first ate the link TARGET, left the link TEXT behind, and gave
    row 3.14 a subject containing the words "ceo" and "decisions". A subject
    made of the record's own filename matches nothing a person would ask.
    """
    t = LINK_RE.sub(" ", text or "")
    t = ATTRIB_RE.sub(" ", t)
    t = t.replace("`", " ").replace("*", " ").replace("#", " ")
    t = re.sub(r"^\s*\d+\.\s*", "", t)
    return t.strip(" .:—–-")


def subject_of(title):
    """The part before the em dash: 'The payload' out of 'The payload — SHIP...'."""
    parts = DASH_RE.split(title)
    return (parts[0] if parts else title).strip(" .:")


def ngrams(words, n):
    return [tuple(words[i:i + n]) for i in range(len(words) - n + 1)]


class Ruling(object):
    __slots__ = ("label", "cite", "title", "subject", "line", "body",
                 "words", "counts", "quotes")

    def __init__(self, label, cite, title, line):
        self.label = label
        self.cite = cite
        self.title = title
        self.subject = subject_of(title)
        self.line = line
        self.body = []
        self.words = []
        self.counts = {}
        self.quotes = []

    def finish(self):
        text = self.title + "\n" + "\n".join(self.body)
        self.words = content_words(text)
        counts = {}
        for n in range(1, MAX_N + 1):
            for g in ngrams(self.words, n):
                counts[g] = counts.get(g, 0) + 1
        self.counts = counts
        self.quotes = self._pick_quotes()

    def _pick_quotes(self):
        """The ruling's OWN WORDS — up to two lines, his first.

        A refusal that quotes the CEO is a refusal the reader believes; one
        that quotes a summary is one he goes and checks, and the hunting is
        what makes a gate get waived. Two lines, because the register carries
        two kinds of quotable thing and they are not always in the same place:

          THE LEAD        the ruling's first paragraph, which in this register
                          is almost always the verdict sentence.
          THE INSTRUCTION a standing order in his own words, quoted somewhere
                          inside the body. Row 3.14 carries "automatically
                          download and install whatever the user needs" five
                          thousand characters into a single-line table row —
                          the exact sentence that answered a question he was
                          asked anyway, and it is unreachable by truncation.

        PARAGRAPHS, NOT LINES. The wiki hard-wraps at ~95 columns, so a
        line-based picker quotes "The dark-mode and light-mode" and stops.
        """
        quotes = []
        paras = _paragraphs(self.body)
        lead = ""
        for p in paras:
            if p.startswith(("|--", "---", "```", ">")):
                continue
            if HIS_WORDS_RE.search(p):
                lead = p
                break
            if not lead:
                lead = p
        if lead:
            quotes.append(_markdown_off(lead)[:QUOTE_CHARS])
        joined = " ".join(paras)
        m = INSTRUCTION_RE.search(joined)
        if m:
            q = _markdown_off('"%s"' % m.group(1))[:QUOTE_CHARS]
            if q not in quotes[0] if quotes else True:
                quotes.append("standing instruction: " + q)
        if not quotes:
            quotes.append(_markdown_off(self.title)[:QUOTE_CHARS])
        return quotes


def _paragraphs(lines):
    """Blank-line separated blocks, unwrapped into one string each."""
    out = []
    cur = []
    for raw in lines:
        if raw.strip():
            cur.append(raw.strip())
        elif cur:
            out.append(" ".join(cur))
            cur = []
    if cur:
        out.append(" ".join(cur))
    return out


def _markdown_off(text):
    t = LINK_RE.sub(" ", text or "")
    t = t.replace("**", "").replace("`", "").replace("*", "")
    t = t.replace("|", " ")
    return re.sub(r"\s+", " ", t).strip()


def _flatten(text):
    return re.sub(r"\s+", " ", (text or "").replace("\t", " ")).strip()


# ---------------------------------------------------------------------------
# THE PARSERS — one per shape of record, none of them clever
# ---------------------------------------------------------------------------
def parse_decisions(label, lines):
    """ceo-decisions.md — `## N. Title` and the `### Sub` headings beneath it."""
    out = []
    cur = None
    top_num = None
    top_open = False
    for i, raw in enumerate(lines, start=1):
        m2 = re.match(r"^##\s+(?!#)(.*)$", raw)
        m3 = re.match(r"^###\s+(?!#)(.*)$", raw)
        if m2:
            head = m2.group(1)
            num = re.match(r"^(\d+)\.\s", head)
            if cur:
                out.append(cur)
                cur = None
            if not num:
                # `## What this page is` and friends: prose about the register,
                # not a ruling in it. Also ends the previous section's number so
                # a later `###` cannot be attributed to it.
                top_num = None
                top_open = False
                continue
            top_num = num.group(1)
            title = clean_title(head)
            top_open = bool(UNSETTLED_RE.search(head))
            if top_open:
                cur = None
                continue
            cur = Ruling(label, "§%s" % top_num, title, i)
            continue
        if m3:
            if cur:
                out.append(cur)
                cur = None
            if top_num is None:
                continue
            head = m3.group(1)
            if UNSETTLED_RE.search(head):
                continue
            title = clean_title(head)
            cite = "§%s › %s" % (top_num, subject_of(title))
            cur = Ruling(label, cite, title, i)
            continue
        if cur is not None:
            cur.body.append(raw)
        elif top_open:
            # Deliberately dropped: the body of an OPEN section is not indexed.
            pass
    if cur:
        out.append(cur)
    return out


VERDICT_LEAD_RE = re.compile(
    r"^(RULED|CLOSED|DECIDED|MEASURED|APPROVED|RATIFIED|NOT ADOPTED|DONE|"
    r"LANDED|BUILT)\b", re.I)


def row_title(cells):
    """A table row's SUBJECT, out of the record's own bold headline.

    Section 3's rows have no title column — they open with a bold headline that
    is sometimes `Subject — verdict` and sometimes `VERDICT — subject`. Both
    shapes are read here, because guessing one of them would silently give half
    the rows a title made of the word RULED and a date, and a subject nobody can
    ask about is a ruling nobody can be refused for.
    """
    m = re.search(r"\*\*(.+?)\*\*", cells)
    if not m:
        return ""
    head = clean_title(m.group(1))
    parts = DASH_RE.split(head)
    cand = parts[0].strip()
    if VERDICT_LEAD_RE.match(cand) and len(parts) > 1:
        cand = parts[1].strip()
    cand = re.split(r"(?<=[a-z0-9])\.(?:\s|$)", cand)[0]
    return cand.strip(" .:,;")


def parse_items(label, lines):
    """open-items.md — table rows and bold-id paragraphs, SETTLED ONES ONLY."""
    out = []
    cur = None

    def flush():
        if cur is None:
            return
        text = "\n".join(cur.body) + "\n" + cur.title
        if SETTLED_RE.search(text):
            out.append(cur)

    for i, raw in enumerate(lines, start=1):
        mrow = ROW_ID_RE.match(raw)
        mbold = BOLD_ID_RE.match(raw.strip())
        if mrow:
            flush()
            rid = mrow.group(1)
            cur = Ruling(label, "row %s" % rid, row_title(raw), i)
            cur.body.append(raw)
            continue
        if mbold:
            flush()
            rid = mbold.group(1)
            paren = (mbold.group(2) or "").strip("()")
            cur = Ruling(label, "row %s" % rid,
                         clean_title(paren) if paren else "", i)
            cur.body.append(raw)
            continue
        if re.match(r"^#{1,6}\s", raw):
            flush()
            cur = None
            continue
        if cur is not None:
            if not raw.strip():
                flush()
                cur = None
            else:
                cur.body.append(raw)
    flush()
    return out


def parse_rules(label, lines):
    """CLAUDE.md — every heading is a standing rule."""
    out = []
    cur = None
    for i, raw in enumerate(lines, start=1):
        m = re.match(r"^(#{2,4})\s+(?!#)(.*)$", raw)
        if m:
            if cur:
                out.append(cur)
            title = clean_title(m.group(2))
            cur = Ruling(label, "%s § %s" % (label, subject_of(title)),
                         title, i)
            continue
        if cur is not None:
            cur.body.append(raw)
    if cur:
        out.append(cur)
    return out


PARSERS = {
    "ceo-decisions.md": parse_decisions,
    "open-items.md": parse_items,
}


def load_rulings(sources):
    """-> (rulings, problems). A source that cannot be read is a PROBLEM.

    Never a silent zero: a record file that vanished must not look like a record
    that rules nothing, which is the exact shape of a defense reporting green
    over an empty corpus.
    """
    rulings = []
    problems = []
    for src in sources or []:
        path = (src or {}).get("path") or ""
        label = (src or {}).get("label") or os.path.basename(path)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except Exception as exc:
            problems.append("%s: %s" % (path, exc))
            continue
        parser = PARSERS.get(os.path.basename(path), parse_rules)
        found = parser(label, lines)
        for r in found:
            r.finish()
        if not found:
            problems.append("%s: parsed to zero rulings" % path)
        rulings.extend(found)
    return rulings, problems


# ---------------------------------------------------------------------------
# THE MATCH
# ---------------------------------------------------------------------------
def build_df(rulings):
    df = {}
    for r in rulings:
        for g in r.counts:
            df[g] = df.get(g, 0) + 1
    return df


def rare_threshold(n_rulings):
    """How many rulings a word may appear in and still count as DISTINCTIVE.

    Derived from the size of the register rather than typed, so it does not
    silently mean something different when the record doubles. RARE_FRACTION of
    the rulings, floored at 2 — measured over the live register (82 rulings,
    threshold 9) this puts "swoosh" at 1, "certificate" at 2, "american" at 3,
    "extra" at 3, "splash" at 6, "payload" at 8 on the distinctive side, and
    "start" at 10, "logo" at 10, "whole" at 12, "system" at 16, "type" at 25,
    "nothing" at 29 on the vocabulary side. That split is the gate.
    """
    return max(2, int(RARE_FRACTION * n_rulings))


def corroborate(qwords, ruling, df, subject):
    """A SECOND, INDEPENDENT signal that a question is about this ruling.

    Required whenever a ruling's title is made ENTIRELY of the register's own
    common vocabulary — "the start screen", "a design system", "the logo",
    "Type". Sharing those words with a question is a coincidence, and it was:
    measured over the 27 real questions asked on this machine, "start screen"
    alone fired on two questions about when to schedule an unrelated migration,
    because one option said "It starts fresh" and another said "against your
    screen".

    What IS evidence is the question ALSO carrying a word or phrase that is
    rare across the register AND REPEATED inside this one ruling — because an
    incidental mention appears once and a SUBJECT repeats. "swoosh" appears
    five times inside the logo ruling and nowhere else, so the question about
    the mark's second tone is refused and cited. "monospaced" appears exactly
    once in the whole register, so the question nobody ever ruled on is not.

    THE SUBJECT'S OWN WORDS ARE EXCLUDED, and that exclusion is the difference
    between a second signal and a spelling of the first. Found by the live
    register moving underneath this file: a ruling titled "The door" was
    corroborated by the word "door", and the gate refused a question from July
    about recording video in the app. A one-word title that vouches for itself
    is the exact coincidence the corroboration rule exists to rule out.

    -> (how, anchor) or None.
    """
    subj = set(subject)
    for n in range(MAX_N, 1, -1):
        for g in ngrams(qwords, n):
            if all(w in subj for w in g):
                continue
            if df.get(g, 0) <= DF_MAX and ruling.counts.get(g, 0) >= TF_PHRASE:
                return "phrase", " ".join(g)
    for w in qwords:
        if w in subj:
            continue
        g = (w,)
        if df.get(g, 0) <= DF_MAX and ruling.counts.get(g, 0) >= TF_TOKEN:
            return "token", w
    return None


def check(question, rulings, df):
    """-> list of (ruling, how, anchor_text, weakest_df, subject_len).

    ONE ANCHOR KIND — the ruling's own TITLE, carried whole by the question —
    with a corroborating second signal demanded when that title is made only of
    common words. This is the narrow version, and it is narrow on purpose.

    A third anchor kind was built, measured and DELETED: any 2-3 word phrase
    shared with a ruling's BODY. It fired on "anything else", "per session" and
    "all companies", because a ruling's body cites half the register and
    sharing words with it is not evidence of anything. Its rate would have got
    this gate waived inside a day, and a waived gate protects nothing.

    See scripts/hooks/ceo-ruled.corpus.md for the corpus and the rate.
    """
    qwords = content_words(question)
    qset = set(qwords)
    rare = rare_threshold(len(rulings))

    hits = []
    for r in rulings:
        subj = []
        for w in content_words(r.subject):
            if w not in subj:
                subj.append(w)
        if not subj:
            continue
        if not all(w in qset for w in subj):
            continue
        weakest = min(df.get((w,), 0) for w in subj)
        how, anchor = "title", " ".join(subj)
        # A title anchor stands ALONE only if it is both MULTI-WORD and carries
        # a word that is distinctive in this register. One word is never enough
        # on its own, however rare it looks here: "surfaces" and "pipeline" are
        # rare in the CEO's register and ordinary everywhere else, and between
        # them they refused three unrelated questions in the measured corpus.
        if len(subj) < MIN_ALONE or weakest > rare:
            corr = corroborate(qwords, r, df, subj)
            if corr is None:
                continue
            how = "title+" + corr[0]
            anchor = "%s / %s" % (" ".join(subj), corr[1])
        hits.append((r, how, anchor, weakest, len(subj)))

    # The most specific citation leads the refusal: rarest subject word first,
    # then the longest title. A refusal is only as useful as its first line.
    hits.sort(key=lambda h: (h[3], -h[4]))
    return hits


def do_check(job):
    question = job.get("question") or ""
    sources = job.get("sources") or []
    exempt = set(str(c) for c in (job.get("exempt") or []))

    rulings, problems = load_rulings(sources)
    for p in problems:
        sys.stdout.write("PROBLEM\t%s\n" % _flatten(p))
    sys.stdout.write("SCANNED\t%d\t%d\n" % (len(rulings), len(sources)))
    if not rulings:
        # No corpus is not "nothing is ruled". The caller decides what to do
        # with a PROBLEM line; it must never read this as CLEAR.
        sys.stdout.write("VERDICT\tCLEAR\n")
        return 0

    df = build_df(rulings)
    hits = check(question, rulings, df)

    live = []
    for r, how, anchor, d, t in hits:
        if r.cite in exempt:
            sys.stdout.write("EXEMPT\t%s\n" % r.cite)
            continue
        live.append((r, how, anchor, d, t))

    for r, how, anchor, d, t in live:
        sys.stdout.write("RULED\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n" % (
            r.label, r.cite, _flatten(r.title), how, anchor, d, t, r.line))
        for q in r.quotes:
            sys.stdout.write("QUOTE\t%s\t%s\n" % (r.cite, q))

    if live:
        sys.stdout.write("VERDICT\tRULED\n")
    elif hits:
        sys.stdout.write("VERDICT\tALL-EXEMPT\n")
    else:
        sys.stdout.write("VERDICT\tCLEAR\n")
    return 0


def do_rulings(job):
    rulings, problems = load_rulings(job.get("sources") or [])
    for p in problems:
        sys.stdout.write("PROBLEM\t%s\n" % _flatten(p))
    for r in rulings:
        sys.stdout.write("RULING\t%s\t%s\t%s\t%d\n" % (
            r.label, r.cite, _flatten(r.title), r.line))
    sys.stdout.write("SCANNED\t%d\t%d\n" % (len(rulings),
                                            len(job.get("sources") or [])))
    return 0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("ceo-ruled.py: expected a job file path (or '-')\n")
        return 2
    try:
        if sys.argv[1] == "-":
            job = json.load(sys.stdin)
        else:
            with open(sys.argv[1], encoding="utf-8") as fh:
                job = json.load(fh)
    except Exception as exc:
        sys.stderr.write("ceo-ruled.py: unreadable job: %s\n" % exc)
        return 2
    if not isinstance(job, dict):
        sys.stderr.write("ceo-ruled.py: job is not an object\n")
        return 2
    mode = job.get("mode") or "check"
    if mode == "check":
        return do_check(job)
    if mode == "rulings":
        return do_rulings(job)
    sys.stderr.write("ceo-ruled.py: unknown mode %r\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main())
