#!/usr/bin/env bash
#
# record-subagent-start.mutation.sh — PROVES record-subagent-start.test.sh CAN
# FAIL, one property at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (S04 etc.) are the ones the suite
# prints on both PASS and FAIL.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "record-subagent-start" "scripts/hooks/record-subagent-start.test.sh"

H="scripts/hooks/record-subagent-start.sh"

mutant start-not-recorded "S01" "$H" \
    '    tx.record_start(sid, aid, str(d.get("cwd") or ""), str(d.get("agent_type") or ""),{NL}                    str(d.get("agent_transcript_path") or ""))' \
    '    pass' \
    "the worker's cwd would never reach the transaction; no manifest could seal and every worker would be refused at its first write."

mutant seal-not-attempted "S04" "$H" \
    '    tx.try_seal(sid, aid)' \
    '    pass' \
    "when the parent's binding is already on disk, the start hook would leave the manifest unsealed until the worker's first write waited on it — and if the binder had already tried, nothing would ever seal it."

mutant cwd-not-recorded "S05" "$H" \
    '    tx.record_start(sid, aid, str(d.get("cwd") or ""), str(d.get("agent_type") or ""),' \
    '    tx.record_start(sid, aid, "", str(d.get("agent_type") or ""),' \
    "the native member would have to be invented from the agent id rather than read from where the worker actually started."

mutant hook-pretends-to-block "S01" "$H" \
    '    raise SystemExit(0){NL}{NL}spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])' \
    '    raise SystemExit(0){NL}{NL}sys.exit(2){NL}spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])' \
    "the hook would exit nonzero on a normal start — a claim that SubagentStart can be refused, which the platform does not honor and the suite must not believe."

mutant library-missing-swallowed "S12" "$H" \
    '    echo "NOTICE: record-subagent-start.sh: scripts/lib/worktree-transactions.py is missing at $TX_PY' \
    '    : "NOTICE: record-subagent-start.sh: scripts/lib/worktree-transactions.py is missing at $TX_PY' \
    "a broken engine would record nothing and say nothing; the first symptom would be a worker refused at its first write."

mutation_end
