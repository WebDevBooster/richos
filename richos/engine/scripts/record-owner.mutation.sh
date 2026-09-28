#!/usr/bin/env bash
#
# record-owner.mutation.sh: PROVES record-owner.test.sh WOULD CATCH THE OWNER
# LINE, ITS TWO TERMINAL-SIDE REFUSALS OR THE SWITCH GOING WRONG (daily-driver plan
# step 8; two-installs spec points 25-28). Each mutant removes ONE property from a
# throwaway copy of the engine and demands that the NAMED case go red. The loop is
# scripts/lib/mutation-harness.sh.
#
# P1 needs the loro writer, which the sandbox copy of the engine does not carry;
# the suite is pointed at this checkout's writer through RICHOS_TEST_LORO_WRITE.
#
# Run directly: scripts/record-owner.mutation.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

export RICHOS_TEST_LORO_WRITE="$ENGINE_ROOT/loro/bin/loro-write.mjs"
mutation_begin "one writer at cut-over" "scripts/record-owner.test.sh"
mutation_focus want-as-argument

RC="scripts/lib/row-currency.sh"
G="scripts/hooks/guard-row-currency-commits.sh"
MG="scripts/hooks/guard-record-owner-memory.sh"
PY="scripts/lib/record_owner.py"
SW="scripts/record-owner.sh"

# --- the owner line ----------------------------------------------------------
mutant owner-line-ignored "O1 " "$RC" \
    '                _rc_owner_raw="$val" ;;' \
    '                : ;;' \
    "spec 27: the line would be read by nothing and the cut-over would rest on his memory."
mutant owner-typo-quiet "O7 " "$RC" \
    '        if [ "$_rc_owner_word" != "app" ]; then' \
    '        if false; then' \
    "a misspelled owner would be taken as a real one instead of refusing loudly."
mutant peer-owner-accepted "O7 " "$RC" \
    '        if [ -n "$RC_PEER_SPEC" ]; then{NL}            RC_BROKEN_REASON="$ROW_CURRENCY_DECLARATION declares ROW_RECORD_OWNER in the peer form.' \
    '        if false; then{NL}            RC_BROKEN_REASON="$ROW_CURRENCY_DECLARATION declares ROW_RECORD_OWNER in the peer form.' \
    "a second copy of who owns the record, in a peer, would be accepted and ignored."
mutant peer-resolved-from-worktree "M4 " "$RC" \
    '            *)  abs="$main/$spec" ;;{NL}        esac{NL}        [ -d "$abs" ] || return 1' \
    '            *)  abs="$root/$spec" ;;{NL}        esac{NL}        [ -d "$abs" ] || return 1' \
    "a teammate's worktree would resolve the record beside itself, find none, and let the write through."

# --- the landing refusal -------------------------------------------------------
mutant landing-owner-check-removed "O1 " "$G" \
    'if [ "$RC_MODE" = "record" ] && [ "${RC_RECORD_OWNER:-terminal}" = "app" ]; then' \
    'if false; then' \
    "spec 27: after cut-over the terminal would keep landing in the record the app owns."
mutant unknown-caller-lands "O4 " "$G" \
    '    if [ "$_RC_WHO" != "app" ]; then' \
    '    if [ "$_RC_WHO" = "terminal" ]; then' \
    "a caller whose identity could not be read would be allowed, which is a guess."

# --- who is calling --------------------------------------------------------------
mutant sdk-counted-as-terminal "O3 " "$PY" \
    '    if entry.startswith("sdk-"):{NL}        return "app", detail' \
    '    if False:{NL}        return "app", detail' \
    "Echo's catch: the app's own lead runs these hooks and would be refused as the terminal."
mutant no-session-is-app "O4 " "$PY" \
    '        return "unknown", "no Claude session record matches any process in this call'"'"'s ancestry"' \
    '        return "app", "no session record"' \
    "a process with no session record would be taken for the app."

# --- the memory refusal ------------------------------------------------------------
mutant memory-switch-ignored "M1 " "$MG" \
    '[ "$RC_OWNER" = "app" ] || exit 0' \
    'exit 0' \
    "spec 25: after cut-over the terminal would keep writing a memory nothing reads."
mutant memory-wrapper-drops-refusal "M1 " "$MG" \
    '    printf '"'"'%s\n'"'"' "$_rom_err" >&2{NL}    exit 2' \
    '    printf '"'"'%s\n'"'"' "$_rom_err" >&2{NL}    exit 0' \
    "the refusal would be printed and the write let through."
mutant any-memory-directory "M1 " "$PY" \
    '    if not OL.inside(OL.realish(expand(path)), OL.realish(expand(memory_dir))):{NL}        return 0' \
    '    if False:{NL}        return 0' \
    "every memory directory of every project would be refused, not the one the line names."
mutant memory-unknown-allowed "M3 " "$PY" \
    '    side, detail = caller(){NL}    if side == "app":{NL}        return 0' \
    '    side, detail = caller(){NL}    if side != "terminal":{NL}        return 0' \
    "a caller whose identity could not be read would write his memory."
mutant broken-declaration-blocks-memory "M6 " "$MG" \
    '        printf '"'"'{"systemMessage":"%s"}\n'"'"' "$_rom_j"{NL}        exit 0 ;;' \
    '        printf '"'"'{"systemMessage":"%s"}\n'"'"' "$_rom_j"{NL}        exit 2 ;;' \
    "a typo in an unrelated key would stop every write to his memory."
mutant memory-guard-unregistered "R1 " "scripts/hooks/dispatch-pretooluse.manifest" \
    'Write|guard-record-owner-memory.sh' \
    '' \
    "the guard would ship, pass its own cases, and run on no call at all."

# --- the switch ----------------------------------------------------------------------
mutant committer-not-required "S1 " "$SW" \
    '    committer_installed || die "the record committer is not installed' \
    '    true || die "the record committer is not installed' \
    "spec 28: the app would own a record whose memory writes nothing commits."
mutant dirty-declaration-accepted "S2 " "$SW" \
    'git -C "$RECORD" diff --quiet HEAD -- "$DECL_REL" \' \
    'true \' \
    "the switch's commit would carry someone's unfinished edit of the declaration."
mutant off-leaves-its-comments "S3 " "$SW" \
    '    new, n = pattern.subn("", text, count=1)' \
    '    new, n = text, 0' \
    "off would not return the declaration to exactly what it was: a one-way door, slightly ajar."

mutation_end
