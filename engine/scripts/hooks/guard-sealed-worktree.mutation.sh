#!/usr/bin/env bash
#
# guard-sealed-worktree.mutation.sh — PROVES the write barrier's suite CAN
# FAIL, one property at a time. Invoked by guard-sealed-worktree.test.sh; the
# loop is scripts/lib/mutation-harness.sh. Case ids (G04 etc.) are the ones
# that suite prints on both PASS and FAIL. This is the piece the specification
# says to test hardest, so every clause of the verdict has a mutant.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "guard-sealed-worktree (the write barrier)" "scripts/hooks/guard-sealed-worktree.test.sh"

G="scripts/hooks/guard-sealed-worktree.sh"

mutant unsealed-allowed "G04" "$G" \
    'out("UNSEALED", reason)' \
    'out("SEALED", reason)' \
    "an unsealed worker would write; nothing it wrote would be owned, and the entire lifecycle downstream would have nothing to act on."

mutant refusal-exits-zero "G04" "$G" \
    '      echo "(hook: scripts/hooks/guard-sealed-worktree.sh)"{NL}    } >&2{NL}    exit 2 ;;{NL}  *)' \
    '      echo "(hook: scripts/hooks/guard-sealed-worktree.sh)"{NL}    } >&2{NL}    exit 0 ;;{NL}  *)' \
    "the barrier would print its refusal and let the write through — a warning wearing a guard's clothes."

mutant readonly-allowlist-is-everything "G04" "$G" \
    'if tool in readonly_tools:' \
    'if True:' \
    "Bash, Agent and every editor would pass as if they were Read; the allowlist would be a list nobody consulted."

mutant readonly-allowlist-is-nothing "G05" "$G" \
    'if tool in readonly_tools:' \
    'if False:' \
    "an unsealed worker could not even Read to report why it is stuck; the barrier would deadlock the worker instead of fencing its writes."

mutant lead-is-a-worker "G01" "$G" \
    '[ -n "$AGENT_ID" ] || exit 0' \
    '[ -n "$AGENT_ID" ] || AGENT_ID="lead-as-worker"' \
    "the lead's own tool calls would be judged against a manifest that does not exist and refused — the orchestrator bricked by its own guard."

mutant readonly-types-not-exempt "G12" "$G" \
    'if bare and bare in exempt:' \
    'if False:' \
    "every Explore and Plan agent would be refused Bash forever: they own no worktree and nothing could ever seal one."

mutant namespace-not-stripped "G13" "$G" \
    'bare = atype.split(":", 1)[1] if ":" in atype else atype' \
    'bare = atype' \
    "a plugin-loaded read-only type would be judged as file-capable and refused."

mutant terminal-not-refused "G15" "$G" \
    'if tx.is_terminal_agent(aid):{NL}    out("TERMINAL",' \
    'if False:{NL}    out("TERMINAL",' \
    "a resumed terminal agent whose manifest is still sealed would write into a quarantine or a removed path."

mutant terminal-from-index-only "G22" "$G" \
    'if tx.is_terminal_agent(aid, sid):' \
    'if os.path.isfile(tx.terminal_index_path(aid)):' \
    "the barrier would trust the marker file alone; a crash between the transaction's terminal write and the index write leaves a terminal worker able to write (review 2026-09-03, blocker 5)."

mutant no-wait "G10" "$G" \
    '    if time.time() >= deadline:{NL}        break{NL}    time.sleep(0.25)' \
    '    break' \
    "a binding that lands a second after the worker's first write would be missed, and a correctly spawned worker refused at its first call."

mutant fail-closed-on-own-error "G17" "$G" \
    'command -v python3 >/dev/null 2>&1 || fail_open "python3 is unavailable"' \
    'command -v python3 >/dev/null 2>&1 || exit 2' \
    "the guard's own breakage would refuse every worker's every write; it would be unwired within the hour and then protect nothing."

mutant library-missing-refuses "G18" "$G" \
    '[ -f "$TX_PY" ] || fail_open "scripts/lib/worktree-transactions.py is missing at $TX_PY"' \
    '[ -f "$TX_PY" ] || exit 2' \
    "same failure one file over: an engine missing its library would brick every worker instead of announcing itself."

mutant half-sealed-passes "G08" "$G" \
    '    if sealed:{NL}        out("SEALED", "")' \
    '    if sealed or "no start record" in str(res):{NL}        out("SEALED", "")' \
    "a worker whose start was never recorded would write before its native member is known — the member would have to be invented later."

mutation_end
