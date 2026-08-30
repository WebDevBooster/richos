#!/usr/bin/env bash
#
# turn-manifest.mutation.sh — PROVES THE MANIFEST'S TESTS CAN FAIL.
#
# A suite of green ticks is evidence of nothing until somebody shows it turning
# red for the right reason. That is not a general worry here, it is this
# project's most-repeated defect, and the manifest is unusually exposed to it:
# every one of its properties is about NOT quietly rendering something
# plausible, and a test for "it did not quietly do the wrong thing" is exactly
# the kind that passes for free.
#
# The sharpest instance is the one this hook was written next to. The sibling
# Stop guard collected tool names SESSION-WIDE while believing it was scoped to
# the turn, and its suite stayed green for weeks — because no fixture carried a
# promptId at all, so the broken scope and the correct one produced identical
# output on every input it was ever given. Mutation 1 below is that exact bug,
# reintroduced on purpose, to show that this suite would have caught it.
#
# So: take the shipped hook, MUTATE ONE PROPERTY OUT OF IT AT A TIME, and
# assert that
#   1. turn-manifest.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives
#      a green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy. Nothing here touches the real tree.
#
# Run directly: scripts/hooks/turn-manifest.mutation.sh
# Exit 0 = every property is proven load-bearing; exit 1 = at least one could be
# removed without any test noticing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t turn-manifest-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# --- the mutator -----------------------------------------------------------
# An exact string replacement, in python rather than sed, because these targets
# contain regex metacharacters and a sed that silently matched nothing is the
# failure mode this whole file exists to rule out. It exits non-zero when the
# target is absent, so a drifted source is a loud error and never a green run.
cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case> <file> <old> <new> <why>
mutant() {
    local name="$1" want_case="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"

    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/turn-manifest.sh" \
       "$ENGINE_ROOT/scripts/hooks/turn-manifest.py" \
       "$ENGINE_ROOT/scripts/hooks/turn-manifest.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$dir/scripts/lib/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1))
        return
    fi

    bash "$dir/scripts/hooks/turn-manifest.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! grep -q "FAIL  $want_case" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want_case"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1))
        return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want_case"
    PASS=$((PASS + 1))
}

echo "=== turn-manifest: every property, proven load-bearing by removing it ==="

# ---------------------------------------------------------------------------
# 1. PER-TURN SCOPING — the sibling guard's real bug, rebuilt.
#    Opening the window at the first record makes every call in the session
#    "this turn's". The manifest does not degrade under this; it INVERTS,
#    printing the session's history under the heading "this turn".
# ---------------------------------------------------------------------------
mutant scoping-session-wide "c." scripts/hooks/turn-manifest.py \
    "    in_turn = False" \
    "    in_turn = True" \
    "A session-wide window reports every call the session ever made as this turn's."

# ---------------------------------------------------------------------------
# 2. THE TOOL'S OWN SENTENCE — the motivating failure itself.
#    Without this rule SendMessage renders as a byte count, and "Message queued
#    for delivery at its next tool round" never reaches the operator's eye —
#    which is the precise gap that let "I've told him" stand.
# ---------------------------------------------------------------------------
mutant no-tool-message "a." scripts/hooks/turn-manifest.py \
    '        if isinstance(obj, dict) and isinstance(obj.get("message"), str):' \
    '        if False and isinstance(obj, dict) and isinstance(obj.get("message"), str):' \
    "Without it, a queued SendMessage renders as a size and reads like success."

# ---------------------------------------------------------------------------
# 3. THE EXPLICIT EMPTY TURN.
#    The "dispatching it rather than queuing it" failure had ZERO tool calls
#    behind it. A manifest that renders nothing on an empty turn hides exactly
#    the turn it was built for.
# ---------------------------------------------------------------------------
mutant blank-on-empty-turn "b." scripts/hooks/turn-manifest.py \
    '    if total == 0:' \
    '    if total == 0 and False:' \
    "A blank render on a no-tool turn is indistinguishable from no manifest."

# ---------------------------------------------------------------------------
# 4. A GAP MUST NOT READ AS AN ABSENCE.
#    If an unreadable transcript falls through to the normal path it renders
#    "0 tool calls this turn" — asserting something false about the turn, which
#    is the defect this hook exists to remove, rebuilt inside it.
# ---------------------------------------------------------------------------
mutant gap-reads-as-empty "b2." scripts/hooks/turn-manifest.py \
    '        return [], {}, 0, "the transcript is not a readable file at %s" % path' \
    '        return [], {}, 0, None' \
    "An unreadable transcript would claim the turn ran nothing."

# ---------------------------------------------------------------------------
# 5. ANNOUNCED TRUNCATION.
#    A manifest that silently elides is the defect it exists to prevent,
#    rebuilt. Dropping the omission line leaves 25 tidy rows and no hint that
#    15 calls existed.
# ---------------------------------------------------------------------------
mutant silent-truncation "e2." scripts/hooks/turn-manifest.py \
    '    if dropped:' \
    '    if dropped and False:' \
    "Dropped rows would vanish with nothing said about them."

# ---------------------------------------------------------------------------
# 6. THE NEGATIVE CONTROL ITSELF.
#    If records_examined stops counting, the suite's proof that the manifest
#    read anything at all evaporates — and a manifest rendered from an empty
#    corpus still looks entirely convincing. This session found a scanner
#    reporting CLEAN over an empty corpus; this case is the guard against a
#    manifest joining it.
# ---------------------------------------------------------------------------
mutant records-uncounted "f." scripts/hooks/turn-manifest.py \
    '                examined += 1' \
    '                examined += 0' \
    "Without the counter, a manifest rendered from nothing passes its own tests."

# ---------------------------------------------------------------------------
# 7. IT MUST NEVER BLOCK.
#    A Stop hook that fails closed refuses to let the SESSION end and re-fires
#    to the block cap while the operator watches.
# ---------------------------------------------------------------------------
mutant can-block "g." scripts/hooks/turn-manifest.sh \
    'if [ "$RC" = "0" ] && [ -n "$OUT" ]; then
    printf '"'"'%s\n'"'"' "$OUT"
fi
exit 0' \
    'if [ "$RC" = "0" ] && [ -n "$OUT" ]; then
    printf '"'"'%s\n'"'"' "$OUT"
fi
exit 2' \
    "A manifest that can refuse a turn is a different, worse mechanism."

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '✓ %s/%s properties proven load-bearing.\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '✗ %s/%s proven, %s NOT load-bearing (removable with no test noticing).\n' \
    "$PASS" "$((PASS + FAIL))" "$FAIL" >&2
exit 1
