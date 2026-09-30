#!/usr/bin/env bash
#
# login-alarm.mutation.sh — PROVES THE LOGIN ALARM'S SUITE CAN FAIL.
#
# Takes the SHIPPED scripts/lib/login_alarm.py, removes ONE property at a time
# in a throwaway copy of the engine, and asserts that the suite fails on the
# SPECIFIC named case and that the mutation applied. The loop is
# scripts/lib/mutation-harness.sh; this file is the list of properties the
# alarm rests on.
#
# Invoked by login-alarm.test.sh, so the runner that discovers *.test.sh runs
# it too. Run directly: scripts/login-alarm.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "login-alarm (told within a minute, once per expiry)" "scripts/login-alarm.test.sh"

L="scripts/lib/login_alarm.py"

# 1. ONE ALARM PER EXPIRY, NOT A LOOP.
mutant alarm-every-tick "L02" "$L" \
    '    if episode:{NL}        first_ts' \
    '    if False:{NL}        first_ts' \
    "Every scan during an outage would notify him again and raise another escalation."

# 2. HIS /login CLOSES IT.
mutant never-closes "L03" "$L" \
    'if written is not None and written > last_failure + RENEW_MARGIN and not newer:' \
    'if False:' \
    "A renewed login would leave the escalation open and the next expiry would never alarm."

# 2b. ONLY A WRITE NEWER THAN THE LATEST FAILURE RENEWS (hunt part 5, P5-14).
mutant renews-on-first-failure "L15" "$L" \
    'last_failure = max([episode.get("last_error", first_ts)] + [e["ts"] for e in events])' \
    'last_failure = first_ts' \
    "A credential write between two failures would close the episode while the later failure proves login is still broken."

# 4. A FAILURE ALREADY FIXED IS NOT NEWS.
mutant alarms-on-renewed "L06" "$L" \
    '        live = [e for e in events if written is None or e["ts"] >= written - RENEW_MARGIN]' \
    '        live = list(events)' \
    "A failure from before his last /login would alarm as if the login were dead now."

# 5. THE VALUE IS NEVER READ.
mutant reads-the-secret "L07" "$L" \
    'args = [sec, "find-generic-password", "-s", SERVICE]' \
    'args = [sec, "find-generic-password", "-w", "-s", SERVICE]' \
    "The alarm would pull the credential itself into its own process."

# 6. ONLY A DEAD LOGIN, NOT EVERY API ERROR.
mutant alarms-on-any-error "L09b" "$L" \
    '    if row.get("error") != "authentication_failed":{NL}        return None' \
    '    if False:{NL}        return None' \
    "A turn that only talks about the incident would be announced as his login dying."

mutant alarms-on-any-text "L09c" "$L" \
    '    if not any(p in text for p in DEAD_LOGIN):{NL}        return None' \
    '    if False:{NL}        return None' \
    "A transient network authentication error, or a sandbox's 'Not logged in', would wake the CEO."

# 7. A FIRST SCAN IS NOT AN ARCHAEOLOGY DIG.
mutant scans-all-history "L10" "$L" \
    'else (now - FIRST_LOOKBACK)' \
    'else 0.0' \
    "Installing the alarm would notify him about a failure from days ago."

# 8. A NOTIFICATION THAT FAILED IS RETRIED.
mutant no-retry "L11" "$L" \
    '            if not episode.get("notified"):' \
    '            if False:' \
    "An osascript refusal at the moment of failure would leave him never told."

# 9. A LEDGER WRITE THAT FAILED IS RETRIED (hunt part 5, P5-13).
mutant no-ledger-retry "L14" "$L" \
    '            if not episode.get("escalation"):' \
    '            if False:' \
    "A ledger outage at the moment of failure would leave the lead with a notification and no durable escalation."

mutation_end
