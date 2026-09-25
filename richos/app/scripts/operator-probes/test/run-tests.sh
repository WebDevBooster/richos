#!/usr/bin/env bash
# run-tests.sh — the operator probe harness, tested without a virtual machine.
#
#   operator-probes/test/run-tests.sh
#
# The probes themselves need a guest and a model (run-probes.py); what can be proved
# without either is proved here in under a second: the ported frame reading, banner parse
# and init check agree with the Rust they stand in for (including the banner line measured
# on the wire), account data never reaches a result file, and the lead's arguments still
# mirror operator_profile.rs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$HERE/test_guest_probes.py"
