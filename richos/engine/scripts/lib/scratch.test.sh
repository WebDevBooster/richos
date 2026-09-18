#!/usr/bin/env bash
#
# scratch.test.sh — THE ALLOCATOR'S PROPERTIES, EACH ONE WITH A POSITIVE
#                   CONTROL.
#
# The allocator's whole value is that the SWEEPER can find what it made
# without being told. So every case here is written from the sweeper's side of
# the contract: after scratch_new returns, is the thing it made discoverable,
# attributable and contained?
#
#   S1   a new directory exists, is empty, and is under the declared root
#   S2   the path is symlink-resolved (macOS $TMPDIR is a symlink, and two
#        spellings of one directory is how a containment wall gets talked past)
#   S3   the owning pid is in the NAME, so a sweeper that lost the ledger can
#        still attribute it
#   S4   a ledger row is written, with path, label, pid and TTL
#   S5   an awkward label still yields ONE path component
#   S6   two allocations never collide (the 16-mutant case)
#   S7   release deletes it and records the release
#   S8   release REFUSES a path outside the root      <- the rm -rf "$D" class
#   S9   release of an EMPTY argument is a silent no-op, not `rm -rf ""`
#   S10  a ledger that cannot be written does NOT fail the allocation
#   S11  the directory is 0700 — scratch holds copies of the engine
#   S12  sourcing the file does not execute the command parser
#
#   CONTROL cases prove the checks can fail: C8 shows the containment check
#   accepting a path that IS inside the root, so S8's refusal is a decision
#   and not a function that refuses everything.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_SH="$LIB_DIR/scratch.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SCRATCH_SH" ] || { echo "FATAL: missing $SCRATCH_SH" >&2; exit 1; }

# The suite gets its OWN $TMPDIR and its own $HOME, so it allocates into a
# throwaway tree and appends to a throwaway ledger. A test for a deleter that
# ran against the real root would be a test that deletes the operator's work.
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scratch-alloc-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude"
mkdir -p "$TMPDIR" "$CLAUDE_CONFIG_DIR"

# shellcheck source=scratch.sh
. "$SCRATCH_SH"

ROOT="$(scratch_root)"
LEDGER="$(scratch_ledger)"

echo "=== scratch allocator tests ==="

# ---------------------------------------------------------------------------
# S1 / S2 / S3 / S11 — one allocation, four properties of it
# ---------------------------------------------------------------------------
D1="$(scratch_new alpha)"

if [ -d "$D1" ] && [ -z "$(ls -A "$D1" 2>/dev/null)" ]; then
    ok "S1  scratch_new made an empty directory"
else
    bad "S1  scratch_new did not make an empty directory (got '$D1')"
fi

RROOT="$( cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT" )"
case "$D1" in
    "$RROOT"/?*) ok "S2  the path is symlink-resolved and under the root" ;;
    *)           bad "S2  '$D1' is not under the resolved root '$RROOT'" ;;
esac

if [ "$(basename "$D1")" != "${D1##*/}" ]; then
    bad "S3  basename disagreement"
elif case "$(basename "$D1")" in "$$-"*) true ;; *) false ;; esac; then
    ok "S3  the owning pid ($$) leads the directory name"
else
    bad "S3  the name '$(basename "$D1")' does not lead with the owning pid $$"
fi

MODE="$(stat -f '%Lp' "$D1" 2>/dev/null || stat -c '%a' "$D1" 2>/dev/null || echo '?')"
if [ "$MODE" = "700" ]; then
    ok "S11 the directory is 0700"
else
    bad "S11 the directory is $MODE, not 700 — scratch holds copies of the engine"
fi

# ---------------------------------------------------------------------------
# S4 — the ledger row
# ---------------------------------------------------------------------------
if [ -f "$LEDGER" ] && grep -q "\"path\":\"$D1\"" "$LEDGER" \
   && grep -q '"label":"alpha"' "$LEDGER" \
   && grep -q "\"pid\":$$," "$LEDGER" \
   && grep -q '"ttl_minutes"' "$LEDGER"; then
    ok "S4  the ledger carries path, label, pid and TTL"
else
    bad "S4  the ledger row is missing or incomplete"
    [ -f "$LEDGER" ] && sed 's/^/        /' "$LEDGER" | tail -3
fi

# The row must also be VALID JSON, because the sweeper parses it. A hand-rolled
# printf is exactly the thing that emits something json.loads refuses.
if python3 -c '
import json,sys
bad=0
for i,l in enumerate(open(sys.argv[1]),1):
    l=l.strip()
    if not l: continue
    try: json.loads(l)
    except Exception as e:
        print("  line %d: %s" % (i,e)); bad=1
sys.exit(bad)' "$LEDGER" 2>&1; then
    ok "S4b every ledger line parses as JSON"
else
    bad "S4b the ledger emitted something json.loads refuses"
fi

# ---------------------------------------------------------------------------
# S5 — an awkward label still yields one path component
# ---------------------------------------------------------------------------
D2="$(scratch_new 'a/b c!!$(echo hi)')"
REL="${D2#"$RROOT"/}"
case "$REL" in
    */*) bad "S5  an awkward label escaped into subdirectories: '$REL'" ;;
    *)   ok "S5  an awkward label yields one path component ('$REL')" ;;
esac

# ---------------------------------------------------------------------------
# S6 — two allocations never collide
# ---------------------------------------------------------------------------
D3="$(scratch_new same)"
D4="$(scratch_new same)"
if [ "$D3" != "$D4" ] && [ -d "$D3" ] && [ -d "$D4" ]; then
    ok "S6  two allocations under one label are distinct directories"
else
    bad "S6  two allocations collided ('$D3' vs '$D4')"
fi

# ---------------------------------------------------------------------------
# S7 — release deletes and records
# ---------------------------------------------------------------------------
: >"$D3/a-file"
if scratch_release "$D3" && [ ! -e "$D3" ] \
   && grep -q "\"path\":\"$D3\",\"pid\":$$,\"released\"" "$LEDGER"; then
    ok "S7  release deleted the tree and recorded the release"
else
    bad "S7  release did not delete '$D3' or did not record it"
fi

# ---------------------------------------------------------------------------
# S8 + C8 — containment, and the control that proves it is a decision
# ---------------------------------------------------------------------------
OUTSIDE="$SANDBOX/not-scratch"
mkdir -p "$OUTSIDE"
if scratch_release "$OUTSIDE" 2>/dev/null; then
    bad "S8  release accepted a path OUTSIDE the root — it deleted $OUTSIDE"
elif [ -d "$OUTSIDE" ]; then
    ok "S8  release refused a path outside the root, and left it alone"
else
    bad "S8  release refused but the directory is gone anyway"
fi

D5="$(scratch_new control)"
if scratch_release "$D5" && [ ! -e "$D5" ]; then
    ok "C8  CONTROL: the same check ACCEPTS a path inside the root"
else
    bad "C8  CONTROL FAILED: release refuses everything, so S8 proves nothing"
fi

# ---------------------------------------------------------------------------
# S9 — an empty argument is a no-op, not `rm -rf ""`
# ---------------------------------------------------------------------------
CANARY="$SANDBOX/canary"
mkdir -p "$CANARY"
OLDPWD_SAVE="$PWD"
cd "$SANDBOX" || exit 1
if scratch_release "" && [ -d "$CANARY" ]; then
    ok "S9  release of an empty argument is a silent no-op"
else
    bad "S9  release of an empty argument did something"
fi
cd "$OLDPWD_SAVE" || exit 1

# ---------------------------------------------------------------------------
# S10 — a ledger that cannot be written must NOT fail the allocation
# ---------------------------------------------------------------------------
# A cleanup mechanism that can refuse to allocate is an availability risk, and
# an availability risk is what gets a cleanup mechanism switched off.
RO="$SANDBOX/readonly-home"
mkdir -p "$RO/state"
: >"$RO/state/scratch-ledger.jsonl"
chmod 500 "$RO/state" 2>/dev/null || true
chmod 400 "$RO/state/scratch-ledger.jsonl" 2>/dev/null || true
D6="$(CLAUDE_CONFIG_DIR="$RO" scratch_new stubborn 2>/dev/null)"
if [ -n "$D6" ] && [ -d "$D6" ]; then
    ok "S10 an unwritable ledger does not stop the allocation"
else
    bad "S10 an unwritable ledger stopped the allocation — availability risk"
fi
chmod 700 "$RO/state" 2>/dev/null || true

# ---------------------------------------------------------------------------
# S12 — sourcing does not run the command parser
# ---------------------------------------------------------------------------
# If the `if [ "${BASH_SOURCE[0]}" = "${0}" ]` guard were wrong, sourcing this
# file from a harness would make it react to the HARNESS's arguments.
SRC_OUT="$(bash -c '
    set -uo pipefail
    export TMPDIR="'"$TMPDIR"'" CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    . "'"$SCRATCH_SH"'" release /etc
    echo SOURCED-CLEANLY
' 2>&1)"
if [ "${SRC_OUT##*$'\n'}" = "SOURCED-CLEANLY" ] \
   && ! printf '%s' "$SRC_OUT" | grep -q 'refusing to release'; then
    ok "S12 sourcing ignores the caller's arguments"
else
    bad "S12 sourcing ran the command parser against the caller's arguments"
    printf '%s\n' "$SRC_OUT" | sed 's/^/        /'
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
