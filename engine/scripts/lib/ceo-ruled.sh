#!/usr/bin/env bash
#
# scripts/lib/ceo-ruled.sh — "THE RECORD ALREADY ANSWERED THIS" AS A CHECK.
#
# ===========================================================================
# THE DEFECT THIS FILE EXISTS FOR
# ===========================================================================
# 2026-09-01. Three times in one evening the orchestrator put a question to the
# CEO that the record already answered — and every one of those answers had
# been written down by the orchestrator ITSELF, hours or days earlier:
#
#   1. What a customer installs. His standing instruction was already in
#      open-items.md row 3.14, in his own words: "automatically download and
#      install whatever the user needs." His reply: "HOW MANY TIMES DO I HAVE
#      TO DISCUSS AND ANSWER THE SAME IDENTICAL SHIT???"
#   2. Whether the logo mark is one tone or two. Already approved, §21.
#   3. The splash screens. A palette approval had been laundered into "seven
#      approved splash screens" and repeated back to him as fact.
#
# THE MECHANISM, IN ONE LINE: THE ORCHESTRATOR WRITES TO THE RECORD CONSTANTLY
# AND READS IT ALMOST NEVER. Every ruling is appended within minutes; nothing
# is ever queried. There is no step between "this looks like a decision" and
# "ask him". This library is that step.
#
# It is the SAME SURFACE as scripts/lib/ceo-asks.sh, asking the opposite
# question. That one refuses to let work start until a prepared decision has
# been PUT to him; this one refuses to put a question to him that he has
# ALREADY ANSWERED. They share a tokenizer by construction — ceo-ruled.py loads
# ceo-asks.py's `content_words` rather than carrying a second stopword list —
# and this file resolves the record's repositories through ca_resolve(), so
# there is exactly one declaration of where the CEO's record lives.
#
# ===========================================================================
# THE REFUSAL MUST BE USEFUL, NOT A WALL
# ===========================================================================
# It names the section, quotes the ruling in the CEO's own words where the
# record has them, and gives the file and line. The orchestrator then ANSWERS
# FROM THE RECORD instead of asking. A refusal that only said "already decided"
# would send him hunting through a 1,400-line register, and a gate that costs
# a hunt is a gate that gets waived.
#
# ===========================================================================
# PRECISION OVER COVERAGE — the design constraint, and it is not negotiable
# ===========================================================================
# A blocking gate with a false-positive class gets waived, and habitual waiving
# is how a defense decays into a formality. So this is the NARROW version the
# brief called for: a question is refused only when it carries a ruling's own
# TITLE, whole. Two broader anchors were built, measured against the 27 real
# AskUserQuestion calls on this machine, and deleted for firing on "days",
# "walk", "much", "anything else" and "all companies".
#
# MEASURED, NOT ASSERTED: 2 of 27 real questions fire, and one of those two is
# a question §16 now genuinely rules. ONE false positive in 27 — 3.7%. The
# corpus, the classification and the deleted anchors are in
# scripts/hooks/ceo-ruled.corpus.md.
#
# ===========================================================================
# WHERE THE RECORD IS — DECLARED, then a NAMED convention
# ===========================================================================
#   CEO_RULINGS_PATHS   in orchestration.config. Space-separated paths,
#                       absolute or relative to the governed repository. Any
#                       declared path that is missing is BROKEN, loudly — a
#                       record file that vanished must never look like a record
#                       that rules nothing.
#
#   otherwise           the convention, derived from the CEO_TODOS_REPOS
#                       declaration that already exists: <repo>/wiki/
#                       ceo-decisions.md and <repo>/wiki/open-items.md, plus
#                       the governed repository's own CLAUDE.md. Nothing is
#                       INFERRED ACROSS REPOSITORIES that ceo-asks.sh has not
#                       already had declared to it.
#
#   nothing found       NOT-DECLARED. Stand down, silently, exactly as
#                       ceo-asks.sh does — the engine loads at USER scope in
#                       every directory on this machine, and a repository with
#                       no CEO record has no protection to lose.
#
# ===========================================================================
# FAIL OPEN. ALWAYS. THIS ONE IS NOT A CLOSE CALL.
# ===========================================================================
# A gate that wedges the orchestrator's ability to ask the CEO ANYTHING is
# worse than the failure it prevents. So every plumbing failure — no python3,
# a missing predicate, an unreadable record, an unparseable payload — lets the
# ask through and SAYS SO. The only fail-closed state is the one where the
# predicate ran, read a real record, and found a ruling it can name and quote.
#
# ===========================================================================
# THE ESCAPE HATCH IS A DECLARATION, NOT A FLAG
# ===========================================================================
#     scripts/ceo-ruled-exempt.sh <session-id> "<cite>" "<why it does not cover this>"
#
# It records WHICH ruling the orchestrator believes does not cover the question
# and WHY, in <entity root>/.claude/state/ceo-ruled-exempts.log, where a
# reviewer sees it. A BARE MARKER EXEMPTS NOTHING: the reason is required and
# is length-checked, because a bare token is something a reflex types and a
# reason is something a person writes. Half the value of this gate is forcing
# the orchestrator to have actually looked at the ruling before deciding it
# does not apply — the same discipline `dialect-exempt:` uses.
#
# The exemption is PER SESSION and PER CITE. It does not accumulate into a
# permanent waiver, because the failure being engineered out is a habit.
#
# ===========================================================================
# WHAT THIS CANNOT DO — named, not implied
# ===========================================================================
#  1. IT CANNOT DECIDE WHETHER A RULING ANSWERS A QUESTION. It can only say the
#     question is about the same subject a ruling is about. The exemption is
#     there because that distinction is a human's to make.
#  2. IT CANNOT SEE A QUESTION ASKED IN PROSE at the moment it is asked. Two of
#     the three failures above were prose, not AskUserQuestion calls, and no
#     PreToolUse event exists for a sentence in a reply.
#     scripts/hooks/notice-ceo-ruled-prose.sh covers that case at the END of
#     the turn, which is late — it is the only place the event exists at all.
#  3. IT CANNOT STOP A QUESTION PHRASED IN ENTIRELY DIFFERENT WORDS from the
#     ruling's title. That is the price of never crying wolf, and it is paid
#     deliberately.
#
# ===========================================================================
# USAGE
# ===========================================================================
#     . scripts/lib/ceo-ruled.sh
#     cr_require                      || echo "$CR_BROKEN"
#     cr_resolve "<entity-root>"      # -> CR_STATUS / CR_SOURCES / CR_REASON
#     cr_exempts "<entity-root>" "<session-id>"    # -> CR_EXEMPT_CITES
#     cr_check "<question-file>"      # -> TSV on stdout
#
# Safe to source repeatedly. Never changes the caller's cwd.

if [ -n "${_CEO_RULED_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CEO_RULED_SH_SOURCED=1

_CR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The optional declaration key. Space-separated record paths.
CR_PATHS_KEY="CEO_RULINGS_PATHS"
CR_EXEMPT_LOG_NAME="ceo-ruled-exempts.log"
# A reason shorter than this is not a reason. Measured against the shortest
# HONEST reason anybody would write ("§14 rules the palette, not the mark's
# tone count") — 47 characters — and set well under it so the gate refuses
# tokens rather than brevity.
CR_MIN_REASON=20

CR_BROKEN=""
CR_STATUS=""
CR_REASON=""
CR_SOURCES=""
CR_EXEMPT_CITES=""

# ---------------------------------------------------------------------------
# cr_require — everything the predicate needs is present, or say what is not.
# ---------------------------------------------------------------------------
# rc 0 usable; rc 1 with CR_BROKEN set otherwise.
cr_require() {
    CR_BROKEN=""
    if ! command -v python3 >/dev/null 2>&1; then
        CR_BROKEN="python3 is not on PATH, so the CEO's record cannot be read"
        return 1
    fi
    if [ ! -f "$_CR_LIB_DIR/ceo-ruled.py" ]; then
        CR_BROKEN="scripts/lib/ceo-ruled.py is missing at $_CR_LIB_DIR/ceo-ruled.py — the whole predicate lives there"
        return 1
    fi
    if [ ! -f "$_CR_LIB_DIR/ceo-asks.py" ]; then
        # NOT a nicety. ceo-ruled.py takes its tokenizer from ceo-asks.py so
        # the two CEO gates can never disagree about what a question SAYS.
        CR_BROKEN="scripts/lib/ceo-asks.py is missing at $_CR_LIB_DIR/ceo-asks.py — it is this predicate's tokenizer and there is no second copy"
        return 1
    fi
    if [ ! -f "$_CR_LIB_DIR/ceo-asks.sh" ]; then
        CR_BROKEN="scripts/lib/ceo-asks.sh is missing at $_CR_LIB_DIR/ceo-asks.sh — the record's repositories are declared to it and nowhere else"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# cr_resolve <entity-root> — which files hold the rulings this seat is bound by?
# ---------------------------------------------------------------------------
# Sets CR_STATUS declared|not-declared|broken, CR_SOURCES (path<TAB>label per
# line), CR_REASON. rc 0 declared; 1 not-declared; 2 broken.
cr_resolve() {
    local root="${1:-}" spec="" p abs found=0 problems="" repo
    CR_STATUS=""; CR_REASON=""; CR_SOURCES=""

    if [ -z "$root" ] || [ ! -d "$root" ]; then
        CR_STATUS="broken"
        CR_REASON="no governed repository was resolved, so there is nowhere to look for the CEO's record"
        return 2
    fi

    # Sourced in a SUBSHELL so an adopter's config cannot clobber this
    # library's variables — the same care ceo-asks.sh takes.
    if [ -f "$root/orchestration.config" ]; then
        spec="$(
            # shellcheck disable=SC1091
            . "$root/orchestration.config" >/dev/null 2>&1 || true
            eval "printf '%s' \"\${$CR_PATHS_KEY:-}\""
        )"
    fi

    if [ -n "$spec" ]; then
        # DECLARED. Every named path must exist; a missing one is BROKEN, not
        # skipped, because a record file that vanished must never be able to
        # look like a record that rules nothing.
        for p in $spec; do
            case "$p" in
                "~"|"~/"*) p="$HOME${p#\~}" ;;
            esac
            case "$p" in
                /*) abs="$p" ;;
                *)  abs="$root/$p" ;;
            esac
            if [ ! -f "$abs" ]; then
                problems="$problems; declared record '$p' is not on this machine (looked at $abs)"
                continue
            fi
            CR_SOURCES="$CR_SOURCES$abs	$(basename "$abs")
"
            found=$((found + 1))
        done
        if [ -n "$problems" ]; then
            CR_STATUS="broken"
            CR_REASON="${problems#; }"
            return 2
        fi
        CR_STATUS="declared"
        return 0
    fi

    # THE CONVENTION. Derived from the CEO_TODOS_REPOS declaration that already
    # exists rather than from a guess: whatever repositories hold his TODOs
    # hold his rulings. Nothing new is inferred across repositories.
    # shellcheck source=ceo-asks.sh
    . "$_CR_LIB_DIR/ceo-asks.sh"
    local rc=0
    ca_resolve "$root" || rc=$?
    if [ "$rc" -eq 2 ]; then
        CR_STATUS="broken"
        CR_REASON="the CEO's repositories are declared and unreadable — ${CA_REASON}"
        return 2
    fi
    if [ "$rc" -eq 0 ]; then
        while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            for p in wiki/ceo-decisions.md wiki/open-items.md; do
                if [ -f "$repo/$p" ]; then
                    CR_SOURCES="$CR_SOURCES$repo/$p	$(basename "$p")
"
                    found=$((found + 1))
                fi
            done
        done <<CR_REPOS_EOF
$CA_REPOS
CR_REPOS_EOF
    fi
    if [ -f "$root/CLAUDE.md" ]; then
        CR_SOURCES="${CR_SOURCES}$root/CLAUDE.md	CLAUDE.md
"
        found=$((found + 1))
    fi

    if [ "$found" -eq 0 ]; then
        CR_STATUS="not-declared"
        CR_REASON="no $CR_PATHS_KEY in $root/orchestration.config, no wiki/ceo-decisions.md in any declared CEO repository, and no CLAUDE.md at $root — this repository carries no CEO record"
        return 1
    fi
    CR_STATUS="declared"
    return 0
}

# ---------------------------------------------------------------------------
# cr_exempts <entity-root> <session-id> — cites declared not to cover, today.
# ---------------------------------------------------------------------------
# Sets CR_EXEMPT_CITES, one per line. Always rc 0: an unreadable ledger means
# NO exemptions, which fails toward refusing rather than toward permitting, and
# that is the one place in this file where the safe direction is closed.
cr_exempts() {
    local root="${1:-}" sid="${2:-}" log
    CR_EXEMPT_CITES=""
    [ -n "$root" ] && [ -n "$sid" ] || return 0
    log="$root/.claude/state/$CR_EXEMPT_LOG_NAME"
    [ -f "$log" ] || return 0
    CR_EXEMPT_CITES="$(awk -F'\t' -v s="session=$sid" '
        {
            ok = 0
            for (i = 1; i <= NF; i++) if ($i == s) ok = 1
            if (!ok) next
            for (i = 1; i <= NF; i++) if (index($i, "cite=") == 1) print substr($i, 6)
        }' "$log" 2>/dev/null | LC_ALL=C sort -u || true)"
    return 0
}

# ---------------------------------------------------------------------------
# cr_check <question-file> — the verdict, as TSV on stdout.
# ---------------------------------------------------------------------------
# Requires cr_resolve to have succeeded. Reads CR_EXEMPT_CITES if set.
# rc 0 with a verdict; rc 2 with CR_BROKEN set if the predicate could not run.
cr_check() {
    local qfile="${1:-}" job rc=0
    CR_BROKEN=""
    [ -f "$qfile" ] || { CR_BROKEN="cr_check: no question file at '$qfile'"; return 2; }

    job="$(mktemp -t ceo-ruled-job.XXXXXX.json)" || {
        CR_BROKEN="cr_check: could not create a job file"; return 2; }

    if ! CR_Q="$qfile" CR_SRC="$CR_SOURCES" CR_EX="$CR_EXEMPT_CITES" \
        python3 -c '
import json, os, sys
sources = []
for line in (os.environ.get("CR_SRC") or "").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    sources.append({"path": parts[0], "label": parts[1] if len(parts) > 1 else ""})
job = {
    "mode": "check",
    "question": open(os.environ["CR_Q"], encoding="utf-8", errors="replace").read(),
    "sources": sources,
    "exempt": [c for c in (os.environ.get("CR_EX") or "").splitlines() if c.strip()],
}
sys.stdout.write(json.dumps(job))
' >"$job" 2>/dev/null; then
        rm -f "$job"
        CR_BROKEN="cr_check: the job could not be assembled"
        return 2
    fi

    python3 "$_CR_LIB_DIR/ceo-ruled.py" "$job" || rc=$?
    rm -f "$job"
    if [ "$rc" -ne 0 ]; then
        CR_BROKEN="cr_check: scripts/lib/ceo-ruled.py exited $rc"
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# cr_questions_of <payload> — every question in an AskUserQuestion call.
# ---------------------------------------------------------------------------
# One line per question: <index><TAB><everything the CEO would see, newlines as
# \001>. The shape was MEASURED from a real call recovered from a session
# transcript on this machine, and the fallback under it is not decoration: if
# the tool renames `questions`, a gate that quietly checked nothing would
# rebuild the defect it exists to prevent.
cr_questions_of() {
    CR_PAYLOAD="${1:-}" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("CR_PAYLOAD") or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

def flatten(q):
    parts = []
    if isinstance(q, dict):
        for key in ("header", "question"):
            v = q.get(key)
            if isinstance(v, str):
                parts.append(v)
        for opt in (q.get("options") or []):
            if isinstance(opt, dict):
                for key in ("label", "description"):
                    v = opt.get(key)
                    if isinstance(v, str):
                        parts.append(v)
            elif isinstance(opt, str):
                parts.append(opt)
    elif isinstance(q, str):
        parts.append(q)
    return "\n".join(p for p in parts if p)

questions = ti.get("questions")
if isinstance(questions, list) and questions:
    texts = [flatten(q) for q in questions]
else:
    texts = ["\n".join(v for v in ti.values() if isinstance(v, str))]

for i, t in enumerate(texts):
    if not t.strip():
        continue
    sys.stdout.write("%d\t%s\n" % (i, t.replace("\t", " ").replace("\n", "\x01")))
' 2>/dev/null || true
}
