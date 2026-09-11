#!/usr/bin/env bash
#
# guard-sealed-worktree.mutation.sh — PROVES the lock-out's suite CAN FAIL, one
# property at a time. Invoked by guard-sealed-worktree.test.sh; the loop is
# scripts/lib/mutation-harness.sh. Case ids (G03 etc.) are the ones that suite
# prints on both PASS and FAIL. The verdict itself (finished, paused,
# registered) is scripts/lib/workspaces.py's and is mutated by
# scripts/lib/workspaces.mutation.sh; this harness mutates what THIS file does
# with each verdict.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "guard-sealed-worktree (the lock-out)" "scripts/hooks/guard-sealed-worktree.test.sh"

G="scripts/hooks/guard-sealed-worktree.sh"

mutant finished-passes "G03" "$G" \
    '  LEAD|REGISTERED){NL}    exit 0 ;;' \
    '  LEAD|REGISTERED|FINISHED){NL}    exit 0 ;;' \
    "a restarted finished agent could write again (point 9)."

mutant finished-refusal-exits-zero "G03" "$G" \
    '      echo "  is over, and the orchestrator lands or discards it."{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 2 ;;' \
    '      echo "  is over, and the orchestrator lands or discards it."{NL}      echo "$HOOK_TAG"{NL}    } >&2{NL}    exit 0 ;;' \
    "the lock-out would print its refusal and let the call through — a warning wearing a guard's clothes."

mutant unregistered-passes "G08" "$G" \
    '  UNREGISTERED){NL}    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS" && exit 0' \
    '  UNREGISTERED){NL}    exit 0' \
    "a worker whose registration failed would work anyway, so a failed registration would not stop the spawn (point 3)."

mutant unregistered-cannot-read "G09" "$G" \
    '  UNREGISTERED){NL}    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS" && exit 0' \
    '  UNREGISTERED){NL}    :' \
    "an unregistered worker could not even read to report why it stopped."

mutant lead-is-a-worker "G18" "$G" \
    'if aid else "LEAD\t\t%s\t" % tool' \
    'if aid else "WORKER\tlead-as-worker\t%s\t" % tool' \
    "with the registry unreadable, the lead's own calls would be judged as a worker's and refused — the orchestrator bricked by its own guard's failure."

mutant readonly-types-not-exempt "G10" "$G" \
    '        [ -n "$BARE_TYPE" ] && [ "$BARE_TYPE" = "$t" ] && exit 0' \
    '        :' \
    "every Explore and Plan agent would be refused Bash forever: they own no workspace and nothing registers one."

mutant namespace-not-stripped "G11" "$G" \
    '    BARE_TYPE="${AGENT_TYPE##*:}"' \
    '    BARE_TYPE="$AGENT_TYPE"' \
    "a plugin-loaded read-only type would be judged as file-capable and refused."

mutant worktree-session-allowed "G15" "$G" \
    '  FORBIDDEN){NL}    is_readonly_tool' \
    '  FORBIDDEN){NL}    exit 0{NL}    is_readonly_tool' \
    "a claude --worktree session could work (point 3)."

mutant fail-open-without-registry "G16" "$G" \
    '    deny_cannot_evaluate "scripts/lib/workspaces.py is missing at $WS_PY" "$TOOL_NAME" "$AGENT_ID"' \
    '    exit 0' \
    "an engine missing its registry would let every worker write, finished or not."

mutant fail-open-on-unparseable "G19" "$G" \
    '    deny_cannot_evaluate "the hook payload is unparseable (' \
    '    exit 0; deny_cannot_evaluate "the hook payload is unparseable (' \
    "a payload nobody could read would be waved through, finished agent or not."

mutation_end
