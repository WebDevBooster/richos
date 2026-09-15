#!/usr/bin/env python3
"""stop-live-work.py — the predicate behind the PreToolUse[TaskStop] gate.

===========================================================================
THE FAILURE
===========================================================================
2026-09-10. The CEO wrote:

    "the currently running agents MIGHT need to be paused IF we get close to
     hitting the quota before it resets."

Within a minute the orchestrator called TaskStop on two mid-flight teammates
and reported it back as compliance. No burn rate had been measured. No
condition had been established. Nothing had been asked.

The cost, verified afterwards: `echo-opus-hw2` had NO COMMITS and a clean
worktree — its entire session is gone. `zach-opus-dor1` survived only because
it had committed as it went.

His answer was "Did I say anything about stopping???", and then a question
about whether this class of failure will ever stop.

It is the FOURTH instance in one day of ONE mechanism: an inference about what
he wanted, substituted for what he said, and then acted on expensively. The
other three each got their own narrow guard. This is the sharpest of the four
because it is the only one that destroys work that cannot be recovered.

===========================================================================
THE ONE THING THIS DECIDES
===========================================================================
A TaskStop against a LIVE teammate requires the CEO's own words or a written,
checkable reason. That is all. Everything else about TaskStop is somebody
else's problem, and deliberately so — see THE NARROWNESS below.

===========================================================================
WHAT A PreToolUse HOOK CAN ACTUALLY SEE — MEASURED, NOT ASSUMED
===========================================================================
Measured 2026-09-10 with a live one-shot session and a probe hook
(scripts/hooks/fixtures/stop-live-work/pretooluse-payload-probe.json holds the
captured payload). Two findings decided this file's whole shape:

  1. THE TRANSCRIPT IS READABLE, AND THE USER'S MESSAGE IS ALREADY IN IT.
     At the moment the hook fired the transcript held 23 lines, ending with
     the `last-prompt` record. The user's message was line 11. So clause 1 —
     "did he actually say it?" — is answerable.

  2. THE ASSISTANT'S OWN TEXT FOR THIS TURN IS **NOT** IN IT YET.
     The assistant records carrying that turn's preface text (line 25) and the
     tool_use itself (line 26) were written AFTER the hook returned. A hook
     cannot read one word of the orchestrator's reasoning for the call it is
     about to make.

  3. TaskStop's ENTIRE tool_input is {"task_id": "<name-or-agent-id>"}.
     Verified across all 100 real TaskStop calls on this machine: 100/100 have
     exactly that one key. There is no reason field, no note field, nothing.

(2) and (3) together kill the transport every other ack in this engine uses.
`model-ceiling-ack:` rides in the Agent prompt and `resume-ack:` rides in the
SendMessage body because those tools HAVE a text field. TaskStop has none, and
the turn's prose is invisible. So the ack here cannot be a marker line — it has
to be WRITTEN DOWN BEFORE THE CALL, by `scripts/stop-work-ack.sh`, into
.claude/state/stop-work-acks.jsonl. That is a harder ack to give than a marker
in a sentence, and on this particular tool that is the correct direction: the
thing being destroyed cannot be recovered.

===========================================================================
THE THREE AUTHORITIES, IN ORDER
===========================================================================
  A. THE TARGET IS NOT PROVABLY ALIVE  -> ALLOW, SILENTLY.
     Retiring a finished teammate is the overwhelming majority of real
     TaskStop traffic (measured below) and it destroys nothing. The verdict
     comes from scripts/lib/agent-liveness.py — the same resolver the removal
     helper and guard-agent-state-claims.sh use, whose authoritative source is
     the worktree lock. ALIVE means the lock is held and the locking pid is
     running. NOT-ALIVE and INDETERMINATE both allow (see FAIL-OPEN).

  B. THE CEO'S OWN WORDS  -> ALLOW.
     The last genuine user message in the transcript carries an unconditional,
     non-negated, non-interrogative stop imperative. A CONDITIONAL IS NOT AN
     INSTRUCTION — "might", "if", "may need to", "should we" all disqualify
     the sentence carrying them, and that single distinction is the whole
     reason this file exists.

  C. A LIVE, TARGETED, UNCONSUMED stop-work-ack  -> ALLOW + record.
     Written by scripts/stop-work-ack.sh, naming the exact task_id, saying
     what is being destroyed and why it cannot wait. A BARE MARKER EXEMPTS
     NOTHING: both fields are required and both have a floor. One ack covers
     ONE target and is consumed on use — because today's two kills were 2.7
     seconds apart, and a single ack that waved through a sweep would have
     let exactly this incident happen with one sentence of paperwork.

  Otherwise -> REFUSE, naming the target, what is known about it, and the two
  honest routes.

===========================================================================
THE NARROWNESS, AND WHY IT IS THE POINT
===========================================================================
This project killed three guards (g11/g12/g13) in one day by shipping gates
broad enough that waiving became routine — and a habitually waived guard is a
dead guard that still looks alive. So this one refuses in ONE situation:

  the orchestrator destroying work that is PROVABLY still running,
  with no instruction from the CEO and nothing written down.

It never fires on:
  * a teammate stopping ITSELF (the caller is the target)
  * a protocol shutdown (no TaskStop involved at all)
  * cleanup of an agent that has already finished  -> authority A
  * a target it cannot positively establish as alive -> authority A

===========================================================================
FAIL-OPEN ON DOUBT, AND WHY THAT IS NOT A HOLE
===========================================================================
The guard blocks ONLY on a POSITIVE ALIVE verdict. INDETERMINATE allows.

That looks backwards for a destructive operation, and it is not, for a reason
this repository has already paid for once: the dominant legitimate use of
TaskStop is retiring a teammate whose worktree is long gone, and for those the
resolver frequently cannot resolve anything at all. Fail closed and every one
of those cleanups needs paperwork; paperwork every time is how g11, g12 and
g13 died. Fail open and the guard still refuses the exact case that cost the
CEO a session's work this morning, because a LIVE agent is precisely the one
whose lock IS held and IS resolvable.

An INDETERMINATE stop is not silent, though — it is allowed and NOTED, so the
one class the guard cannot decide is at least visible.
"""

import json
import os
import re
import sys
import time

# ---------------------------------------------------------------------------
# 1. THE LAST GENUINE USER MESSAGE
# ---------------------------------------------------------------------------
# A transcript's `user` records are NOT all the user. The harness files tool
# results, teammate messages, task notifications, command output and system
# reminders under the same role. Every one of those is a channel a teammate or
# the harness can write to, so treating them as the CEO's voice would let a
# teammate authorize the destruction of another teammate's work by saying the
# word "stop" in a handoff summary. Measured on the corpus: 32 of 100 real
# TaskStop calls were immediately preceded by a teammate completion message
# carrying prose. They are not instructions and they are excluded here.

_INJECTED_MARKERS = (
    "<teammate-message",
    "<agent-message",
    "<cross-session-message",
    "<task-notification",
    "<local-command-stdout",
    "<local-command-stderr",
    "<command-name>",
    "<command-message>",
    "<bash-input>",
    "<bash-stdout>",
    "Another Claude session sent a message:",
    "[Request interrupted by user]",
    "Caveat: The messages below were generated",
    "[Cross-session idle notice]",
)

_SYSTEM_REMINDER_RE = re.compile(
    r"<system-reminder>.*?</system-reminder>", re.DOTALL | re.IGNORECASE)


def strip_noise(text):
    """Remove system reminders before matching.

    A reminder is machine-authored text the harness staples to a user turn. It
    is not the CEO speaking, and this project's own CLAUDE.md is quoted into
    reminders verbatim — which contains the word "stop" many times over.
    """
    return _SYSTEM_REMINDER_RE.sub(" ", text or "")


def is_injected(text):
    t = (text or "").lstrip()
    return any(m in t[:400] for m in _INJECTED_MARKERS)


def last_user_message(transcript_path, limit_bytes=32 * 1024 * 1024):
    """The most recent genuine user message text, or "".

    Reads the whole file rather than tailing by record count, because a single
    teammate handoff can be tens of kilobytes and the CEO's actual instruction
    can sit many records behind it.
    """
    if not transcript_path or not os.path.isfile(transcript_path):
        return ""
    try:
        size = os.path.getsize(transcript_path)
        with open(transcript_path, encoding="utf-8", errors="replace") as fh:
            if size > limit_bytes:
                fh.seek(size - limit_bytes)
                fh.readline()
            lines = fh.read().splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        if '"user"' not in line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "user":
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            # A record holding ANY tool_result block is harness traffic, not a
            # typed message, even when it also carries text.
            if any(isinstance(b, dict) and b.get("type") == "tool_result"
                   for b in content):
                continue
            text = "\n".join(b.get("text", "") for b in content
                             if isinstance(b, dict) and b.get("type") == "text")
        else:
            continue
        text = strip_noise(text).strip()
        if not text:
            continue
        if is_injected(text):
            continue
        return text
    return ""


# ---------------------------------------------------------------------------
# 2. IS IT AN INSTRUCTION TO STOP?
# ---------------------------------------------------------------------------
# THE ONE DISTINCTION THIS GUARD EXISTS FOR. His sentence was
#
#     "the currently running agents might need to be paused if we get close
#      to hitting the quota before it resets"
#
# and it contains a stop word. It is not an instruction. It is a hypothesis
# about a future condition, and it was read as an order.
#
# So the predicate is deliberately two-sided: find an imperative stop, then
# DISQUALIFY it if the sentence carrying it hedges, questions or negates.

# Base/imperative forms only. `stopped`, `stopping`, `stops`, `killed`,
# `cancelled` are excluded on purpose: an inflected form is almost always
# narration ("the deploy stopped working", "I'm stopping Reed") rather than an
# order, and narration must never authorize a kill.
_STOP_VERB = re.compile(
    r"(?<![\w-])("
    r"stop|halt|abort|cancel|kill|terminate|shutdown"
    r"|shut\s+(?:it|them|him|her|that|those|everything|down)"
    r"|pause|call\s+it\s+off|stand\s+down|knock\s+it\s+off"
    r")(?![\w-])",
    re.IGNORECASE)

# Never a stop instruction, whatever else the sentence says.
_STOP_FALSE_FRIENDS = re.compile(
    r"(?<![\w-])(non-?stop|stop\s+sign|full\s+stop|bus\s+stop|stop\s+gap"
    r"|stopgap|showstopper|show-?stopper|backstop|pit\s+stop"
    r"|kill\s+switch|killer|overkill)(?![\w-])",
    re.IGNORECASE)

# THE HEDGES. Any of these in the sentence carrying the stop word means the
# sentence is a possibility, a question or a plan — not an order.
_CONDITIONAL = re.compile(
    r"(?<![\w-])("
    r"might|may|maybe|perhaps|possibly|probably|potentially"
    r"|if|whether|unless|in\s+case|as\s+soon\s+as|once\s+we|once\s+it"
    r"|when\s+we|when\s+it|when\s+you|before\s+we|after\s+we"
    r"|should\s+we|shall\s+we|do\s+we|can\s+we|could|would|will\s+need"
    r"|going\s+to\s+need|need\s+to\s+be|needs\s+to\s+be|may\s+need"
    r"|consider|considering|think\s+about|be\s+ready\s+to|get\s+ready"
    r"|prepared\s+to|prepare\s+to|in\s+the\s+event|assuming|suppose"
    r"|eventually|at\s+some\s+point|later|tomorrow|plan\s+to|planning"
    r")(?![\w-])",
    re.IGNORECASE)

_NEGATED = re.compile(
    r"(?<![\w-])("
    r"do\s?n[o'’]?t|do\s+not|never|no\s+need\s+to|without|rather\s+than"
    r"|instead\s+of|stop\s+asking|didn[o'’]?t|won[o'’]?t|nobody\s+said"
    r"|did\s+I\s+say"
    r")(?![\w-])",
    re.IGNORECASE)

# A canonical teammate name. Used only to answer "is he telling me to stop
# SOMEONE ELSE?" — the one scoping question worth asking, because it is the
# one form in which he reliably names a specific teammate.
_TEAMMATE_NAME = re.compile(
    r"(?<![\w-])([a-z]{2,12}-(?:fable|opus|sonnet|haiku)-[a-z0-9]{1,20})(?![\w-])",
    re.IGNORECASE)

# EXPLANATION ONLY — never authorization. Inflected and nominal forms
# ("paused", "stopping", "shutting down") are how a stop word appears in a
# sentence that is describing rather than ordering, which makes them exactly
# the forms worth QUOTING BACK in a refusal. His sentence on 2026-09-10 used
# "paused", and a refusal that says "the last user message says nothing about
# stopping" teaches nothing, while one that says
#
#     the only stop-like sentence is conditional on 'might':
#     "the currently running agents might need to be paused if ..."
#
# names the exact reading that destroyed a teammate's session.
_STOP_ANYFORM = re.compile(
    r"(?<![\w-])("
    r"stop|stops|stopped|stopping|halt|halts|halted|halting"
    r"|abort|aborts|aborted|aborting|cancel|cancels|cancell?ed|cancell?ing"
    r"|kill|kills|killed|killing|terminate|terminates|terminated|terminating"
    r"|pause|pauses|paused|pausing|shutdown|shut\s+down|shutting\s+down"
    r"|stand\s+down|standing\s+down|wind\s+down|winding\s+down"
    r")(?![\w-])",
    re.IGNORECASE)

_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+|\n+")


def split_sentences(text):
    return [s.strip() for s in _SENTENCE_SPLIT.split(text or "") if s.strip()]


def authorizes_stop(text, task_id=""):
    """(bool, reason) — does THIS message unconditionally order a stop?

    Returns the sentence that authorized it, so a refusal or an allowance can
    always quote the words it acted on rather than asserting them.
    """
    text = strip_noise(text or "")
    if not text.strip():
        return False, "no user instruction in this session's transcript"
    target = (task_id or "").strip().lower()
    # A name may arrive session-qualified: norm-sonnet-title1@session-ad9b54ca
    target_bare = target.split("@", 1)[0]

    hedged = []
    for sent in split_sentences(text):
        m = _STOP_VERB.search(sent)
        if not m:
            continue
        if _STOP_FALSE_FRIENDS.search(sent):
            continue
        if sent.rstrip().endswith("?"):
            hedged.append(("a question, not an instruction", sent))
            continue
        cond = _CONDITIONAL.search(sent)
        if cond:
            hedged.append(("conditional on '%s'" % cond.group(1).lower(), sent))
            continue
        neg = _NEGATED.search(sent)
        if neg:
            hedged.append(("negated by '%s'" % neg.group(1).lower(), sent))
            continue
        # Scoped at somebody else? The only scoping test worth making is the
        # one that is unambiguous: he named a canonical teammate, and it is
        # not this one. Anything subtler ("stop the guard work") is left
        # permissive on purpose — over-reading HIS OWN ORDER is a far smaller
        # error than refusing it, and the written ack remains for the rest.
        named = [n.lower() for n in _TEAMMATE_NAME.findall(sent)]
        if named and target_bare and not any(
                n == target_bare or n.split("@")[0] == target_bare for n in named):
            hedged.append(("scoped to %s, not to %s"
                           % (", ".join(named), task_id), sent))
            continue
        return True, sent.strip()

    if not hedged:
        # Second pass, for the REFUSAL MESSAGE only. A stop word in an
        # inflected form never authorizes anything — but it is the form his
        # 2026-09-10 sentence used, and naming it is the difference between a
        # refusal that teaches and one that stonewalls.
        for sent in split_sentences(text):
            m = _STOP_ANYFORM.search(sent)
            if not m or _STOP_FALSE_FRIENDS.search(sent):
                continue
            if sent.rstrip().endswith("?"):
                hedged.append(("a question, not an instruction", sent))
                continue
            cond = _CONDITIONAL.search(sent)
            if cond:
                hedged.append(("conditional on %r" % cond.group(1).lower(), sent))
                continue
            neg = _NEGATED.search(sent)
            if neg:
                hedged.append(("negated by %r" % neg.group(1).lower(), sent))
                continue
            hedged.append(("%r used as narration, not as an order"
                           % m.group(1).lower(), sent))
            break

    if hedged:
        why, sent = hedged[0]
        return False, "the only stop-like sentence is %s: %r" % (why, sent[:220])
    return False, "the last user message says nothing about stopping"


# ---------------------------------------------------------------------------
# 3. THE WRITTEN ACK
# ---------------------------------------------------------------------------
# Because TaskStop has no text field and the turn's prose is invisible (see the
# module header), the ack is a FILE. scripts/stop-work-ack.sh writes it; this
# reads it. Three properties, each of which exists because of a specific way an
# ack can be made meaningless:
#
#   TARGETED    it names one task_id.        (today's two kills were 2.7s apart)
#   LIVE        it expires.                  (a stale ack is not a decision)
#   CONSUMED    it is spent on first use.    (one ack, one destruction)

ACK_TTL_SECONDS = 900          # 15 minutes: long enough to write, too short to bank
MIN_DESTROYING = 20
MIN_WHY = 20


def ack_path(entity_root):
    return os.path.join(entity_root, ".claude", "state", "stop-work-acks.jsonl")


def read_acks(entity_root):
    p = ack_path(entity_root)
    if not os.path.isfile(p):
        return []
    out = []
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except OSError:
        return []
    return out


def find_live_ack(entity_root, task_id, now=None, session_id=""):
    """The newest unconsumed, unexpired, well-formed ack for this exact target."""
    now = time.time() if now is None else now
    target = (task_id or "").strip()
    if not target:
        return None, "no task_id to match an ack against"
    best = None
    stale = expired = malformed = 0
    for rec in read_acks(entity_root):
        if (rec.get("task_id") or "").strip() != target:
            continue
        if rec.get("consumed"):
            stale += 1
            continue
        if session_id and rec.get("session_id") and rec["session_id"] != session_id:
            stale += 1
            continue
        try:
            age = now - float(rec.get("epoch") or 0)
        except (TypeError, ValueError):
            malformed += 1
            continue
        if age > ACK_TTL_SECONDS or age < -60:
            expired += 1
            continue
        # A BARE MARKER EXEMPTS NOTHING.
        d = (rec.get("destroying") or "").strip()
        w = (rec.get("why") or "").strip()
        if len(d) < MIN_DESTROYING or len(w) < MIN_WHY:
            malformed += 1
            continue
        if best is None or float(rec.get("epoch") or 0) > float(best.get("epoch") or 0):
            best = rec
    if best:
        return best, ""
    bits = []
    if stale:
        bits.append("%d already spent" % stale)
    if expired:
        bits.append("%d older than %d minutes" % (expired, ACK_TTL_SECONDS // 60))
    if malformed:
        bits.append("%d without a real reason" % malformed)
    return None, ("no live stop-work-ack for %s%s"
                  % (target, (" (" + "; ".join(bits) + ")") if bits else ""))


def consume_ack(entity_root, ack):
    """Spend the ack. One ack, one destruction — rewritten in place.

    Best-effort: a failure to mark it spent must never turn an ALLOW into a
    refusal, so the caller ignores the result. The worst case is one ack that
    could cover a second kill inside the same 15 minutes, which is strictly
    better than a guard that blocks because it could not write a file.
    """
    p = ack_path(entity_root)
    if not os.path.isfile(p):
        return False
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        out = []
        done = False
        for line in lines:
            try:
                rec = json.loads(line)
            except Exception:
                out.append(line)
                continue
            if (not done and not rec.get("consumed")
                    and rec.get("id") and rec.get("id") == ack.get("id")):
                rec["consumed"] = True
                rec["consumed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
                done = True
            out.append(json.dumps(rec, ensure_ascii=False))
        if done:
            tmp = p + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write("\n".join(out) + "\n")
            os.replace(tmp, p)
        return done
    except OSError:
        return False


# ---------------------------------------------------------------------------
# 4. THE VERDICT
# ---------------------------------------------------------------------------

ALLOW_NOT_LIVE = "allow-not-live"
ALLOW_SELF = "allow-self"
ALLOW_CEO = "allow-ceo-said-so"
ALLOW_ACK = "allow-acked"
ALLOW_UNDECIDABLE = "allow-undecidable"
REFUSE = "refuse"


def decide(task_id, liveness, user_text, entity_root, self_agent_id="",
           resolved_agent_id="", now=None, session_id=""):
    """The whole contract, as one pure function so the tests can drive it.

    `liveness` is "ALIVE" | "NOT-ALIVE" | "INDETERMINATE" — supplied by the
    caller from scripts/lib/agent-liveness.py, never re-derived here.
    """
    tid = (task_id or "").strip()
    if self_agent_id and tid and tid in (self_agent_id, "agent-" + self_agent_id):
        return ALLOW_SELF, "a teammate stopping itself destroys nobody else's work", None
    if (self_agent_id and resolved_agent_id
            and resolved_agent_id == self_agent_id):
        return ALLOW_SELF, "a teammate stopping itself destroys nobody else's work", None

    if liveness == "NOT-ALIVE":
        return (ALLOW_NOT_LIVE,
                "the target is not running — retiring a finished teammate "
                "destroys nothing", None)
    if liveness != "ALIVE":
        return (ALLOW_UNDECIDABLE,
                "liveness is INDETERMINATE for %s — allowed, and said out loud "
                "rather than guessed" % (tid or "the target"), None)

    ok, why = authorizes_stop(user_text, tid)
    if ok:
        return ALLOW_CEO, why, None

    ack, ack_why = find_live_ack(entity_root, tid, now=now, session_id=session_id)
    if ack:
        return ALLOW_ACK, ack_why, ack

    return REFUSE, why + " | " + ack_why, None


# ---------------------------------------------------------------------------
# 5. CLI — the hook's single entry point
# ---------------------------------------------------------------------------

def _cli():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--task-id", required=True)
    ap.add_argument("--liveness", required=True,
                    choices=["ALIVE", "NOT-ALIVE", "INDETERMINATE"])
    ap.add_argument("--transcript", default="")
    ap.add_argument("--entity-root", required=True)
    ap.add_argument("--self-agent-id", default="")
    ap.add_argument("--resolved-agent-id", default="")
    ap.add_argument("--session-id", default="")
    ap.add_argument("--user-text", default=None,
                    help="override the transcript read (tests only)")
    ap.add_argument("--consume", action="store_true")
    a = ap.parse_args()

    user_text = (a.user_text if a.user_text is not None
                 else last_user_message(a.transcript))
    verdict, why, ack = decide(
        a.task_id, a.liveness, user_text, a.entity_root,
        self_agent_id=a.self_agent_id, resolved_agent_id=a.resolved_agent_id,
        session_id=a.session_id)
    if verdict == ALLOW_ACK and ack and a.consume:
        consume_ack(a.entity_root, ack)
    print(json.dumps({"verdict": verdict, "reason": why,
                      "ack": ack, "task_id": a.task_id,
                      "liveness": a.liveness}, ensure_ascii=False))
    return 2 if verdict == REFUSE else 0


if __name__ == "__main__":
    sys.exit(_cli())
