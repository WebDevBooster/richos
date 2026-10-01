#!/usr/bin/env bash
# Explicit private execution for resource-policy regression fixtures. The outer
# proof-run still owns and contains this complete tree. These suites simulate
# controllers/budgets and never build, boot devices or consume live user records.
#
# ALLOCATED, NOT NAMED (scripts/lib/scratch.sh): a suite stopped by a signal
# before its EXIT trap leaves a directory the sweeper finds without being told
# its name. The bare `mktemp -d` this replaced was the 46th unallocated site
# against scratch-allocation-lint.sh's declared baseline of 45.
# shellcheck source=scratch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch.sh"
verification_fixture_root="$(scratch_new verification-fixture)" || {
    echo "verification-fixture: no scratch directory" >&2; exit 1; }
trap 'rm -rf "$verification_fixture_root"' EXIT
export RICHOS_VERIFICATION_MODE=fixture RICHOS_VERIFICATION_FIXTURE_ROOT="$verification_fixture_root"
export HOME="$verification_fixture_root/home" CLAUDE_CONFIG_DIR="$verification_fixture_root/config"
export TMPDIR="$verification_fixture_root/tmp" RICHOS_MACHINE_WORKERS="$verification_fixture_root/machine"
export RICHOS_ENGINE_PASS_DIR="$verification_fixture_root/slot" RICHOS_CPU_GUARD_STATE="$verification_fixture_root/controller"
unset RICHOS_WORKER_TOKENS RICHOS_WORKER_SLOT_HELD RICHOS_WORKER_BORROW_LOCK RICHOS_VERIFICATION_OWNER RICHOS_VERIFICATION_CONTAMINATION
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/state" "$TMPDIR"
