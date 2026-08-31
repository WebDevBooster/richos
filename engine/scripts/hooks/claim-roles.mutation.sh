#!/usr/bin/env bash
#
# claim-roles.mutation.sh — PROVES THE BARE-ROLE ARMS OF THE CLAIM GATE CAN FAIL.
#
# The bare-role check was added because a measured rule was proposed and the
# measurement said no. That makes its own tests exactly the kind that pass for
# free: almost every one asserts "it did NOT quietly wave something through",
# and a check that never runs satisfies that perfectly. This session already
# shipped one suite that was green over machinery which did not work at all.
#
# So: take the shipped source, remove ONE property at a time, and assert that
#   1. guard-unresolved-claims.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied.
#
# Run directly: scripts/hooks/claim-roles.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t claim-roles-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

mutant() { # <name> <expected-failing-case> <rel-file> <old> <new> <why>
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-unresolved-claims.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-unresolved-claims.py" \
       "$ENGINE_ROOT/scripts/hooks/guard-unresolved-claims.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/guard-unresolved-claims.test.sh" >"$dir/out.txt" 2>&1
    if [ "$?" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

P="scripts/hooks/guard-unresolved-claims.py"
S="scripts/hooks/guard-unresolved-claims.sh"

echo "=== the bare-role arms, proven load-bearing by removing them ==="

mutant no-role-block "y1." "$P" \
    '            if not ever:\n                undispatched_roles.append((role, span))' \
    '            if False:\n                undispatched_roles.append((role, span))' \
    "the one arm that blocks: a role named that was never dispatched at all."

mutant role-block-not-in-verdict "x." "$P" \
    'if (unresolved_names or unresolved_shas\n                               or undispatched_roles) else "pass",' \
    'if (unresolved_names or unresolved_shas) else "pass",' \
    "a violation recorded as a pass is a violation nobody will ever count."

mutant no-stale-report "y2." "$P" \
    '            elif live is not None and role not in live:' \
    '            elif False:' \
    "the half that sees the real failure; unmeasurable is not the same as unreported."

mutant liveness-always-true "y2." "$P" \
    '        if str(m.get("status") or "").lower() in TERMINAL_STATUS:\n            continue' \
    '        if False:\n            continue' \
    "a liveness set that never shrinks answers 'ever spawned' again, which is the question that misses it."

mutant live-role-still-reported "y3b." "$P" \
    '            elif live is not None and role not in live:' \
    '            elif live is not None:' \
    "reporting on a teammate that IS running is the noise that gets the whole gate muted."

mutant names-do-not-suppress "y4c." "$P" \
    'if names_evaluable and rclaims and not names and "Agent" not in turn_tools:' \
    'if names_evaluable and rclaims and "Agent" not in turn_tools:' \
    "a message that names an identifier belongs to the name check; two verdicts on one sentence is one too many."

mutant agent-call-does-not-suppress "y5." "$P" \
    'and "Agent" not in turn_tools:' \
    'and True:' \
    "a turn that actually dispatched has nothing to answer for."

mutant case-insensitive-roles "y6." "$P" \
    'rx = re.compile(r"(?<![A-Za-z0-9_-])(%s)(?![A-Za-z0-9_-])\s+%s" % (alt, PROGRESSIVE))' \
    'rx = re.compile(r"(?<![A-Za-z0-9_-])(%s)(?![A-Za-z0-9_-])\s+%s" % (alt, PROGRESSIVE), re.I)' \
    "lowercase matching turns 'the mark is fading' into a dispatch claim."

mutant no-progressive-requirement "y6b." "$P" \
    '% (alt, PROGRESSIVE))' \
    '% (alt, ""))' \
    "naming a teammate would become a claim that they are working right now."

mutant nameless-number-hidden "y7." "$P" \
    'lines.append("  ...and it named no agent identifier (10.3% precision -- also never enforced)")' \
    'pass' \
    "a rejected rule shipped without its number is a rule somebody promotes next month."

echo ""
echo "  $PASS mutant(s) killed, $FAIL survived or misfired"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
