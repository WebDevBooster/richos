#!/usr/bin/env bash
#
# reconcile-terminal-worktrees.mutation.sh — PROVES the reconciler's suite
# CAN FAIL, one property at a time. Invoked by
# reconcile-terminal-worktrees.test.sh; the loop is
# scripts/lib/mutation-harness.sh. Case ids (C07 etc.) are the ones that suite
# prints on both PASS and FAIL.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "reconcile-terminal-worktrees (the persistent reconciler)" "scripts/reconcile-terminal-worktrees.test.sh"

R="scripts/reconcile-terminal-worktrees.py"

mutant ignored-evidence-dropped "C07" "$R" \
    '            if fn in disposable or rel in disposable:{NL}                continue{NL}            full = os.path.join(dirpath, fn)' \
    '            if fn in disposable or rel in disposable or fn.endswith(".log"):{NL}                continue{NL}            full = os.path.join(dirpath, fn)' \
    "an ignored evidence file would be missing from the archive — PF9: git worktree remove deletes gitignored files without refusing, and the archive is the only copy."

mutant disposable-policy-ignored "C08" "$R" \
    '        for d in dirnames:{NL}            rel = os.path.join(rel_dir, d) if rel_dir else d{NL}            if d in disposable or rel in disposable:{NL}                continue' \
    '        for d in dirnames:{NL}            rel = os.path.join(rel_dir, d) if rel_dir else d{NL}            if False:{NL}                continue' \
    "node_modules would be archived on every removal — the committed policy would be prose."

mutant staged-blob-not-archived "C09" "$R" \
    '        e["needs_blob"] = e["mode"] != "160000" and e["sha"] not in head_objects' \
    '        e["needs_blob"] = False' \
    "a staged-but-uncommitted blob would exist only in an index that git worktree remove is about to delete."

mutant verification-skipped "C18" "$R" \
    '    try:{NL}        _verify_archive(m, cdir){NL}    except ArchiveMismatch as e:' \
    '    try:{NL}        pass{NL}    except ArchiveMismatch as e:' \
    "a damaged archive would authorize deletion — the one thing verification exists to refuse."

mutant settle-not-required "C16" "$R" \
    '    if man_a != man_b:{NL}        raise RuntimeError("the quarantine changed during the settle interval' \
    '    if False:{NL}        raise RuntimeError("the quarantine changed during the settle interval' \
    "a file being written during capture would produce a torn archive that verifies against a manifest taken from the same torn moment."

mutant writers-not-killed "C14" "$R" \
    '    left = kill_and_reap(processes_using([quar])){NL}    if left:{NL}        raise RuntimeError("processes still using %s after SIGKILL: %s" % (quar, left))' \
    '    left = []{NL}    if left:{NL}        raise RuntimeError("processes still using %s after SIGKILL: %s" % (quar, left))' \
    "a process standing in the quarantine would survive capture and could recreate the path after removal."

mutant residue-not-reclaimed "C15" "$R" \
    '    if os.path.lexists(orig):{NL}        foreign = _foreign_registration(m, orig)' \
    '    if False:{NL}        foreign = _foreign_registration(m, orig)' \
    "a recreated original path would sit beside a removed quarantine forever, uncounted."

mutant backup-ref-not-protected "C04" "$R" \
    '    if "re-created" in outcomes:{NL}        fields["backup_ref_recreated"] = True{NL}    return tx.update_member(sid, aid, index, **fields)' \
    '    if "re-created" in outcomes:{NL}        fields["backup_ref_recreated"] = True{NL}    git_out(repo, "update-ref", "-d", ref) if ref else None{NL}    return tx.update_member(sid, aid, index, **fields)' \
    "unregistering would delete the backup ref — the only thing that keeps unlanded commits reachable once the harness deletes the branch (PF11)."

# (retired 2026-09-03: hard-failure-hidden mutated `done` to ignore present
# directories. No member state parks a directory any more — every condition
# retries or closes — so the mutant has no case to turn red here; the
# denominator property lives in worktree-transactions.mutation.sh metrics-hide-failed / T49.)

mutant status-exit-always-zero "C42" "$R" \
    '        return 0 if s["done"] else 1' \
    '        return 0' \
    "every caller that checks the exit code would read a dead-present machine as clean."

mutant grace-ignored "C26" "$R" \
    '        if age < grace:{NL}            continue' \
    '        if False:{NL}            continue' \
    "a pending event would be routed through fallback cleanup the instant it was recorded, before the bind or start fact that would have sealed it properly had any chance to arrive (review 2026-09-03, blocker 4)."

mutant fallback-never-built "C27" "$R" \
    '        with tx.tx_lock(sid, aid):{NL}            if tx.load_tx(sid, aid) is None:{NL}                tx.atomic_write_json(tx.tx_path(sid, aid), fallback)' \
    '        with tx.tx_lock(sid, aid):{NL}            pass' \
    "a permanently unbindable agent's prepared worktrees would never be cleaned: the pending event would sit forever and the trees with it."

mutant start-only-native-dropped "C28b" "$R" \
    '        nat, _why = tx._verify_native_member(tx.norm_path(cand), aid){NL}        if nat is not None:{NL}            members.insert(0, nat)' \
    '        nat, _why = None, "dropped"{NL}        if nat is not None:{NL}            members.insert(0, nat)' \
    "a start-only exact native worktree — the binder-failure path — would never be retired: the pending record would close as a zero-member tombstone with the worktree left behind forever (landed review 2026-09-03, blocker 2)."

mutant tombstone-dropped "C28a" "$R" \
    '        members = _creation_time_members(sid, aid, bound, start, p)' \
    '        members = _creation_time_members(sid, aid, bound, start, p){NL}        if not members:{NL}            _unlink(ppath); continue' \
    "a recorded terminal event for an agent with no verifiable member would be reinterpreted as if it never happened — no transaction, no tombstone — which is the certification C28 used to carry (landed review 2026-09-03, blocker 2)."

mutant native-gone-backstop-blind "C39" "$R" \
    '        gone, why = native_member_gone(nat)' \
    '        gone, why = False, ""' \
    "a worker whose native worktree the platform tore down with no hook delivered (the measured TaskStop kill) would stay sealed-live forever and its hand-rolled worktree would leak — the reproduction of 2026-09-03 (CEO specification, section 4)."

mutant native-gone-backstop-trigger-happy "C40" "$R" \
    '        gone, why = native_member_gone(nat)' \
    '        gone, why = True, "always"' \
    "every sealed LIVE worker would be terminalized on the next reconciler pass — the old sweep, back, deleting a live agent's worktrees with every guard reporting green."

L="scripts/lib/worktree-transactions.py"

mutant residue-unverified "C19" "$R" \
    '                _verify_tar(rpath, rman){NL}                residue_verified = True' \
    '                residue_verified = False' \
    "the residue at an original path would be deleted on the strength of an archive nobody verified — the both-present policy requires both exact paths archived AND verified before anything is removed (landed review 2026-09-03, blocker 3)."

mutant foreign-original-deleted "C45" "$R" \
    '        foreign = _foreign_registration(m, orig)' \
    '        foreign = ""' \
    "a worktree git registers at the original path — somebody else's, prepared later at the same path — would be archived as residue and DELETED: a live worker's tree destroyed by name resemblance."

mutant drift-parked-as-failed "C44" "$R" \
    '    if m.get("head") and head and head != m.get("head"):{NL}        n = int(m.get("head_drift_count") or 0) + 1' \
    '    if m.get("head") and head and head != m.get("head"):{NL}        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed", error="drift"){NL}        n = int(m.get("head_drift_count") or 0) + 1' \
    "a quarantine whose HEAD moved would park as FAILED for an operator instead of preserving the moved HEAD under a drift ref and proceeding (landed review 2026-09-03, blocker 3)."

mutant backoff-ignored "C42" "$R" \
    '                if base > 0 and float(m.get("retry_after_epoch") or 0) > time.time():' \
    '                if False:' \
    "a failing member would be hammered on every pass with no backoff — the persistent schedule the landed review requires (blocker 3) would be prose."

mutant legacy-failed-parked "C46" "$R" \
    '                if st == "removed":{NL}                    break' \
    '                if st in ("removed", "failed", "missing"):{NL}                    break' \
    "a member an earlier revision left FAILED or MISSING would never be re-derived: the permanent manual queue, back."

mutant unregistered-native-parked "C43" "$L" \
    '        if reg is not None and norm_path(src) in reg and not reg[norm_path(src)].get("prunable"):' \
    '        if True:' \
    "a directory git can neither read nor list would be retried forever as a transient failure instead of having its raw bytes captured and closed (landed review 2026-09-03, blocker 3)."

mutant native-missing-not-in-done "C47b" "$R" \
    '                 and m["sealed_native_missing"] == 0 and overdue == 0' \
    '                 and overdue == 0' \
    "--status would report done: true over a sealed transaction whose native member the platform tore down — the measured defect: a leaked hand-rolled worktree behind a clean status (CEO specification, section 5)."

mutant native-presence-unexamined "C47b" "$L" \
    '            elif native_member_gone(nat)[0]:{NL}                out["sealed_native_missing"] += 1' \
    '            elif False:{NL}                out["sealed_native_missing"] += 1' \
    "every sealed non-terminal transaction would be called present without examining its native member — `sealed_live` under a new name."

mutant index-failure-swallowed "C29" "$R" \
    '    for rec in git_must(quar, "ls-files", "-s", "-z").split("\0"):' \
    '    for rec in git_out(quar, "ls-files", "-s", "-z")[1].split("\0"):' \
    "a failed ls-files would be an empty index and the member would advance to captured; staged-only state would be deleted on the strength of an archive that never held it (review 2026-09-03, blocker 2)."

mutant missing-blob-accepted "C31" "$R" \
    '        if not os.path.isfile(bpath):{NL}            raise ArchiveMismatch("staged blob %s for %s is missing from the archive" % (e["sha"], e.get("path")))' \
    '        if not os.path.isfile(bpath):{NL}            continue' \
    "a staged blob that should exist but was never written would verify by its absence."

mutant symlink-target-unchecked "C32" "$R" \
    '                if ti.linkname != info.get("target"):' \
    '                if False:' \
    "an archived symlink pointing anywhere would verify (review 2026-09-03, blocker 8)."

mutant mode-unchecked "C33" "$R" \
    '            if (ti.mode & 0o7777) != info.get("mode"):' \
    '            if False:' \
    "an executable restored as non-executable, or the reverse, would verify."

mutant artifacts-not-private "C34" "$R" \
    '    os.umask(0o077){AND}        os.chmod(p, 0o700){AND}    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)' \
    '    pass{AND}        pass{AND}    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)' \
    "captures holding ignored secrets would be created at the ambient umask, readable by every account on the machine."

mutant retention-never-runs "C37" "$R" \
    '    try:{NL}        retention_pass(){NL}    except Exception as e:' \
    '    try:{NL}        pass{NL}    except Exception as e:' \
    "captures, backup refs and transaction records would accumulate forever; the secret-retention window would be unbounded."

mutant record-expires-before-artifacts "C36" "$R" \
    '            if age >= tx_days and artifacts_gone:' \
    '            if age >= tx_days:' \
    "a transaction record would be deleted while its backup ref still existed — an artifact orphaned from the record that explains it."

mutant backup-ref-expiry-assumed "C38" "$R" \
    '                    gone, why = _expire_backup_ref(m.get("repo"), ref)' \
    '                    gone, why = True, "assumed"' \
    "a rejected `git update-ref -d` would still stamp the member expired; transaction retention trusts the stamp and deletes the only record saying the ref exists, and the ref lives on forever, untracked (landed review 2026-09-03, blocker 4)."

mutant backup-ref-exit-code-trusted "C38b" "$R" \
    '    if _ref_exists(repo, ref):{NL}        return False, "git update-ref -d %s exited 0 but the ref still resolves" % ref' \
    '    if False:{NL}        return False, "git update-ref -d %s exited 0 but the ref still resolves" % ref' \
    "a deletion that exited 0 without removing the ref would be believed — the exact ref is what must be verified absent, not the exit code."

mutant budget-ignored "C23" "$R" \
    '        if deadline and time.time() > deadline:{NL}            log("time budget reached; the rest waits for the next run"){NL}            break' \
    '        if False:{NL}            log("time budget reached; the rest waits for the next run"){NL}            break' \
    "a SessionStart crash-recovery run could hold a session start for as long as the backlog takes."

# --- THE HARNESS LOCK (2026-09-04). Each mutant here removes ONE precondition
# on breaking a git worktree lock. The lock is the platform's own signal, and
# the whole safety of this revision is that it is released only over an object
# that is provably nobody's workspace with its bytes provably preserved.

mutant lock-never-broken "C48" "$R" \
    '            _break_own_quarantine_lock(t, index, repo, quar, reg.get(tx.norm_path(quar)))' \
    '            pass' \
    "the pre-2026-09-04 behavior returns: a verified quarantine locked by its own agent retries forever, and worktrees accumulate one per dispatch until the session process exits."

mutant foreign-lock-broken "C52" "$R" \
    '    if holder != aid:{NL}        refuse("P4: the lock is signed %r, not by this member'"'"'s agent %r" % (holder or lock_line, aid))' \
    '    if False:{NL}        refuse("P4: the lock is signed %r, not by this member'"'"'s agent %r" % (holder or lock_line, aid))' \
    "a lock left by ANY other agent — including one that is still running — would be broken and its worktree removed. This is the live-agent eviction of wiki 12.1, mechanized."

mutant quarantine-name-not-checked "C60" "$R" \
    '    if tx.norm_path(quar) != tx.norm_path(expected) or tx.norm_path(quar) != tx.norm_path(m.get("quarantine") or ""):' \
    '    if False:' \
    "the lock break could be aimed at any path a transaction record happened to name, instead of only at the canonical quarantine name that ONLY a terminal ingress can create."

mutant archive-not-required "C58" "$R" \
    '    if not (m.get("verified_ts") and cap and os.path.isdir(cap)):' \
    '    if False:' \
    "a lock would be broken and a directory deleted with no verified archive on disk — the bytes would be preserved only by assertion."

mutant blocked-reported-as-retry "C54" "$R" \
    '        "members_blocked_on_a_condition_waiting_cannot_clear": m["blocked"],' \
    '        "members_blocked_on_a_condition_waiting_cannot_clear": 0,' \
    "a deadlock would be reported as a normal retry again — thirty stuck members read as a fleet under control for a full day on 2026-09-04."

\n
mutant blocked-backoff-compounds "C62" "$R" \
    '        delay = base if blocked else min(base * (2 ** max(attempts - 1, 0)), cap)' \
    '        delay = min(base * (2 ** max(attempts - 1, 0)), cap)' \
    "a blocked member would compound to six hours again, so a repair that lands at any moment would go unnoticed for most of a working day and read as not working."

mutation_end
