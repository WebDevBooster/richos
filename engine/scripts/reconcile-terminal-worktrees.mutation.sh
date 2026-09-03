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
    '    if os.path.lexists(orig):{NL}        left = kill_and_reap(processes_using([orig]))' \
    '    if False:{NL}        left = kill_and_reap(processes_using([orig]))' \
    "a recreated original path would sit beside a removed quarantine forever, uncounted."

mutant backup-ref-not-protected "C04" "$R" \
    '    if ref and not _ref_exists(repo, ref):{NL}        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed",{NL}                                error="backup ref %s vanished during unregistering" % ref){NL}    return tx.update_member(t["session_id"], t["agent_id"], index, state="unregistered")' \
    '    git_out(repo, "update-ref", "-d", ref){NL}    return tx.update_member(t["session_id"], t["agent_id"], index, state="unregistered")' \
    "unregistering would delete the backup ref — the only thing that keeps unlanded commits reachable once the harness deletes the branch (PF11)."

mutant hard-failure-hidden "C19" "$R" \
    '    m["done"] = (m["terminal_members_present"] == 0 and m["pending_retry"] == 0)' \
    '    m["done"] = (m["pending_retry"] == 0)' \
    "a failed member with its directory still on disk would read as done — the reporting exemption finding 10 of the archiver review names."

mutant status-exit-always-zero "C19" "$R" \
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

mutation_end
