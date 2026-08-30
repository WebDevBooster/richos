#!/usr/bin/env bash
#
# guard-idle-land.sh — BLOCKING Stop hook. Refuses to let a turn end when the
# session LANDED work and STARTED NOTHING.
#
# THE FAILURE, PRECISELY
#   The orchestrator's working record opens by stating its own rule: a land
#   ends by STARTING the top unblocked item, then reports — not the other way
#   round; the only permitted stop is an item whose next action needs a
#   decision only the CEO can make. That rule was written by the orchestrator.
#   The orchestrator then landed four branches across two repositories, wrote a
#   long report, and ended the turn with an empty dispatch queue and seven
#   unblocked rows still in the file. The operator had to ask "why has
#   everything stopped again" — for the seventh time in two days.
#
#   Every previous answer to that question was a document. This engine has
#   catalogued the same defect a dozen times in a week under one sentence:
#
#       A RULE ENFORCED BY ATTENTION LASTS EXACTLY AS LONG AS THE ATTENTION.
#
#   So the answer here is the answer everywhere else in this engine — a
#   chokepoint that fires whether or not anybody remembers it. Stop is the
#   chokepoint, and guard-unresolved-claims.sh already established, against the
#   shipping binary rather than against documentation, that Stop can block, that
#   the payload carries `transcript_path` / `prompt_id` / `stop_hook_active` /
#   `background_tasks`, and that the turn's tool traffic is readable there.
#   This hook is built on that finding and follows all of its conventions.
#
# THE PREDICATE — four terms, all four required, none of them read from prose
#   1. this turn LANDED something   a `git merge`/`git push` in the turn's own
#                                   tool traffic whose EFFECT is confirmed
#                                   against the repository by identity
#   2. nothing was STARTED          no `Agent` call this turn, scoped to
#                                   promptId
#   3. there IS something to start  an unblocked row DERIVED from the record's
#                                   `## Next` table — never a typed count
#   4. nothing is still RUNNING     `background_tasks` from the payload
#
#   The derivation, the conservatism rules and the honest list of what none of
#   this can see are in the module docstring of guard-idle-land.py, which is the
#   analysis half. READ THAT FILE; this one is the wiring.
#
# NO LIVE OVERRIDE TOKEN
#   Deliberately. The escape is legitimate and already exists: move the row into
#   the CEO's record, which is a committed, diffable act. An in-the-moment token
#   would be reached for at exactly the moment this gate is doing its job — the
#   argument guard-row-currency-commits.sh makes about "I will update the row
#   after the deploy", applied unchanged. The standing-down key below is in
#   `orchestration.config`, which is also committed and also diffable.
#
# FAIL-OPEN, LIKE ITS SIBLING AND FOR ITS REASON
#   Every other blocking guard in this engine fails CLOSED. The two Stop guards
#   do not. A PreToolUse guard that fails closed refuses one tool call; a Stop
#   guard that fails closed refuses to let the SESSION END, re-firing on every
#   retry until the binary's block cap gives up while the operator watches a
#   wedged session. So a broken install, an unparseable payload, a missing
#   python3, an unreadable or unparsable record — all let the turn end, and the
#   ones worth knowing about SAY SO on stderr rather than dying quietly.
#
# WHEN IT TAKES EFFECT
#   Hooks snapshot at session start. Installing this changes nothing in the
#   session that installs it; it begins enforcing in the NEXT session.
#
# Exit codes (Claude Code Stop convention):
#   0  did not land, dispatched something, nothing to start, not evaluable, or
#      anything went wrong
#   2  BLOCKED — landed, started nothing, and the record has an unblocked row
#
# Self-test:  scripts/hooks/guard-idle-land.sh --self-test

set -eo pipefail

HOOK_TAG="(hook: scripts/hooks/guard-idle-land.sh)"

# --- self-test dispatch ---------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/guard-idle-land.test.sh"
fi

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
        echo "  hook: scripts/hooks/guard-idle-land.sh"
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

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes — but unlike a PreToolUse
# guard, ALL THREE let the turn end. See "FAIL-OPEN" above.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/guard-idle-land.sh" >&2
    exit 0
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CHECK_IDLE_LAND:=1}"
# The record and its section. Defaults name the file the orchestrator's own
# rule lives in; an adopter whose backlog is named something else says so here
# rather than being silently ungoverned.
: "${IDLE_LAND_RECORD:=RICH-TODOs.md}"
: "${IDLE_LAND_SECTION:=Next}"
# 1 = block the turn, 0 = report on stderr and let it end. Report-only exists so
# a repository whose backlog shape has not been measured yet can run the gate
# and read its own numbers before arming it.
: "${IDLE_LAND_ENFORCE:=1}"

if [ "$CHECK_IDLE_LAND" = "0" ]; then
    # Never a silent permission: an opt-out that cannot be seen is a defence
    # that decays into a rumour.
    echo "idle-land gate STOOD DOWN by CHECK_IDLE_LAND=0 in $CONFIG $HOOK_TAG" >&2
    exit 0
fi

# python3 is the analysis half's only dependency. Absent, the turn ends — this
# guard never turns a missing interpreter into an unendable session.
if ! command -v python3 >/dev/null 2>&1; then
    echo "idle-land gate SKIPPED: python3 not on PATH $HOOK_TAG" >&2
    exit 0
fi

ANALYZER="$SCRIPT_DIR/guard-idle-land.py"
if [ ! -f "$ANALYZER" ]; then
    echo "idle-land gate SKIPPED: analyzer missing at $ANALYZER $HOOK_TAG" >&2
    exit 0
fi

set +e
printf '%s' "$INPUT" | RICHOS_IDLE_ENTITY_ROOT="$ENTITY_ROOT" \
    RICHOS_IDLE_RECORD="$IDLE_LAND_RECORD" \
    RICHOS_IDLE_SECTION="$IDLE_LAND_SECTION" \
    RICHOS_IDLE_ENFORCE="$IDLE_LAND_ENFORCE" \
    python3 "$ANALYZER"
RC=$?
set -e

# Only 2 is a block. Anything else — including a crash in the analyzer — lets
# the turn end.
[ "$RC" = "2" ] && exit 2
exit 0
