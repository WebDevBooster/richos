#!/usr/bin/env python3
"""ceo-asks.py — THE PREDICATE FOR "WAS HE ACTUALLY ASKED?"

Read scripts/lib/ceo-asks.sh first; it carries the rationale and the fail-open /
fail-closed argument. This file carries only the mechanism, because the
mechanism has to be exact and has to be testable without a session.

===========================================================================
WHAT IT DECIDES, AND THE ONE THING IT REFUSES TO DECIDE
===========================================================================
Two questions, and they are deliberately separate:

  match   Given the TEXT of a question that was actually put to the CEO, which
          prepared item — if any — was it about? Determined from the words he
          saw. Never from anything the orchestrator asserts about its own
          intent, because an assertion is exactly what failed on 2026-08-31:
          the record said the questions were prepared and nobody was asked.

  assess  Given the prepared items and the asks witnessed THIS SESSION, is the
          session's obligation discharged?

The thing it refuses to decide is whether the question was a GOOD one. A
question can match item 1.1 and still be a poor rendering of it. No text
predicate can tell those apart, and one that claimed to would be a score to
optimize against rather than a fact. What is engineered out here is a session
in which he was never asked AT ALL — which is the failure that happened.

===========================================================================
THE MATCH, AND WHY IT IS DELIBERATELY HARD TO SATISFY BY ACCIDENT
===========================================================================
A question matching NOTHING records UNMATCHED and discharges NOTHING. That
property is the whole anti-gaming design: without it, one junk question per
session clears the gate forever and the gate becomes a formality with a log.

So the matcher errs strict. Two independent ways to match, both requiring the
question to carry the item's own content:

  BY ID       the item's id ("1.1", "2.4") appears in the question as a whole
              token. Unambiguous, and typing it is an act of naming the item.

  BY TITLE    at least MIN_HITS of the item's title content-words appear, AND
              they are at least SCORE_FLOOR of that title. A title of one or
              two content words requires ALL of them, because 60% of two is one
              word and one word is a coincidence.

Word matching is prefix-tolerant from MIN_STEM characters ("enroll" matches
"enrollment", "sign" does not match "signing" at 4 — it does, and that is
intended; "app" never matches "apple" because it is under the floor). That
tolerance exists because a real question says "enroll as an individual" while
the record's title says "enrollment", and a gate that refused THAT would train
its operator to route around it.

MEASURED AGAINST THE REAL RECORD, not tuned in the abstract — see
scripts/hooks/ceo-asks.test.sh, which pins both directions: a plausible
question for each of the 13 live items matches it, and a spread of junk and
near-miss questions match nothing.

===========================================================================
INPUT / OUTPUT
===========================================================================
INPUT   one JSON job, path as argv[1] (or on stdin when argv[1] is "-"):

    {
      "mode":        "match" | "assess",
      "question":    "<question + every option label + every description>",
      "items":       [{"repo","section","id","state","title","open","time",
                       "done","unblocks"}, ...],
      "asks":        [{"matched_item","repo","timestamp","discharges"}, ...],
      "ready_state": "READY-FOR-CEO"
    }

OUTPUT  tab-separated lines on stdout.

  mode "match":
      MATCH      <repo>  <id>  <score>  <hits>  <needed>  <how>
      UNMATCHED  <repo>  <id>  <score>  <hits>  <needed>  <how>
    UNMATCHED still names the BEST candidate and its score, so a near miss is
    diagnosable rather than a shrug. The repo/id on an UNMATCHED line are the
    near miss and carry NO discharge — every consumer keys off field 1.

  mode "assess":
      PREPARED   <n>
      ASKED      <n>
      UNASKED    <n>
      ASK        <repo>  <id>  <title>  <one-line-ask>     (0..N, unasked only,
                                                            document order)
      VERDICT    OPEN | SATISFIED | NOTHING-PREPARED

EXIT    0 with a verdict. 2 only when the JOB itself is unreadable, which is a
        broken CALLER and must never look like "nothing to ask".
"""

import json
import math
import re
import sys

# --- The knobs, named and in one place -------------------------------------
# Changing any of these changes what counts as having asked, so they are
# constants with names rather than literals in an expression.
MIN_STEM = 4        # shortest prefix that may stand for a longer word
MIN_HITS = 2        # title content-words a question must carry
SCORE_FLOOR = 0.6   # ...and the fraction of the title they must be
SHORT_TITLE = 2     # a title of this many content-words or fewer needs ALL

# Function words and record-vocabulary words. Deliberately SHORT: every word
# removed from an item's title makes that item easier to match by accident, so
# this list is the words that carry no identity at all, and nothing else.
STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "does",
    "for", "from", "has", "have", "how", "if", "in", "into", "is", "it", "its",
    "not", "of", "on", "or", "our", "out", "should", "so", "than", "that",
    "the", "their", "them", "then", "there", "these", "they", "this", "to",
    "up", "was", "we", "what", "when", "which", "who", "why", "will", "with",
    "you", "your",
}

ID_TOKEN_RE = re.compile(r"(?<![0-9.])(\d+\.\d+[a-z]?)(?![0-9.])")
WORD_RE = re.compile(r"[a-z0-9]+")


def content_words(text):
    """Lowercased content tokens: no punctuation, no stopwords, no 1-2 char noise.

    Backticks, markdown emphasis and path separators are separators here, so
    `packaging-and-signing.md` contributes packaging/signing rather than one
    unmatchable blob.
    """
    out = []
    for w in WORD_RE.findall((text or "").lower()):
        if len(w) < 3 or w in STOPWORDS:
            continue
        out.append(w)
    return out


def _covers(qword, tword):
    """Does a question word stand for a title word?

    Equal, or one is a prefix of the other from MIN_STEM characters. Prefix
    tolerance in BOTH directions: the question may generalize ("enroll" for
    "enrollment") or specialize ("transcription" for "transcript").
    """
    if qword == tword:
        return True
    n = min(len(qword), len(tword))
    if n < MIN_STEM:
        return False
    return qword[:n] == tword[:n]


def score_item(qwords, qids, item):
    """-> (matched: bool, score: float, hits: int, needed: int, how: str)"""
    item_id = str(item.get("id") or "")
    if item_id and item_id in qids:
        return True, 1.0, 0, 0, "id"

    title_words = []
    for w in content_words(item.get("title")):
        if w not in title_words:
            title_words.append(w)
    if not title_words:
        # A title with no content words cannot be matched by title. Reported as
        # a 0-of-0 miss rather than as a free pass: an item nobody can ask
        # about is a defect in the record, and silently treating it as matched
        # would hide it.
        return False, 0.0, 0, 0, "title"

    hits = sum(1 for t in title_words if any(_covers(q, t) for q in qwords))
    score = float(hits) / float(len(title_words))
    if len(title_words) <= SHORT_TITLE:
        needed = len(title_words)
    else:
        # ceil, with the float slack taken off first: 0.6 * 5 is 3.0000000000000004
        # in binary, and a naive ceil turns a 5-word title's threshold into 4.
        # A threshold that is wrong by one on some title lengths and not others
        # is exactly the kind of quiet arithmetic that makes a gate untrustable.
        needed = max(MIN_HITS, int(math.ceil(SCORE_FLOOR * len(title_words) - 1e-9)))
    return hits >= needed, score, hits, needed, "title"


def do_match(job):
    question = job.get("question") or ""
    items = job.get("items") or []
    qwords = set(content_words(question))
    qids = set(ID_TOKEN_RE.findall(question.lower()))

    best = None
    for item in items:
        matched, score, hits, needed, how = score_item(qwords, qids, item)
        cand = (matched, score, hits, needed, how, item)
        if best is None:
            best = cand
            continue
        # A match always beats a non-match; among equals, the higher score, then
        # document order (which puts section 1 — the decisions — first).
        if (cand[0], cand[1]) > (best[0], best[1]):
            best = cand

    if best is None:
        sys.stdout.write("UNMATCHED\t\t\t0.00\t0\t0\tnone\n")
        return 0

    matched, score, hits, needed, how, item = best
    sys.stdout.write("%s\t%s\t%s\t%.2f\t%d\t%d\t%s\n" % (
        "MATCH" if matched else "UNMATCHED",
        item.get("repo") or "", item.get("id") or "",
        score, hits, needed, how,
    ))
    return 0


def one_line_ask(item):
    """The item, rendered as something answerable in one line.

    NAMED, NOT COUNTED — the same rule notice-unstarted-rows.sh states. "13
    items waiting" is the sentence that got demoted on the morning this whole
    mechanism was ordered; a specific question is what got answered in seconds.
    Every part of it comes from the record, so it cannot drift from the page.
    """
    title = (item.get("title") or "").strip()
    open_at = (item.get("open") or "").strip().strip("`")
    time = (item.get("time") or "").strip()
    done = (item.get("done") or "").strip()
    parts = ["%s?" % title.rstrip("?")]
    if done:
        parts.append("Answer = %s." % done.rstrip("."))
    if open_at:
        parts.append("Open %s%s." % (open_at, (" (%s)" % time) if time else ""))
    return " ".join(parts)


def do_assess(job):
    items = job.get("items") or []
    ready_state = job.get("ready_state") or "READY-FOR-CEO"
    asks = job.get("asks") or []

    # PREPARED means: in a CEO section AND in the ready state. An item sitting
    # in a CEO section in the BLOCKED-ON-RICH state is NOT prepared — the CEO
    # TODOs lint refuses it separately, and demanding that an unprepared item be
    # put to him would be asking him about work nobody has finished. That is the
    # failure this engine's CEO-TODOs contract already exists to stop, and this
    # gate must not reintroduce it from the other side.
    prepared = [i for i in items if (i.get("state") or "") == ready_state]

    # WHAT COUNTS AS AN ASK, decided here and nowhere else. Two conditions, and
    # both are the anti-gaming property:
    #
    #   `discharges` true — the witness computed this at the moment of the call.
    #     It is false for a question that matched no prepared item (otherwise one
    #     junk question per session clears the gate forever) and false for a
    #     question asked by a WORKER (otherwise any subagent's clarifying
    #     question hands the session a free discharge).
    #   a real item id     — belt and braces, so a hand-appended record with
    #     `discharges: true` and no item still discharges nothing.
    asked_ids = set()
    for a in asks:
        a = a or {}
        if not a.get("discharges"):
            continue
        mid = str(a.get("matched_item") or "")
        if mid and mid != "UNMATCHED":
            asked_ids.add(mid)

    unasked = [i for i in prepared if str(i.get("id") or "") not in asked_ids]

    sys.stdout.write("PREPARED\t%d\n" % len(prepared))
    sys.stdout.write("ASKED\t%d\n" % len([i for i in prepared
                                          if str(i.get("id") or "") in asked_ids]))
    sys.stdout.write("UNASKED\t%d\n" % len(unasked))
    for item in unasked:
        sys.stdout.write("ASK\t%s\t%s\t%s\t%s\n" % (
            item.get("repo") or "",
            item.get("id") or "",
            (item.get("title") or "").replace("\t", " "),
            one_line_ask(item).replace("\t", " ").replace("\n", " "),
        ))

    if not prepared:
        verdict = "NOTHING-PREPARED"
    elif asked_ids:
        # THE RULE IS ONE PER SESSION, NOT ALL. Thirteen items are open; a gate
        # that demanded all thirteen before any teammate could be dispatched
        # would be the same wall this exists to remove, and its operator would
        # switch it off in a day. One is the floor that makes the conversation
        # happen; the Stop notice carries the rest.
        verdict = "SATISFIED"
    else:
        verdict = "OPEN"
    sys.stdout.write("VERDICT\t%s\n" % verdict)
    return 0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("ceo-asks.py: expected a job file path (or '-')\n")
        return 2
    try:
        if sys.argv[1] == "-":
            job = json.load(sys.stdin)
        else:
            with open(sys.argv[1], encoding="utf-8") as fh:
                job = json.load(fh)
    except Exception as exc:
        # An unreadable job is a broken CALLER. It exits non-zero and prints no
        # verdict, because the one thing it must never be mistaken for is
        # "there was nothing to ask about".
        sys.stderr.write("ceo-asks.py: unreadable job: %s\n" % exc)
        return 2
    if not isinstance(job, dict):
        sys.stderr.write("ceo-asks.py: job is not an object\n")
        return 2

    mode = job.get("mode") or "assess"
    if mode == "match":
        return do_match(job)
    if mode == "assess":
        return do_assess(job)
    sys.stderr.write("ceo-asks.py: unknown mode %r\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main())
