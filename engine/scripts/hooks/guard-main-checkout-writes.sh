#!/usr/bin/env bash
#
# guard-main-checkout-writes.sh — PreToolUse guard (Write|Edit|MultiEdit|NotebookEdit).
#
# Blocks edits to SOURCE in the MAIN checkout. All implementation work must
# happen in an isolated git worktree (native Agent `isolation: "worktree"`, or
# a manual worktree under .claude/worktrees/); the orchestrator only ever
# MERGES source into main via git and edits docs/config there. So a Write/Edit
# targeting one of the protected source trees in the main checkout is almost
# always an agent that drifted into the shared checkout by mistake — the #1
# isolation failure class this hook exists to catch AT THE MOMENT of the write.
#
# The protected trees are project-specific and read from orchestration.config
# (PROTECTED_PATHS). ALLOWED (exit 0): anything under a worktree
# (…/.claude/worktrees/…), plus docs/config in main (CLAUDE.md, .claude/**,
# scripts/**, docs/**, team/**, skills/** …). BLOCKED (exit 2): writes to
# "<main>/<protected-prefix>/**".
#
# REPO_ROOT is resolved from THIS script's own location, and settings.json
# wires the hook by absolute path to the MAIN checkout's copy — so REPO_ROOT is
# always the main checkout, regardless of which session triggered the write.

set -eo pipefail

# Fail-closed, not fail-open: TOOL_NAME and FILE_PATH below are both extracted
# via `python3 ... || true`. If python3 is missing, that swallowed failure
# yields an empty TOOL_NAME/FILE_PATH, which every downstream check below reads
# as "not a guardable write" — i.e. this guard would let EVERY write through,
# including one targeting a protected source tree. Refuse outright instead.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-main-checkout-writes.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-main-checkout-writes.sh"
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

# --- JURISDICTION ----------------------------------------------------------
# Deliberately BELOW the root-resolution bootstrap, never inside it: Layer R of
# contract-integrity-probe.sh extracts that block verbatim and asserts it is
# byte-identical across every rooted hook, so anything added inside it would
# read as divergence.
#
# The seat resolved above answers "am I governed?". It does NOT answer "does
# the artifact I was just handed belong to the repository I govern?" — and
# until 2026-08-30 nothing asked. See scripts/lib/seat-jurisdiction.sh.
_SJ_LIB="$SCRIPT_DIR/../lib/seat-jurisdiction.sh"
if [ ! -f "$_SJ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-main-checkout-writes.sh"
        echo "  scripts/lib/seat-jurisdiction.sh is missing at: $_SJ_LIB"
        echo "  Without it this guard cannot tell whether the artifact it was"
        echo "  handed belongs to the repository it governs, and a guard that"
        echo "  cannot tell must not answer."
    } >&2
    exit 2
fi
# shellcheck source=../lib/seat-jurisdiction.sh
. "$_SJ_LIB"

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, three different behaviours —
# see the contract for why "block everything unresolvable" is NOT the rule.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # LOUD, once per repository per session. engine-status.sh announces the
    # stand-down at SessionStart, which fires before any work happens and names
    # no action; this fires at the MOMENT this guard declines, which is the only
    # moment the absence costs anything.
    richos_announce_stand_down "scripts/hooks/guard-main-checkout-writes.sh"
    # This repository never adopted the engine, so there is no enforcement to
    # lose here. Stand down. NOT a silent skip: engine-status.sh announces the
    # stand-down into the orchestrator's own context at every session start.
    exit 0
else
    # BROKEN: this guard believes it is governing something and cannot. Block.
    root_failure_banner "scripts/hooks/guard-main-checkout-writes.sh" >&2
    exit 2
fi

# Load the GOVERNED repository's config — its protected source trees, not the
# engine's. Under the old resolution this loaded the engine's own config and
# then guarded the engine's own directories, which is why a plugin-loaded
# engine protected nothing at all in the repository it was watching.
CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${PROTECTED_PATHS:=}"

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}; print(ti.get("file_path") or ti.get("notebook_path") or "")' 2>/dev/null || true)"
[ -n "$FILE_PATH" ] || exit 0

# Only absolute paths are guardable (the file tools require absolute paths anyway).
case "$FILE_PATH" in
  /*) ;;
  *) exit 0 ;;
esac

# A worktree edit is always fine (manual worktrees live under .claude/worktrees/;
# native isolation worktrees are a separate checkout path entirely). Allow explicitly.
case "$FILE_PATH" in
  */.claude/worktrees/*) exit 0 ;;
esac

# --- GOVERNANCE: resolved from the FILE, not from the seat -----------------
# "Am I governed?" and "what am I inspecting?" are now the SAME question about
# the SAME repository. The file's own repository governs it if it has adopted;
# failing that the seat governs it, but only if the file is inside the seat.
#
# THIS IS THE LINE THAT WAS WRONG. PROTECTED_PATHS was joined onto whatever the
# session happened to be seated in, so in richos the guard defended
# richos/engine/app — WHICH DOES NOT EXIST — and allowed every write to the real
# richos/app. Reloading the config from the governing root makes the protected
# trees belong to the same repository as the path they are matched against.
if ! GOVERNING_ROOT="$(richos_governing_root "$FILE_PATH" "${ENTITY_ROOT}")"; then
    richos_announce_stand_down "scripts/hooks/guard-main-checkout-writes.sh" \
        "neither this file's repository nor the session's seat has adopted the engine, so no repository's PROTECTED_PATHS govern this write"
    exit 0
fi
if [ "$GOVERNING_ROOT" != "$ENTITY_ROOT" ]; then
    richos_assert_jurisdiction "scripts/hooks/guard-main-checkout-writes.sh" \
        "$ENTITY_ROOT" "$FILE_PATH" "file" || true
    ENTITY_ROOT="$GOVERNING_ROOT"
    PROTECTED_PATHS=""
    CONFIG="$ENTITY_ROOT/orchestration.config"
    # shellcheck disable=SC1090
    [ -f "$CONFIG" ] && . "$CONFIG"
    : "${PROTECTED_PATHS:=}"
fi

# Sensible failure: with no protected paths configured, the guard cannot know
# what to protect. Surface it loudly (never silently) and allow the write.
if [ -z "${PROTECTED_PATHS// /}" ]; then
  echo "(hook: guard-main-checkout-writes.sh) NOTE: PROTECTED_PATHS is unset in orchestration.config — write-guard is INACTIVE. Fill PROTECTED_PATHS to enable main-checkout write protection." >&2
  exit 0
fi

# Block source writes to any protected tree in the MAIN checkout.
for p in $PROTECTED_PATHS; do
  case "$FILE_PATH" in
    "$ENTITY_ROOT/$p"/*)
      echo "=== Main-checkout write BLOCKED ===" >&2
      echo "  Refusing to write '$FILE_PATH'." >&2
      echo "  This is the SHARED main checkout ($ENTITY_ROOT). All source (protected trees:" >&2
      echo "  $PROTECTED_PATHS) must be edited in your own git worktree, never in the main" >&2
      echo "  checkout — concurrent edits here corrupt other agents' work and block landing." >&2
      echo "  Re-issue the edit against your worktree path (…/.claude/worktrees/<your-worktree>/…)." >&2
      echo "  (If you are the orchestrator: land source via git merge, or make source changes in a worktree.)" >&2
      echo "(hook: scripts/hooks/guard-main-checkout-writes.sh)" >&2
      exit 2
      ;;
  esac
done

exit 0
