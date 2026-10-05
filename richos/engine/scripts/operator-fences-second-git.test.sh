#!/usr/bin/env bash
#
# operator-fences-second-git.test.sh: THE FENCE SUITE under the SECOND distinct git on this host
# (Apple git at /usr/bin where Homebrew git is first). It runs scripts/operator-fences.test.sh
# itself with OPERATOR_FENCES_GIT_INDEX=2; the cases, the fixtures and what each proves are there.
# The suite was one unit running every case once per git until 2026-10-05, 420 s (median of 8
# merge-gate runs) against the gate's 600 s cap per check; one git per unit halves it.
#
# Every engine file operator-fences.test.sh names, named here too, so a change to any of them
# selects this unit exactly as it selects that one (the selector's basename rule):
#   app.py commit-ceo-inputs.py guard-land-lease-commands.sh install-ref-forensics.sh land-lease.sh operator-fence-launcher.sh
#   operator-fences-fixture.sh operator-fences-holders.test.py operator-fences-mutation.test.sh operator-fences.sh operator_fences.py operator_fences_admin.py
#   ref-transaction-forensics.sh workspaces.py
#
# Usage: scripts/operator-fences-second-git.test.sh
# Exit 0 = every case passed under the second git, or this host has only one distinct git
# (said in one line; operator-fences.test.sh then covered every git there is).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_FENCES_GIT_INDEX=2 exec bash "$SCRIPT_DIR/operator-fences.test.sh"
