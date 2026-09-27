#!/usr/bin/env bash
# engine_pass.test.sh — one full engine pass at a time (engine_pass.test.py), then its
# mutation harness (engine_pass.mutation.sh), which proves every property load-bearing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
source "$(dirname "${BASH_SOURCE[0]}")/verification-fixture.sh"
python3 -B "$HERE/engine_pass.test.py" "$@" || exit 1
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ "$#" -eq 0 ] && [ -f "$HERE/../engine_pass.mutation.sh" ]; then
    bash "$HERE/../engine_pass.mutation.sh" || exit 1
fi
