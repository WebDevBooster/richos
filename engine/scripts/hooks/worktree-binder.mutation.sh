#!/usr/bin/env bash
#
# worktree-binder.mutation.sh — PROVES the binder (third job of
# detect-nonnative-worktree.sh) CAN FAIL, one property at a time. Invoked by
# detect-nonnative-worktree.test.sh; the loop is scripts/lib/mutation-harness.sh.
# Case ids (B06 etc.) are the ones that suite prints on both PASS and FAIL.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "detect-nonnative-worktree binder" "scripts/hooks/detect-nonnative-worktree.test.sh"

D="scripts/hooks/detect-nonnative-worktree.sh"

mutant sync-run-fabricates-id "B06" "$D" \
    'elif not agent_id:{NL}    problem("this file-capable spawn' \
    'elif not agent_id:{NL}    agent_id = "fabricated00000001"; tx.bind(sid, tuid, agent_id, "fabricated"){NL}    problem("") if False else None{NL}elif False:{NL}    problem("this file-capable spawn' \
    "a synchronous run would be bound to an invented agent id — ownership fabricated for a worker that has already finished."

mutant missing-intent-invented "B10" "$D" \
    'elif intent is None:{NL}    problem("NO spawn-intent is on disk' \
    'elif intent is None:{NL}    tx.write_intent(sid, tuid, {"kind": "native", "teammate": os.environ.get("NAME", ""), "externals": []}); tx.bind(sid, tuid, agent_id, "invented"){NL}elif False:{NL}    problem("NO spawn-intent is on disk' \
    "a spawn the isolation guard never saw would be given a member set by the binder — the best-effort registration this replaces, one hook later."

mutant library-missing-silent "B14" "$D" \
    '    BIND_PROBLEMS+=("scripts/lib/worktree-transactions.py is MISSING at $_TX_PY' \
    '    _UNUSED_NOTICE=("scripts/lib/worktree-transactions.py is MISSING at $_TX_PY' \
    "an engine that cannot bind would report clean spawns; every worker would be refused at its first write with nothing having said why."

mutant transcript-join-dropped "B04" "$D" \
    'elif al is not None and tuid:{NL}    tp = str(payload.get("transcript_path") or "")' \
    'elif False:{NL}    tp = str(payload.get("transcript_path") or "")' \
    "a spawn whose acknowledgement was not in tool_response would never bind, even though the parent transcript carries the exact join."

mutant bind-failure-swallowed "B18" "$D" \
    '    except Exception as e:{NL}        problem("binding tool_use %s to agent %s FAILED: %s. The worker is unbound and its writes will be refused." % (tuid, agent_id, e))' \
    '    except Exception as e:{NL}        pass' \
    "a refused rebind would look like a clean spawn; the agent would carry the wrong member set with nothing said."

mutant banner-does-not-exit "B06" "$D" \
    'if [ "${#WARN[@]}" -gt 0 ] || [ "${#REAPED[@]}" -gt 0 ] || [ "${#ZOMBIE_PROCS[@]}" -gt 0 ] || [ "${#BIND_PROBLEMS[@]}" -gt 0 ]; then{NL}  exit 2' \
    'if [ "${#WARN[@]}" -gt 0 ] || [ "${#REAPED[@]}" -gt 0 ] || [ "${#ZOMBIE_PROCS[@]}" -gt 0 ]; then{NL}  exit 2' \
    "the binding-failed banner would print and the hook would exit 0 — the lead's context never receives it."

mutation_end
