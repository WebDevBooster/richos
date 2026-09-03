#!/usr/bin/env bash
#
# worktree-transactions.mutation.sh — PROVES worktree-transactions.test.sh CAN
# FAIL, one property at a time. Invoked by that suite; see
# scripts/lib/mutation-harness.sh for the loop. Case ids (T27 etc.) are the
# ones the suite prints on both its PASS and FAIL lines.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "worktree-transactions" "scripts/lib/worktree-transactions.test.sh"

F="scripts/lib/worktree-transactions.py"

mutant claim-never-loses "T27" "$F" \
    '        if tx.get("terminal"):{NL}            _repair_terminal_indexes(tx){NL}            return False, tx{NL}        tx["terminal"] =' \
    '        if False:{NL}            _repair_terminal_indexes(tx){NL}            return False, tx{NL}        tx["terminal"] =' \
    "both terminal ingresses would win, each rewriting the claim — two actors mutating one worktree set with no serialization."

mutant seal-without-start "T08" "$F" \
    '        if not start:{NL}            return False, "no start record' \
    '        if not start:{NL}            start = {"agent_id": agent_id, "cwd_real": ""}{NL}        if False:{NL}            return False, "no start record' \
    "a manifest would seal from the parent's bind alone, before the worker's cwd is known — the native member would be a guess."

mutant seal-without-bound "T10" "$F" \
    '        if not bound:{NL}            return False, ("no bound record' \
    '        if not bound:{NL}            bound = {"agent_id": agent_id, "kind": "native", "externals": []}{NL}        if False:{NL}            return False, ("no bound record' \
    "a manifest would seal from the worker's start alone, with no spawn-intent behind it — ownership invented from a cwd."

mutant native-name-unchecked "T15" "$F" \
    '    if os.path.basename(cwd_real) != want_base:{NL}        return None,' \
    '    if False:{NL}        return None,' \
    "any git worktree the worker happened to start in — including the MAIN checkout — could be sealed as its native member."

mutant native-git-unchecked "T16" "$F" \
    '    top = worktree_toplevel(cwd_real){NL}    if top != cwd_real:' \
    '    top = cwd_real{NL}    if False:' \
    "a directory named like a worktree would be owned, quarantined and later removed on the strength of its name."

mutant external-branch-unchecked "T19" "$F" \
    '    if (m.get("branch") or "") != br:{NL}        return None,' \
    '    if False:{NL}        return None,' \
    "the prepared record could describe one branch while the tree checked out another; the backup ref would save the wrong line of work."

mutant cwd-not-prepared "T18" "$F" \
    '                if cwd_real not in prepared_paths:{NL}                    return False,' \
    '                if False:{NL}                    return False,' \
    "a cwd worker could start anywhere and still be sealed against the prepared set — the tree it actually writes in would be unowned."

mutant bind-invents-intent "T03" "$F" \
    '    if not intent:{NL}        raise LookupError(' \
    '    if not intent:{NL}        intent = {"kind": "native", "externals": []}{NL}    if False:{NL}        raise LookupError(' \
    "the binder would fabricate a member set for an agent nobody declared — the best-effort registration this replaces."

mutant rebind-allowed "T06" "$F" \
    '    if existing and existing.get("tool_use_id") not in (None, tool_use_id):{NL}        raise RuntimeError(' \
    '    if False:{NL}        raise RuntimeError(' \
    "one agent id could be bound to two intents; the later one silently replaces the member set the first one owns."

mutant both-present-renames-over "T39" "$F" \
    '    if o and not q:{NL}        try:{NL}            os.rename(orig, quar)' \
    '    if o:{NL}        try:{NL}            os.rename(orig, quar)' \
    "with both directories present the code would rename the original over the existing quarantine — choosing, which recovery must never do; the failed rename parks the member instead of advancing the quarantine that is already ours."

mutant rename-not-idempotent "T38" "$F" \
    '    if not o and not q:{NL}        return update_member(session_id, agent_id, index, state="missing",' \
    '    if not o:{NL}        return update_member(session_id, agent_id, index, state="missing",' \
    "a crash between the rename and the state write would leave a quarantined tree recorded as MISSING forever."

mutant native-path-prefix "T44" "$F" \
    '            if m.get("class") == "native" and norm_path(m.get("path")) == want:' \
    '            if m.get("class") == "native" and norm_path(m.get("path")).startswith(want):' \
    "WorktreeRemove for one path would resolve another agent's transaction — the wrong worktree set terminalized."

mutant native-path-any-session "T45" "$F" \
    '    try:{NL}        sd = session_dir(session_id){NL}    except ValueError:{NL}        return ""' \
    '    try:{NL}        sd = session_dir(session_id){NL}        import glob as _g{NL}        for _p in _g.glob(os.path.join(tx_root(), "*", "*.json")):{NL}            _t = read_json(_p){NL}            if _t and _t.get("sealed"):{NL}                for _m in _t.get("members") or []:{NL}                    if norm_path(_m.get("path")) == want:{NL}                        return _t.get("agent_id") or ""{NL}    except ValueError:{NL}        return ""' \
    "a native path would resolve across sessions, so a later session reusing the path inherits an old transaction."

mutant terminal-name-global "T32" "$F" \
    '                touch_marker(terminal_name_path(session_id, tx["teammate"]), agent_id + "\n")' \
    '                touch_marker(terminal_name_path("22222222-0000-4000-8000-000000000002", tx["teammate"]), agent_id + "\n"){NL}                touch_marker(terminal_name_path(session_id, tx["teammate"]), agent_id + "\n")' \
    "a terminal NAME would poison the same name in another session — tombstone poisoning by name, finding 4 of the archiver review."

mutant metrics-hide-failed "T49" "$F" \
    '            if st in TERMINAL_STATES:{NL}                out["failed"] += 1{NL}                if present:{NL}                    out["failed_present"] += 1' \
    '            if st in TERMINAL_STATES:{NL}                out["failed"] += 1{NL}                if present:{NL}                    out["terminal_members_present"] -= 1' \
    "a failed member's directory would drop out of the denominator — the reporting exemption finding 10 of the archiver review names."

mutant lock-is-noop "T50" "$F" \
    '                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB){NL}                return self' \
    '                return self' \
    "two ingresses could interleave inside one transaction's read-modify-write; the compare-and-set would compare against a stale read."

mutant second-stop-mutates "T37" "$F" \
    '    if m.get("state") != "ref_saved":{NL}        return tx{NL}    orig = m["path"]{NL}    quar = m.get("quarantine") or quarantine_name(orig, session_id, agent_id){NL}    o, q = os.path.isdir(orig), os.path.isdir(quar)' \
    '    if m.get("state") == "quarantined" and os.path.isdir(m.get("quarantine") or ""):{NL}        os.rename(m["quarantine"], m["quarantine"] + ".again"){NL}        return update_member(session_id, agent_id, index, quarantine=m["quarantine"] + ".again"){NL}    if m.get("state") != "ref_saved":{NL}        return tx{NL}    orig = m["path"]{NL}    quar = m.get("quarantine") or quarantine_name(orig, session_id, agent_id){NL}    o, q = os.path.isdir(orig), os.path.isdir(quar)' \
    "a repeated terminal event would move the quarantine again; every re-fire changes the record and the reconciler chases it."

mutant refs-before-any-rename "T51" "$F" \
    '        for i in order:{NL}            save_ref(session_id, agent_id, i){NL}            quarantine(session_id, agent_id, i)' \
    '        for i in order:{NL}            save_ref(session_id, agent_id, i){NL}        for i in order:{NL}            quarantine(session_id, agent_id, i)' \
    "every repository's ref would be saved before the first rename; a stalled external repository would exhaust the hook budget with the native path still at its original name, and the harness would delete it with its uncommitted bytes (review 2026-09-03, blocker 1)."

mutant repair-result-ignored "T53" "$F" \
    '    if rc != 0 or entry is None or entry.get("prunable"):' \
    '    if False:' \
    "a failed worktree repair would be recorded as a successful quarantine; the next prune deletes the admin directory the quarantine points at and the reconciler loses the index it claims to preserve (review 2026-09-03, blocker 6)."

mutant terminal-index-is-truth "T55" "$F" \
    '        if tx and tx.get("record") == "transaction" and tx.get("terminal"):{NL}            _repair_terminal_indexes(tx){NL}            return True' \
    '        if False:{NL}            _repair_terminal_indexes(tx){NL}            return True' \
    "a crash between the transaction's terminal write and the index write would leave a terminal worker that every guard reads as live — it could write into a quarantine (review 2026-09-03, blocker 5)."

mutant loser-does-not-repair "T56" "$F" \
    '        if tx.get("terminal"):{NL}            _repair_terminal_indexes(tx){NL}            return False, tx{AND}        return tx{NL}    _repair_terminal_indexes(tx){NL}    order = list(' \
    '        if tx.get("terminal"):{NL}            return False, tx{AND}        return tx{NL}    order = list(' \
    "the losing ingress would see the transaction terminal and return without healing a missing index, and terminalize (the other caller every ingress reaches) would not either; the O(1) guards would stay wrong until a reconciler pass happened to run. Both carry the property, so both are removed at once."

mutant ref-not-saved "T33" "$F" \
    '    rc, _, err = _git(m["repo"], "update-ref", ref, head)' \
    '    rc, _, err = 0, "", ""' \
    "the terminal path would quarantine a tree whose unlanded commits are held by nothing but a branch the harness deletes on cleanup (PF11)."

# Two places see a vanished member — save_ref (first to look) and quarantine
# (second). Either alone closes it, so both are mutated in one mutant: back to
# the manual MISSING state this revision retired.
mutant absent-parked-as-missing "T40" "$F" \
    '    if not src:{NL}        return close_absent(session_id, agent_id, index, "neither %s nor %s exists at ref_saved" % (orig, quar)){AND}    if not o and not q:{NL}        return close_absent(session_id, agent_id, index, "neither %s nor %s exists at quarantine" % (orig, quar))' \
    '    if not src:{NL}        return update_member(session_id, agent_id, index, state="missing", error="neither %s nor %s exists" % (orig, quar)){AND}    if not o and not q:{NL}        return update_member(session_id, agent_id, index, state="missing", error="neither %s nor %s exists" % (orig, quar))' \
    "a vanished member would park in a manual MISSING state with no backup ref and wait for a person — the babysitting state the landed review (blocker 3) and the CEO specification (section 4) both forbid."

mutant absent-loses-the-head "T40" "$F" \
    '            rc2, _, err = _git(repo, "update-ref", ref, head)' \
    '            rc2, _, err = 0, "", ""' \
    "closing an absent member would claim the head was preserved under a backup ref it never wrote; the harness deletes the branch, and the unlanded commits would be unreachable."

mutant dir-fsync-swallowed "T61" "$F" \
    '            if e.errno in _DIR_FSYNC_UNSUPPORTED:{NL}                if path not in _dir_fsync_unsupported_noted:' \
    '            if True:{NL}                if path not in _dir_fsync_unsupported_noted:' \
    "every directory-fsync error would be swallowed again — a terminal claim reported durable could vanish after a crash, the exact overstatement the landed review named (2026-09-03, blocker 6)."

mutation_end
