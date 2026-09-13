#!/usr/bin/env bash
# The container reaper's suite, then the harness that proves it can fail.
# C1..C9 need no Docker; D1..D5 start real containers and SKIP without it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B -W ignore "$HERE/containers.test.py" "$@" || exit 1
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/containers.mutation.sh" ]; then
    bash "$HERE/containers.mutation.sh" || exit 1
fi
exit 0
