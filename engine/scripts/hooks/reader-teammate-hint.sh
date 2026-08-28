#!/usr/bin/env bash
#
# reader-teammate-hint.sh — PreToolUse guard (Agent).
#
# Routes READING/INGEST work to the right teammate. When a spawn is a
# full-read / ingest / enumerate-from-sources task but is handed to a GENERIC
# search agent (Explore, Plan, general-purpose, claude) instead of the reading
# specialist (READER_TEAMMATE in orchestration.config — ships as `reed`), this
# BLOCKS the spawn and says so.
#
# Why: Explore reads *excerpts*, so it locates code but can silently MISS
# things on a "read all of this / enumerate every screen" task — an
# incomplete result that bites later. The reading specialist reads sources IN
# FULL and always writes a cited, committed brief (and never idles without an
# artifact). Plan/general-purpose/claude are not reading specialists either.
#
# Scope (fail-narrow — only nudges when it's clearly a reading job on a
# generic agent): triggers only when BOTH (a) subagent_type is a generic
# search/utility type, AND (b) the prompt carries a strong full-read/ingest/
# enumerate signal. A quick single-file "locate" Explore (no full-read
# wording) passes untouched; a build agent that happens to read passes
# untouched; a reader-specialist spawn passes untouched.
#
# Wired in the PreToolUse[Agent] chain BEFORE verify-agent-prompt.sh — this
# hint fires first so a misrouted reading task gets redirected before the
# stricter spawn-content gate runs.

set -eo pipefail

# Fail-closed, not fail-open: this hint's SUBAGENT_TYPE/PROMPT extraction below
# depends on python3. If python3 is missing, the swallowed `|| true` failure
# yields an empty parse, which reads as "not an Agent spawn" and the hint
# silently never fires — a misrouted full-read task would sail through with
# no redirect and no diagnostic. Refuse loudly instead. (This hook is the
# first in the PreToolUse[Agent] chain, wired ahead of guard-worktree-
# isolation.sh and verify-agent-prompt.sh, and shares their JSON-parsing
# dependency.)
command -v python3 >/dev/null 2>&1 || { echo "ERROR: reader-teammate-hint.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/reader-teammate-hint.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

# Read the payload BEFORE resolving, so the payload's `cwd` is available as a
# resolution candidate.
INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, three different behaviours —
# see the contract for why "block everything unresolvable" is NOT the rule.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # This repository never adopted the engine, so there is no enforcement to
    # lose here. Stand down. NOT a silent skip: engine-status.sh announces the
    # stand-down into the orchestrator's own context at every session start.
    exit 0
else
    # BROKEN: this guard believes it is governing something and cannot. Block.
    root_failure_banner "scripts/hooks/reader-teammate-hint.sh" >&2
    exit 2
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${READER_TEAMMATE:=reed}"
: "${READER_SIGNAL_SOURCE_DIRS:=src docs}"

# (payload already read above, before root resolution)

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    st = str(ti.get("subagent_type","") or "")
    pr = str(ti.get("prompt","") or "")
    # tab-separate; strip tabs/newlines from the prompt so the split stays clean
    print("%s\t%s" % (st, pr.replace("\t"," ").replace("\n"," ")))
except Exception:
    print("\t")
' 2>/dev/null || printf '\t')"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f1)"
PROMPT="$(printf '%s' "$PARSED" | cut -f2-)"

# Never nudge the reader specialist itself.
[ "$SUBAGENT_TYPE" = "$READER_TEAMMATE" ] && exit 0

# Only nudge the GENERIC search/utility agents — never a build specialist that
# merely reads as part of its job.
case "$SUBAGENT_TYPE" in
  Explore|Plan|general-purpose|claude|"") ;;
  *) exit 0 ;;
esac

# Build the source-dir alternation for the enumerate/catalog clauses from
# config (replaces the old hardcoded literal).
SRC_ALT="wiki|docs|source|codebase"
for d in $READER_SIGNAL_SOURCE_DIRS; do
  SRC_ALT="$SRC_ALT|$d"
done

# Strong full-read / ingest / enumerate-from-sources signals.
READ_SIGNAL="in full|read all of|\\bingest\\b|read the full|end[ -]to[ -]end|read (these|the following|the)[^.]*(pages|documents|docs|files|sources|wiki|adrs?)|enumerat[a-z]*[^.]*(from|across|by reading)[^.]*($SRC_ALT)|catalog[a-z]*[^.]*(from|across)[^.]*($SRC_ALT)"

if printf '%s' "$PROMPT" | grep -qiE "$READ_SIGNAL"; then
  {
    echo "=== Reader-teammate hint: use \`$READER_TEAMMATE\`, not '${SUBAGENT_TYPE:-<unset/general-purpose>}' ==="
    echo "  This reads like a FULL-READ / ingest / enumerate-from-sources task."
    echo "  - '${SUBAGENT_TYPE:-general-purpose}' reads excerpts (Explore) or isn't a reading specialist —"
    echo "    it can silently MISS material on a 'read all of this' job."
    echo "  - \`$READER_TEAMMATE\` reads sources IN FULL and always writes a cited, committed brief."
    echo "  Re-spawn with subagent_type: \"$READER_TEAMMATE\" and isolation: \"worktree\" (it commits its brief)."
    echo "  If this is genuinely a quick single-file LOCATE (not a full read), rephrase the"
    echo "  prompt without the full-read wording and it will pass."
    echo "(hook: scripts/hooks/reader-teammate-hint.sh)"
  } >&2
  exit 2
fi

exit 0
