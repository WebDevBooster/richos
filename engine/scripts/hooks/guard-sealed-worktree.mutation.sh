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
    '      echo "  (specification: docs/plans/worktree-real-fix-2026-09-03.md, phase 4)"{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 2 ;;' \
    '      echo "  (specification: docs/plans/worktree-real-fix-2026-09-03.md, phase 4)"{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 0 ;;' \
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
    '  LEAD) exit 0 ;;' \
    '  LEAD) AGENT_ID="lead-as-worker" ;;' \
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
    '    if tx.is_terminal_agent(aid, sid):{NL}        out("TERMINAL",{AND}        if isinstance(res, dict) and res.get("terminal"):' \
    '    if False:{NL}        out("TERMINAL",{AND}        if False:' \
    "a resumed terminal agent whose manifest is still sealed would write into a quarantine or a removed path."

mutant terminal-from-index-only "G22" "$G" \
    '    if tx.is_terminal_agent(aid, sid):{AND}        if isinstance(res, dict) and res.get("terminal"):' \
    '    if os.path.isfile(tx.terminal_index_path(aid)):{AND}        if False:' \
    "the barrier would trust the marker file alone; a crash between the transaction's terminal write and the index write leaves a terminal worker able to write (review 2026-09-03, blocker 5)."

mutant no-wait "G10" "$G" \
    '    if time.time() >= deadline:{NL}        break{NL}    time.sleep(0.25)' \
    '    break' \
    "a binding that lands a second after the worker's first write would be missed, and a correctly spawned worker refused at its first call."

# The next four are the INVERSE of the mutants that stood here until
# 2026-09-03 (fail-closed-on-own-error, library-missing-refuses): those proved
# the guard failed OPEN on its own error. Review blocker 3 ruled that the hole
# the barrier exists to close; these prove it now fails CLOSED.
mutant fail-open-without-python "G17" "$G" \
    '    deny_cannot_evaluate "python3 is unavailable, so the worker'"'"'s worktree state cannot be read" "${RAW_TOOL:-<unknown>}" "<unparsed>"' \
    '    exit 0' \
    "without python3 every worker's every write would pass unexamined — the hole review blocker 3 names (review 2026-09-03)."

mutant fail-open-without-library "G18" "$G" \
    '    deny_cannot_evaluate "scripts/lib/worktree-transactions.py is missing at $TX_PY" "$TOOL_NAME" "$AGENT_ID"' \
    '    exit 0' \
    "an engine missing its transaction library would let every worker write unowned bytes and announce it to nobody who could act."

mutant unparseable-is-the-lead "G21" "$G" \
    '    deny_cannot_evaluate "the hook payload is unparseable (${PARSED#*	}); a payload that cannot be proven the lead'"'"'s is treated as a worker'"'"'s" "${RAW_TOOL:-<unknown>}" "<unparsed>" ;;' \
    '    exit 0 ;;' \
    "a worker payload the guard could not parse would read as the lead and pass — the exact hole the review found."

mutant fail-open-on-resolver-error "G25" "$G" \
    '    deny_cannot_evaluate "${DETAIL:-unexpected verdict '"'"'$KIND'"'"'}" "$TOOL_NAME" "$AGENT_ID" ;;' \
    '    exit 0 ;;' \
    "a resolver that raised (unreadable transaction state) would allow the write it could not judge."

mutant broken-root-allows "G24" "$G" \
    '    deny_cannot_evaluate "the governed root could not be resolved (${RICHOS_ROOT_REASON:-no reason given})" "$TOOL_NAME" "$AGENT_ID"' \
    '    exit 0' \
    "a guard that could not tell which repository it governs would allow the write anyway."

mutant lead-proof-is-raw-grep-only "G17d" "$G" \
    '    printf '"'"'%s'"'"' "$INPUT" | grep -Eq '"'"'(^|[^\\])"agent_id"'"'"'' \
    '    false' \
    "without python3 every payload would be proven the lead's, and every worker write would pass."

mutant half-sealed-passes "G08" "$G" \
    '    if sealed:{NL}        # The sealed transaction is re-read for a terminal record: sealing' \
    '    if sealed or "no start record" in str(res):{NL}        # The sealed transaction is re-read for a terminal record: sealing' \
    "a worker whose start was never recorded would write before its native member is known — the member would have to be invented later."

mutant exemption-before-terminal "G26" "$G" \
    'try:{NL}    if tx.is_terminal_agent(aid, sid):' \
    'bare0 = atype.split(":", 1)[1] if ":" in atype else atype{NL}if bare0 and bare0 in set((os.environ.get("READONLY_ALLOWLIST") or "").split()) | set((os.environ.get("HARNESS_UTILITY_TYPES") or "").split()):{NL}    out("EXEMPT", "early exemption restored"){NL}try:{NL}    if tx.is_terminal_agent(aid, sid):' \
    "a terminal read-only agent would pass the barrier for Read, Bash and any unknown tool because its type was exempted before its terminal state was read; terminal finality would depend on a different guard running first (landed review 2026-09-03, blocker 5)."

mutation_end
