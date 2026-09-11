#!/usr/bin/env bash
#
# workspaces.sh — the CEO's workspace spec, as the one command Rich runs.
#
# The page: docs/plans/worktree-spec-2026-09-11.md. The mechanism:
# scripts/lib/workspaces.py. This file only finds python3 and the library.
#
#   workspaces.sh status
#       every finished agent this session must land or discard (point 5),
#       every paused and working agent, and every deletion being retried
#   workspaces.sh land <agent> [--ignored-not-needed '<why>']
#       its branches are already in main and nothing is uncommitted (point 8):
#       stop its processes and delete every workspace and branch (points 4, 9, 10)
#   workspaces.sh discard <agent> --reason '<why>' (--ceo-word '<his words>' | --not-ceo-ordered '<why>')
#       work that must not go into main: every workspace and branch deleted,
#       the reason and the branch tips recorded (point 7)
#   workspaces.sh pause <agent> --until '<what ends it>'   /  resume <agent>  /  stop <agent>
#       point 11. A SendMessage carrying a line `pause-until: <what ends it>`
#       records the same pause; a later message to the paused agent resumes it.
#   workspaces.sh wait <agent> --started '<what>' | --outside '<what>' --todo '<ref>' | --ceo '<question>' --todo '<ref>'
#       point 5's allowances for ending a turn while an item waits
#   workspaces.sh retry
#       run every due deletion retry now (point 13 retries on its own anyway)
#
# THESE ARE THE ONLY THINGS IN THE ENGINE THAT DELETE A WORKSPACE.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/workspaces.py"
command -v python3 >/dev/null 2>&1 || { echo "workspaces.sh: python3 is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "workspaces.sh: $LIB is missing" >&2; exit 2; }
exec python3 "$LIB" "$@"
