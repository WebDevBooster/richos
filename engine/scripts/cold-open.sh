#!/usr/bin/env bash
#
# cold-open.sh — ASK SOMEONE WHO DOES NOT KNOW.
#
# ===========================================================================
# THE DEFECT THIS EXISTS FOR
# ===========================================================================
# A CEO-facing surface was built, gated, tested and landed, and the person it
# was for could not find it. The record was correct. The lint was green. The
# guard fired. The report — "the contract is live, 9 prepared items" — was true
# of the file and false of his experience, and his reply was one sentence:
# "Why am I not IMMEDIATELY seeing my queue in the repo?"
#
# The cause generalises, and that is why this file exists rather than a fix to
# that one page. EVERY ACCEPTANCE CRITERION IN THAT LANDING WAS INTERNAL: lint
# exit codes, guard tests, probe layers, git state. Each one was checked by the
# person who had just written the thing being checked, using knowledge only he
# had. Nobody opened the repository the way its reader would and asked "where
# would I click?" — because that question has no exit code, so it was in nobody's
# definition of done.
#
# A view has no test that fails. So it fell out of scope silently, and the half
# that COULD be verified got reported as the whole.
#
# ===========================================================================
# THE PROPERTY THAT MATTERS
# ===========================================================================
# THE CHECK MUST BE PERFORMED BY SOMETHING THAT GENUINELY LACKS THE BUILDER'S
# KNOWLEDGE, AND ITS OUTPUT MUST BE A TRANSCRIPT — evidence of what a naive
# reader concluded — NOT A BOOLEAN.
#
# A boolean would be the same mistake one level up: it would compress the one
# output that carries information (what confused him) into the one that does
# not (pass/fail), and it would immediately be optimised for.
#
# ===========================================================================
# WHERE THIS CAN HONESTLY LIVE — and where it CANNOT
# ===========================================================================
# Four homes were considered. Three are dishonest and are written down here so
# nobody has to re-derive that.
#
#   IN THE COMMIT GUARD — NO. A hook cannot spawn a reader: it is a subprocess
#   of a tool call, it must answer in milliseconds, and a model call is slow,
#   non-deterministic and needs the network. A guard that sometimes cannot run
#   is a guard people disable.
#
#   IN run-all-tests.sh — NO, for the same reasons plus one worse: the suite is
#   the engine's hermetic self-check. Making it depend on a network round-trip
#   and a non-deterministic answer would mean a red suite no longer implies a
#   defect, and a suite you learn to re-run until it goes green is not a suite.
#   (What IS in the suite: scripts/cold-open.test.sh, which drives this harness
#   with a STUB reader and asserts every mechanical part of it.)
#
#   AS A CHECKLIST ITEM IN A RUNBOOK — NO. A rule enforced by somebody's
#   attention lasts exactly as long as their attention. That failure mode
#   occurred nine times in the session this was built in, twice inside the very
#   mechanism this extends.
#
#   AS AN ON-DEMAND HARNESS WHOSE ARTIFACT IS GATED — YES, and this is it.
#   The reading is a command a person or an agent runs. Its product is a
#   committed transcript stamped with the FINGERPRINT OF THE FRONT DOOR IT
#   DESCRIBES. The commit guard never runs a reader; it asks one cheap,
#   deterministic, offline question: does a transcript exist for the front door
#   as it stands RIGHT NOW? Change the front door and the next commit is
#   refused until somebody cold-reads the new one.
#
#   That is the freshness contract — identity or refuse — applied to a
#   judgment instead of to a build artifact. It needs nobody's memory, it
#   cannot pass by looking fresh, and the slow non-deterministic part happens
#   where slowness and non-determinism are fine.
#
# ===========================================================================
# THE LINE THE MACHINE DOES NOT CROSS
# ===========================================================================
# THE GATE ENFORCES THAT A COLD READER WAS CONSULTED. IT NEVER ENFORCES WHAT
# THE COLD READER SAID.
#
# If a favorable transcript were required, the finding — the entire product —
# would be the one output that costs its author a blocked commit, and within a
# week every transcript would say the page was lovely. So a transcript that
# reports the surface is incomprehensible satisfies the gate exactly as well as
# one that reports it is clear. The difference is for a human to read.
#
# ===========================================================================
# WHAT THIS CANNOT DO, SAID HERE RATHER THAN DISCOVERED LATER
# ===========================================================================
#   * It cannot verify the reader was actually cold. The transcript records WHO
#     read it. Nothing can check that claim. What it CAN do — and does — is
#     refuse a transcript that describes a front door which no longer exists,
#     which is the failure that actually happens.
#   * It cannot tell a lazy reading from a careful one. It refuses an empty
#     one, and that is the whole of its opinion on quality.
#   * The default reader is a language model. It is not the CEO. It stands in
#     for "someone with no context", which is the property being tested, and it
#     is wrong about anything requiring taste. --record exists so a HUMAN cold
#     reading counts identically, and is the better instrument when one is
#     available.
#   * It says nothing about a surface nobody declared. A repository with no
#     COLD_OPEN_DIR is never blocked — and every verdict prints that it was
#     never read, so "clean" cannot quietly come to mean "checked".
#   * Rot without a diff. If the front door does not change, a transcript from
#     a year ago still satisfies the gate. Age was deliberately NOT made a
#     trigger: a rule that fires on a calendar is a rule that gets switched off.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scripts/cold-open.sh --brief  [repo]   print the verbatim prompt and the
#                                          fingerprints; run nothing
#   scripts/cold-open.sh --run    [repo]   run a fresh reader, file a transcript
#   scripts/cold-open.sh --record [repo] --from <file> --reader "<who>"
#                                          file a reading done by a human or by
#                                          some other tool
#   scripts/cold-open.sh --check  [repo]   is a current transcript on file?
#
#   --reader-cmd "<cmd>"  the reader. Gets the prompt on STDIN, runs with the
#                         repository as its working directory, prints its answer
#                         on stdout. Default: a fresh, customisation-free Claude
#                         Code process. Any program honouring that contract works
#                         — this is a seam, not a vendor lock.
#   --model <alias>       model for the default reader (default: sonnet)
#   --run-by "<who>"      recorded in the transcript (default: $USER)
#
# EXIT CODES
#   0  done (--check: a current transcript is on file)
#   1  --check only: no transcript for the front door as it stands
#   2  cannot run: no declaration, no COLD_OPEN_DIR, a stale view, a broken
#      harness, or the reader failed
#   3  the declared record is not on disk

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/ceo-todos.sh"
RENDER="$SCRIPT_DIR/ceo-todos-render.sh"

MODE=""
TARGET=""
FROM=""
READER=""
READER_CMD="${COLD_OPEN_READER_CMD:-}"
MODEL="${COLD_OPEN_MODEL:-sonnet}"
RUN_BY="${USER:-unknown}"

die() { echo "ERROR: cold-open.sh: $1" >&2; exit "${2:-2}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --brief|--run|--record|--check)
            [ -z "$MODE" ] || die "one mode only (--brief, --run, --record, --check)"
            MODE="${1#--}" ;;
        --from)       shift; FROM="${1:-}" ;;
        --reader)     shift; READER="${1:-}" ;;
        --reader-cmd) shift; READER_CMD="${1:-}" ;;
        --model)      shift; MODEL="${1:-}" ;;
        --run-by)     shift; RUN_BY="${1:-}" ;;
        -h|--help)
            sed -n '108,140p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) die "unrecognised argument '$1'" ;;
        *)
            [ -z "$TARGET" ] || die "one target only"
            TARGET="$1" ;;
    esac
    shift
done
[ -n "$MODE" ] || die "no mode given. One of --brief, --run, --record, --check."
[ -n "$TARGET" ] || TARGET="$PWD"

[ -f "$LIB" ] || die "scripts/lib/ceo-todos.sh is missing at $LIB — the fingerprint and the parse both live there and this script will not guess."
# shellcheck source=lib/ceo-todos.sh
. "$LIB"

PROMPT_FILE="$(ct_prompt_file)"
[ -f "$PROMPT_FILE" ] || die "the verbatim prompt is missing at $PROMPT_FILE. Without it there is no fixed question, and a cold open with an improvised question is not reproducible."

REPO="$(ct_repo_root "$TARGET" 2>/dev/null || true)"
[ -n "$REPO" ] || die "'$TARGET' is not inside a git repository."

DECL_RC=0
ct_load_declaration "$REPO" || DECL_RC=$?
case "$DECL_RC" in
    0) ;;
    1) die "$REPO carries no $CEO_TODOS_DECLARATION, so it declares no CEO TODOs and there is no surface to cold-read. Start one: scripts/ceo-todos-init.sh $REPO" ;;
    *) ct_broken_banner "cold-open.sh" "$CT_BROKEN_REASON" >&2; exit 2 ;;
esac

[ -n "$CT_COLD_OPEN_DIR" ] || die "$CEO_TODOS_DECLARATION declares no COLD_OPEN_DIR, so there is nowhere to file a transcript and nothing gates one. Add COLD_OPEN_DIR=\"docs/cold-open\"."

RECORD="$REPO/$CT_TODO_RECORD"
[ -f "$RECORD" ] || die "the declared record is not on disk: $RECORD" 3

ct_resolve_roots "$REPO"

# --- The fingerprint, from the SAME code path the gate uses -----------------
# Never computed a second way here. The harness stamps exactly what the guard
# will later demand, so the two cannot drift into disagreeing about what
# "current" means — which is how every duplicated-fact defect in this engine
# started.
VERDICT="$(ct_lint_file "$CT_TODO_RECORD" "$RECORD" "$REPO")" \
    || die "the CEO-TODOs predicate could not run — refusing rather than stamping a fingerprint nobody computed."
FP="$(ct_verdict_fp "$VERDICT")"
[ -n "$FP" ] || die "the predicate returned no front-door fingerprint. Refusing to invent one."
PROMPT_FP="$(ct_sha256 "$PROMPT_FILE")"

COLD_DIR="$REPO/$CT_COLD_OPEN_DIR"
TRANSCRIPT="$COLD_DIR/$(date +%Y-%m-%d)-${FP:0:12}.md"

# A SECOND READING OF THE SAME FRONT DOOR ON THE SAME DAY IS NOT A MISTAKE, AND
# IT MUST NOT DESTROY THE FIRST. Date plus fingerprint collides exactly when a
# repository is being worked on hard: two landings in one day that both leave
# the CEO page's shape alone, each correctly running a reading. Observed on
# 2026-08-30, where a second run silently overwrote a transcript filed hours
# earlier — and the FINDING is the entire product of this exercise, so losing
# one is worse than never having run it. The suffix is added only on collision,
# so the ordinary name is unchanged and every transcript already on file keeps
# its own.
if [ "$MODE" != "check" ] && [ -e "$TRANSCRIPT" ]; then
    _CO_N=2
    while [ -e "$COLD_DIR/$(date +%Y-%m-%d)-${FP:0:12}-$_CO_N.md" ]; do
        _CO_N=$((_CO_N + 1))
        [ "$_CO_N" -le 99 ] || die "99 readings of the same front door on one day — refusing to guess a hundredth name."
    done
    TRANSCRIPT="$COLD_DIR/$(date +%Y-%m-%d)-${FP:0:12}-$_CO_N.md"
fi

# --- --check ---------------------------------------------------------------
if [ "$MODE" = "check" ]; then
    if printf '%s\n' "$VERDICT" | grep -q "COLD-OPEN-"; then
        printf '%s\n' "$VERDICT" | awk -F'\t' '$1=="V" && $4 ~ /^COLD-OPEN/ {printf "✗ %s\n  %s\n", $4, $5}' >&2
        exit 1
    fi
    printf '✓ a cold-open transcript is on file for the current front door (%s)\n' "${FP:0:16}"
    exit 0
fi

# --- --brief ---------------------------------------------------------------
render_prompt() {
    sed "s|{{REPO}}|$REPO|g" "$PROMPT_FILE"
}

if [ "$MODE" = "brief" ]; then
    echo "=== COLD OPEN — the verbatim prompt ==="
    echo "  repository          : $REPO"
    echo "  front-door surface  : sha256:$FP"
    echo "  prompt              : sha256:$PROMPT_FP"
    echo "  transcript goes to  : $CT_COLD_OPEN_DIR/$(basename "$TRANSCRIPT")"
    echo ""
    echo "  Hand the text below, unchanged, to someone who has not worked on this"
    echo "  repository and has not been told what it is for. Then file what they"
    echo "  wrote back:"
    echo "    scripts/cold-open.sh --record $REPO --from <their-answer.md> --reader \"<who they are>\""
    echo ""
    echo "-----------------------------8<-----------------------------"
    render_prompt
    echo "----------------------------->8-----------------------------"
    exit 0
fi

# --- Everything below files a transcript, so the page must be worth reading --
# A cold reader must be shown the page the record renders to. Reading a STALE
# view and stamping the CURRENT fingerprint would file a transcript about a
# document nobody has ever seen — a fresh-looking artifact describing something
# that does not exist, which is the precise failure the freshness contract
# exists to prevent.
if [ -x "$RENDER" ]; then
    if ! "$RENDER" --check "$REPO" >/dev/null 2>&1; then
        {
            echo "ERROR: cold-open.sh: $CT_TODO_VIEW is missing or stale, so there is no"
            echo "       settled page for a cold reader to read. Render it first:"
            echo "         scripts/ceo-todos-render.sh $REPO"
        } >&2
        exit 2
    fi
fi

mkdir -p "$COLD_DIR" || die "could not create $COLD_DIR"

# --- Is the repository settled? --------------------------------------------
# Warned about, never refused, and RECORDED in the transcript. The second real
# run of this harness surfaced it unprompted: "git status shows CEO-QUEUE.md and
# .ceo-queue as modified and a script as deleted. I don't know if the queue I
# just read is current or stale relative to those uncommitted changes — that's a
# real ambiguity." (Quoted verbatim; both files were renamed on 2026-08-29 to
# CEO-TODOs.md and .ceo-todos.) It is, and it is about the worktree rather than about the
# surface. Cold-reading mid-change is often exactly what you want; reading a
# transcript later without knowing which it was is not.
DIRTY_COUNT="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -c . || true)"
if [ "${DIRTY_COUNT:-0}" -gt 0 ]; then
    REPO_STATE="dirty — $DIRTY_COUNT uncommitted path(s) at the time of reading"
else
    REPO_STATE="clean"
fi

ANSWER="$(mktemp -t cold-open-answer.XXXXXX)" || exit 2
trap 'rm -f "$ANSWER"' EXIT

if [ "$MODE" = "record" ]; then
    [ -n "$FROM" ] || die "--record needs --from <file> containing what the reader wrote."
    [ -f "$FROM" ] || die "--from: no such file: $FROM"
    [ -n "$READER" ] || die "--record needs --reader \"<who read it>\". A transcript that does not say who read it is an anonymous claim, and the one thing the machine cannot check is the one thing it must at least record."
    cp "$FROM" "$ANSWER"
else
    # --- --run: a reader with no context, BY CONSTRUCTION --------------------
    # A brand-new process with an empty context window and every customisation
    # off: no CLAUDE.md, no plugins, no hooks, no skills, no agents, no MCP, no
    # session history. It cannot know what this repository is, who built it, or
    # what it was supposed to become, because there is nowhere for it to have
    # learned any of that. Read-only tools: it is here to read, not to fix.
    if [ -z "$READER_CMD" ]; then
        command -v claude >/dev/null 2>&1 || die "no --reader-cmd given and no 'claude' on PATH. Either install it, pass --reader-cmd \"<program>\", or do the reading with a person and file it with --record."
        READER_CMD="claude -p --safe-mode --strict-mcp-config --no-session-persistence --tools Read,Glob,Grep --model $MODEL"
    fi
    [ -n "$READER" ] || READER="$READER_CMD"

    echo "=== COLD OPEN — running a reader with no context ==="
    echo "  repository : $REPO"
    echo "  reader     : $READER_CMD"
    echo "  front door : sha256:${FP:0:16}"
    echo ""
    echo "  (this takes a minute or two; the reader is reading the repository)"
    RRC=0
    render_prompt | ( cd "$REPO" && eval "$READER_CMD" ) > "$ANSWER" 2>"$ANSWER.err" || RRC=$?
    if [ "$RRC" -ne 0 ] || [ ! -s "$ANSWER" ]; then
        {
            echo "ERROR: cold-open.sh: the reader failed (rc=$RRC) or said nothing."
            echo "       NOT filing a transcript. An empty transcript would satisfy the gate"
            echo "       while proving that nobody read anything, which is the whole defect."
            [ -s "$ANSWER.err" ] && sed 's/^/       | /' "$ANSWER.err"
            echo "       Fall back to a human reading:  scripts/cold-open.sh --brief $REPO"
        } >&2
        rm -f "$ANSWER.err"
        exit 2
    fi
    rm -f "$ANSWER.err"
fi

# --- The checked claims ----------------------------------------------------
# Three facts the surface states, and whether the reader came away with them.
# CRUDE ON PURPOSE — a substring test, nothing cleverer. It is not a grade and
# it gates nothing; it exists so a transcript is not purely unfalsifiable prose,
# and so a DIVERGENCE (the surface says nine, the reader read six) lands in the
# file as a finding instead of dissolving into an impression.
TRUE_VIEW="$CT_TODO_VIEW"
TRUE_ITEMS="$(grep -c '^### ' "$REPO/$CT_TODO_VIEW" 2>/dev/null || echo 0)"
TRUE_MINUTES="$(sed -n 's/.*total about \*\*\([0-9][0-9]*\) minutes\*\*.*/\1/p' "$REPO/$CT_TODO_VIEW" 2>/dev/null | head -1)"

claim_row() {
    # claim_row <what the surface says> <needle>
    local what="$1" needle="$2" saw="no"
    [ -n "$needle" ] || { printf '| %s | _(the surface does not state it)_ | — |\n' "$what"; return; }
    grep -qiF -- "$needle" "$ANSWER" && saw="yes"
    printf '| %s | `%s` | %s |\n' "$what" "$needle" "$saw"
}

{
    echo "# Cold-open transcript — $(basename "$REPO")"
    echo ""
    echo "- **Surface-fingerprint:** \`sha256:$FP\`"
    echo "- **Prompt-fingerprint:** \`sha256:$PROMPT_FP\`"
    echo "- **Reader:** $READER"
    echo "- **Run-by:** $RUN_BY"
    echo "- **Date:** $(date +%Y-%m-%d)"
    echo "- **Repo-state:** $REPO_STATE"
    echo ""
    echo "> Generated by \`scripts/cold-open.sh\`. The reader below had no context: a fresh"
    echo "> process, no memory of this repository, no briefing, and no knowledge of who built"
    echo "> it or what it was supposed to become. Its answer is the product of this file."
    echo ">"
    echo "> The gate that consumes this transcript checks only that it EXISTS for the front"
    echo "> door as it currently stands. It has no opinion on what the reader concluded, on"
    echo "> purpose — a gate that demanded a favorable verdict would get one every time."
    echo ""
    echo "## Checked claims"
    echo ""
    echo "A substring test, not a grade. Nothing here blocks anything; a \`no\` is a finding to read."
    echo ""
    echo "| what the surface states | value | reader's answer contains it |"
    echo "|---|---|---|"
    claim_row "the entry point"      "$TRUE_VIEW"
    claim_row "items waiting"        "$TRUE_ITEMS"
    claim_row "total minutes"        "$TRUE_MINUTES"
    echo ""
    echo "## The prompt, verbatim"
    echo ""
    echo '```'
    render_prompt
    echo '```'
    echo ""
    echo "## What the reader answered"
    echo ""
    cat "$ANSWER"
    echo ""
} > "$TRANSCRIPT"

# --- Does the GATE accept what was just filed? -----------------------------
# The harness does not get its own opinion about what counts as a transcript.
# It writes one and then asks the predicate — the same code the commit guard
# runs — whether the obligation is now discharged. Two definitions of "a valid
# transcript" is one definition too many, and this engine has been bitten by
# that shape three times already.
#
# It also closes a real hole found by this file's own test suite: a reader that
# printed a single blank line produced a non-empty file, so a size check passed
# it, and the transcript satisfied nothing while looking filed.
AFTER="$(ct_lint_file "$CT_TODO_RECORD" "$RECORD" "$REPO" 2>/dev/null || true)"
COLD_LEFT="$(printf '%s\n' "$AFTER" | awk -F'\t' '$1=="V" && $4 ~ /^COLD-OPEN/ {print $4": "$5}')"
if [ -n "$COLD_LEFT" ]; then
    rm -f "$TRANSCRIPT"
    {
        echo "ERROR: cold-open.sh: the reading was filed and the gate still refuses it, so it"
        echo "       has been REMOVED rather than left lying there looking like evidence:"
        printf '%s\n' "$COLD_LEFT" | sed 's/^/         /'
    } >&2
    exit 2
fi

printf '✓ filed %s\n' "${TRANSCRIPT#"$REPO"/}"
echo ""
echo "  Read it. The transcript is the product — the gate only checks it exists."
echo "  Checked claims:"
sed -n '/^| what the surface states/,/^$/p' "$TRANSCRIPT" | sed 's/^/    /'
exit 0
