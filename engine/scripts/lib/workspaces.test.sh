#!/usr/bin/env bash
# One test per numbered point of docs/plans/worktree-spec-2026-09-11.md, then
# the mutation harness that proves each of them can fail (workspaces.mutation.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B -W ignore "$HERE/workspaces.test.py" "$@" || exit 1
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/workspaces.mutation.sh" ]; then
    bash "$HERE/workspaces.mutation.sh" || exit 1
fi
exit 0
