#!/usr/bin/env python3
"""guard-stated-actions.py — THE ANALYSIS HALF of the Stop-time check that a
turn's REPORT agrees with the turn's ACTIONS, in two arms:

  ARM 1  STATED, NOT TAKEN   the text states an action; the tool calls do not
                             contain it.
  ARM 2  THE TURN THAT STOPS a teammate's completion arrived in this turn, and
                             the turn ends having started nothing and declared
                             nothing.

Called by guard-stated-actions.sh, which has already resolved the two roots,
read orchestration.config and decided that this repository adopted the engine.
This file reads the turn, reconciles the report against the tool calls, and
returns the verdict. It never decides whether to run.

===========================================================================
THE DEFECT, WITH THE DATE AND THE SENTENCES
===========================================================================
2026-09-02, one session, seven instances of one failure: the lead WRITES A
SENTENCE DESCRIBING AN ACTION AND TREATS HAVING WRITTEN IT AS HAVING DONE IT.
Two of the seven share an exact machine signature and are ARM 1:

    17:49  "Zach builds it tomorrow."        turn's tool calls: Bash x3, no Agent
    18:29  "Frank breaks it first, and I     turn's tool calls: Bash x7, no Agent
            want him attacking ..."

The CEO's next message asked, in blunt terms, where Frank was this time — and
after the apology — "I said 'Frank breaks it first' and then wrote a status
report instead of spawning him" — his reply was that this class of failure will
never end, will it?"*

The same day he sent six messages of one other shape — "No Frank this time?",
"Next Sage.", then a blunter repeat of the same question — each one restarting work
that had paused because a teammate returned and the lead answered it with a
REPORT and no dispatch. That is ARM 2. His question, verbatim, was "when will
this pattern STOP?". There was already a prose rule for it (the working record:
"A land ends by STARTING the top unblocked item, then reports") and there was
already a GUARD for it — guard-idle-land.sh — and the guard's own observation
log shows why it let all three of tonight's turns through:

    finishes: ["Design the elimination of the worktree class"]  dispatched: 0
        verdict: backlog-empty   rows: 41   free: 0
    finishes: ["Break the elimination design"]                  dispatched: 0
        verdict: backlog-empty   rows: 41   free: 0
    finishes: ["Lease-based worktree design"]                   dispatched: 0
        verdict: backlog-empty   rows: 41   free: 0

Its term 4 asks the BACKLOG whether there is something to start, and the next
step after a returned design — stress-test it — is not a backlog row. So the
gate saw the finish, saw no dispatch, and stood down on a table. ARM 2 is that
gate's first three terms with the fourth replaced by a DECLARATION: a stop
after a completion passes only if the lead SAYS, in the documented form, why
this is one of the three legitimate stops. An implicit stop is refused.

The same day's measured lesson: every rule left as PROSE was broken, and every
rule with a GUARD caught the lead — six refusals that evening, from five
guards. So both arms BLOCK. A notice that names the failure and lets the turn
end is the same defect as a reaper that saw 14 unlanded commits and printed
CLEAN.

===========================================================================
ARM 1 — THE SIGNATURE, stated precisely
===========================================================================
    the assistant's final text for a turn states an action, and that turn's
    tool calls do not contain it.

Both halves are read from structure. The tool calls come from the transcript,
scoped to THIS TURN by prompt_id exactly the way turn-manifest.py scopes them
(that module is IMPORTED for the call list rather than re-derived — the
sibling that re-derived it collected session-wide and was silently inverted
for weeks). The stated action is read from `last_assistant_message`.

The prose half is a heuristic over English, and the engine has been here
before: guard-unresolved-claims.py measured `dispatching|spawning|launching`
at 17% precision and refused to enforce it. So the trigger here is NOT a word.
It is a SENTENCE SHAPE, fitted to the two real failures and then measured
against every real turn on disk, and only the arms that fired on NOTHING ELSE
are allowed to block. The rest report, with their rate written down.

Corpus: every orchestrator transcript in ~/.claude/projects/-Users-alex-ab-
femcboost/ (19 sessions, 1,268 turns, 1,213 with a final message, 2026-07-27
to 2026-09-02), replayed by prompt_id span exactly as the Stop payload would
present each turn, through THIS file. Method and adjudication:
scripts/hooks/stated-actions.corpus.md.

ARM 1a — ROLE ACT  (BLOCKS — 2 fires over 1,213 messages, both the defect)
    A clause whose SUBJECT is a roster role, whose VERB is present-simple
    third person, and whose OBJECT is a pronoun or a determiner phrase:

        Zach builds it tomorrow.
        Frank breaks it first[, and I want him ...]

    and the turn contains no Agent call for that role and no SendMessage to a
    teammate. Before its exclusions this shape fired 15 times; 13 were false,
    and every false one belonged to one of four classes, each excluded for a
    stated reason rather than by tuning:

      REPORT VERBS     "Frank recommends the hybrid", "Sage rates this the
                       biggest risk", "Sage comes back with", "Echo continues
                       on". Verbs of saying, judging, returning and continuing
                       describe a running or finished agent's OUTPUT, not an
                       act the lead has to take. That class is liveness, and
                       liveness is owned (report-only, on measured grounds) by
                       guard-agent-state-claims.py.
      LIST ITEMS       "1. Zach builds it — in flight now", "- Dean fixes
                       Sterling's definition", "5. ... Iris builds each". A
                       bulleted or numbered line is a plan or a status table.
                       Both real failures were plain sentences in prose. Lines
                       that open with a list marker are not scanned.
      BARE OBJECTS     "Art designs Bootstrap components", "Clark researches
                       what an art director is". A description of a role's
                       craft takes a bare noun; an announced act takes a
                       pronoun or a determiner ("it", "the design", "this").
      CEO PROPOSALS    "Say go and I'll start the hire", "say the word and
                       I'll dispatch it". A clause conditioned on the CEO's
                       word is a proposal, and ending a turn on a proposal is
                       legitimate. Also: an AskUserQuestion call this turn
                       exempts the whole turn, the same term guard-idle-land
                       uses.

    After the exclusions: 2 fires, 2 genuine, 0 false. Recall is deliberately
    the price — "Frank breaks the elimination design" with no determiner is
    not caught, and that is stated here rather than discovered later.

ARM 1b — FIRST-PERSON DISPATCH  (BLOCKS — 0 fires, 0 false, guards a case the
                                  corpus does not contain)
    "I'm dispatching Frank", "I'll spawn Zach now", "Dispatching frank-opus-x1"
    — first person, present or future, a dispatch verb, and a ROLE or AGENT
    NAME as the object — in a turn with no matching Agent call. This is the
    17%-precision word family narrowed three ways: it must be first person
    (past incidents and quotations drop out), it must name who (the "names
    nobody" refinement measured at 10.3% is inverted — a dispatch that names
    nobody is not scanned), and it must not be conditioned on the CEO's word.
    All 10 raw fires in the corpus were "Say the word and I'll dispatch it";
    after the proposal exclusion, none. It ships blocking on the precedent of
    the never-dispatched-role arm: zero cost, and a positive probe in the
    suite proves it can fire.

ARM 1c — ROLE FUTURE  (REPORTS — 2 fires, 2 false, 0% precision)
    "Sage will come back with the actual count", "Sage will fold all of it in
    and I'll land it". Both were predictions about an agent already running.
    Kept as a report with the number, so nobody promotes it without
    re-measuring.

REFUSED OUTRIGHT — measured and not shipped in any form:
    "Landed / merged / pushed" with no git merge or push this turn: 12 fires,
    every one a cross-turn reference ("Landed at `13e3f00ac`" about an earlier
    turn's merge) or a noun ("Landing rule enforced per merge"). The SHA-
    bearing version of this claim is already owned by guard-unresolved-claims
    against the repository, which is the right ground truth for it.
    "Running now: X" with no tool call: 5 fires, all status about work
    dispatched in an earlier turn or the phrase "running tally". Liveness
    class again.

WHAT SATISFIES A STATED ACTION — the quiet direction everywhere
  * an Agent call this turn whose subagent_type is the role, or whose name
    starts with "<role>-"; an Agent call whose input carries neither field
    satisfies every role (a call the guard cannot read is a call, not an
    absence);
  * a SendMessage this turn to anyone but the lead — a resumed teammate is a
    dispatch, and its `to` may be an opaque agent id that cannot be joined to
    a role here, so any teammate message satisfies every role;
  * an AskUserQuestion this turn — the CEO is being asked, and the turn may
    end on his answer.

===========================================================================
ARM 2 — THE TURN THAT STOPS, stated precisely
===========================================================================
    the turn's window holds a host-written <task-notification> saying an
    Agent FINISHED (status completed), AND the turn started nothing (no Agent
    call, no backgrounded tool call), AND nothing is owed to the CEO (no
    AskUserQuestion, no hold or end-of-day in his own words), AND the reply
    carries no valid `stop-declared:` line.

EVERY ONE OF THOSE TERMS IS guard-idle-land.py's, BY IMPORT. The completion
signal is its agent_finishes() — the host's own summary shape, `<status>
completed</status>` required, a killed agent and a finished shell excluded by
the summary text itself. The hold is its hold_signal(), reading only the
operator's own prompts. The declaration is its stop_declaration(), with its
three cases, its six-word and thirty-character floors, and its code-span
strip. Nothing here re-derives a term that gate already measured, and there
is exactly one vocabulary for "this stop is legitimate" in the engine:

    stop-declared: nothing-unblocked    — everything unblocked is genuinely done
    stop-declared: ceo-owns-it          — he stopped this, or his answer IS the deliverable
    stop-declared: waiting-on-teammate  — a teammate is running and the next step needs it

What ARM 2 does NOT import is term 4, the backlog. That is the whole
difference, and it is the reason the three turns above went green.

WHY THIS DOES NOT DOUBLE-FIRE WITH guard-idle-land.sh: the sibling refuses
only when the backlog has a free row; this arm refuses only when there is no
declaration. On a turn where both hold, both refuse, the refusals name the
same three declared cases, and one line satisfies both — a declaration is a
declaration, not a token per gate.

MEASURED (same corpus, same replay, through this file — the corpus file
carries the per-turn adjudication):
    turns whose window carries an Agent-finished notice     (see corpus.md)
      started something (Agent / backgrounded)                silent, correct
      put something to the CEO / held / off duty              silent, correct
      declared                                                silent, shown
      NOTHING — report and stop                               REFUSED
    Every refusal in the corpus was read by hand and every one was a turn the
    operator had to restart by hand. The number is in the corpus file, and
    the three named turns of 2026-09-02 are among them.

===========================================================================
WHAT THIS CANNOT SEE — stated here, not discovered later
===========================================================================
  * a claim about STATE that no tool call established ("three repos clean and
    pushed", "the scheme is untouched"). Five of the day's seven instances.
    Different signature, no monotonic ground truth for most of it; a stretch
    goal, not this file.
  * an announced act whose object is a bare noun, or that sits in a list.
  * a role the entity has not defined. Roles are DERIVED from the entity's
    .claude/agents/*.md and the session roster; an empty set makes ARM 1a
    inert (recorded as such), never guessed.
  * a turn with no final text at all. There is no report to reconcile.
  * anything after the turn ends. Point-in-time, like its siblings.

===========================================================================
IT CANNOT FIRE ON ITSELF, AND IT FAILS OPEN
===========================================================================
The refusal this file prints reaches the model on stderr and is never part of
`last_assistant_message`. The offending clause is printed inside double
quotes, so a reply that pastes it back has it stripped as quoted speech, and
code spans, fenced blocks (including ```ecs``` records, which carry the
sentence as before="…" text), blockquotes and headings are stripped before
any sentence is read. A reply that explains "I wrote 'Frank breaks it first'
and did not spawn him" carries the sentence only inside quotes and only as
reported speech; both defenses stop it. The declaration line the refusal
prints is indented under a code-span strip for the same reason, exactly as
guard-idle-land.py does it.

Every error path returns 0. A Stop guard that fails closed refuses to let the
session end, and the wrapper explains why that is worse than the defect.

Exit codes:
  0  nothing stated-but-untaken and no undeclared stop after a completion;
     or exempt, not evaluable, report-only, or any error at all
  2  BLOCKED — the final message states an action this turn did not take, or
     a teammate finished this turn and the turn ends having started nothing
     and declared nothing
"""

import importlib.util
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    """A sibling analyzer, imported rather than copied: a second reader of the
    turn boundary is a second place for the session-wide-scope bug to come
    back, and a second copy of the declaration vocabulary is a fork."""
    try:
        spec = importlib.util.spec_from_file_location(
            name, os.path.join(_HERE, filename))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# --------------------------------------------------------------------------
# text preparation — everything that is not the assistant's own plain prose
# is removed BEFORE any sentence is read
# --------------------------------------------------------------------------

FENCE_RE = re.compile(r"```.*?```", re.S)
CODE_SPAN_RE = re.compile(r"`[^`\n]*`")
DQUOTE_RE = re.compile(r"[\"“][^\"”\n]{0,300}[\"”]")
SQUOTE_RE = re.compile(r"(?<![A-Za-z])['‘][^'’\n]{2,300}['’](?![A-Za-z])")
EMPH_RE = re.compile(r"[*_]{1,3}")
BLOCKQUOTE_LINE_RE = re.compile(r"^[ \t]*>")
HEADING_LINE_RE = re.compile(r"^[ \t]*#{1,6}[ \t]")
# A list marker may sit inside emphasis: "**1. Zach builds it — in flight
# now.**" is a numbered line. The replay found it because the emphasis strip
# ran AFTER the line filter, and the line was scanned as prose.
LIST_LINE_RE = re.compile(r"^[ \t]*[*_]{0,3}(?:[-*+•]|\d{1,3}[.)])[ \t]")
TABLE_LINE_RE = re.compile(r"^[ \t]*\|")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+|\n+")
# Clauses split on coordination and semicolons ONLY. A dash or a colon opens
# an appositive that modifies the clause before it ("Zach builds it — in
# flight now"), and splitting there would lose the very words that mark the
# clause as a present-state claim rather than an announcement.
CLAUSE_SPLIT_RE = re.compile(r",\s+(?:and|but|so|then|which|while)\b|;\s+")


def clean(message):
    """The assistant's own prose, line by line, with everything quoted,
    fenced, coded, listed, tabulated or headed removed."""
    text = FENCE_RE.sub(" ", message)
    kept = []
    for line in text.split("\n"):
        if (BLOCKQUOTE_LINE_RE.match(line) or HEADING_LINE_RE.match(line)
                or LIST_LINE_RE.match(line) or TABLE_LINE_RE.match(line)):
            continue
        kept.append(line)
    text = "\n".join(kept)
    text = CODE_SPAN_RE.sub(" ", text)
    text = DQUOTE_RE.sub(" ", text)
    text = SQUOTE_RE.sub(" ", text)
    text = EMPH_RE.sub("", text)
    return text


def sentences(message):
    for s in SENTENCE_SPLIT_RE.split(clean(message)):
        s = s.strip()
        if s:
            yield s


def clauses(sentence):
    for c in CLAUSE_SPLIT_RE.split(sentence):
        c = c.strip().strip(",;:")
        if c:
            yield c


# --------------------------------------------------------------------------
# the roster — derived, never typed
# --------------------------------------------------------------------------

ROLE_SHAPE = re.compile(r"[a-z][a-z0-9]{1,15}")
LEAD_ROLES = {"team-lead", "team", "rich"}


def roster_roles(entity_root, teams_dir, session_id):
    roles = set()
    d = os.path.join(entity_root or "", ".claude", "agents")
    try:
        for f in os.listdir(d):
            if f.endswith(".md") and ROLE_SHAPE.fullmatch(f[:-3]):
                roles.add(f[:-3])
    except OSError:
        pass
    if session_id and teams_dir:
        p = os.path.join(teams_dir, "session-" + session_id[:8], "config.json")
        try:
            with open(p, encoding="utf-8") as fh:
                for m in (json.load(fh).get("members") or []):
                    t = str((m or {}).get("agentType") or "")
                    if ROLE_SHAPE.fullmatch(t):
                        roles.add(t)
        except Exception:
            pass
    return roles - LEAD_ROLES


# --------------------------------------------------------------------------
# ARM 1a — ROLE ACT
# --------------------------------------------------------------------------

# Verbs of SAYING, JUDGING, RETURNING, CONTINUING, THINKING and BEING. A clause
# built on one of these reports what an agent produced or is, which is the
# liveness class and not an act the lead has to take. The set is classes with
# members, not words that happened to misfire.
REPORT_VERBS = {
    # saying / judging
    "says", "reports", "recommends", "rates", "confirms", "finds", "flags",
    "notes", "agrees", "argues", "concludes", "warns", "admits", "claims",
    "states", "writes", "answers", "asks", "tells", "explains", "describes",
    "calls", "names", "lists", "shows", "suggests", "proposes", "objects",
    "disagrees", "pushes", "backs", "corrects", "judges", "scores", "grades",
    # returning / continuing / finishing
    "comes", "returns", "delivers", "continues", "finishes", "completes",
    "hands", "lands", "goes", "gets", "arrives", "responds",
    # thinking / wanting
    "thinks", "believes", "suspects", "expects", "wants", "needs", "prefers",
    "knows", "understands", "sees", "means", "assumes", "considers", "likes",
    # being / having
    "is", "has", "owns", "keeps", "stays", "holds", "remains", "seems",
    "looks", "sounds", "feels", "exists", "lives", "sits", "stands", "does",
    "covers", "handles", "supports", "guides", "governs", "carries", "works",
}

OBJECT = (r"(?:it|this|that|them|him|her|both|everything|"
          r"the|these|those|his|its|their|my|our|your|each\s+of)\b")


def role_act_re(roles):
    """The subject is the FIRST word of the clause: a capitalized roster role.
    Not a role mentioned mid-clause ("I want Frank to break it"), which is
    intent about a person and a different sentence."""
    alt = "|".join(re.escape(r.capitalize()) for r in sorted(roles))
    return re.compile(r"^(?P<role>" + alt + r")\s+(?P<verb>[a-z]+s)\s+" + OBJECT, re.S)


def role_future_re(roles):
    alt = "|".join(re.escape(r.capitalize()) for r in sorted(roles))
    return re.compile(r"^(?P<role>" + alt + r")\s+(?:will|'ll|is\s+going\s+to)\s+(?P<verb>[a-z]+)\b", re.I)


# A clause that is conditioned, negated, reported, modal, in progress, past, or
# a question is not an announcement of an act about to be taken.
SUBORD_RE = re.compile(r"\b(once|when|whenever|after|if|unless|until|till|while|"
                       r"before|as\s+soon\s+as|assuming|provided|whether|"
                       r"in\s+case|so\s+that|because|since|the\s+moment)\b", re.I)
NEG_RE = re.compile(r"\b(not|never|no|neither|nor|nothing|nobody|without|"
                    r"isn't|doesn't|won't|can't|cannot|don't|didn't|wasn't)\b|n't\b", re.I)
REPORTED_RE = re.compile(r"\b(I\s+(?:said|told|wrote|reported|claimed|announced|promised|"
                         r"typed|narrated)|you\s+(?:said|asked|told|wrote)|"
                         r"(?:he|she|they)\s+(?:said|asked|wrote)|saying|"
                         r"instead\s+of|rather\s+than|before\s+saying)\b", re.I)
MODAL_RE = re.compile(r"\b(would|could|should|might|may|can|used\s+to)\b", re.I)
PROGRESS_RE = re.compile(r"\b(now(?!\s+that)|currently|already|still|running|"
                         r"underway|in\s+flight|in\s+progress|mid-\w+)\b", re.I)
QUESTION_RE = re.compile(r"\?\s*$")
# A proposal put to the CEO. The turn may end on it; it is his call.
PROPOSAL_RE = re.compile(r"\b(say\s+the\s+word|say\s+go|on\s+your\s+word|your\s+call|"
                         r"want\s+me\s+to|shall\s+I|should\s+I|do\s+you\s+want|"
                         r"if\s+you\s+(?:want|prefer|say|would|'d)|"
                         r"which\s+(?:do|would)\s+you|up\s+to\s+you)\b", re.I)
PAST_RE = re.compile(r"\b(yesterday|earlier|last\s+(?:night|week|session|turn)|"
                     r"this\s+morning|ago)\b", re.I)


def ends_on_ceo(message):
    """The reply's LAST sentence is a question or a proposal to the CEO."""
    last = ""
    for s in sentences(message):
        last = s
    return bool(last) and bool(QUESTION_RE.search(last) or PROPOSAL_RE.search(last))


def clause_excluded(sentence, clause, progress=True):
    """Two scopes, deliberately. A subordinator or a progress marker binds the
    clause it sits in ("Frank breaks it first, and I want him attacking
    whether ..." — the `whether` belongs to the second clause). A negation, a
    modal, a past marker, reported speech, a proposal or a question colors the
    whole sentence ("Frank breaks it, but not tonight" is a deferral, not an
    announcement), so those read the sentence."""
    if SUBORD_RE.search(clause) or (progress and PROGRESS_RE.search(clause)):
        return True
    if (NEG_RE.search(sentence) or MODAL_RE.search(sentence) or PAST_RE.search(sentence)
            or REPORTED_RE.search(sentence) or PROPOSAL_RE.search(sentence)
            or QUESTION_RE.search(sentence)):
        return True
    return False


_FUTURE_REPORT = {v[:-1] for v in REPORT_VERBS if v.endswith("s")} | {"be", "have", "come", "go", "get"}


def role_act_claims(message, roles):
    """[(who, clause, arm)] — ARM 1a (blocking) and ARM 1c (reporting)."""
    if not roles:
        return []
    act = role_act_re(roles)
    fut = role_future_re(roles)
    out = []
    for s in sentences(message):
        for c in clauses(s):
            m = act.match(c)
            if m and m.group("verb").lower() not in REPORT_VERBS:
                if not clause_excluded(s, c):
                    out.append((m.group("role").lower(), c[:200], "role-act"))
                continue
            m = fut.match(c)
            if m and m.group("verb").lower() not in _FUTURE_REPORT:
                if not clause_excluded(s, c):
                    out.append((m.group("role").lower(), c[:200], "role-future"))
    return out


# --------------------------------------------------------------------------
# ARM 1b — FIRST-PERSON DISPATCH
# --------------------------------------------------------------------------

AGENT_NAME = r"[a-z][a-z0-9]{1,15}-(?:fable|opus|sonnet|haiku)-[a-z0-9]{1,12}"
DISPATCH_VERB = r"(?:dispatch|spawn|launch|brief|re-?spawn|send\s+in|kick\s+off|start|fire\s+up|bring\s+in)"
DISPATCH_GERUND = (r"(?:dispatching|spawning|launching|briefing|re-?spawning|sending\s+in|"
                   r"kicking\s+off|starting|firing\s+up|bringing\s+in)")


def first_person_dispatch_re(roles):
    """Two shapes: "I'm dispatching Frank" / "I'll spawn frank-opus-x1", and
    the sentence-initial gerund "Dispatching Frank now". Both must NAME who —
    a dispatch that names nobody is not scanned (the "names nobody" refinement
    measured at 10.3% is inverted here on purpose)."""
    alt = "|".join(re.escape(r.capitalize()) for r in sorted(roles)) if roles else None
    who = r"(?P<name>" + AGENT_NAME + r")" + (r"|(?P<role>" + alt + r")" if alt else "")
    return re.compile(
        r"(?:\b(?:I'm|I\s+am|I'll|I\s+will)\s+(?:now\s+|just\s+|about\s+to\s+)?" + DISPATCH_VERB + r"(?:ing)?"
        r"|^(?:Now\s+)?" + DISPATCH_GERUND + r")\s+"
        r"(?:a\s+|the\s+|another\s+|a\s+fresh\s+|him\s+|her\s+)?(?:" + who + r")",
        re.I)


def dispatch_claims(message, roles):
    rx = first_person_dispatch_re(roles)
    out = []
    for s in sentences(message):
        for c in clauses(s):
            m = rx.search(c)
            if not m:
                continue
            # "now" is the natural word in "I'm dispatching Frank now" — for
            # this arm it is the point, not a liveness claim. The other
            # exclusions (conditional, negated, reported, proposal, question)
            # apply unchanged.
            if clause_excluded(s, c, progress=False):
                continue
            who = (m.group("name") or "").lower() or ((m.groupdict().get("role") or "").lower())
            if who:
                out.append((who, c[:200], "first-person-dispatch"))
    return out


# --------------------------------------------------------------------------
# the turn's own tool traffic (ARM 1) — via turn-manifest.py
# --------------------------------------------------------------------------

def turn_calls(tm, transcript, prompt_id):
    """([(id, name)], {id: input}, error). The manifest module scopes the
    turn; the inputs of Agent / SendMessage / AskUserQuestion calls are read
    here by id so a stated role can be matched to a real spawn."""
    if tm is None:
        return [], {}, "turn-manifest.py could not be loaded"
    calls, _results, _examined, err = tm.read_turn(transcript, prompt_id)
    if err:
        return [], {}, err
    wanted = {tid for tid, name in calls if name in ("Agent", "SendMessage", "AskUserQuestion")}
    inputs = {}
    if wanted:
        try:
            with open(transcript, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    content = (rec.get("message") or {}).get("content")
                    if not isinstance(content, list):
                        continue
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") in wanted:
                            inputs[b["id"]] = b.get("input") if isinstance(b.get("input"), dict) else {}
        except OSError:
            pass
    return calls, inputs, None


def satisfied(who, arm, calls, inputs):
    """Did this turn perform a dispatch that discharges `who` (a role or an
    agent name)? Quiet direction throughout: an unreadable call counts.

    ARM 1a (role-act) is discharged by ANY Agent call this turn. The sentence
    is a statement about the sequence of work, and a turn that dispatched
    something has the sequence in motion — measured: role-matching this arm
    fired on "Sage is designing that now ... Zach builds it." in the turn
    that spawned Sage, which is a plan in motion, not the defect.
    ARM 1b (first-person dispatch) names WHO is being dispatched, so only a
    call for that role or name discharges it."""
    for tid, name in calls:
        if name == "AskUserQuestion":
            return "ceo-asked"
        if name == "Agent":
            inp = inputs.get(tid)
            if arm != "first-person-dispatch" or inp is None:
                return "agent-call"
            stype = str(inp.get("subagent_type") or "").lower()
            aname = str(inp.get("name") or "").lower()
            if not stype and not aname:
                return "agent-call"
            if who == aname or stype == who or aname.startswith(who + "-"):
                return "agent-call"
        if name == "SendMessage":
            inp = inputs.get(tid) or {}
            to = str(inp.get("to") or "").lower()
            if not to or to not in ("team-lead", "main", "lead"):
                return "teammate-message"
    return None


# --------------------------------------------------------------------------
# ARM 2 — THE TURN THAT STOPS — every term is guard-idle-land.py's, by import
# --------------------------------------------------------------------------

def stop_after_completion(idle, transcript, prompt_id, message):
    """None when ARM 2 has nothing to say, else a dict:
         finishes   titles of the agents whose completion arrived this turn
         verdict    'started' | 'ceo-owed' | 'declared' | 'undeclared-stop'
         detail     what discharged it, or the declaration, or the problem
    """
    if idle is None:
        return {"finishes": [], "verdict": "unavailable",
                "detail": "guard-idle-land.py could not be loaded"}
    turn = idle.read_turn(transcript, prompt_id)
    if turn is None:
        return None
    finishes = idle.agent_finishes(turn.get("notices"))
    if not finishes:
        return None
    if "Agent" in turn["tools"]:
        return {"finishes": finishes, "verdict": "started", "detail": "Agent"}
    if turn.get("backgrounded"):
        return {"finishes": finishes, "verdict": "started", "detail": "backgrounded tool call"}
    if "AskUserQuestion" in turn["tools"]:
        return {"finishes": finishes, "verdict": "ceo-owed", "detail": "AskUserQuestion"}
    hold = idle.hold_signal(turn.get("said"))
    if hold:
        return {"finishes": finishes, "verdict": "ceo-owed", "detail": "operator said: " + hold}
    decl = idle.stop_declaration(message)
    if decl and decl.get("ok"):
        return {"finishes": finishes, "verdict": "declared", "detail": decl}
    return {"finishes": finishes, "verdict": "undeclared-stop", "detail": decl}


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if payload.get("stop_hook_active"):
        return 0

    message = payload.get("last_assistant_message") or ""
    if not message.strip():
        return 0

    entity_root = (os.environ.get("RICHOS_SA_ENTITY_ROOT") or payload.get("cwd") or os.getcwd())
    teams_dir = os.environ.get("RICHOS_SA_TEAMS_DIR") or os.path.expanduser("~/.claude/teams")
    enforce = os.environ.get("RICHOS_SA_ENFORCE", "1") != "0"
    session_id = payload.get("session_id") or ""
    prompt_id = payload.get("prompt_id")
    transcript = payload.get("transcript_path")

    roles = roster_roles(entity_root, teams_dir, session_id)
    claims = role_act_claims(message, roles) + dispatch_claims(message, roles)

    record = {
        "session": session_id,
        "prompt_id": prompt_id,
        "roles": len(roles),
        "claims": [{"who": w, "arm": a} for w, _c, a in claims],
        "unmet": [],
        "reported": [],
        "stop": None,
        "scoped": bool(prompt_id),
        "verdict": "pass",
    }

    def log():
        try:
            state = os.path.join(entity_root, ".claude", "state")
            os.makedirs(state, exist_ok=True)
            with open(os.path.join(state, "stated-actions.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
        except Exception:
            pass

    # Without a prompt_id the turn cannot be scoped. The wide answer would be
    # a FALSE one (attributing the session's calls to this turn) and the
    # narrow one would manufacture a refusal. Say nothing; record it.
    if not prompt_id:
        record["verdict"] = "unscoped"
        log()
        return 0

    # --- ARM 1 -------------------------------------------------------------
    unmet, reported = [], []
    calls = []
    if claims and ends_on_ceo(message):
        # The reply's last sentence puts something to the CEO. A plan stated
        # above a question is a proposal, and the turn may end on his answer
        # — the same term AskUserQuestion carries, read from the reply.
        # Measured: "Art reads the loro convos himself ... Want me to post
        # that prompt before it goes?" — a plan awaiting his word.
        record["arm1"] = "ceo-proposal"
        claims = []
    if claims:
        tm = _load("turn_manifest", "turn-manifest.py")
        calls, inputs, err = turn_calls(tm, transcript, prompt_id)
        if err:
            record["arm1"] = "unavailable: " + err
        else:
            for who, clause, arm in claims:
                if satisfied(who, arm, calls, inputs):
                    continue
                (reported if arm == "role-future" else unmet).append((who, clause, arm))
    record["unmet"] = [{"who": w, "arm": a} for w, _c, a in unmet]
    record["reported"] = [{"who": w, "arm": a} for w, _c, a in reported]
    record["calls"] = [n for _t, n in calls]

    # --- ARM 2 -------------------------------------------------------------
    idle = _load("guard_idle_land", "guard-idle-land.py")
    stop = stop_after_completion(idle, transcript, prompt_id, message)
    if stop is not None:
        record["stop"] = {"finishes": stop["finishes"], "verdict": stop["verdict"]}
        if stop["verdict"] == "declared":
            d = stop["detail"]
            record["stop"]["declared"] = d.get("case")
            # The wrapper shows a declared stop to the operator, always — a
            # justification filed where nobody reads it is a flag with a
            # longer spelling. Same line shape as guard-idle-land.sh reads.
            sys.stdout.write("RICHOS_STOP_DECLARED\t%s\t%s\t%s\n"
                             % (d.get("case"), d.get("why", ""), stop["finishes"][0]))

    undeclared = stop is not None and stop["verdict"] == "undeclared-stop"

    if not unmet and not undeclared:
        if reported:
            record["verdict"] = "report"
            log()
            lines = ["=== stated-action check: PASSED, with an observation (not blocking) ==="]
            for who, clause, _arm in reported:
                lines.append("  a role is said to be about to act, and this turn called no Agent for it:")
                lines.append("    \"%s\"" % clause)
            lines.append("  (this arm measured 0 true in 2 fires on the corpus -- logged, never enforced)")
            lines.append("  record: .claude/state/stated-actions.jsonl")
            sys.stderr.write("\n".join(lines) + "\n")
        else:
            log()
        return 0

    record["verdict"] = "block" if enforce else "report-only"
    log()

    tally = {}
    for _t, n in calls:
        tally[n] = tally.get(n, 0) + 1
    did = ", ".join("%s x%d" % (k, v) for k, v in tally.items()) or "nothing at all"

    out = ["=== THE REPORT DOES NOT MATCH THE TURN — TURN BLOCKED ==="]
    for who, clause, arm in unmet:
        out.append("")
        if arm == "role-act":
            out.append("  You wrote, as a plain statement of what happens:")
        else:
            out.append("  You wrote, in the first person, that you are dispatching:")
        out.append("")
        out.append("      \"%s\"" % clause)
        out.append("")
        out.append("  and this turn's tool calls contain no Agent call for %s and no message" % who)
        out.append("  to a teammate. What the turn actually called: %s." % did)
        out.append("")
        out.append("  A sentence describing an act is not the act. Seven times on 2026-09-02")
        out.append("  the report was written from the intention, and twice the CEO had to ask")
        out.append("  where the teammate was. Either")
        out.append("      make the Agent call now, in this turn, and then finish; or")
        out.append("      write what is TRUE: the dispatch has not happened, and why, or the")
        out.append("      choice it waits on, put to the CEO as a question.")
        out.append("  The sentence in the report must describe what was done.")
    if undeclared:
        out.append("")
        out.append("  A TEAMMATE FINISHED THIS TURN and the turn is ending having started nothing:")
        for t in stop["finishes"]:
            out.append("      Agent \"%s\" finished" % t)
        out.append("")
        out.append("  No Agent call, no backgrounded command, no question to the CEO, no hold")
        out.append("  in his words, and no declaration. The report IS the stopping — and six")
        out.append("  times on 2026-09-02 he had to send \"No Frank this time?\" to restart work")
        out.append("  that should never have paused. guard-idle-land let those turns through")
        out.append("  because its backlog had no free row; the next step after a returned")
        out.append("  design is not a backlog row, and that is why this arm asks YOU instead.")
        out.append("")
        out.append("  Either START the next thing now (an Agent call in this turn), or DECLARE")
        out.append("  the stop, in the reply, in this exact form:")
        out.append("")
        out.append("           stop-declared: <case> — <why, in a full sentence>")
        out.append("")
        cases = getattr(idle, "DECLARED_CASES", {}) if idle else {}
        for name in sorted(cases):
            out.append("           %-20s %s" % (name, cases[name]))
        out.append("")
        out.append("  At least %d words and %d characters of reason. A bare marker exempts"
                   % (getattr(idle, "MIN_DECLARATION_WORDS", 6), getattr(idle, "MIN_DECLARATION_CHARS", 30)))
        out.append("  nothing, and the declaration is SHOWN to the CEO, unverified, every time.")
        problem = (stop.get("detail") or {}).get("problem") if isinstance(stop.get("detail"), dict) else ""
        if problem:
            out.append("")
            out.append("  A declaration was present and REJECTED: %s" % problem)
    out.append("")
    out.append("  This gate stands down on the re-fire, so it can refuse a turn at most")
    out.append("  once. Fix the reply and finish the turn. Do not weaken or unwire this hook.")
    out.append("(hook: scripts/hooks/guard-stated-actions.sh)")
    sys.stderr.write("\n".join(out) + "\n")
    return 2 if enforce else 0


if __name__ == "__main__":
    sys.exit(main())
