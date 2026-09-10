#!/usr/bin/env bash
#
# finish-row-completion.mutation.sh — PROVES finish-row-completion.test.sh CAN
# FAIL, one property at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (F9 etc.) are the ones the suite
# prints on both its PASS and FAIL lines.
#
# ===========================================================================
# WHY THIS HARNESS EXISTS AT ALL
# ===========================================================================
# The completion this suite covers was written, reviewed, shipped and GREEN
# for two days while producing nothing whatsoever in the real ledger. Every
# case passed, because every case handed the resolver a payload whose
# `agent_id` was the owner's — a payload shape the platform has never emitted.
# The proof that made it look wired was a hand call with the owning id.
#
# A green suite is evidence of nothing until somebody has watched it go red for
# the right reason. The first mutant below is the exact regression that defect
# WAS: prefer-the-present instead of prefer-the-resolvable. If F9 does not go
# red when the fallback is put back the way it was, then F9 is not testing the
# fix and this file is worth more than the suite.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "finish-row-completion" "scripts/lib/finish-row-completion.test.sh"

F="scripts/lib/worktree-ledger.py"

# THE DEFECT ITSELF, restored. `if not agent_id` is the condition the three
# writers carried: a present-but-meaningless per-run id beat an absent one, and
# the payload always carries one, so the second key was never consulted.
mutant prefer-the-present "F9" "$F" \
    '    owner = agent_id_from_worktree(worktree)' \
    '    owner = agent_id_from_worktree(worktree) if not agent_id else ""' \
    "the per-run payload id would win again over the owning id in the path, and every finish row would go back to a blank teammate and no workspaces — 0.0% of 15,889 rows, which is what shipped."

# The fallback must fire on RESOLUTION, not on emptiness. Requiring the first
# lookup to return literally nothing while still accepting a bare teammate is
# not the same rule; this asserts the resolvable-versus-present distinction is
# carried by the guard clause and not by luck.
mutant fallback-never-taken "F9" "$F" \
    '    if owner and owner != agent_id:' \
    '    if False:' \
    "the second key would never be consulted at all — the completion would resolve only the id the harness happens to send, which is the id nothing is registered under."

# The first key must still WIN when it resolves. A blanket "trust the path"
# reads a worker running inside another agent's folder as that agent.
mutant path-always-wins "F11" "$F" \
    '        if paths or (name and not teammate):{NL}            return paths, name, agent_id' \
    '        pass' \
    "the path would outrank a payload id that genuinely resolves, so an assignment could be attributed to whoever's folder the process happened to be standing in."

# The owning id is RECORDED, never substituted. A row that silently replaced
# the run's id with the owner's would change the meaning of a field existing
# readers already join on.
mutant no-owner-recorded "F9" "$F" \
    '            if key and (found or teammate) and key != (record.get("agent_id") or "").strip():{NL}                record = dict(record, owner_agent_id=key)' \
    '            pass' \
    "the row would carry workspaces resolved through a key it does not name, so which of the two ids the completion trusted would be unauditable after the fact."

# A terminal event is never prevented by bookkeeping. The bare except is the
# whole reason the completion may live on the write path at all.
mutant completion-can-block-the-row "F14" "$F" \
    '    except Exception:{NL}        pass{NL}    path = path or ledger_path()' \
    '    except Exception:{NL}        raise{NL}    path = path or ledger_path()' \
    "a resolver that raised would take the terminal row with it — the finish signal lost to the bookkeeping that was only ever meant to decorate it."

mutation_end
