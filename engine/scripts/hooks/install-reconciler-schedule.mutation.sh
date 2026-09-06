#!/usr/bin/env bash
#
# install-reconciler-schedule.mutation.sh — PROVES the installer's
# fail-closed reconciler schedule CAN FAIL, one property at a time. Invoked by
# install-reconciler-schedule.test.sh; the loop is scripts/lib/mutation-harness.sh.
# Case ids (S17 etc.) are the ones that suite prints on both PASS and FAIL.
# Review 2026-09-03, blocker 7.
#
# WHAT PROTECTS THE OPERATOR'S MACHINE (global-state-witness.test.sh d2 lists
# this file as an installer runner): this harness never runs install.sh
# itself. It names the file as a mutation target and runs the SUITE, which
# exports CLAUDE_CONFIG_DIR into a sandbox and redirects
# RICHOS_LAUNCH_AGENTS_DIR, so no mutant can reach ~/.claude or the
# production launchd label.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "install-reconciler-schedule (the installer fails closed without its reconciler)" "scripts/hooks/install-reconciler-schedule.test.sh"

I="scripts/hooks/install.sh"

mutant schedule-failure-exits-zero "S16b" "$I" \
    '    echo "  (review 2026-09-03 blocker 7; specification: docs/plans/worktree-real-fix-2026-09-03.md, '"'"'Capture and removal'"'"')"{NL}    } >&2{NL}    exit 1' \
    '    echo "  (review 2026-09-03 blocker 7; specification: docs/plans/worktree-real-fix-2026-09-03.md, '"'"'Capture and removal'"'"')"{NL}    } >&2{NL}    exit 0' \
    "an installation with no working reconciler would report success — the pre-fix behavior, which told the operator to load the job by hand (review 2026-09-03, blocker 7)."

# ---------------------------------------------------------------------------
# macOS-ONLY, and gated rather than quietly counted.
#
# These three remove a property from schedule_reconciler_job(), and install.sh
# never calls that function off Darwin — it refuses earlier, at the `uname -s`
# test. So off Darwin the mutants change nothing observable and would be
# reported NOT LOAD-BEARING against properties that are load-bearing on the
# only platform that has the code path. That is the mirror image of the trap
# this file exists to avoid, so the skip is PRINTED and names what went
# unproven; it is never folded into the pass count.
#
# The off-Darwin behavior itself is not left unproven — the suite's S16b-S16d
# assert it on every host, and `schedule-failure-exits-zero` above is aimed at
# S16b for exactly that reason.
# ---------------------------------------------------------------------------
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then

mutant print-not-verified "S18" "$I" \
    '    if ! printed="$(launchctl print "$domain/$LAUNCHD_LABEL" 2>&1)"; then' \
    '    if false; then' \
    "a bootstrap that returned 0 over a job launchd did not actually keep would count as scheduled; nothing would ever run."

mutant program-path-unchecked "S19" "$I" \
    '    if ! printf '"'"'%s'"'"' "$printed" | grep -qF "$RECONCILER"; then' \
    '    if false; then' \
    "a job left over from another checkout would satisfy the install; the landed engine would never be the one that runs."

mutant launchctl-absence-tolerated "S20" "$I" \
    '    if ! command -v launchctl >/dev/null 2>&1; then{NL}        echo "launchctl is not on PATH" >&2; return 1{NL}    fi' \
    '    command -v launchctl >/dev/null 2>&1 || return 0' \
    "a host without launchctl would count as scheduled."

else
    printf '  SKIP  print-not-verified, program-path-unchecked, launchctl-absence-tolerated — schedule_reconciler_job() is unreachable off Darwin (host: %s), so these three cannot be proven load-bearing here. They are NOT counted as proven.\n' "$(uname -s 2>/dev/null)"
fi

# Host-independent: the label is validated before any scheduler is consulted.
mutant any-label-accepted "S21" "$I" \
    '        *) echo "ERROR: install.sh: RICHOS_LAUNCHD_LABEL='"'"'$LAUNCHD_LABEL'"'"' is not the production label and not a test label ($LAUNCHD_PROD_LABEL.test-<id>) — refusing to register a launchd job under it." >&2; exit 1 ;;' \
    '        *) LAUNCHD_TEST_LABEL=1 ;;' \
    "an override could register a machine-wide job under any name at all — a leak nobody would find by listing the production label."

mutation_end
