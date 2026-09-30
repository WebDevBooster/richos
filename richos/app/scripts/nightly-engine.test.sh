#!/usr/bin/env bash
# nightly-engine.test.sh — the nightly engine run: every engine unit with every mutation pass, as
# a job of its own, never beside an app nightly, from a checkout it removes, its failures raised
# for the lead. Throwaway Git repositories with stand-in tools and a scratch escalation ledger;
# nothing runs an engine unit, builds or opens a window.
# run-tests: no-host-screen: throwaway Git repositories only; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/nightly-engine.test.sh richos/app/scripts/nightly-engine.test.py richos/app/scripts/nightly-engine.py richos/engine/scripts/escalate.sh richos/engine/scripts/lib/escalations.py richos/engine/scripts/lib/escalations.sh
# run-tests: covers richos/app/scripts/nightly-engine.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/nightly-engine.test.py"
