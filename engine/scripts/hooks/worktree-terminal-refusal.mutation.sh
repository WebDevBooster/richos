#!/usr/bin/env bash
#
# worktree-terminal-refusal.mutation.sh — PROVES the terminal-agent refusal
# in guard-resume-isolation.sh CAN FAIL, one property at a time. Invoked by
# guard-resume-isolation.test.sh; the loop is scripts/lib/mutation-harness.sh.
# Case ids (T02 etc.) are the ones that suite prints on both PASS and FAIL.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "guard-resume-isolation terminal refusal" "scripts/hooks/guard-resume-isolation.test.sh"

G="scripts/hooks/guard-resume-isolation.sh"

mutant terminal-id-not-checked "T03" "$G" \
    'if tx.is_terminal_agent(to_id):{NL}    out("TERMINAL", "agent id %s is terminal" % to_id)' \
    'if False:{NL}    out("TERMINAL", "agent id %s is terminal" % to_id)' \
    "a terminal agent addressed by its id would be resumed; it would wake with no workspace and improvise."

mutant terminal-name-not-checked "T04" "$G" \
    'if sid and tx.is_terminal_name(sid, to):{NL}    out("TERMINAL", "teammate %s is terminal in session %s" % (to, sid[:8]))' \
    'if False:{NL}    out("TERMINAL", "teammate %s is terminal in session %s" % (to, sid[:8]))' \
    "a terminal agent addressed by its name would be resumed while its roster row still says active."

mutant refusal-after-escape-hatches "T05" "$G" \
    '  if [ "$TKIND" = "TERMINAL" ]; then{NL}    {{NL}      echo "=== Resume-isolation guard: REFUSED (terminal agent) ==="' \
    '  if [ "$TKIND" = "TERMINAL" ] && ! printf "%s" "$MESSAGE" | grep -qE "^[[:space:]]*resume-ack:"; then{NL}    {{NL}      echo "=== Resume-isolation guard: REFUSED (terminal agent) ==="' \
    "resume-ack: would reopen a terminal agent — the escape hatch the specification removes for exactly this case."

mutant refusal-exits-zero "T02" "$G" \
    '      echo "  (specification: docs/plans/worktree-real-fix-2026-09-03.md)"{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 2' \
    '      echo "  (specification: docs/plans/worktree-real-fix-2026-09-03.md)"{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 0' \
    "the refusal would be printed and the resume allowed."

mutation_end
