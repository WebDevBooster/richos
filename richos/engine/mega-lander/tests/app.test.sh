#!/usr/bin/env bash
# Synthetic desktop dispatch across real Git workspaces and the actual ECS store,
# then the mutation harness that proves the land lock's properties can fail
# (app.mutation.sh). A harness nobody runs proves nothing about anything, which
# is why it is invoked from the suite it mutates.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B -W ignore "$HERE/app.test.py" "$@" || exit 1
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/app.mutation.sh" ]; then
    bash "$HERE/app.mutation.sh" || exit 1
fi
exit 0
