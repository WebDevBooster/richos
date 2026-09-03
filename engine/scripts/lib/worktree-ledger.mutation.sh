#!/usr/bin/env bash
#
# worktree-ledger.mutation.sh — PROVES worktree-ledger.test.sh CAN FAIL, one
# property at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (L03 etc.) are the ones the suite
# prints on both its PASS and FAIL lines.
#
# NOT COVERED, stated rather than implied: the fsync inside `append`. A
# missing fsync is invisible to any test that reads the file back through the
# same kernel — the data is in the page cache either way. It is a property
# only a power cut can falsify.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "worktree-ledger" "scripts/lib/worktree-ledger.test.sh"

F="scripts/lib/worktree-ledger.py"

mutant name-match-restored "L03" "$F" \
    '    regs = registrations(records, worktree=worktree, repo=repo)' \
    '    regs = registrations(records, worktree=worktree, names=names, repo=repo, match_names=True)' \
    "a tree would be judged by its branch or directory NAME — reusable across sessions — and a dead owner's verdict would delete a later, unrelated tree."

mutant prepared-ignores-session "L22" "$F" \
    '        if session_id and (r.get("session_id") or "") != session_id:{NL}            continue' \
    '        if False:{NL}            continue' \
    "a prepared record from LAST session would satisfy THIS session's spawn-intent; the binding would cross sessions."

mutant prepared-ignores-teammate "L23" "$F" \
    '        if teammate and (r.get("teammate") or "") != teammate:{NL}            continue' \
    '        if False:{NL}            continue' \
    "any teammate could be spawned into a worktree prepared for another."

mutant prepared-matches-basename "L24" "$F" \
    '        if wt and norm_path(r.get("worktree")) != wt:{NL}            continue' \
    '        if wt and os.path.basename(norm_path(r.get("worktree"))) != os.path.basename(wt):{NL}            continue' \
    "a prepared record would match any path with the same last component — the name-shaped matching the specification forbids."

mutant prepared-ignores-repo "L25" "$F" \
    '        if rp and norm_path(r.get("repo")) != rp:{NL}            continue' \
    '        if False:{NL}            continue' \
    "a record could name one repository while the tree belongs to another; the backup ref would be written to the wrong repository."

mutant prepared-not-ownership "L26" "$F" \
    'OWNERSHIP_EVENTS = ("registered", "prepared")' \
    'OWNERSHIP_EVENTS = ("registered",)' \
    "the spawn guard's clause 4 would refuse every worktree the helper creates, and the helper would have to keep writing the old best-effort row."

mutant bound-members-fallback "L28" "$F" \
    '    mod = _transactions_module(){NL}    if mod is None:{NL}        return []' \
    '    mod = _transactions_module(){NL}    if mod is None or True:{NL}        return [{"class": r.get("class"), "repo": r.get("repo"), "path": r.get("worktree"), "branch": r.get("branch"), "state": "bound"} for r in read_all() if r.get("event") in OWNERSHIP_EVENTS]' \
    "a destructive caller would receive registrations in place of a sealed manifest — the best-effort record promoted to authority."

mutant transcript-join-accepted "L14" "$F" \
    '        return {"verdict": UNRESOLVED, "agent_ids": [], "source": "",{NL}                "reason": ("no ownership record: no ledger registration for the exact path %s; "' \
    '        for n in names:{NL}            for hit in transcript_names.get(n) or []:{NL}                regs.append({"event": "registered", "teammate": n, "agent_id": hit.get("agent_id"), "session_id": hit.get("session_id") or "", "class": "native", "repo": entity}){NL}    if not regs:{NL}        return {"verdict": UNRESOLVED, "agent_ids": [], "source": "",{NL}                "reason": ("no ownership record: no ledger registration for the exact path %s; "' \
    "the transcript's name join would be ownership again — the fallback that judged 29 richos worktrees by a name and a newest-file lookup."

mutation_end
