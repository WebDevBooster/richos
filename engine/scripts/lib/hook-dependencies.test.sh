#!/usr/bin/env bash
#
# hook-dependencies.test.sh — does the derivation see what a registered hook
#                              actually needs, and does it REFUSE when it has
#                              stopped seeing?
#
# Run directly: scripts/lib/hook-dependencies.test.sh
# Exit 0 = pass; exit 1 = at least one failure.
#
# ===========================================================================
# WHAT THESE CASES ARE FOR
# ===========================================================================
# The class under test is the one that killed scripts/demo.sh on 2026-09-14: a
# hook's DEPENDENCY is not a hook, so no inventory derived from hooks/hooks.json
# can enumerate it, and the two places that assemble a throwaway copy of this
# engine were enumerating it BY HAND.
#
# Cases 1-3 are the regression, stated against the live engine. Cases 4-6 are
# the CLASS, stated against a fixture engine the derivation has never seen — a
# case that only knows today's filenames would go green the day the derivation
# stopped working on anything else.
#
# Case 7 is the negative control and it is not optional. This library reports a
# problem by printing a SHORTER LIST, which is the same output a deriver that
# has stopped matching produces — the exact objection
# scripts/lib/sandbox-completeness.sh raised when it rejected deriving a copy
# list. The anchor is the answer to that objection, so the anchor is the thing
# that has to be shown FIRING, not merely shown installed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREDICATE="$SCRIPT_DIR/hook-dependencies.py"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "=== hook-dependencies.test.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-deps-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The live engine's closure, taken once.
# ---------------------------------------------------------------------------
LIVE_RC=0
LIVE="$(python3 "$PREDICATE" "$ENGINE_ROOT" 2>"$TMP/live.err")" || LIVE_RC=$?

if [ "$LIVE_RC" -eq 0 ] && [ -n "$LIVE" ]; then
    ok "0  the live engine derives a non-empty closure (rc 0)"
else
    bad "0  the live engine derives a non-empty closure (rc $LIVE_RC): $(head -2 "$TMP/live.err" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 1 — THE REGRESSION. scripts/hook-registration-completeness.sh is the file
# whose absence killed demo.sh. It is sourced by a registered hook and is not
# itself a registered hook, so it is precisely what no hooks.json-derived
# inventory can name.
# ---------------------------------------------------------------------------
if printf '%s\n' "$LIVE" | grep -qx 'scripts/hook-registration-completeness\.sh'; then
    ok "1  names the helper whose absence killed demo.sh (2026-09-14)"
else
    bad "1  scripts/hook-registration-completeness.sh is NOT in the closure"
fi

# ---------------------------------------------------------------------------
# 2 — THE SOFT HALF, which is the harder half and the one nothing else catches.
# 18 Stop hooks do `[ -f "$_SHN_LIB" ] || exit 0` against stop-hook-notice.sh
# and 36 hooks guard unevaluated-notice.sh the same way. A sandbox missing
# either starts every hook, passes a can-it-START check, and enforces nothing.
# ---------------------------------------------------------------------------
for soft in scripts/lib/stop-hook-notice.sh scripts/lib/unevaluated-notice.sh; do
    if printf '%s\n' "$LIVE" | grep -qxF "$soft"; then
        ok "2  names the SOFT dependency $soft"
    else
        bad "2  $soft is NOT in the closure — a hook that fails soft without it"
    fi
done

# ---------------------------------------------------------------------------
# 3 — THE FALSE-POSITIVE CLASS, measured not feared. This engine's hooks name
# other scripts inside their refusal text on purpose. scripts/ceo-asks-status.sh
# appears in session-start-ceo-ask.sh only that way — including once in single
# quotes INSIDE a double-quoted sentence, which a regex reads as a perfect token
# and a shell reads as literal text. A check that demanded it would be demanding
# an edit nobody owes.
# ---------------------------------------------------------------------------
if printf '%s\n' "$LIVE" | grep -qx 'scripts/ceo-asks-status\.sh'; then
    bad "3  a path named only in refusal PROSE was counted as a dependency"
else
    ok "3  a path named only in refusal prose is NOT a dependency"
fi

# ---------------------------------------------------------------------------
# A fixture engine: the smallest tree this predicate will speak about.
# ---------------------------------------------------------------------------
make_fixture() { # <root>
    local root="$1"
    mkdir -p "$root/hooks" "$root/scripts/hooks" "$root/scripts/lib"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$root/scripts/lib/"
    cat >"$root/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command",
                     "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-fixture.sh" } ] }
    ]
  }
}
JSON
    cat >"$root/scripts/hooks/guard-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"
_FIX_LIB="$SCRIPT_DIR/../lib/fixture-predicate.sh"
[ -f "$_FIX_LIB" ] || exit 0
. "$_FIX_LIB"
echo "To fix this, run scripts/fixture-advice.sh by hand."
exit 0
SH
    cat >"$root/scripts/lib/fixture-predicate.sh" <<'SH'
#!/usr/bin/env bash
_FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$_FIX_DIR/fixture-predicate.py" "$@"
SH
    printf '#!/usr/bin/env python3\nprint("fixture")\n' >"$root/scripts/lib/fixture-predicate.py"
    printf '#!/usr/bin/env bash\necho advice\n' >"$root/scripts/fixture-advice.sh"
}

FIX="$TMP/fixture"
make_fixture "$FIX"
FIX_RC=0
FIX_OUT="$(python3 "$PREDICATE" "$FIX" 2>"$TMP/fix.err")" || FIX_RC=$?

# ---------------------------------------------------------------------------
# 4 — THE CLASS, on a hook this predicate has never seen: a dependency sourced
# by a newly registered hook is in the closure, with no edit anywhere.
# ---------------------------------------------------------------------------
if [ "$FIX_RC" -eq 0 ] && printf '%s\n' "$FIX_OUT" | grep -qx 'scripts/lib/fixture-predicate\.sh'; then
    ok "4  a NEW hook's sourced dependency is derived with no list edited"
else
    bad "4  the new hook's dependency was not derived (rc $FIX_RC): [$FIX_OUT]"
fi

# ---------------------------------------------------------------------------
# 5 — TRANSITIVITY. The dependency's own sibling .py half is reached too. This
# is the shape the whole engine uses (ceo-todos.sh/.py, escalations.sh/.py); a
# closure that stopped at depth one would carry a library that cannot run.
# ---------------------------------------------------------------------------
if printf '%s\n' "$FIX_OUT" | grep -qx 'scripts/lib/fixture-predicate\.py'; then
    ok "5  the dependency's own sibling half is reached (transitive)"
else
    bad "5  transitive dependency scripts/lib/fixture-predicate.py was not derived"
fi

# ---------------------------------------------------------------------------
# 6 — and the advice path in the SAME fixture hook is still not a dependency.
# Stated on the fixture as well as the live engine, because case 3 could pass
# for the accidental reason that one file changed its wording.
# ---------------------------------------------------------------------------
if printf '%s\n' "$FIX_OUT" | grep -qx 'scripts/fixture-advice\.sh'; then
    bad "6  the fixture's advice path was counted as a dependency"
else
    ok "6  the fixture's advice path is NOT a dependency"
fi

# ---------------------------------------------------------------------------
# 7 — NEGATIVE CONTROL: THE ANCHOR FIRES. The fixture hook keeps calling
# resolve_engine_root() — so it demonstrably needs resolve-roots.sh — but now
# reaches the file through a form no token scan can read. That is precisely
# "the deriver stopped matching", and the required answer is rc 4 with NOTHING
# on stdout. A shorter list here would be indistinguishable from a correct one,
# which is the objection this library exists to answer.
# ---------------------------------------------------------------------------
BLIND="$TMP/blind"
make_fixture "$BLIND"
cat >"$BLIND/scripts/hooks/guard-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-""roots.sh"
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"
exit 0
SH
BLIND_RC=0
BLIND_OUT="$(python3 "$PREDICATE" "$BLIND" 2>"$TMP/blind.err")" || BLIND_RC=$?

if [ "$BLIND_RC" -eq 4 ]; then
    ok "7  a deriver that has gone blind returns rc 4 (ANCHOR FAILED)"
else
    bad "7  expected rc 4 from the anchor, got $BLIND_RC"
fi
if [ -z "$BLIND_OUT" ]; then
    ok "7b the blinded deriver prints NOTHING, not a shorter list"
else
    bad "7b the blinded deriver still printed a list: [$BLIND_OUT]"
fi
if grep -q 'ANCHOR FAILED' "$TMP/blind.err"; then
    ok "7c the refusal says ANCHOR FAILED and names the hook"
else
    bad "7c the refusal did not say ANCHOR FAILED: [$(head -1 "$TMP/blind.err")]"
fi

# ---------------------------------------------------------------------------
# 8 — THE CONSUMER CONTRACT. demo.sh must PROVISION the closure, not merely be
# able to compute it. Asserted against the script rather than by running it
# (demo.test.sh runs it), because the failure being prevented is a wiring that
# gets removed, and a wiring that is gone is a grep away from being seen.
# ---------------------------------------------------------------------------
if grep -q 'richos_hook_dependency_closure' "$ENGINE_ROOT/scripts/demo.sh"; then
    ok "8  demo.sh provisions the derived closure"
else
    bad "8  demo.sh no longer calls richos_hook_dependency_closure"
fi

# ---------------------------------------------------------------------------
# 9 — THE WRAPPER. The shell entry point callers actually source.
# ---------------------------------------------------------------------------
WRAP_RC=0
# shellcheck source=./hook-dependencies.sh
. "$SCRIPT_DIR/hook-dependencies.sh"
WRAP_OUT="$(richos_hook_dependency_closure "$ENGINE_ROOT")" || WRAP_RC=$?
if [ "$WRAP_RC" -eq 0 ] && [ "$(printf '%s\n' "$WRAP_OUT" | LC_ALL=C sort)" = "$(printf '%s\n' "$LIVE" | LC_ALL=C sort)" ]; then
    ok "9  the wrapper returns exactly what the predicate returns"
else
    bad "9  wrapper/predicate disagree (rc $WRAP_RC)"
fi
if richos_hook_dependency_closure "$TMP/not-an-engine" >/dev/null 2>&1; then
    bad "9b the wrapper answered for a directory that is not an engine"
else
    ok "9b the wrapper refuses a directory that registers no hooks"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "=== hook-dependencies.test.sh: all $PASS passed ==="
    exit 0
fi
echo "=== hook-dependencies.test.sh: $PASS passed, $FAIL FAILED ==="
exit 1
