#!/usr/bin/env bash
# dialect-table.test.sh - runs dialect-table.test.py.
#
# The suite covers, and so names for ci-affected-units.sh, every input and output of the
# generated American spelling table: dialect-table.py, dialect-en-US.generated.dict,
# dialect-en-US.overrides.dict, dialect-en-US.leave.tsv, ../dialect-en-US.dict,
# third_party/varcon/varcon.txt, fixtures/harper-review-list.tsv.
# A change to any of them without a regenerated table fails here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/dialect-table.test.py" "$@"
