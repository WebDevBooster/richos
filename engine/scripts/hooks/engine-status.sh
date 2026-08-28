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
# So this hook runs at every session start and emits:
#
#   * which ENGINE is loaded, and from where
#   * which REPOSITORY it resolved as the one it governs, and via which candidate
#   * whether enforcement is ACTIVE, STOOD DOWN, or BROKEN
#   * the count of guards that will actually run
#
# TWO CHANNELS, AND WHY BOTH ARE NEEDED
# =====================================
# `hookSpecificOutput.additionalContext` reaches the MODEL. It does not reach
# the human. That distinction is not academic: on 2026-08-28 an operator ran a
# real session in an adopted repository, looked at its stdout and stderr, saw no
# engine banner anywhere, and concluded the engine was not loaded. It was
# loaded, and enforcement was on — the announcement had gone somewhere only the
# model could see. "Firing silently" and "not firing" were indistinguishable to
# the one person who needed to tell them apart, which is the exact failure class
# this hook exists to remove, reproduced by the hook itself.
#
# So every status is now emitted on BOTH channels:
#
#   systemMessage                        -> the OPERATOR (Claude Code renders it
#                                           in the UI; the host's own hook schema
#                                           documents it as "Display a message to
#                                           the user (all hooks)")
#   hookSpecificOutput.additionalContext -> the MODEL
#
# The operator line is deliberately emitted for the STOOD-DOWN status too, even
# though the plugin is enabled at USER scope and therefore loads in every
# directory on the machine. One short line per session in an unadopted directory
# is the price of the guarantee, and the guarantee is the whole point: nobody
# can be unguarded without being told. There is deliberately no quiet switch —
# a mute for "this repo is not protected" is the silent skip walking back in
# through the door marked configuration.
#
# It never blocks (SessionStart hooks must not), but a BROKEN status is
# unmissable: it goes to stderr AND to the operator AND into the model's context
# AND names every candidate that was examined.
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

# NOTE ON STDIN — this hook does NOT read the payload.
#
# It is a SessionStart hook AND a plain CLI tool, and in the CLI case stdin is
# an inherited pipe that nobody closes, so an unconditional `cat` hangs forever
# (`[ ! -t 0 ]` does not help: an inherited pipe is not a TTY). Measured: 92
# seconds and counting, inside the contract-integrity probe, before this was
# reverted.
#
# It costs nothing, because the payload's `cwd` is a REDUNDANT resolution
# candidate here: CLAUDE_PROJECT_DIR is measured present and correct in a
# plugin-loaded hook's environment at SessionStart (probe, 2026-08-28), and it
# outranks the payload cwd anyway. Paying a hang risk for a candidate that
# never wins is a bad trade.

# emit_context <model-summary> <operator-line>
#
# ONE call, TWO audiences. The operator line is a short verdict a human reads at
# a glance; the model summary is the full detail. Both are always emitted — a
# call site that supplied only one would recreate the invisible-announcement
# defect for whichever audience it left out, so the operator line is a REQUIRED
# positional argument rather than an option.
emit_context() { # <model-summary> <operator-line>
    local summary="$1"
    local sysmsg="$2"
    if command -v python3 >/dev/null 2>&1; then
        SUMMARY="$summary" SYSMSG="$sysmsg" python3 - <<'PY' 2>/dev/null || true
import json, os
print(json.dumps({
    "systemMessage": os.environ.get("SYSMSG", ""),
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("SUMMARY", ""),
    }
}))
PY
    else
        # No python3: hand-escape. Both channels still carry a value — the
        # fallback path is exactly where a quietly-dropped field would never be
        # noticed.
        local escaped="${summary//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        local escaped_msg="${sysmsg//\\/\\\\}"
        escaped_msg="${escaped_msg//\"/\\\"}"
        printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped_msg" "$escaped"
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

resolve_entity_root ""
RC=$?

case "$RICHOS_ROOT_STATUS" in
    governed)
        emit_context \
            "RichOS engine ${VERSION} ACTIVE. Engine: ${ENGINE_ROOT}. Governing: ${RICHOS_ENTITY_ROOT_RESOLVED} (resolved via ${RICHOS_ROOT_SOURCE}). ${GUARD_COUNT}/13 guards present. Enforcement is ON for this repository." \
            "RichOS engine ${VERSION}: ENFORCEMENT ACTIVE for ${RICHOS_ENTITY_ROOT_RESOLVED} (${GUARD_COUNT}/13 guards, engine at ${ENGINE_ROOT}, root via ${RICHOS_ROOT_SOURCE})."
        ;;
    engine-self)
        emit_context \
            "RichOS engine ${VERSION} ACTIVE — governing ITSELF. Engine: ${ENGINE_ROOT}. Governing: ${RICHOS_ENTITY_ROOT_RESOLVED}. ${GUARD_COUNT}/13 guards present. NOTE: no repository in this session's candidate chain carries orchestration.config, so the guards are acting on the engine's own tree rather than on the session's project directory. That is correct when you are developing the engine and wrong for anything else." \
            "RichOS engine ${VERSION}: ENFORCEMENT ACTIVE, governing ITSELF at ${ENGINE_ROOT} (${GUARD_COUNT}/13 guards). No repository in this session's candidate chain carries orchestration.config — right when you are developing the engine, wrong for anything else."
        ;;
    not-adopted)
        # Loud enough to be seen, calm enough not to be noise: this is the
        # normal state in every repository that has not adopted the engine, and
        # the engine loads in all of them.
        emit_context \
            "RichOS engine ${VERSION} loaded but STOOD DOWN — this repository has NOT adopted it. Engine: ${ENGINE_ROOT}. No orchestration.config was found at any candidate root, so NONE of the ${GUARD_COUNT} guards will enforce anything in this session: no worktree-isolation contract, no main-checkout write protection, no secret scanning, no definition-drift check. This is a stand-down, not a pass. To adopt, commit an orchestration.config at this repository's root." \
            "RichOS engine ${VERSION}: STOOD DOWN — this repository has not adopted the engine, so NONE of its ${GUARD_COUNT} guards will enforce anything in this session. This is a stand-down, not a pass. To adopt, commit an orchestration.config at the repository root."
        ;;
    *)
        BANNER="$(root_failure_banner "scripts/hooks/engine-status.sh")"
        printf '%s\n' "$BANNER" >&2
        emit_context \
            "RichOS engine ${VERSION}: ROOT RESOLUTION FAILURE — ENFORCEMENT IS NOT ACTIVE. ${RICHOS_ROOT_REASON} Every guard in this session will refuse rather than guess. Fix the root declaration before doing any work that depends on enforcement." \
            "RichOS engine ${VERSION}: ROOT RESOLUTION FAILURE — ENFORCEMENT IS NOT ACTIVE. ${RICHOS_ROOT_REASON} Every guard in this session will refuse rather than guess."
        ;;
esac

exit 0
