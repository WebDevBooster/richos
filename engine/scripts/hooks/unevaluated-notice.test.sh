#!/usr/bin/env bash
#
# unevaluated-notice.test.sh — THE LIBRARY THAT MAKES AN UNEVALUATED CALL
#                              AUDIBLE, TESTED ON ITS OWN.
#
# scripts/lib/unevaluated-notice.sh is sourced by twenty-seven guards. Its two
# properties are worth more than any one of them:
#
#   1. IT CHANGES NO VERDICT. Every guard wired to it already exited 0 on
#      exactly these payloads. If this library ever starts refusing something,
#      a blanket change across twenty-seven gates stops being safe.
#   2. IT IS SILENT ON A PAYLOAD IT CAN READ. A message on every clean call is
#      noise, and noise is how a real signal gets ignored.
#
# The cross-hook suite (unevaluated-payload.test.sh) proves each guard is wired.
# This one proves the thing they are all wired to.
#
# Usage: scripts/hooks/unevaluated-notice.test.sh
# Exit:  0 all checks passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: unevaluated-notice.test.sh needs python3." >&2
    exit 1
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/unevaluated-notice.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
STATE="$SANDBOX/state"

echo "=== the unevaluated-call notice: audible, and still not a verdict ==="
echo ""

[ -f "$LIB" ] || { bad "0. the library exists at $LIB" "absent"; echo "=== $PASS passed, $FAIL failed ==="; exit 1; }
ok "0.  scripts/lib/unevaluated-notice.sh is present"

# Every case drives the library through a REAL SCRIPT rather than an inline
# subshell, and the reason is a bug this suite caught in its own first run: a
# redirect written after the last command inside `$( ... )` binds to that
# command, not to the substitution, so stderr escaped to the terminal and two
# cases failed for a reason that had nothing to do with the library. A stand-in
# hook makes the two streams unambiguous.
STANDIN="$SANDBOX/guard-example.sh"
# It reads stdin with `read -d ''` rather than `$(cat)` for one reason: section
# 5 strips PATH to prove the library needs no external binary, and a harness
# that shells out to `cat` would report the harness's dependency as the
# library's.
cat > "$STANDIN" <<STANDIN_EOF
#!/usr/bin/env bash
set -eo pipefail
. "$LIB"
PAYLOAD=""
IFS= read -r -d '' PAYLOAD || true
unevaluated_or_continue "guard-example.sh" "\$PAYLOAD" "\$UE_TEST_STATE" \\
    "whether this call is allowed to happen"
printf 'GUARD-CONTINUED\n'
STANDIN_EOF

ERR="$SANDBOX/err.txt"
drive() { # <payload> [<extra env assignment>...] -> OUT (stdout), ERR file, RC
    : > "$ERR"
    OUT="$(printf '%s' "$1" | UE_TEST_STATE="$STATE" bash "$STANDIN" 2>"$ERR")"
    RC=$?
}

continued() { printf '%s' "$OUT" | grep -q 'GUARD-CONTINUED'; }
announced() { { printf '%s' "$OUT"; cat "$ERR" 2>/dev/null; } | grep -q 'was NOT checked'; }

# ===========================================================================
# 1. THE POSITIVE CONTROL, FIRST.
#    Without it every case below could be satisfied by a library that
#    announced unconditionally, or by one that did nothing at all.
# ===========================================================================
drive '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
if continued; then ok "1a  a READABLE payload returns and the guard carries on — the library is not a gate"
else bad "1a  a readable payload lets the guard continue" "$OUT"; fi
if announced; then bad "1b  a readable payload must be SILENT" "$OUT $(cat "$ERR")"
else ok "1b  a readable payload says NOTHING — silence stays correct on the happy path"; fi

# ===========================================================================
# 2. THE THREE DEGRADED SHAPES FROM THE SURVEY, PLUS ONE MORE
# ===========================================================================
for shape_name in empty truncated prose array; do
    case "$shape_name" in
        empty)     P="" ;;
        truncated) P='{"tool_name":"Bash","tool_inp' ;;
        prose)     P='this is not JSON at all, it is a sentence' ;;
        array)     P='[{"tool_name":"Bash"}]' ;;
    esac
    drive "$P"
    if announced; then ok "2$shape_name  a $shape_name payload is ANNOUNCED — the absence of a check is distinguishable from the absence of a finding"
    else bad "2$shape_name  a $shape_name payload announces" "$OUT $(cat "$ERR")"; fi
    if [ "$RC" -eq 0 ]; then ok "2$shape_name-rc  and it still exits 0 — the verdict is exactly what it was"
    else bad "2$shape_name-rc  a $shape_name payload still exits 0" "rc=$RC"; fi
    if continued; then bad "2$shape_name-stop  it must not fall through into the guard's own logic" "$OUT"
    else ok "2$shape_name-stop  and the guard's own logic is not reached with a payload it cannot read"; fi
done

# The `array` case is the one a `json.load` succeeds on. A library that only
# caught exceptions would pass every other case here and hand a guard a list
# where it expects a mapping.
ok "2note  the array case is the reason readability means 'parses AS AN OBJECT', not 'parses'"

# ===========================================================================
# 3. THE OPERATOR CHANNEL, AND THE PROOF IT IS NOT A DECISION
#    Measured 2026-09-05: on a zero exit the host renders a PreToolUse hook's
#    stderr to nobody and its stdout {"systemMessage":...} to the operator.
#    docs/verification/unevaluated-payload-notice-2026-09-05.md has the run.
# ===========================================================================
drive ""
if printf '%s' "$OUT" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
d = json.loads(raw)
sys.exit(0 if isinstance(d, dict) and d.get("systemMessage") else 1)
' 2>/dev/null; then
    ok "3a  stdout is a single valid JSON object carrying systemMessage — the channel that reaches the operator"
else bad "3a  stdout is a systemMessage object" "$OUT"; fi

if printf '%s' "$OUT" | grep -q 'permissionDecision'; then
    bad "3b  the systemMessage must carry NO permissionDecision" "$OUT"
else ok "3b  it carries NO permissionDecision — announcing is not deciding, which is what makes this safe across 27 gates"; fi

if [ -s "$ERR" ] && grep -q 'was NOT checked' "$ERR"; then
    ok "3c  and stderr carries the same sentence — invisible to the operator, but it survives into the transcript attachment"
else bad "3c  stderr carries the sentence too" "$(cat "$ERR")"; fi

# ===========================================================================
# 4. THE DURABLE HALF
#    An operator channel is something a person can miss. resume-acks.log and
#    definition-drift.log exist for the same reason.
# ===========================================================================
LOG="$STATE/unevaluated-payloads.log"
if [ -f "$LOG" ] && grep -q 'hook=guard-example.sh' "$LOG"; then
    ok "4a  a durable line is appended to .claude/state/unevaluated-payloads.log"
else bad "4a  the durable log is written" "$( [ -f "$LOG" ] && cat "$LOG" )"; fi

BEFORE="$(grep -c . "$LOG" 2>/dev/null || echo 0)"
drive ""
drive ""
AFTER="$(grep -c . "$LOG" 2>/dev/null || echo 0)"
if [ "$AFTER" -eq "$BEFORE" ]; then
    ok "4b  an identical repeat is de-duplicated on CONTENT, never on the timestamp — the fix already made in guard-definition-drift.sh"
else bad "4b  an identical repeat is de-duplicated" "grew from $BEFORE to $AFTER"; fi

drive 'still not json'
AFTER2="$(grep -c . "$LOG" 2>/dev/null || echo 0)"
if [ "$AFTER2" -gt "$AFTER" ]; then
    ok "4c  POSITIVE CONTROL — a DIFFERENT reason still gets its own line, so 4b is de-duplication and not a dead writer"
else bad "4c  a different reason gets its own line" "stayed at $AFTER2"; fi

# 4d. An unwritable state dir must not take the announcement down with it.
: > "$ERR"
OUT="$(printf '%s' "" | UE_TEST_STATE="/dev/null/impossible" bash "$STANDIN" 2>"$ERR")"
if announced; then
    ok "4d  an unwritable state dir still announces — the durable half is a bonus, never a precondition"
else bad "4d  an unwritable state dir still announces" "$OUT $(cat "$ERR")"; fi

# ===========================================================================
# 5. A BARE ENVIRONMENT DOES NOT BREAK THE NOTICE
#    This library runs in a FAILURE PATH. A notice about a broken check that is
#    itself conditional on a healthy environment is the same defect one level
#    up — and the first version of this file had it twice: `tr` for the label
#    and python3 for the JSON. Both are now optional.
#
#    And NO python3 IS NOT REPORTED AS UNREADABLE. Without it nothing here can
#    tell a good payload from a bad one, so announcing "unreadable" would be a
#    claim this file cannot support.
# ===========================================================================
FAKEBIN="$SANDBOX/nobin"
mkdir -p "$FAKEBIN"
bare() { # <payload>
    : > "$ERR"
    OUT="$(printf '%s' "$1" | PATH="$FAKEBIN" UE_TEST_STATE="$STATE" \
        /bin/bash "$STANDIN" 2>"$ERR")"
    RC=$?
}

bare '{"tool_name":"Bash"}'
if continued; then
    ok "5a  with no python3 a non-empty payload is NOT called unreadable — the guard's own no-python3 path owns that case"
else bad "5a  no python3 does not manufacture an unreadable verdict" "$OUT $(cat "$ERR")"; fi

bare ""
if announced; then
    ok "5b  but an EMPTY payload needs no parser to be unreadable, and is still announced"
else bad "5b  an empty payload is announced with no python3" "$OUT $(cat "$ERR")"; fi

if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
    ok "5c  and the OPERATOR channel survives a bare environment — the pure-shell JSON fallback"
else bad "5c  the systemMessage survives with no python3" "$OUT"; fi

if printf '%s' "$OUT$(cat "$ERR")" | grep -q 'EXAMPLE GUARD'; then
    ok "5d  the label survives too — uppercasing is pure bash, so no PATH lookup can strip it"
else bad "5d  the label survives with no tr on PATH" "$OUT $(cat "$ERR")"; fi

if [ -s "$ERR" ] && grep -q 'command not found' "$ERR"; then
    bad "5e  a bare environment must produce NO 'command not found' noise" "$(cat "$ERR")"
else ok "5e  and nothing reports a missing binary — a notice that is itself visibly broken is not a notice"; fi

# ===========================================================================
# 6. THE LABEL IS DERIVED FROM THE FILE NAME
#    A second name for a hook is a second thing to keep in step with the first.
# ===========================================================================
LBL="$( . "$LIB"; _ue_label "guard-worktree-isolation.sh" )"
if [ "$LBL" = "WORKTREE-ISOLATION GUARD" ]; then
    ok "6a  the label is derived: guard-worktree-isolation.sh -> $LBL"
else bad "6a  the label is derived from the file name" "got '$LBL'"; fi
LBL="$( . "$LIB"; _ue_label "notice-hook-staleness.sh" )"
if [ "$LBL" = "HOOK-STALENESS GUARD" ]; then
    ok "6b  and the notice- prefix is stripped the same way: $LBL"
else bad "6b  the notice- prefix is stripped" "got '$LBL'"; fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
