#!/usr/bin/env bash
#
# demo.test.sh — smoke check for scripts/demo.sh. Runnable anywhere, with or
# without a CI runner (the engine also ships
# `.github/workflows/engine-self-verify.yml`, which invokes this suite): the
# at-minimum check is syntax-clean, and a real unattended invocation exits 0
# with all 7 beats reporting PASSED, and the engine repo is untouched by the run.
#
# Run directly: scripts/demo.test.sh
# Exit 0 = pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$SCRIPT_DIR/demo.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "=== demo.test.sh ==="

# --- bash -n on demo.sh itself ---
if bash -n "$DEMO" 2>/tmp/demo-syntax-err.$$; then
    ok "demo.sh: bash -n syntax check"
else
    bad "demo.sh: bash -n syntax check ($(cat /tmp/demo-syntax-err.$$))"
fi
rm -f /tmp/demo-syntax-err.$$

if [ ! -x "$DEMO" ]; then
    bad "demo.sh: not executable"
else
    ok "demo.sh: executable"
fi

# --- snapshot the engine repo's git status before running the demo ---
BEFORE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
# Snapshot the operator's global state BEFORE the demo runs, so the assertion
# below proves the demo left it alone rather than asserting that it meant to.
# Taken through scripts/lib/global-state-witness.sh — one definition of "what a
# run may not leave moved", shared with locate-engine.test.sh, rather than a
# second hand-rolled `readlink` that cannot tell a DELETED pointer from an
# unchanged one.
STATE_BEFORE=""
if [ -f "$REPO_ROOT/scripts/lib/global-state-witness.sh" ]; then
    # shellcheck source=./lib/global-state-witness.sh
    . "$REPO_ROOT/scripts/lib/global-state-witness.sh"
    STATE_BEFORE="$(richos_global_snapshot)"
fi

# --- a real, unattended invocation ---
DEMO_OUT="$("$DEMO" 2>&1)"
DEMO_RC=$?

if [ "$DEMO_RC" -eq 0 ]; then
    ok "demo.sh: exits 0 on a clean run"
else
    bad "demo.sh: expected exit 0, got $DEMO_RC"
fi

if printf '%s' "$DEMO_OUT" | grep -qE '7/7 beats passed'; then
    ok "demo.sh: reports 7/7 beats passed"
else
    bad "demo.sh: did not report 7/7 beats passed"
fi

# Every beat must report PASSED (no silently-skipped beat).
BEAT_PASS_COUNT="$(printf '%s' "$DEMO_OUT" | grep -c 'Beat [0-9] PASSED')"
if [ "$BEAT_PASS_COUNT" -eq 7 ]; then
    ok "demo.sh: exactly 7 individual 'Beat N PASSED' lines"
else
    bad "demo.sh: expected 7 'Beat N PASSED' lines, got $BEAT_PASS_COUNT"
fi

# Honest-labeling check: both label classes must appear (Frank's truth-in-
# labeling lesson applies to the demo itself — never silently drop the
# real-vs-simulated distinction).
if printf '%s' "$DEMO_OUT" | grep -qF '[REAL ENFORCEMENT]' && printf '%s' "$DEMO_OUT" | grep -qF '[NARRATED SIMULATION]'; then
    ok "demo.sh: labels both REAL ENFORCEMENT and NARRATED SIMULATION beats"
else
    bad "demo.sh: missing one of the REAL/SIMULATED labels"
fi

# --- engine repo must be untouched by the run ---
AFTER_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
if [ "$BEFORE_STATUS" = "$AFTER_STATUS" ]; then
    ok "demo.sh: engine repo git status unchanged by the run"
else
    bad "demo.sh: engine repo git status changed by the run (before != after)"
fi

# --- the OPERATOR's machine is untouched ---
# The demo runs the real install.sh, which mints an engine pointer into the
# operator's config dir. Before CLAUDE_CONFIG_DIR was redirected into the sample
# repo, the demo repointed a REAL pointer at its own temp directory and then
# deleted it, leaving a dangling symlink. "engine repo git status unchanged" did
# not notice, because the damage was outside the repository. A demo a buyer runs
# sight-unseen must leave nothing behind anywhere.
if [ -n "$STATE_BEFORE" ] && richos_global_verify "$STATE_BEFORE" 2>/dev/null; then
    ok "demo.sh: the operator's engine pointer and registration are unchanged by the run"
elif [ -z "$STATE_BEFORE" ]; then
    bad "demo.sh: the global-state witness is missing (scripts/lib/global-state-witness.sh)"
else
    bad "demo.sh: THE DEMO MUTATED THE OPERATOR'S GLOBAL STATE — $(richos_global_verify "$STATE_BEFORE" 2>&1 | tr '\n' ' ')"
fi

# --- no leftover temp dirs from this run ---
LEFTOVER="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'richos-engine-demo.*' 2>/dev/null || true)"
if [ -z "$LEFTOVER" ]; then
    ok "demo.sh: no leftover temp directories after exit"
else
    bad "demo.sh: leftover temp directories found: $LEFTOVER"
fi

# --- re-runnable: a second invocation also exits 0 ---
"$DEMO" >/dev/null 2>&1
RERUN_RC=$?
if [ "$RERUN_RC" -eq 0 ]; then
    ok "demo.sh: re-runnable (second invocation also exits 0)"
else
    bad "demo.sh: second invocation failed (rc=$RERUN_RC)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== demo.test.sh: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== demo.test.sh: all $PASS passed ==="
    exit 0
fi
