#!/usr/bin/env bash
#
# land-lease.sh: the per-repository land lease (spec r3 e1, with Frank G5, G7, G10).
#
#   land-lease.sh acquire      --repo <path> [--holder <kind> [--holder-pid <pid>]] [--wait <seconds>]
#   land-lease.sh release      --repo <path> [--holder <kind>]
#   land-lease.sh status       --repo <path>
#   land-lease.sh takeover     --repo <path> [--holder <kind>]
#   land-lease.sh abort-orphan --repo <path>
#
# A land is several tool calls (merge, verify, push), so it takes a lease rather
# than the single-command flock. Take it immediately before your first write into
# a main checkout; release it once pushed.
#
# EXIT 75 MEANS "HELD, RUN IT AGAIN". One call waits at most LAND_LEASE_WAIT
# seconds (default 90, below the Claude Code Bash tool's 120 s default; a value
# above 540 is refused) and then prints who holds the lease, for how long, and
# what state the repository is in. A wait longer than that is several calls.
# A caller that also raises its own tool timeout to 600000 ms may pass --wait up
# to 540.
#
# The holder is found from the caller's own ancestry: the nearest Claude session
# with a session record, or, with --holder <kind>, the nearest process whose
# executable is the one declared for that kind (LAND_LEASE_HOLDERS). Nothing is
# ever signaled.
#
# WITH THE SWITCH OFF (the repository's launcher says OPERATOR_FENCES_STATE="off",
# or there is no launcher) every command is a no-op that says so and exits 0.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
exec "$PY" "$SCRIPT_DIR/lib/operator_fences.py" lease "$@"
