#!/usr/bin/env bash
#
# root-contract.mutation.sh — PROVES THE TESTS CAN FAIL.
#
# "A negative test that passes for the wrong reason is this project's
# most-repeated defect." A suite of green ticks is evidence of nothing until
# somebody shows it turning red for the right reason. So this harness takes the
# shipped engine, MUTATES ONE FIX OUT OF IT AT A TIME — restoring, as exactly as
# a sed can, the pre-contract behavior — and asserts that:
#
#   1. the corresponding suite FAILS, and
#   2. the SPECIFIC named case fails (not merely "something went red"), and
#   3. the mutation actually applied (a sed that matched nothing would give a
#      green run that looked like a green run, which is the same trap again).
#
# Every mutant is a full copy of the engine in a throwaway sandbox. Nothing here
# touches the real tree.
#
# Run directly: scripts/hooks/root-contract.mutation.sh
# Exit 0 = every fix is proven load-bearing; exit 1 = at least one fix could be
# removed without any test noticing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t root-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PROVEN     %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  NOT PROVEN %s\n' "$1"; FAIL=$((FAIL + 1)); }

unset CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT

N=0

# mutate <label> <suite-relative-path> <expected-failing-case-substring> <mutator-fn>
#
# <mutator-fn> receives the mutant engine root as $1 and must return 0 only if
# it actually changed something.
mutate() {
    local label="$1" suite="$2" expect="$3" fn="$4"
    N=$((N + 1))
    local M="$SANDBOX/mutant-$N"
    cp -R "$SRC_ENGINE" "$M"

    if ! "$fn" "$M"; then
        bad "$label — THE MUTATION DID NOT APPLY (the anchor it edits has moved; this harness is no longer testing what it claims)"
        return
    fi

    local out rc
    out="$(bash "$M/$suite" 2>&1)"; rc=$?

    if [ "$rc" -eq 0 ]; then
        bad "$label — the suite still PASSED with the fix removed. The fix is not load-bearing, or nothing covers it."
        return
    fi
    if ! printf '%s' "$out" | grep -q "FAIL.*$expect"; then
        bad "$label — the suite failed, but NOT on '$expect'. It went red for some other reason, which is not proof."
        printf '%s\n' "$out" | grep '  FAIL' | sed 's/^/           /'
        return
    fi
    ok "$label — removing the fix turns '$expect' red"
}

# --- mutators --------------------------------------------------------------

# M1. The whole contract: make resolve_entity_root return the ENGINE root
# unconditionally — i.e. the pre-contract "SCRIPT_DIR/../.." answer.
m_engine_root_always() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/lib/resolve-roots.sh"
s = open(p).read()
old = '''    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && _rr_try "$CLAUDE_PROJECT_DIR" "project-dir"; then
        RICHOS_ROOT_STATUS="governed"; return 0
    fi'''
if old not in s:
    raise SystemExit(1)
new = '''    RICHOS_ENTITY_ROOT_RESOLVED="$engine_root"
    RICHOS_ROOT_STATUS="governed"
    RICHOS_ROOT_SOURCE="project-dir"
    return 0'''
open(p, "w").write(s.replace(old, new))
PY
}

# M2. The namespace split: put back the bare stat that a namespaced type can
# never match.
m_no_namespace_strip() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/lib/resolve-roots.sh"
s = open(p).read()
old = '''    bare="$(strip_agent_namespace "$stype")"'''
if old not in s:
    raise SystemExit(1)
open(p, "w").write(s.replace(old, '''    bare="$stype"'''))
PY
}

# M2b. The splitter itself. M2 proves the CONSUMER breaks; this proves the
# primitive is covered on its own, so a future refactor that keeps the consumer
# working by accident still cannot delete the split unnoticed.
m_strip_is_identity() {
    local M="$1"
    python3 - "$M" <<'PYEOF' || return 1
import sys
p = sys.argv[1] + "/scripts/lib/resolve-roots.sh"
s = open(p).read()
old = """    printf '%s' "${t##*:}"
}"""
if old not in s:
    raise SystemExit(1)
open(p, "w").write(s.replace(old, """    printf '%s' "$t"
}""", 1))
PYEOF
}

# M3. not-adopted quietly falls back to the engine root — the silent
# substitution that made a plugin-loaded engine govern the wrong repository.
m_notadopted_falls_back() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/lib/resolve-roots.sh"
s = open(p).read()
old = '''    RICHOS_ROOT_STATUS="not-adopted"
    RICHOS_ROOT_SOURCE=""'''
if old not in s:
    raise SystemExit(1)
new = '''    RICHOS_ENTITY_ROOT_RESOLVED="$engine_root"
    RICHOS_ROOT_STATUS="governed"
    RICHOS_ROOT_SOURCE="project-dir"
    return 0
    RICHOS_ROOT_STATUS="not-adopted"
    RICHOS_ROOT_SOURCE=""'''
open(p, "w").write(s.replace(old, new))
PY
}

# M4. An explicitly declared, non-adopted root falls through to the next
# candidate instead of failing — substituting a repository nobody named.
m_override_falls_through() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/lib/resolve-roots.sh"
s = open(p).read()
old = '''        RICHOS_ROOT_STATUS="broken"
        RICHOS_ROOT_SOURCE="env-override"'''
if old not in s:
    raise SystemExit(1)
new = '''        if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && _rr_try "$CLAUDE_PROJECT_DIR" "project-dir"; then
            RICHOS_ROOT_STATUS="governed"; return 0
        fi
        RICHOS_ROOT_STATUS="broken"
        RICHOS_ROOT_SOURCE="env-override"'''
open(p, "w").write(s.replace(old, new))
PY
}

# M5. The reaper's two roots collapse back into one variable.
m_reaper_single_root() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/session-start-reap-worktrees.sh"
s = open(p).read()
old = '''REAPER="$ENGINE_ROOT/scripts/reap-stale-worktrees.sh"'''
if old not in s:
    raise SystemExit(1)
new = '''REAPER="${RICHOS_ENTITY_ROOT:-$CLAUDE_PROJECT_DIR}/scripts/reap-stale-worktrees.sh"'''
open(p, "w").write(s.replace(old, new))
PY
}

# M6. The snapshotter's honest wording reverts to the one word that made a real
# failure read as routine.
m_snapshot_says_skipped() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/snapshot-agent-definitions.sh"
s = open(p).read()
old = '''    emit_context "agent-definition snapshot: not run — this repository has not adopted the engine (no orchestration.config at its root). No definitions are being tracked here."'''
if old not in s:
    raise SystemExit(1)
new = '''    emit_context "agent-definition snapshot: skipped — no $AGENTS_DIR directory (definition-drift guard will fail open)"'''
open(p, "w").write(s.replace(old, new))
PY
}

# M7. A BROKEN root stops blocking and quietly stands down instead — the exact
# "silent skip" the contract forbids, applied to the write guard.
m_broken_stands_down() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/guard-main-checkout-writes.sh"
s = open(p).read()
old = '''    root_failure_banner "scripts/hooks/guard-main-checkout-writes.sh" >&2
    exit 2'''
if old not in s:
    raise SystemExit(1)
open(p, "w").write(s.replace(old, '''    exit 0'''))
PY
}

# M8. The spawn guard's unresolvable-namespace refusal degrades back to
# "undeterminable -> accept".
m_unresolvable_accepted() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/guard-worktree-isolation.sh"
s = open(p).read()
old = '''    2) printf 'UNRESOLVABLE'; return 0 ;;'''
if old not in s:
    raise SystemExit(1)
open(p, "w").write(s.replace(old, '''    2) printf ''; return 0 ;;'''))
PY
}

# M9. engine-status.sh reports ACTIVE regardless — a defense that says it is on
# without checking. Named explicitly because it is the exact shape of all three
# incidents this contract answers.
m_status_always_active() {
    local M="$1"
    python3 - "$M" <<'PY' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/engine-status.sh"
s = open(p).read()
old = '''    not-adopted)'''
if old not in s:
    raise SystemExit(1)
new = '''    not-adopted)
        emit_context "RichOS engine ${VERSION} ACTIVE. Enforcement is ON for this repository."
        exit 0
        ;;
    never-taken-branch)'''
open(p, "w").write(s.replace(old, new, 1))
PY
}

# M10. Re-introduce the unconditional stdin read in the snapshotter — the hang
# I actually shipped and then caught. If case 9c cannot see it, the regression
# test is decoration.
m_snapshot_reads_stdin() {
    local M="$1"
    python3 - "$M" <<'PYEOF' || return 1
import sys
p = sys.argv[1] + "/scripts/hooks/snapshot-agent-definitions.sh"
s = open(p).read()
old = 'ROOT_FAILURE=""\nif resolve_entity_root ""; then'
if old not in s:
    raise SystemExit(1)
new = 'STDIN_JSON="$(cat 2>/dev/null || true)"\nROOT_FAILURE=""\nif resolve_entity_root "$STDIN_JSON"; then'
open(p, "w").write(s.replace(old, new, 1))
PYEOF
}

echo "=== mutation harness: is each fix load-bearing? ==="
echo ""

mutate "M1 root resolution -> always the engine root" \
       "scripts/hooks/root-contract.test.sh" "1a" m_engine_root_always
mutate "M2 resolve_agent_def stops stripping the namespace" \
       "scripts/lib/resolve-roots.test.sh" "8c" m_no_namespace_strip
mutate "M2b strip_agent_namespace becomes an identity function" \
       "scripts/lib/resolve-roots.test.sh" "8a" m_strip_is_identity
mutate "M3 not-adopted silently falls back to the engine root" \
       "scripts/lib/resolve-roots.test.sh" "4a" m_notadopted_falls_back
mutate "M4 a declared root falls through instead of failing" \
       "scripts/lib/resolve-roots.test.sh" "1c" m_override_falls_through
mutate "M5 reaper collapses its two roots into one" \
       "scripts/hooks/root-contract.test.sh" "6a" m_reaper_single_root
mutate "M6 snapshotter reverts to the ambiguous 'skipped'" \
       "scripts/hooks/root-contract.test.sh" "5b" m_snapshot_says_skipped
mutate "M7 a BROKEN root stands down instead of blocking" \
       "scripts/hooks/root-contract.test.sh" "1e" m_broken_stands_down
mutate "M8 an unresolvable namespace is accepted again" \
       "scripts/hooks/root-contract.test.sh" "3e" m_unresolvable_accepted
mutate "M9 engine-status reports ACTIVE without checking" \
       "scripts/hooks/root-contract.test.sh" "7b" m_status_always_active
mutate "M10 the snapshotter reads stdin unconditionally again (the 92s hang)" \
       "scripts/hooks/root-contract.test.sh" "9c" m_snapshot_reads_stdin

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== mutation harness: $FAIL fix(es) NOT PROVEN load-bearing, $PASS proven ==="
    exit 1
else
    echo "=== mutation harness: all $PASS fixes proven load-bearing ==="
    exit 0
fi
