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
    '    regs = _join_prepared_rows(registrations(records, worktree=worktree, repo=repo))' \
    '    regs = _join_prepared_rows(registrations(records, worktree=worktree, names=names, repo=repo, match_names=True))' \
    "a tree would be judged by its branch or directory NAME — reusable across sessions — and a dead owner's verdict would delete a later, unrelated tree."

mutant platform-terminal-record-ignored "L06b" "$F" \
    '        state, why_terminal = platform_terminal_record(reg){NL}        if state == "terminal":' \
    '        state, why_terminal = platform_terminal_record(reg){NL}        if False:' \
    "a finished cross-repository worktree whose native shell the platform removed at completion would sit INDETERMINATE until the whole session ended, refused by the operator door while the reclaim lane removed it on the same record (round 14, O2: Frank's round-three tree, 22:57Z refused, 23:00Z reclaimed)."

mutant open-post-terminal-run-ignored "L06c" "$F" \
    '        if state == "open":{NL}            # The agent was run AGAIN' \
    '        if False:{NL}            # The agent was run AGAIN' \
    "a terminal agent the platform started again -- with that run still open in the transaction's notes or the platform's event log -- would be judged by the generic session-alive branch instead of by row 5, and the reason would stop saying the agent is running."

# --- round 15 (2026-09-11): the four properties Frank D1-D3 / Sage D-A asked for ---
mutant lock-resolved-in-callers-entity-only "L06e" "$F" \
    '        for lock_entity in _lock_entities(reg, records, entity):' \
    '        for lock_entity in [entity]:' \
    "the lock would be resolved only in the CALLER'S entity again (round 14's step 2): a cross-repository tree judged with its own repository as entity finds no shell there, falls through to the terminal record, and a LOCKED, running owner is answered NOT-ALIVE — the 00:02:34Z row on the operator's ledger."

mutant terminal-record-witness-persisted "L06g" "$F" \
    '            return NOT_ALIVE, joined + "platform terminal record: " + why_terminal' \
    '            if write:{NL}                append({"event": "terminated", "agent_id": aid, "teammate": name, "session_id": reg.get("session_id") or "", "worktree": reg.get("worktree") or "", "reason": why_terminal, "witness": "platform-terminal-record"}, ledger){NL}            return NOT_ALIVE, joined + "platform terminal record: " + why_terminal' \
    "step 2b would write a ledger row from the transaction's record again, and step 1 would return that row on every later call ahead of the lock and ahead of row 5 — the fact made permanent, which round 14 did once on the operator's ledger and which L06g' proves destroys row 5's INDETERMINATE."

mutant record-derived-witness-decides "L06h" "$F" \
    '            if (t.get("witness") or "") not in RECORD_DERIVED_WITNESSES]' \
    '            if True]' \
    "a 'platform-terminal-record' row already on a ledger (the one round 14 wrote) would outrank a held lock at step 1 for the life of the ledger, for every entity, on every call."

mutant retraction-ignored "L06j" "$F" \
    '            and (r.get("ts") or "") not in retracted]' \
    '            and True]' \
    "a 'retracted' row would void nothing: the append-only ledger would have no way to express that a witnessed termination was wrong, and the only remedy for a false row would be editing the operator's record by hand."

mutant prepared-row-never-joined "L06k" "$F" \
    '        if len(ids) == 1:{NL}            joined = dict(reg)' \
    '        if False:{NL}            joined = dict(reg)' \
    "the id-less 'prepared' row every helper-made tree carries would fall to step 3 and hold the aggregate at INDETERMINATE while the session lives, so the terminal record would decide nothing for any real tree (76 of 76 on the operator's ledger) and the operator door would refuse every finished cross-repository reviewer until session end."

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

# ROUND 15 (2026-09-11): this mutant used to substitute `read_all()` WITH NO
# PATH for the sealed manifest — which reads ~/.claude/state/worktree-ledger.jsonl,
# the OPERATOR'S REAL LEDGER (the suite passes its sandbox ledger by --ledger
# and never exports RICHOS_WORKTREE_LEDGER). It was "proven" only because that
# real file held 17,000 rows; with HOME redirected it read nothing, L28 stayed
# green and the red moved to L29. A proof that depends on the operator's record
# is the class Frank D2 named, read-only. The substitute is now a constant
# registration-shaped row, which proves the same property with no file at all.
mutant bound-members-fallback "L28" "$F" \
    '    mod = _transactions_module(){NL}    if mod is None:{NL}        return []' \
    '    mod = _transactions_module(){NL}    if mod is None or True:{NL}        return [{"class": "hand-rolled", "repo": "", "path": "/a/registration/not/a/manifest", "branch": "", "state": "bound"}]' \
    "a destructive caller would receive registrations in place of a sealed manifest — the best-effort record promoted to authority."

mutant transcript-join-accepted "L14" "$F" \
    '        return {"verdict": UNRESOLVED, "agent_ids": [], "source": "",{NL}                "reason": ("no ownership record: no ledger registration for the exact path %s; "' \
    '        for n in names:{NL}            for hit in transcript_names.get(n) or []:{NL}                regs.append({"event": "registered", "teammate": n, "agent_id": hit.get("agent_id"), "session_id": hit.get("session_id") or "", "class": "native", "repo": entity}){NL}    if not regs:{NL}        return {"verdict": UNRESOLVED, "agent_ids": [], "source": "",{NL}                "reason": ("no ownership record: no ledger registration for the exact path %s; "' \
    "the transcript's name join would be ownership again — the fallback that judged 29 richos worktrees by a name and a newest-file lookup."

mutation_end
