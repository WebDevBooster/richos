#!/usr/bin/env bash
#
# testdevices.mutation.sh — PROVES the test-device suite CAN FAIL, one property
# at a time. Invoked by testdevices.test.sh; the loop is mutation-harness.sh.
#
# The two directions of the one asymmetry matter most: a device whose owner is
# gone must go (owner-alive-ignored proves the opposite direction is held too),
# and a device whose owner cannot be proven must NEVER be deleted
# (undecided-deleted), because a collector that deletes on a guess deletes a
# live test's simulator once and is switched off for ever.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "testdevices (test simulators and emulators)" "scripts/lib/testdevices.test.sh"

D="scripts/lib/testdevices.py"

mutant owner-alive-ignored "test_T04" "$D" \
    '    verdict = {"alive": LEAVE, "gone": COLLECT}.get(st, UNDECIDED)' \
    '    verdict = {"alive": COLLECT, "gone": COLLECT}.get(st, UNDECIDED)' \
    "a running test's own simulator would be deleted under it."

mutant creator-pid-reuse-ignored "test_T03" "$D" \
    '        if started > born + 1:' \
    '        if False:' \
    "a simulator whose creator's pid was reused by another process would be kept for ever."

mutant undecided-deleted "test_T05" "$D" \
    '        elif verdict == UNDECIDED:{NL}            res["undecided"].append(row)' \
    '        elif False:{NL}            res["undecided"].append(row)' \
    "a device whose owner nothing proves would be deleted on a guess."

mutant emulator-args-not-verified "test_T10b" "$D" \
    '        if not _names_avd(rec["pid"], rec["avd"]):{NL}            continue' \
    '        if False:{NL}            continue' \
    "a recorded pid that another process now holds would be treated as the emulator."

mutant sandbox-reads-the-machine "test_T11" "$D" \
    '    try:{NL}        import pwd{NL}        real = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)' \
    '    return True{NL}    try:{NL}        import pwd{NL}        real = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)' \
    "a test suite with a sandboxed HOME would read, and could delete, the machine's own simulators."

mutant shutdown-unproven-alerted "test_T06b" "$D" \
    '            if verdict == "owner cannot be proven" and d.get("state") == "Shutdown":' \
    '            if False:' \
    "every shut-down device from an unrecorded checkout would sit in the MASSIVE ALERT for ever."

mutant failure-row-never-resolves "test_T08" "$D" \
    '            continue                    # nothing was read, so nothing is resolved{NL}        del rows[key]' \
    '            continue                    # nothing was read, so nothing is resolved{NL}        pass' \
    "the alert would outlive the device Rich deleted by hand, and an alert that never clears is not read."

mutation_end
