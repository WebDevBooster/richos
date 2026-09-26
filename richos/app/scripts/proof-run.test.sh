#!/usr/bin/env bash
# proof-run.test.sh — the land runner (proof-run.py): every selected command runs, concurrently
# where safe, one lane at a time where not, admitted by CPU, and the run is red by name when a
# check is. Fixture commands only; nothing builds, boots or opens a window.
# run-tests: no-host-screen: fixture shell commands only; nothing is launched on any screen
# run-tests: inputs richos/engine/scripts/lib/cpu_guard.py richos/engine/scripts/lib/engine_pass.py richos/app/scripts/proof-failure.test.py richos/app/scripts/lib/test_results.py richos/engine/scripts/lib/cpu_policy.py richos/engine/scripts/lib/native-work.py richos/app/scripts/lib/simulator_budget.py richos/app/scripts/proof-run.test.sh richos/app/scripts/proof-run.test.py richos/app/scripts/proof-run.py richos/app/scripts/proof-for.sh richos/app/scripts/battery-check.py richos/app/scripts/testvm/reserve.py richos/app/scripts/runner-reliability.test.py richos/app/scripts/runner-reliability.mutation.py richos/app/scripts/nightly-local.py richos/engine/scripts/lib/worker_tokens.py richos/engine/scripts/lib/proc_tree.py richos/engine/scripts/lib/testdevices.py richos/app/scripts/lib/proof_evidence.py richos/app/scripts/proof-evidence.test.py richos/engine/scripts/lib/operator_fences.py richos/engine/scripts/lib/ci-receipts.py richos/app/scripts/proof-inputs.json
# run-tests: covers richos/app/scripts/lib/simulator_budget.py richos/app/scripts/proof-run.py richos/app/scripts/runner-reliability.test.py richos/app/scripts/runner-reliability.mutation.py richos/engine/scripts/lib/worker_tokens.py richos/engine/scripts/lib/proc_tree.py richos/app/scripts/lib/proof_evidence.py richos/app/scripts/proof-evidence.test.py richos/engine/scripts/lib/operator_fences.py richos/engine/scripts/lib/ci-receipts.py richos/app/scripts/proof-inputs.json
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$here/proof-evidence.test.py"
python3 "$here/proof-run.test.py"
python3 "$here/proof-failure.test.py"
python3 "$here/runner-reliability.test.py"
python3 "$here/runner-reliability.mutation.py"
