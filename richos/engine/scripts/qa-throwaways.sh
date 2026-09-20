#!/usr/bin/env bash
#
# qa-throwaways.sh — how many helper scripts did this walk write from scratch?
#
# The committed walk toolkit is app/scripts/qa/. This counts what a run wrote
# INSTEAD of reaching for it, from the run's own tool calls, and names every
# one. Information at a QA land, never a refusal.
#
#   qa-throwaways.sh <transcript.jsonl> [--json]
#   qa-throwaways.sh --help       the counting rules, and what each was derived from
#
# The transcript is the harness's per-agent JSONL:
#   ~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl
# which <scratch>/<session>/tasks/<id>.output also points at.
#
# The mechanism, and the walk it was derived from, are in
# scripts/lib/qa-throwaways.py.
#
# Exit: 0 none; 1 at least one, listed; 2 it cannot answer.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/qa-throwaways.py"
command -v python3 >/dev/null 2>&1 || { echo "qa-throwaways.sh: python3 is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "qa-throwaways.sh: $LIB is missing" >&2; exit 2; }
exec python3 "$LIB" "$@"
