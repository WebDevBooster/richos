#!/usr/bin/env bash
#
# hunt-part5-v3.test.sh — runs lib/hunt-part5-v3.test.py, which proves the fixes for the
# hunt part 5 v3 findings (richos-hq docs/audits/2026-09-29-hunt/part-5-codex-v3.md) in:
#   lib/device-identifiers.py (P5-08)
#   lib/hook_command.py, lib/registered-hooks.sh (P5-45)
#   lib/failure-type.py (P5-57)
#   row-headline-verify.sh (P5-67)
# This wrapper is what names those files to the proof selector.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/lib/hunt-part5-v3.test.py"
