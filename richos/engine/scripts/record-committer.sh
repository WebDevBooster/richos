#!/usr/bin/env bash
#
# record-committer.sh: the scheduled committer for loro writes in a record
# (daily-driver plan step 8; two-installs spec point 28).
#
#   record-committer.sh run       --repo <main checkout>      one tick, now
#   record-committer.sh install   --repo <main checkout> [--interval 300]
#   record-committer.sh uninstall --repo <main checkout>      the way out
#   record-committer.sh status    --repo <main checkout>      the way to see it
#
# Each tick commits ONLY the paths the loro writer writes, and only while no land
# is running, no land lease is held, the checkout is at rest and no loro write is
# in progress. Everything, including why it cannot fight a lander, is in
# scripts/lib/record_committer.py.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env python3 "$HERE/lib/record_committer.py" "$@"
