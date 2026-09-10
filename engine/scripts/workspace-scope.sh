#!/usr/bin/env bash
#
# workspace-scope.sh — WHAT IS STANDING, AND WHY, WITH NOTHING UNDECIDED.
#
# Every worktree of every repository this machine's record knows, each with
# exactly one disposition and the reason it was reached:
#
#   OURS-READY   ours, and the lane would reclaim it now
#   OURS-HELD    ours, still standing, WITH THE CAUSE NAMED
#   EXCLUDED     the CEO's codex ruling, by name
#   NOT-OURS     no declared owned shape matches; someone else's
#
# READ-ONLY. It removes nothing, renames nothing and takes no lock, so it is
# safe to run at any time, including while agents are working.
#
#   scripts/workspace-scope.sh            the table and a summary line
#   scripts/workspace-scope.sh --json     the same thing for a machine
#
# The implementation is scripts/lib/workspace-scope.py; this wrapper exists so
# the operator-facing entry point sits with the other scripts an operator runs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/workspace-scope.py" "$@"
