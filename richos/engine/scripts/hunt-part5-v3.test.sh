#!/usr/bin/env bash
#
# hunt-part5-v3.test.sh — runs lib/hunt-part5-v3.test.py, which proves the fixes for the
# hunt part 5 v3 findings (richos-hq docs/audits/2026-09-29-hunt/part-5-codex-v3.md) in:
#   lib/device-identifiers.py (P5-08)
#   lib/hook_command.py, lib/registered-hooks.sh (P5-45)
#   lib/failure-type.py (P5-57)
#   row-headline-verify.sh (P5-67)
#   lib/unguarded_rm.py (P5-82)
#   lib/shared_scratchpad.py (P5-83)
#   lib/qa-throwaways.py (P5-29, P5-30)
#   login-alarm.sh (P5-32)
#   quota-reset.sh (P5-33)
#   land-completeness-measure.py (P5-46)
# This wrapper is what names those files to the proof selector.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/lib/hunt-part5-v3.test.py"
