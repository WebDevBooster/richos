#!/usr/bin/env bash
#
# scripts/lib/premise-ask.sh — "WHY IS THIS WORTH HIS TIME?" AS A STEP.
#
# ===========================================================================
# THE DEFECT THIS FILE EXISTS FOR
# ===========================================================================
# 2026-09-10. Two questions went to the CEO that could not affect him.
#
#   1. A capability a feasibility gate marked BLOCKED — which turned out to be
#      a safety net for the orchestrator's own misjudgment rather than part of
#      the job. He was asked what to promise about it.
#   2. A capability the same gate marked UNKNOWN, about work surviving him
#      QUITTING MID-FLIGHT. It was described to him as "the capability the
#      whole thing rests on", and a design constraint was briefed from it.
#
# He asked, about the second, when he had ever quit mid-work and how many
# times. NOBODY HAD LOOKED. The measurement, run afterwards:
#
#     grep -oE 'session[_ ]gone' ~/.claude/state/worktree-reconciler.log   -> 0
#     grep -ciE 'dead pid|locked by dead' <same file>                      -> 0
#
# Zero, across that log's entire history, against 47 femcboost session
# transcripts. The scenario had been constructed by a probe in a disposable
# environment, and nothing said the CEO produces it. His words, at the end of
# the day: "When will I stop being bothered by ... this nature?"
#
# THE MECHANISM: a fact was true (a probe reproduced a failure path), and the
# step between "this is true" and "therefore he must decide it" was never
# taken. This library is that step. It cannot take it FOR anybody — see the
# next section, which is the honest half of this file.
#
# ===========================================================================
# WHAT WAS MEASURED, AND WHY THIS IS A CHECK RATHER THAN A REFUSAL
# ===========================================================================
# The obvious build is a blocking gate: refuse a question whose premise is
# missing or unmeasured. It was measured before it was built, against every
# AskUserQuestion ever asked on this machine — 72 calls, 85 questions,
# 2026-07-27 to 2026-09-10, extracted from 2,492 transcripts. THE CORPUS SAID
# NO, and it said it clearly:
#
#   predicate                                      fires   catches the 2 targets
#   no declarative premise anywhere                10/85    NEITHER
#   no evidence token anywhere                     32/85    NEITHER
#   hypothetical framing without evidence          21/85    1 of 2 (the second
#                                                             ask, not the first)
#   occurrence claim without observation evidence  11/85    NEITHER — both
#                                                             targets carry
#                                                             observation words
#                                                             and pass
#
# Every one of those "fires" columns is real business decisions: the license,
# the wordmark font, the ACP adapter, worker trust, his own machine.
#
# The two questions that MUST be refused sit in the top decile for premise
# richness: four and six declarative sentences, a pinned host version, a
# measured six-second latency, four reproduced failure paths. Textually they
# are BETTER than the average genuine business decision. What was wrong with
# them is not in the text at all — it is that the premise, though true, could
# not change anything for him.
#
# THIS PROJECT HAS KILLED THREE BLOCKING GUARDS BY SHIPPING THEM BROADER THAN
# THEIR EVIDENCE (g11/g12/g13, all in one day). A gate that refused 11 of 85
# real questions to catch neither target would be the fourth. So:
#
#   * NOTHING HERE IS EVER PERMANENTLY REFUSED. The gate interrupts a question
#     AT MOST ONCE PER EPISODE (default 15 minutes per session), prints what
#     the question does and does not carry, and asks the one question the
#     corpus proves a machine cannot answer: does this change anything for HIM.
#     Re-issuing — changed or unchanged — passes.
#   * THE COST IS BOUNDED AND SMALL. 72 calls in six weeks, about one a day.
#     One extra round trip on a once-a-day event is not a false-positive class;
#     it is a speed bump on the rarest tool in the system.
#   * IT IS MEASURABLE BY CONSTRUCTION. Every question is written to a ledger
#     with its findings and whether it was re-issued CHANGED or UNCHANGED. If
#     re-issuing becomes a reflex, the ledger will say so in numbers, and the
#     next person can argue from them instead of from instinct.
#
# The whole measurement, every predicate cut, and the reproduction command:
# scripts/hooks/premise-ask.corpus.md.
#
# ===========================================================================
# THE ESCAPE HATCH IS THE RULE ITSELF
# ===========================================================================
#     premise-unverified: <what is unknown and what would settle it>
#
# On its own line in the question text. The check then does not fire at all —
# no round trip — and the declaration is logged. This is deliberate: the rule
# being enforced is "state the premise, or mark it unverified", so the marked
# form is not an evasion of the rule, it IS the rule. A BARE MARKER EXEMPTS
# NOTHING; the reason is length-checked.
#
# ===========================================================================
# SCOPE, AND WHERE THIS STANDS DOWN
# ===========================================================================
#   * A WORKER'S QUESTION is never checked. A teammate asking its own
#     clarifying question is not the orchestrator putting a decision to the
#     CEO — the same line notice-ceo-asks.sh and guard-ceo-ruled-ask.sh draw.
#   * A REPOSITORY THAT DECLARES NO CEO RECORD is never checked. The engine
#     loads at user scope in every directory on this machine; a repository
#     with no CEO has no CEO's attention to protect.
#   * EVERY PLUMBING FAILURE PASSES THE QUESTION THROUGH. A gate that can wedge
#     the orchestrator's ability to ask the CEO anything is worse than the
#     failure it prevents.
#
# ===========================================================================
# WHAT THIS CANNOT DO — named here, not discovered in a postmortem
# ===========================================================================
#  1. IT CANNOT TELL WHETHER A PREMISE MATTERS TO HIM. That is the whole
#     finding of the corpus and the reason this is a check. It can only put
#     the question in front of the person who can.
#  2. IT CANNOT SEE A QUESTION ASKED IN PROSE. The second failure of
#     2026-09-10 was never an AskUserQuestion call — it was a sentence in a
#     reply ("that one came back unknown across a live exit"), and no
#     PreToolUse event exists for a sentence. Stated rather than papered over:
#     this gate would have interrupted the FIRST failure and not the second.
#  3. IT CANNOT STOP A SECOND ASK INSIDE THE STAND-DOWN WINDOW. That is the
#     price of never trapping a revision, and it is paid deliberately: the
#     alternative refuses the improved question for being improved.
#
# ===========================================================================
# USAGE
# ===========================================================================
#     . scripts/lib/premise-ask.sh
#     pa_require                     || echo "$PA_BROKEN"
#     pa_governed "<entity-root>"    # rc 0 governed, 1 no CEO record, 2 broken
#     pa_check "<question-file>"     # -> TSV on stdout (MARKER/FINDING/VERDICT)
#     pa_standdown_active "<root>" "<session>"   # rc 0 if a check already fired
#     pa_standdown_arm    "<root>" "<session>"
#     pa_record "<root>" "<session>" "<state>" "<header>" "<codes>" "<text>"
#
# Safe to source repeatedly. Never changes the caller's cwd.

if [ -n "${_PREMISE_ASK_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_PREMISE_ASK_SH_SOURCED=1

_PA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PA_LEDGER_NAME="premise-ask-ledger.jsonl"
PA_STANDDOWN_NAME="premise-ask-standdown"
# ONE CHECK PER EPISODE. 30 minutes, and the number was measured rather than
# picked. Every real orchestrator AskUserQuestion call on this machine (72 of
# them, 46 days) was replayed against five windows:
#
#   window   checks   stood down   busiest day   interrupts 2026-09-10 07:41
#     300s      65            7            15            yes
#     900s      60           12            15            yes
#    1800s      51           21            10            yes   <- shipped
#    3600s      47           25             8            yes
#    7200s      39           33             5            NO
#
# The lower bound is comfort and the UPPER BOUND IS MEASURED: at two hours the
# 07:41 question collapses behind an unrelated one asked 74 minutes earlier and
# the check that had to fire does not. 1800 halves the worst day (15 -> 10),
# still fires on the question that had to be interrupted, and still collapses
# the 07:54 re-ask 13 minutes later — which is the same decision asked again,
# and interrupting a revision is how a check becomes a wall.
: "${PA_STANDDOWN_SECONDS:=1800}"

PA_BROKEN=""
PA_REASON=""

# ---------------------------------------------------------------------------
# pa_require — everything the predicate needs, or say what is missing.
# ---------------------------------------------------------------------------
pa_require() {
    PA_BROKEN=""
    if ! command -v python3 >/dev/null 2>&1; then
        PA_BROKEN="python3 is not on PATH, so a question cannot be read at all"
        return 1
    fi
    if [ ! -f "$_PA_LIB_DIR/premise-ask.py" ]; then
        PA_BROKEN="scripts/lib/premise-ask.py is missing at $_PA_LIB_DIR/premise-ask.py — the whole predicate lives there"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# pa_governed <entity-root> — is there a CEO here whose attention this protects?
# ---------------------------------------------------------------------------
# Takes the answer from the CEO-TODOs declaration that already exists rather
# than inventing a second one. rc 0 governed; 1 no CEO record; 2 broken.
pa_governed() {
    local root="${1:-}" rc=0
    PA_REASON=""
    [ -n "$root" ] && [ -d "$root" ] || {
        PA_REASON="no governed repository was resolved"
        return 2
    }
    if [ ! -f "$_PA_LIB_DIR/ceo-asks.sh" ]; then
        PA_REASON="scripts/lib/ceo-asks.sh is missing, and it is the only declaration of where the CEO's record lives"
        return 2
    fi
    # shellcheck source=ceo-asks.sh
    . "$_PA_LIB_DIR/ceo-asks.sh"
    ca_resolve "$root" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) PA_REASON="${CA_REASON:-this repository declares no CEO record}"; return 1 ;;
        *) PA_REASON="${CA_REASON:-the CEO record declaration could not be read}"; return 2 ;;
    esac
}

# ---------------------------------------------------------------------------
# pa_questions_of <payload> — every question in an AskUserQuestion call.
# ---------------------------------------------------------------------------
# ONE DECLARATION OF THE PAYLOAD'S SHAPE, and it is not this file's: it is
# ceo-ruled.sh's cr_questions_of, which was measured against a real call
# recovered from a transcript on this machine. A second copy here would be a
# second thing to keep true. Emits <index><TAB><question field><TAB><whole>,
# newlines as \001.
pa_questions_of() {
    python3 3<<< "${1:-}" -c '
import json, os, sys
try:
    d = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

def qfield(q):
    parts = []
    if isinstance(q, dict):
        for key in ("header", "question"):
            v = q.get(key)
            if isinstance(v, str):
                parts.append(v)
    elif isinstance(q, str):
        parts.append(q)
    return "\n".join(p for p in parts if p)

def options(q):
    parts = []
    if isinstance(q, dict):
        for opt in (q.get("options") or []):
            if isinstance(opt, dict):
                for key in ("label", "description"):
                    v = opt.get(key)
                    if isinstance(v, str):
                        parts.append(v)
            elif isinstance(opt, str):
                parts.append(opt)
    return "\n".join(p for p in parts if p)

questions = ti.get("questions")
if isinstance(questions, list) and questions:
    pairs = [(qfield(q), options(q)) for q in questions]
else:
    # The tool renamed its field. A gate that quietly checked nothing here
    # would rebuild the defect it exists to prevent, so everything textual in
    # the payload becomes the question.
    flat = "\n".join(v for v in ti.values() if isinstance(v, str))
    pairs = [(flat, "")]

def enc(s):
    return s.replace("\t", " ").replace("\n", "\x01")

for i, (q, o) in enumerate(pairs):
    whole = (q + "\n" + o).strip()
    if not whole:
        continue
    sys.stdout.write("%d\t%s\t%s\n" % (i, enc(q), enc(whole)))
' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# pa_check <question-file> <whole-file> — the findings, as TSV on stdout.
# ---------------------------------------------------------------------------
# rc 0 with a verdict; rc 2 with PA_BROKEN set if the predicate could not run.
pa_check() {
    local qfile="${1:-}" wfile="${2:-}" job rc=0
    PA_BROKEN=""
    [ -f "$qfile" ] || { PA_BROKEN="pa_check: no question file at '$qfile'"; return 2; }
    [ -f "$wfile" ] || wfile="$qfile"

    job="$(mktemp -t premise-ask-job.XXXXXX.json)" || {
        PA_BROKEN="pa_check: could not create a job file"; return 2; }

    if ! PA_Q="$qfile" PA_W="$wfile" python3 -c '
import json, os, sys
job = {
    "question": open(os.environ["PA_Q"], encoding="utf-8", errors="replace").read(),
    "whole":    open(os.environ["PA_W"], encoding="utf-8", errors="replace").read(),
}
sys.stdout.write(json.dumps(job))
' >"$job" 2>/dev/null; then
        rm -f "$job"
        PA_BROKEN="pa_check: the job could not be assembled"
        return 2
    fi

    python3 "$_PA_LIB_DIR/premise-ask.py" check <"$job" || rc=$?
    rm -f "$job"
    if [ "$rc" -ne 0 ]; then
        PA_BROKEN="pa_check: scripts/lib/premise-ask.py exited $rc"
        return 2
    fi
    return 0
}

_pa_state_dir() {
    printf '%s/.claude/state' "${1:-}"
}

# ---------------------------------------------------------------------------
# pa_standdown_active <root> <session> — has a check already fired this episode?
# ---------------------------------------------------------------------------
# rc 0 active (stand down, let the question through), 1 not active.
# An unreadable or absent marker means NOT active, which fails toward asking
# the orchestrator one question rather than toward silence.
pa_standdown_active() {
    local root="${1:-}" sid="${2:-}" f then now
    [ -n "$root" ] && [ -n "$sid" ] || return 1
    f="$(_pa_state_dir "$root")/$PA_STANDDOWN_NAME.${sid}"
    [ -f "$f" ] || return 1
    then="$(head -n1 "$f" 2>/dev/null || true)"
    case "$then" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now="$(date +%s 2>/dev/null || echo 0)"
    [ "$now" -ge "$then" ] || return 1
    [ "$((now - then))" -lt "$PA_STANDDOWN_SECONDS" ] || return 1
    return 0
}

pa_standdown_arm() {
    local root="${1:-}" sid="${2:-}" dir
    [ -n "$root" ] && [ -n "$sid" ] || return 0
    dir="$(_pa_state_dir "$root")"
    mkdir -p "$dir" 2>/dev/null || return 0
    date +%s >"$dir/$PA_STANDDOWN_NAME.${sid}" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# pa_record <root> <session> <state> <header> <codes> <question-text>
# ---------------------------------------------------------------------------
# THE LEDGER IS THE POINT, not a byproduct: it is the only thing that can tell
# a later reader whether this check changed any question or merely delayed
# them. `state` is CHECKED | STOOD-DOWN | DECLARED | UNGATED. The question's
# text is hashed rather than stored — this record must be safe to read, and a
# question to the CEO can carry anything.
pa_record() {
    local root="${1:-}" sid="${2:-}" state="${3:-}" header="${4:-}" codes="${5:-}" text="${6:-}"
    local dir hash prev="" changed="-"
    [ -n "$root" ] || return 0
    dir="$(_pa_state_dir "$root")"
    mkdir -p "$dir" 2>/dev/null || return 0
    hash="$(printf '%s' "$text" | shasum -a 256 2>/dev/null | cut -c1-16 || true)"
    [ -n "$hash" ] || hash="$(printf '%s' "$text" | cksum 2>/dev/null | cut -d' ' -f1 || echo '-')"
    if [ "$state" = "STOOD-DOWN" ] && [ -f "$dir/$PA_LEDGER_NAME" ]; then
        prev="$(grep '"state":"CHECKED"' "$dir/$PA_LEDGER_NAME" 2>/dev/null | tail -n1 || true)"
        if [ -n "$prev" ]; then
            case "$prev" in
                *"\"hash\":\"$hash\""*) changed="UNCHANGED" ;;
                *)                      changed="CHANGED" ;;
            esac
        fi
    fi
    PA_R_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')" \
    PA_R_SID="$sid" PA_R_STATE="$state" PA_R_HEADER="$header" \
    PA_R_CODES="$codes" PA_R_HASH="$hash" PA_R_CHANGED="$changed" \
    python3 -c '
import json, os, sys
rec = {
    "ts":      os.environ.get("PA_R_TS", ""),
    "session": os.environ.get("PA_R_SID", ""),
    "state":   os.environ.get("PA_R_STATE", ""),
    "header":  os.environ.get("PA_R_HEADER", "")[:120],
    "codes":   [c for c in (os.environ.get("PA_R_CODES") or "").split(",") if c],
    "hash":    os.environ.get("PA_R_HASH", ""),
    "reissue": os.environ.get("PA_R_CHANGED", "-"),
}
# COMPACT, and that is load-bearing rather than tidy: the re-issue comparison
# above greps this file for `"state":"CHECKED"` and for a hash, so a separator
# change here silently turns every re-issue into "-" and the one number this
# ledger exists to produce stops being produced.
sys.stdout.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")
' >>"$dir/$PA_LEDGER_NAME" 2>/dev/null || true
    return 0
}
