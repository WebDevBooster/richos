#!/usr/bin/env bash
#
# scripts/lib/agent-liveness.sh — the shell face of the ONE liveness resolver.
#
# The rule, the evidence, the measured fact about the lock pid and the list of
# advisory sources are all in scripts/lib/agent-liveness.py. Read that first.
# This file exists so a bash caller does not have to know the python invocation,
# and — more importantly — so there is exactly ONE place the resolver is called
# from shell. remove-agent-worktree.sh used to carry its own inline copy of the
# parse; it now sources this, because two implementations of "alive" is how one
# of them silently becomes the stale one.
#
# USAGE
#     . "<engine>/scripts/lib/agent-liveness.sh"
#     line="$(agent_liveness_triple "<entity-main>" "<agent-id|worktree-path>")"
#     kind="$(printf '%s' "$line" | cut -f1)"
#
# The triple, one line, tab separated:
#     ALIVE<TAB><pid><TAB><worktree-path>
#     NOT-ALIVE<TAB><reason><TAB><worktree-path or empty>
#     INDETERMINATE<TAB><reason><TAB>
#
# INDETERMINATE IS NEVER COLLAPSED into either other verdict. Callers decide
# what to do with it — the remover refuses (fail closed, it is about to delete
# something), the claim guard stays quiet (fail open, it is about to speak).
# Folding it into NOT-ALIVE here would take that decision away from both and
# hand a guess to the one that must not guess.
#
# Returns 0 whenever it produced a line, including an INDETERMINATE one. A
# non-zero return is reserved for "could not even run", and it still prints an
# INDETERMINATE triple so a caller that only reads stdout is never handed an
# empty string it might read as absence.

if [ -n "${_AGENT_LIVENESS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_AGENT_LIVENESS_SH_SOURCED=1

_AGENT_LIVENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_LIVENESS_PY="${AGENT_LIVENESS_PY:-$_AGENT_LIVENESS_LIB_DIR/agent-liveness.py}"

# agent_liveness_triple <entity-main> <agent-id|worktree-path>
agent_liveness_triple() {
    local entity="${1:-}" owner="${2:-}" out=""

    if [ -z "$entity" ] || [ -z "$owner" ]; then
        printf 'INDETERMINATE\tagent_liveness_triple needs <entity-main> and <agent-id>\t\n'
        return 1
    fi
    if [ ! -f "$AGENT_LIVENESS_PY" ]; then
        printf 'INDETERMINATE\tthe liveness resolver is missing at %s\t\n' "$AGENT_LIVENESS_PY"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'INDETERMINATE\tpython3 is not on PATH, so liveness cannot be resolved\t\n'
        return 1
    fi

    out="$(python3 "$AGENT_LIVENESS_PY" --entity "$entity" --owner "$owner" \
              --format triple 2>/dev/null | head -1)"
    if [ -z "$out" ]; then
        printf 'INDETERMINATE\tthe liveness resolver produced no verdict for %s\t\n' "$owner"
        return 1
    fi
    printf '%s\n' "$out"
    return 0
}

# agent_liveness_verdict <entity-main> <agent-id> — just the word.
agent_liveness_verdict() {
    agent_liveness_triple "$1" "$2" | cut -f1
}
