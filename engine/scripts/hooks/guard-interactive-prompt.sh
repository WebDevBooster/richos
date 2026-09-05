#!/usr/bin/env bash
#
# guard-interactive-prompt.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# At 02:01 on 2026-09-01 a macOS password window appeared on the CEO's screen:
# "Enter the password for D.p12". An agent had run
#
#     security import D.p12 -k <scratch>/t3.keychain-db -T /usr/bin/codesign
#
# with no -P. A MISSING passphrase is not an empty passphrase — macOS escalates
# to SecurityAgent, which draws a window on the logged-in user's screen, and the
# calling process waits on it forever. PID 70803, killed by hand.
#
# His question was, bluntly, when that would STOP — and this hook is the answer.
#
# THE ROOT CAUSE IS A HOLE IN THE GUARD SET, NOT A CARELESS ENGINEER. Forty-one
# guards were registered that night. Every one of them inspects text and state —
# files, commit contents, agent names, spawn prompts, worktree locks, dialect,
# secrets. NOT ONE ASKED WHETHER A COMMAND CAN WAIT ON A HUMAN. Combined with
# shell commands executing without per-call approval, nothing at all sat between
# that command and his screen. A rule in CLAUDE.md would not have: the engineer
# who ran it was mid-repro on a signing problem and had every reason to believe
# the command was inert.
#
# ===========================================================================
# WHAT IT DOES
# ===========================================================================
# Refuses a Bash command that can stop and wait for a person, AND NAMES THE FLAG
# that makes it fail instead of wait. The judgment is entirely in
# scripts/lib/interactive-prompt.py, which carries the shape table, the two-tier
# policy and the measured false-positive record. This file is the wiring: root
# resolution, the refusal text, and the exit code.
#
#   verdict block   -> exit 2, refusal on stderr, the fix named per finding
#   verdict report  -> exit 0, one line on stderr, the command runs
#   verdict clean   -> exit 0, silent
#
# ===========================================================================
# NO ESCAPE HATCH ON THE BLOCKING TIER, AND THAT IS THE DESIGN
# ===========================================================================
# Several guards in this engine carry a live opt-out line, because they can be
# wrong in a way the author cannot route around. This one cannot: every blocking
# refusal names a one-token fix that keeps the command working and is what the
# author meant anyway. `-P ''`. `-n`. `-o BatchMode=yes`. So there is no waiver
# marker, no ack file and no config switch that turns the blocking tier off.
#
# That decision is only defensible because it was MEASURED rather than asserted.
# Against 65,781 unique Bash commands drawn from every Claude Code transcript on
# this machine, the blocking tier fires 4 times — 0.006% — and all four are
# `security import` with no -P, the exact incident shape. The full record,
# including the shapes that were CUT for measuring badly, is in
# scripts/hooks/interactive-prompt.corpus.md.
#
# ===========================================================================
# FAIL-CLOSED, AND WHAT THAT MEANS HERE
# ===========================================================================
# Missing python3, or a missing scripts/lib/interactive-prompt.py, is exit 2 with
# the shared BROKEN INSTALL banner. A guard that cannot judge must not wave
# things through: the whole failure being fixed is a defense that was not there.
# The refusal names the file it went looking for, which is what
# scripts/lib/sandbox-completeness.sh reads to prove this hook can start in every
# sandbox that claims to model the engine.
#
# A repository that never adopted the engine stands down, like every other rooted
# guard — see scripts/lib/resolve-roots.sh §"not-adopted". `broken` blocks.
#
# ===========================================================================
# WHAT THIS DOES NOT COVER — the app-facing half is somebody else's row
# ===========================================================================
# RichOS MUST raise real microphone and accessibility dialogs or it cannot work.
# This guard governs COMMANDS AGENTS RUN. It says nothing about shipped code
# paths, and it must never be extended to, because the guarantee there is a
# different one: every prompt follows a user-initiated action and none blocks a
# background operation. RICH-TODOs.md row g4 names that half separately.
#
# It also does not look inside scripts. `bash app/scripts/install-signing-cert.sh`
# is one token here, and that script contains `security import`. Stated in
# scripts/lib/interactive-prompt.py under "WHAT THIS CANNOT SEE", and repeated
# here so nobody has to find it.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || {
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-interactive-prompt.sh"
        echo "  python3 is required for this guard and is not on PATH."
        echo "  Refusing rather than passing every command through unjudged."
    } >&2
    exit 2
}

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-interactive-prompt.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

ANALYZER="$ENGINE_ROOT/scripts/lib/interactive-prompt.py"
if [ ! -f "$ANALYZER" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-interactive-prompt.sh"
        echo "  scripts/lib/interactive-prompt.py is missing at: $ANALYZER"
        echo "  Every judgment this guard makes comes from that file. Without it"
        echo "  no command can be checked for the ability to wait on a human."
        echo "  Refusing rather than passing every command through unjudged."
    } >&2
    exit 2
fi

INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    :
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # Never adopted, so there is no enforcement to lose here. engine-status.sh
    # announces the stand-down at session start; this is not a silent skip.
    exit 0
else
    root_failure_banner "scripts/hooks/guard-interactive-prompt.sh" >&2
    exit 2
fi
# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# On a payload it cannot read, this guard takes the SAME silent exit 0 that a
# well-formed payload for a DIFFERENT tool takes: the tool-name extraction ends
# in `|| true`, so "this call is not mine" and "I could not tell whose call this
# is" are one exit. That is why 17 of 25 PreToolUse guards were measured passing
# a call in complete silence on 2026-09-05. This separates the two. NO VERDICT
# CHANGES — the exit is the one already taken — only the silence does. The
# measurement, the channel and the argument: scripts/lib/unevaluated-notice.sh.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    unevaluated_or_continue "guard-interactive-prompt.sh" "$INPUT" \
        "${ENTITY_ROOT:-${SEAT_ROOT:-${RICHOS_ENTITY_ROOT_RESOLVED:-}}}" \
        "whether this command opens an interactive prompt with nobody at the keyboard"
fi

RESULT="$(printf '%s' "$INPUT" | python3 "$ANALYZER" 2>/dev/null || true)"
[ -n "$RESULT" ] || exit 0

VERDICT="$(printf '%s' "$RESULT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("verdict","clean"))
except Exception: print("clean")')"

case "$VERDICT" in
  clean) exit 0 ;;

  report)
    printf '%s' "$RESULT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for f in d.get("findings", []):
    if f.get("severity") != "report":
        continue
    sys.stderr.write("(hook: guard-interactive-prompt) NOTE: `%s` may wait on a human "
                     "(%s) — %s. FIX: %s\n" % (f["token"], f["shape"], f["why"], f["fix"]))
' >&2 || true
    exit 0 ;;

  block)
    {
        echo "=== guard-interactive-prompt: BLOCKED ==="
        echo "  This command can STOP AND WAIT FOR A HUMAN. Agents run without a"
        echo "  terminal, so waiting means one of two things: a window drawn on the"
        echo "  CEO's screen, or a process hung until somebody notices and kills it."
        echo "  Both have happened. 2026-09-01, 02:01, PID 70803."
        echo ""
        printf '%s' "$RESULT" | python3 -c '
import json, sys
for f in json.load(sys.stdin).get("findings", []):
    if f.get("severity") != "block":
        continue
    sys.stdout.write("  * %s (%s)\n      why: %s\n      FIX: %s\n"
                     % (f["token"], f["shape"], f["why"], f["fix"]))
' || echo "  (the analyzer produced a blocking verdict with no readable finding)"
        echo ""
        echo "  Apply the fix and re-run. There is no waiver line for this guard:"
        echo "  every refusal above names a change that keeps the command working."
        echo "(hook: scripts/hooks/guard-interactive-prompt.sh)"
    } >&2
    exit 2 ;;

  *) exit 0 ;;
esac
