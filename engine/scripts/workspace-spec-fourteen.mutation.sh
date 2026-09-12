#!/usr/bin/env bash
#
# workspace-spec-fourteen.mutation.sh — EVERY ONE OF THE FOURTEEN CHECKS, WATCHED
# GOING RED FOR ITS OWN REASON. Invoked by workspace-spec-fourteen.test.sh; the
# loop is scripts/lib/mutation-harness.sh.
#
# THE BAR, AND WHERE IT CAME FROM. Round-6 brief §6, after the CEO's ruling of
# 2026-09-12 (lifecycle-failure-record-2026-09-12.md §2d): "why is there any
# need to 'imagine' anything if there is a shitload of transcripts from previous
# sessions and this one?" So every mutant here carries one of two labels, in its
# NAME and in its reason:
#
#   R-  RECORDED      derived from a named incident: the record file, its
#                     section, the date, and the commit where the record has
#                     one. Where the record holds ANY mechanical incident for a
#                     point, at least one R- mutant is required.
#   S-  SPEC-DERIVED  the negation of the CEO's sentence, and labeled as
#                     constructed rather than found.
#
# A point with no R- mutant SAYS SO in the report rather than passing quietly:
# points 1 and 2 have no mechanical incident anywhere in the three records
# (lifecycle-failure-record-2026-09-{10,11,12}.md) — the four pre-spec
# `zach-opus-dor*` trees are excluded by the CEO's own second sentence of point
# 1 and are not a failure of this code, and no codex/ workspace has ever been
# touched — so both carry S- mutants only. The count per point is printed by
# the measurement report from the PASS lines below.
#
# EVERY WANT NAMES A SUB-ASSERTION (`C4.3 `), NEVER A CHECK (`C4 `). Check C14 is
# red on the base this was written against (its C14.1: the first spawn with no
# integration branch recorded is not refused), so any mutant wanting `FAIL  C14 `
# would be "proven" by a suite that was red before the mutation was applied.
# The trailing space in each want keeps `C1.1 ` from matching `C1.10`.
#
# Run directly: scripts/workspace-spec-fourteen.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "the fourteen checks of the workspace spec" "scripts/workspace-spec-fourteen.test.sh"

W="scripts/lib/workspaces.py"
G="scripts/hooks/guard-worktree-removal.sh"
C="scripts/create-teammate-worktree.sh"
U="scripts/lib/unlanded-branches.py"
Q="scripts/hooks/guard-unresolved-claims.py"

# --- point 1: no recorded mechanical incident; SPEC-DERIVED only --------------
mutant S-p01-non-cc-registered "C1.1 " "$W" \
    '    if not (branch or "").startswith(CC_PREFIX):{NL}        raise SpecError("branch %r is not named cc/ (point 1)" % branch)' \
    '    if False:{NL}        raise SpecError("branch %r is not named cc/ (point 1)" % branch)' \
    "SPEC-DERIVED (point 1 negated; no recorded incident): a non-native workspace on a branch not named cc/ would be registered and created."
mutant S-p01-raw-worktree-add-allowed "C1.2 " "$G" \
    '        elif sub2 == "add":' \
    '        elif sub2 == "add" and False:' \
    "SPEC-DERIVED (points 1, 3 negated; no recorded incident): a raw 'git worktree add' in Bash would create a workspace registered by nothing, named anything."

# --- point 2: no recorded mechanical incident; SPEC-DERIVED only --------------
mutant S-p02-bash-guard-lets-codex-branch-go "C2.2 " "$G" \
    '        if deletes and any(re.search(r"(?:^|refs/heads/)codex/\S+", t) for t in rest):{NL}            spec.append("git branch -D of a codex/ branch (codex/ is never touched — point 2)")' \
    '        if False:{NL}            spec.append("git branch -D of a codex/ branch (codex/ is never touched — point 2)")' \
    "SPEC-DERIVED (point 2 negated; no recorded incident): 'git branch -D codex/x' in Bash would delete a codex/ branch with no refusal."
mutant S-p02-cc-copy-not-required "C2.4 " "$C" \
    '    codex/*|refs/heads/codex/*)' \
    '    never-a-real-base/*)' \
    "SPEC-DERIVED (point 2 negated; no recorded incident): a cc/ workspace could be cut FROM a codex/ branch, so an agent would work on codex/ work without the copy the page requires."

# --- point 3 ---------------------------------------------------------------
mutant R-p03-registration-without-identity "C3.1 " "$W" \
    '    ident = identity_for(sid){NL}    if not ident:{NL}        raise SpecError("the session'"'"'s process identity could not be read from the operating system; "' \
    '    ident = identity_for(sid){NL}    if False:{NL}        raise SpecError("the session'"'"'s process identity could not be read from the operating system; "' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3.4, 2026-09-10: create-teammate-worktree.sh wrote an ownership row with no agent id; brief-audit-sage-round6 §4.2: the live spec store's one record carries agent_id \"\"]: a spawn whose registration could never tell its session ended would proceed."
mutant R-p03-unregistered-never-listed "C3.4 " "$W" \
    '    made = []{NL}    for repo, path, branch, kind in found:' \
    '    made = []{NL}    for repo, path, branch, kind in []:' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3.1 and §2.11, 2026-09-10: 'Nothing made removing a finished one happen'; five finished branches never landed, found by the CEO in his IDE]: a cc/ or native workspace with no registration would sit forever and never be pending work."
mutant S-p03-worktree-session-allowed "C3.3 " "$W" \
    '        if s and s.get("forbidden"):' \
    '        if False:' \
    "SPEC-DERIVED (point 3 negated): a session started inside its own workspace would be allowed every tool."
mutant S-p03-claude-w-allowed "C3.2 " "$G" \
    'if CLAUDE_WT.search(scan):' \
    'if False:' \
    "SPEC-DERIVED (point 3 negated): 'claude --worktree' / 'claude -w' in Bash would not be refused."

# --- point 4 ---------------------------------------------------------------
mutant R-p04-branch-left-after-land "C4.3 " "$W" \
    '    if branches:{NL}        for repo, b in _branch_targets([rec]):' \
    '    if False:{NL}        for repo, b in _branch_targets([rec]):' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md §2c, 2026-09-12: 'git branch --contains 6fd5aef8' returned cc/frank-opus-c6, cc/sage-opus-c6, cc/zach-opus-g4 after their workspaces were cut and left; and the same record's addendum §A2: 22 cc/ branches deleted by hand today, none by the system]: a land would delete the workspace and leave the branch."
mutant R-p04-quarantine-instead-of-delete "C4.4 " "$W" \
    '            rc, _o, err = git(main, "worktree", "remove", "--force", "--force", path, timeout=300)' \
    '            rc, _o, err = git(main, "worktree", "move", path, os.path.join(os.path.dirname(path), ".richos-retired-" + os.path.basename(path)), timeout=300)' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md addendum §A4, 2026-09-12 16:12Z and 16:13Z: the running engine's removal path renamed cc/sage-opus-c6 and cc/frank-opus-c6 into richos-wt/.richos-retired/ and both are still registered git worktrees; brief-audit-frank-round6 P7; brief-audit-sage-round6 §4.4]: a land would quarantine the workspace instead of deleting it."
mutant S-p04-no-automatic-land "C4.1 " "$W" \
    '        if auto and not _past(deadline):{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=deadline)' \
    '        if False:{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=deadline)' \
    "SPEC-DERIVED (point 4 negated, 'automatically, with nothing left undecided'): merged work would stay undecided until somebody ran a command."

# --- point 5 ---------------------------------------------------------------
mutant R-p05-turn-end-not-blocked "C5.1b" "$W" \
    '    if not blocking:{NL}        msg = "\n".join(notes)' \
    '    if True:{NL}        msg = "\n".join(notes)' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3.1 and §2.11, 2026-09-10: notice-unlanded-branches.sh reported, de-duplicated, and went quiet while six then five finished branches sat outside main; the turn ended every time]: Rich could end his turn with finished work neither landed nor discarded."
mutant R-p05-new-work-not-blocked "C5.1 " "$W" \
    '    if blocking and not (helps & set(i["name"] for i in blocking)):' \
    '    if False:' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md §5 Type D, 2026-09-12: within the hour of clearing 30 worktrees Rich had spawned new agents and left four more finished agents' worktrees plus a native leftover]: new work could start while finished work is pending."
mutant S-p05-answer-allowance-unlimited "C5.3 " "$W" \
    '            if prev.get("state") == state[i["key"]]:{NL}                spent.append((i, prev))' \
    '            if False:{NL}                spent.append((i, prev))' \
    "SPEC-DERIVED (point 5's parenthesis negated, 'the reply names the pending work, which is handled right after'): naming the work again and again would end every turn."
mutant S-p05-notification-counts-as-the-ceo "C5.4 " "$W" \
    '                or "<task-notification>" in text:{NL}            return False{NL}        return True' \
    '                or "<task-notification>" in text:{NL}            return True{NL}        return True' \
    "SPEC-DERIVED (point 5's first allowance negated, 'answering the CEO'): a turn that began with a platform notification would count as answering him."

# --- point 6 ---------------------------------------------------------------
mutant R-p06-native-workspace-not-registered "C6.1 " "$W" \
    '        if rec.get("isolation") == "worktree" and entity:{AND}        if native:{NL}            branch = ""' \
    '        if False and entity:{AND}        if False:{NL}            branch = ""' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3.4, 2026-09-10: 'The sealed manifest is taken at spawn, so a workspace created later joins nothing and no terminal event ever names it. Two workspaces were unreclaimable for the life of a session']: the native workspace the platform creates after the spawn would join no record, so nothing would ever delete it."
mutant S-p06-native-branch-kept "C6.3 " "$W" \
    '            if w.get("branch_deleted_at") or not w.get("branch"):{NL}                continue{NL}            if (w.get("repo"), w["branch"]) not in out:' \
    '            if w.get("branch_deleted_at") or not w.get("branch") or w.get("kind") == "native":{NL}                continue{NL}            if (w.get("repo"), w["branch"]) not in out:' \
    "SPEC-DERIVED (point 6 negated, 'workspace and branch deleted automatically'): a landed native agent's worktree-agent-<id> branch would survive its land."

# --- point 7 ---------------------------------------------------------------
mutant R-p07-discard-records-no-reason "C7.2 " "$W" \
    '            fresh["disposition"] = {"kind": "discarded", "at": now(), "reason": reason.strip(),' \
    '            fresh["disposition"] = {"kind": "discarded", "at": now(), "reason": "",' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md addendum §A2, 2026-09-12: 22 cc/ branches gone today with no deletion event and no reason anywhere in the running engine's ledger; lifecycle-failure-record-2026-09-10.md §2.2: two agents' work destroyed on an inference with nothing recorded]: a discard would record no reason."
mutant S-p07-ending-reads-neither "C7.1 " "$W" \
    '            fresh["disposition"] = {"kind": "landed", "at": now(), "auto": bool(auto), "by_session": me,' \
    '            fresh["disposition"] = {"kind": "closed", "at": now(), "auto": bool(auto), "by_session": me,' \
    "SPEC-DERIVED (point 7 negated, 'ends in exactly one of two ways — landed or discarded'): an ending would read a third word in the store."
mutant S-p07-ceo-order-discardable "C7.4 " "$W" \
    '    if ordered and not (ceo_word or "").strip():' \
    '    if False:' \
    "SPEC-DERIVED (point 7 negated, 'Work the CEO ordered is never discarded without his word'): CEO-ordered work would be discarded on a --not-ceo-ordered claim."

# --- point 8 ---------------------------------------------------------------
mutant R-p08-ignored-needed-files-landed "C8.3 " "$W" \
    '            if ignored and not ignored_ok:' \
    '            if False:' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3b.2, 2026-09-10: an ignored nested repository under a 'disposable' path deleted with no copy taken; scripts/inflight-ack.sh header, 2026-09-05: echo-opus-529's three gitignored acks deleted with its unchanged worktree]: a workspace with ignored files it needs would be landed and the files lost."
mutant S-p08-uncommitted-landed "C8.1 " "$W" \
    '            if dirty:{NL}                problems.append("%s has %d uncommitted entr%s (%s)" % (' \
    '            if False:{NL}                problems.append("%s has %d uncommitted entr%s (%s)" % (' \
    "SPEC-DERIVED (point 8 negated, 'Nothing uncommitted is ever landed'): an uncommitted file would not hold the land."

# --- point 9 ---------------------------------------------------------------
mutant R-p09-finished-agent-not-locked-out "C9.1 " "$W" \
    '    if fin:{NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why)' \
    '    if False:{NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why)' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3b.1 and §3b.5, 2026-09-10: thirteen agents restarted after their terminal record, 0.3 s to 8 h later, three deliverables lost to it; lifecycle-failure-record-2026-09-11.md §2 S4: the fourteenth]: a restarted finished agent would be given its tools back."
mutant R-p09-processes-not-stopped "C9.3 " "$W" \
    '    stopped = stop_processes([w["path"] for _r, w in allw])' \
    '    stopped = {"stopped": [], "survivors": []}' \
    "RECORDED [femcboost CLAUDE.md, Git Worktree Isolation, 'Corollary (zombie residue, 2026-07-18)': a background child outlived both its agent and its worktree and re-created the path; brief-audit-frank-round6 P11, 2026-09-12: VM pid 1483 holding 324 files inside a finished agent's trees five days later]: a process the agent started would outlive the deletion of its workspace."

# --- point 10 --------------------------------------------------------------
mutant R-p10-cc-workspace-left-behind "C10.2 " "$W" \
    '        for w in workspaces:{NL}            # Point 3: the branches the agent created are its branches too, and' \
    '        for w in [w for w in workspaces if w.get("kind") != "cc"]:{NL}            # Point 3: the branches the agent created are its branches too, and' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md addendum §A4, 2026-09-12: for sage-opus-c6 and frank-opus-c6 the native workspaces and branches are gone and the cc/ halves remain as quarantines; lifecycle-failure-record-2026-09-10.md §3.4: zero of 15,882 finish rows ever named a cross-repository workspace]: a land would delete the native workspace and leave the cc/ one."
mutant S-p10-cc-branch-kept "C10.3 " "$W" \
    '            if w.get("branch_deleted_at") or not w.get("branch"):{NL}                continue{NL}            if (w.get("repo"), w["branch"]) not in out:' \
    '            if w.get("branch_deleted_at") or not w.get("branch") or w.get("kind") == "cc":{NL}                continue{NL}            if (w.get("repo"), w["branch"]) not in out:' \
    "SPEC-DERIVED (point 10 negated, 'every workspace and branch it has is deleted, as one'): the cc/ branch of a two-workspace agent would survive the land."

# --- point 11 --------------------------------------------------------------
mutant R-p11-sub-run-end-finishes-the-teammate "C11.1 " "$W" \
    '        rec = _record_for_agent(session_id, agent_id){NL}        if not rec:{NL}            return None{NL}        if rec.get("disposition"):{NL}            rec.setdefault("history", []).append({"at": iso(), "fact": "end after disposition", "signal": signal_name})' \
    '        rec = _record_for_agent(session_id, agent_id) or next((r for r in all_agents() if r.get("session_id") == session_id and r.get("agent_id") and not r.get("end") and not r.get("disposition")), None){NL}        if not rec:{NL}            return None{NL}        if rec.get("disposition"):{NL}            rec.setdefault("history", []).append({"at": iso(), "fact": "end after disposition", "signal": signal_name})' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §3.5, 2026-09-10: the finish event's agent_id is a per-run identifier, not the owning agent, and the code derived the owner from the folder instead; lifecycle-failure-record-2026-09-12.md addendum §A3: 974 finished rows for 25 teammates today, 973 distinct ids, 0 carrying a branch]: a sub-run's end would be recorded as the teammate's own and finish it mid-work."
mutant S-p11-pause-ignored "C11.3 " "$W" \
    '        pause = rec.get("pause"){NL}        if pause and pause.get("at", 0) <= end.get("at", 0):' \
    '        pause = rec.get("pause"){NL}        if False:' \
    "SPEC-DERIVED (point 11 negated, 'An agent Rich pauses ... is not finished'): a paused agent whose run ended would be finished and locked out."
mutant S-p11-nameless-pause-not-pending "C11.5 " "$W" \
    '            if paused_ and rec.get("session_id") == me and not (rec.get("pause") or {}).get("until"):' \
    '            if False:' \
    "SPEC-DERIVED (point 11 negated, 'a pause with nothing named counts as pending work under point 5'): a pause naming nothing would block nothing and stay paused forever."

# --- point 12 --------------------------------------------------------------
mutant R-p12-ended-session-agents-not-finished "C12.4 " "$W" \
    '        if st == "ended":{NL}            return True, False, "its session has ended: %s (point 12)" % why' \
    '        if False:{NL}            return True, False, "its session has ended: %s (point 12)" % why' \
    "RECORDED [brief-audit-sage-round6-2026-09-12.md §4.3, 2026-09-12: 26 of the running engine's 49 holds belong to sessions b7869424 and d0eef867, both ended, and are still held; lifecycle-failure-record-2026-09-10.md §2.5: pgrep cannot see subagents at all]: an ended session's agents would never count as finished."
mutant S-p12-a-pid-alone-is-the-session "C12.2 " "$W" \
    '        elif st == "ok" and text != ident["pid_start"]:' \
    '        elif False:' \
    "SPEC-DERIVED (point 12 negated, 'The record carries more than a process number, since those get reused'): a reused process number would be taken for the session."
mutant S-p12-next-session-does-not-take-over "C12.5 " "$W" \
    '        st, _ = session_state(owner, rec.get("session_identity"), cache){NL}        if st != "ended":{NL}            return False' \
    '        st, _ = session_state(owner, rec.get("session_identity"), cache){NL}        if True:{NL}            return False' \
    "SPEC-DERIVED (point 12 negated, 'the next session lands or discards their work before anything else'): the next session would never handle an ended session's agents."

# --- point 13 --------------------------------------------------------------
mutant R-p13-failed-deletion-not-retried "C13.3 " "$W" \
    '        if not d or d.get("next_at", 0) > now():{NL}            continue' \
    '        if True:{NL}            continue' \
    "RECORDED [lifecycle-failure-record-2026-09-10.md §2.17, 2026-09-10: 'It was a virtual machine holding files open, and the prefix was irrelevant'; brief-audit-frank-round6 P5, 2026-09-12: four trees held by VM pid 1483, called RETRY by the running engine and never retried to completion]: a failed deletion would never be retried."
mutant S-p13-ceo-told-at-the-first-failure "C13.2 " "$W" \
    'RETRY_TELL_CEO_AFTER = int(os.environ.get("RICHOS_WORKSPACES_RETRY_TELL_CEO", "5"))' \
    'RETRY_TELL_CEO_AFTER = int(os.environ.get("RICHOS_WORKSPACES_RETRY_TELL_CEO", "1"))' \
    "SPEC-DERIVED (point 13 negated, 'The CEO hears about it only if it keeps failing'): the CEO would be told at the first failed attempt."

# --- point 14 --------------------------------------------------------------
mutant R-p14-land-assumes-main "C14.3 " "$W" \
    '    branch = (work or {}).get("branch") or ""{NL}    if not branch:' \
    '    branch = "main"{NL}    if not branch:' \
    "RECORDED [lifecycle-failure-record-2026-09-12.md §2c and brief-audit-sage-round6 §4.6, 2026-09-12: a true land onto dev/workspace-spec was refused by a check that asked main; 19 of the running engine's holds read 'NOT on refs/heads/main' for work that is on dev/workspace-spec]: a land would be proved against main whatever branch was recorded."
mutant S-p14-consumer-keeps-its-own-answer "C14.6 " "$Q" \
    '    if why_not or not branch:{NL}        return (){NL}    remote = "origin/" + branch' \
    '    if why_not or not branch:{NL}        return INTEGRATION_REFS{NL}    remote = "origin/" + branch' \
    "SPEC-DERIVED (point 14 negated, 'None of them is allowed its own answer, and none of them assumes main'): guard-unresolved-claims.py would fall back to main where nothing is recorded."
mutant S-p14-unlanded-sweep-assumes-main "C14.5 " "$U" \
    '    if why_not or not branch:{NL}        return None{NL}    return branch' \
    '    if why_not or not branch:{NL}        return "main"{NL}    return branch' \
    "SPEC-DERIVED (point 14 negated): unlanded-branches.py would measure against main where nothing is recorded instead of abstaining."

mutation_end
