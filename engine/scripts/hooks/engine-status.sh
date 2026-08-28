#!/usr/bin/env bash
#
# engine-status.sh — SessionStart hook. THE ANSWER TO "IS THIS DEFENCE ON?"
#
# WHY THIS HOOK EXISTS
# ====================
# This operation has been burned three times by defences that reported ON while
# missing a whole failure class. The common shape is not "the guard was wrong";
# it is "nobody could tell the guard was doing nothing". A silent skip is worse
# than no guard at all, because it buys false confidence.
#
# The cure is not "block everything you cannot resolve" — applied literally that
# would brick every session in every directory on the machine, since the engine
# plugin is enabled at USER scope and therefore loads in EVERY project. The cure
# is that the defence must ALWAYS STATE WHETHER IT IS ON, in a place nobody has
# to go looking for.
#
# So this hook runs at every session start and emits, into the orchestrator's
# own context via SessionStart additionalContext:
#
#   * which ENGINE is loaded, and from where
#   * which REPOSITORY it resolved as the one it governs, and via which candidate
#   * whether enforcement is ACTIVE, STOOD DOWN, or BROKEN
#   * the count of guards that will actually run
#
# It never blocks (SessionStart hooks must not), but a BROKEN status is
# unmissable: it goes to stderr AND into the model's context AND names every
# candidate that was examined.
#
# LOG-ONLY / NEVER BLOCKS: always exits 0.

set -o pipefail

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
        echo "  hook: scripts/hooks/engine-status.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

PAYLOAD="$(cat 2>/dev/null || true)"

emit_context() { # <summary>
    local summary="$1"
    if command -v python3 >/dev/null 2>&1; then
        SUMMARY="$summary" python3 - <<'PY' 2>/dev/null || true
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("SUMMARY", ""),
    }
}))
PY
    else
        local escaped="${summary//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped"
    fi
}

VERSION="unknown"
[ -f "$ENGINE_ROOT/VERSION" ] && VERSION="$(awk 'NR==1 {gsub(/[[:space:]]/,""); print; exit}' "$ENGINE_ROOT/VERSION" 2>/dev/null || echo unknown)"

# How many guards are actually on disk and executable? A count is not proof of
# wiring — contract-integrity-probe.sh owns that — but a count that has fallen
# is a cheap, visible signal that something is missing.
GUARD_COUNT=0
for g in guard-worktree-isolation guard-definition-drift reader-teammate-hint \
         verify-agent-prompt guard-main-checkout-writes scan-secrets \
         guard-resume-isolation guard-bash-main-writes detect-nonnative-worktree \
         session-start-reap-worktrees snapshot-agent-definitions \
         teammate-idle-handoff task-completed-handoff; do
    [ -x "$ENGINE_ROOT/scripts/hooks/$g.sh" ] && GUARD_COUNT=$((GUARD_COUNT + 1))
done

resolve_entity_root "$PAYLOAD"
RC=$?

case "$RICHOS_ROOT_STATUS" in
    governed)
        emit_context "RichOS engine ${VERSION} ACTIVE. Engine: ${ENGINE_ROOT}. Governing: ${RICHOS_ENTITY_ROOT_RESOLVED} (resolved via ${RICHOS_ROOT_SOURCE}). ${GUARD_COUNT}/13 guards present. Enforcement is ON for this repository."
        ;;
    engine-self)
        emit_context "RichOS engine ${VERSION} ACTIVE — governing ITSELF. Engine: ${ENGINE_ROOT}. Governing: ${RICHOS_ENTITY_ROOT_RESOLVED}. ${GUARD_COUNT}/13 guards present. NOTE: no repository in this session's candidate chain carries orchestration.config, so the guards are acting on the engine's own tree rather than on the session's project directory. That is correct when you are developing the engine and wrong for anything else."
        ;;
    not-adopted)
        # Loud enough to be seen, calm enough not to be noise: this is the
        # normal state in every repository that has not adopted the engine, and
        # the engine loads in all of them.
        emit_context "RichOS engine ${VERSION} loaded but STOOD DOWN — this repository has NOT adopted it. Engine: ${ENGINE_ROOT}. No orchestration.config was found at any candidate root, so NONE of the ${GUARD_COUNT} guards will enforce anything in this session: no worktree-isolation contract, no main-checkout write protection, no secret scanning, no definition-drift check. This is a stand-down, not a pass. To adopt, commit an orchestration.config at this repository's root."
        ;;
    *)
        BANNER="$(root_failure_banner "scripts/hooks/engine-status.sh")"
        printf '%s\n' "$BANNER" >&2
        emit_context "RichOS engine ${VERSION}: ROOT RESOLUTION FAILURE — ENFORCEMENT IS NOT ACTIVE. ${RICHOS_ROOT_REASON} Every guard in this session will refuse rather than guess. Fix the root declaration before doing any work that depends on enforcement."
        ;;
esac

exit 0
