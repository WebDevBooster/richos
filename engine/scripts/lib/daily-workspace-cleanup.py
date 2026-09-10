"""Cooperative terminal cleanup. No forced removal or hostile-writer claim.

Caller holds the existing transaction lock. A durable per-member proof precedes
removal, native Git checks cleanliness again and branch deletion uses exact CAS.
Incomplete/ambiguous ownership stays pending. Historical quarantine is separate.

ROUND 10 (2026-09-10, docs/worktree-reclaim-round-10-2026-09-10.md). What
authorizes a removal did not change: a sealed transaction with a recorded
terminal ingress, a proof that the tracked tree is byte-identical to a commit
that `main` contains, an exact unlocked registration, and no competing
reservation. What changed is four predicates that were refusing on grounds
that were never about ownership or terminal state:

  * ignored bytes no longer hold a workspace. Those matching the committed
    disposable policy (CAPTURE_DISPOSABLE_PATHS) go with the tree; every
    other ignored file is archived and verified digest-by-digest BEFORE the
    non-force `git worktree remove`, and the archive is named on the journal.
    Nothing ignored is discarded without a copy, and nothing disposable is
    kept on behalf of nobody;
  * `TaskStop` (a platform ingress this engine already claims on) and
    `Adoption` (T1/T2 evidence) are terminal facts like the other three;
  * a platform-native checkout whose OWNING SESSION IS PROVABLY GONE — every
    recorded process identity of that session answers gone/reused, the
    harness registry names no running pid for it, and its lock (if any) names
    a dead pid — is RichOS's to remove: the dead lock is released and the same
    proof, integration check and non-force removal apply. A running or
    unknown session keeps deferring to the platform exactly as before;
  * an absent, platform-removed native member with no completion receipt has
    its branch deleted only when the branch's CURRENT tip is an ancestor of
    `main` and no checkout holds it — a fully merged branch with no working
    tree loses nothing — by compare-and-set on the tip that was checked.

A process standing in the tree holds it (nothing is killed). An untracked
file, an unmerged commit, a live lock, a running owner, a changed tip or an
unverifiable archive holds it. Every hold is written on the member.
"""
import hashlib
import importlib.util
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import time

HERE = Path(__file__).resolve().parent
ENGINE_ROOT = HERE.parent.parent

# The ingresses this engine records. SubagentStop / WorktreeRemove / TaskStop
# are written by terminalize-agent-worktrees.sh from platform events about an
# exact agent id; NativeMemberGone by the reconciler's backstop on a verified
# absence; Adoption by worktree-adoption.py on T1/T2 evidence. Anything else
# (a name-based event, a fixture, a future event nobody measured) is not a
# terminal fact and keeps the member reserved.
ACCEPTED_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'NativeMemberGone', 'TaskStop', 'Adoption')

DEFAULT_DISPOSABLE = "node_modules .venv venv target build dist .gradle .next .turbo __pycache__ .pytest_cache .DS_Store .cache"
LOCK_PID_RE = re.compile(r"\(pid\s+(\d+)")

# How many immediate-reclaim attempts are kept per member. The journal used to
# keep ONE and the last writer erased every earlier outcome (Frank D14).
IMMEDIATE_RECLAIM_HISTORY_LIMIT = 20


def _load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def config_value(key, default, repo=None):
    """The entity's orchestration.config if it declares the key, else the
    engine's, else the default — the same resolution the reconciler uses."""
    candidates = ([os.path.join(repo, 'orchestration.config')] if repo else []) + [str(ENGINE_ROOT / 'orchestration.config')]
    for cfg in candidates:
        try:
            with open(cfg, encoding='utf-8') as stream:
                for line in stream:
                    line = line.strip()
                    if line.startswith(key + '='):
                        return line.split('=', 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return default


def disposable_paths(repo):
    """The committed disposable-path policy: names that match a path component
    at any depth. Data a reviewer can read, never a constant hidden in code."""
    return set(config_value('CAPTURE_DISPOSABLE_PATHS', DEFAULT_DISPOSABLE, repo).split())


def read_record(path):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 16 * 1024 * 1024:
        raise RuntimeError('ownership record is not a bounded regular file: ' + str(path))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, encoding='utf-8') as stream:
        opened = os.fstat(stream.fileno())
        if (info.st_dev, info.st_ino) != (opened.st_dev, opened.st_ino):
            raise RuntimeError('ownership record changed while opening')
        value = json.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError('ownership record malformed')
    return value


def _same_scope(member, target):
    paths = [member.get('path'), member.get('quarantine'), member.get('worktree')]
    wanted = target['path']
    for path in filter(None, paths):
        if not isinstance(path, str) or not os.path.isabs(path):
            raise RuntimeError('ownership path malformed')
        if path == wanted or path.startswith(wanted + '/') or wanted.startswith(path.rstrip('/') + '/'):
            return True
    branch, wanted_branch = member.get('branch') or '', target.get('branch') or ''
    if not isinstance(branch, str) or not isinstance(wanted_branch, str):
        raise RuntimeError('ownership branch malformed')
    branch = branch[len('refs/heads/'):] if branch.startswith('refs/heads/') else branch
    wanted_branch = wanted_branch[len('refs/heads/'):] if wanted_branch.startswith('refs/heads/') else wanted_branch
    return member.get('repo') == target['repo'] and bool(branch) and branch == wanted_branch


def _is_this_members_own_row(row, member):
    """The ledger row names EXACTLY this member's path. `_same_scope` also
    matches on repository+branch, which is right for a reservation question
    and too loose for "this row is this member's own preparation"."""
    try:
        return os.path.realpath(row.get('worktree') or '') == os.path.realpath(member.get('path') or '')
    except (TypeError, ValueError):
        return False


def terminal_fact(transaction):
    return (transaction.get('sealed') is True
            and isinstance(transaction.get('terminal'), dict)
            and transaction['terminal'].get('ingress') in ACCEPTED_INGRESSES)


def _adopted_owns_row(transaction, member, row):
    """An adopted transaction claimed ONE exact path on T1/T2 evidence, so the
    ledger's preparation of that same path belongs to it — the row's session
    is the dead one adoption proved gone. Any other path is not its own."""
    if transaction.get('kind') != 'adopted':
        return False
    return os.path.realpath(row.get('worktree') or '') == os.path.realpath(member.get('path') or '')


def ceo_owned_workspace(member):
    """(is_ceo_owned, why) — ceo-decisions.md section 31, IN THE MECHANISM.

    Section 31: "no sweep, reaper, reconciler or land sequence removes a
    `codex/` workspace ... There is no blanket flag, no reason string that
    unlocks the class", and "an excluded workspace is REPORTED, never silently
    skipped: 'excluded by CEO ruling', never counted as clean and never absent
    from the report."

    Until 2026-09-10 no removal path in this engine tested for it. The argument
    was that Codex folders are never registered by us, so they are never
    members and never reached — and that argument is true, and section 31 says
    in as many words that it must not be the defense: "The record hole WAS the
    protection ... Closing it without this ruling in the mechanism would have
    destroyed all eight on the first sweep." The same day, a hand-written
    ledger row brought an unregistered workspace INTO the lane and it was
    removed 45 minutes later, which is the record hole being closed by hand.
    That door is shut separately (worktree-ledger.BINDING_LEDGER_WRITERS); this
    is the ruling itself, in the code, so it holds even if the door opens
    again.

    It is a REFUSAL TO REMOVE and never a reason to act on anything: no path
    removes, unlocks, refuses or reports anything ELSE because of it.
    """
    branch = (member.get('branch') or '')
    branch = branch[len('refs/heads/'):] if branch.startswith('refs/heads/') else branch
    if branch.startswith('codex/'):
        return True, ('branch %s is the CEO\'s by ceo-decisions.md section 31 — excluded by CEO '
                      'ruling, and there is no flag and no reason string that unlocks the class' % branch)
    path = os.path.realpath(member.get('path') or '') if member.get('path') else ''
    codex_root = os.path.realpath(os.path.join(os.path.expanduser('~'), '.codex', 'worktrees'))
    if path and (path == codex_root or path.startswith(codex_root + os.sep)):
        return True, ('%s is under %s and is the CEO\'s by ceo-decisions.md section 31 — excluded '
                      'by CEO ruling' % (path, codex_root))
    return False, ''


def owner_check(tx, transaction, member):
    """Positive terminal fact plus fresh complete competing-reservation veto.

    A workspace this engine never registered is not a member of any
    transaction, so it is never a candidate. That was offered as satisfying the
    CEO's codex ruling by construction; section 31 says outright that the
    record hole must not BE the protection, so ceo_owned_workspace is checked
    FIRST, before any other gate, and is defense in depth rather than the
    defense.
    """
    ceo_owned, why = ceo_owned_workspace(member)
    if ceo_owned:
        raise RuntimeError('EXCLUDED BY CEO RULING (ceo-decisions.md section 31): ' + why)
    if not terminal_fact(transaction):
        raise RuntimeError('exact sealed native terminal ownership required')
    sid, aid = transaction['session_id'], transaction['agent_id']
    root = Path(tx.tx_root())
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('transaction inventory unavailable')
    records = {}
    for session in root.iterdir():
        if session.name in ('terminal', 'terminal-names'):
            continue
        if session.is_symlink():
            raise RuntimeError('transaction inventory symlink')
        if not session.is_dir():
            continue
        for path in session.glob('*.json'):
            other = read_record(path)
            if other.get('record') != 'transaction' or not isinstance(other.get('members'), list):
                raise RuntimeError('transaction inventory malformed')
            key = (other.get('session_id'), other.get('agent_id'))
            if key in records:
                raise RuntimeError('duplicate transaction identity')
            records[key] = other
            for candidate in other['members']:
                if not isinstance(candidate, dict):
                    raise RuntimeError('transaction member malformed')
                if key != (sid, aid) and _same_scope(candidate, member):
                    if not terminal_fact(other):
                        raise RuntimeError('active or unknown transaction reservation')
    current = records.get((sid, aid))
    if not current or not terminal_fact(current):
        raise RuntimeError('terminal ownership changed')
    ledger = _load('worktree-ledger')
    ledger_path = Path(ledger.ledger_path())
    if os.path.lexists(ledger_path):
        info = os.lstat(ledger_path)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise RuntimeError('ownership ledger unavailable')
        with open(ledger_path, encoding='utf-8') as stream:
            for line in stream:
                if not line.strip():
                    continue
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise RuntimeError('ownership ledger malformed')
                if row.get('event') not in ('prepared', 'registered') or not _same_scope(row, member):
                    continue
                key = (row.get('session_id'), row.get('agent_id'))
                own = key == (sid, aid) or _adopted_owns_row(transaction, member, row)
                if (not own and not row.get('agent_id') and row.get('session_id') == sid
                        and row.get('teammate') == transaction.get('teammate')
                        and bool(transaction.get('teammate'))
                        # AN ENGINE WRITER, OR THE NAME JOIN DOES NOT HAPPEN.
                        # See worktree-ledger.BINDING_LEDGER_WRITERS: a hand
                        # -written row with a session, a teammate and no agent
                        # id put an unregistered workspace into this lane on
                        # 2026-09-10 and it was removed 45 minutes later. Such a
                        # row still RESERVES below (fail-closed); it never
                        # authorizes.
                        and ledger.row_may_bind_by_name(row)):
                    # A name can be reused after an earlier terminal record.
                    # Only the preparation predating this exact seal belongs
                    # to it; absent/ambiguous timestamps retain the reservation.
                    try:
                        own = datetime.fromisoformat(row['ts'].replace('Z', '+00:00')) <= datetime.fromisoformat(transaction['sealed_ts'].replace('Z', '+00:00'))
                    except (KeyError, TypeError, ValueError):
                        own = False
                    if not own and member.get('bound_late') and _is_this_members_own_row(row, member):
                        # THE ROW IS THIS MEMBER'S OWN PREPARATION. It postdates
                        # the seal, which is why the clause above rejects it,
                        # and that boundary is exactly what left two of
                        # zach-opus-dor2's four workspaces owned by nobody on
                        # 2026-09-10. worktree-transactions.bind_late_members
                        # has since bound this EXACT path to this transaction
                        # on this same row, having checked the name is unique
                        # in the session, the path is a real worktree of the
                        # named repository on the named branch, and no other
                        # transaction owns it. Two places were reading one
                        # join and disagreeing; they now agree.
                        own = True
                other = records.get(key)
                if not own and not row.get('agent_id') and not (other and terminal_fact(other)):
                    # A ROW THAT NAMES NO AGENT IS A CLAIM ON BEHALF OF A
                    # SESSION, and nothing keyed to it can ever retire it —
                    # there is no transaction at (session, '') and there never
                    # will be. Measured 2026-09-10: two id-less rows written by
                    # session 44276098 on 2026-09-02 were still reserving
                    # /Users/alex/ab/richos-wt/zach-opus-prem1 eight days
                    # later, for a session with no running process anywhere.
                    # So the row is retired by the only thing that can retire
                    # it: positive evidence that its session is over, to the
                    # same standard as everywhere else (every recorded pid
                    # gone or reused, and no running registration). A session
                    # that is alive, unknown, or has no recorded identity
                    # still reserves, exactly as before.
                    gone, _why = session_id_gone(row.get('session_id') or '', tx)
                    if gone:
                        continue
                if not own and not (other and terminal_fact(other)):
                    raise RuntimeError('active or unbound preparation reservation')
    # THE AGENT IS IN A RUN RIGHT NOW. Round 12, 2026-09-10: the platform runs
    # agents again after their terminal record (ten of 66 workspace-owning
    # terminal transactions on this machine, the earliest two days before
    # round 11 was written — `restart-after-terminal-measure.py`). Nothing had
    # ever recorded that, so nothing could refuse on it. The start and stop
    # hooks now append every post-terminal lifecycle event to the transaction,
    # and this is the refusal that reads them. It covers EVERY member class,
    # which the native lock below cannot: a cross-repository worktree carries
    # no platform lock at all, and that is where the work actually lives.
    #
    # ROUND 13: read from TWO sources, voided by the session's death, and aged
    # (post_terminal_run_open) — a hold that could never clear is Type J.
    run_open, why_open = post_terminal_run_open(tx, transaction)
    if run_open:
        raise RuntimeError(why_open)
    # A live native lock vetoes everything above it. Never use the
    # cross-repository worktree as that lock.
    native = [m for m in transaction['members'] if m.get('class') == 'native']
    entity = native[0]['repo'] if native else member['repo']
    live = _load('agent-liveness').resolve(entity, aid)
    if live.get('verdict') != 'NOT-ALIVE':
        raise RuntimeError('native owner is live or unknown: ' + str(live.get('reason')))


# ---------------------------------------------------------------------------
# row 5 — a post-terminal run is open (or is not, or cannot be any more)
# ---------------------------------------------------------------------------

def post_terminal_run_stale_seconds(repo=None):
    """How old an open post-terminal run may be before the hold names the
    operator remedy instead of "until the run ends". Committed data. Every
    post-terminal run observed on this machine to 2026-09-10 lasted under a
    minute (fix1: 49 s and 17 s); an hour is far outside the population."""
    try:
        return max(0.0, float(config_value('POST_TERMINAL_RUN_STALE_SECONDS', '3600', repo)))
    except (TypeError, ValueError):
        return 3600.0


def post_terminal_run_open(tx, transaction):
    """(open, reason) — ROW 5 OF THE DECISION TABLE, with the two things
    Frank R2 found missing from the first version: a SECOND SOURCE and a way
    for the hold to END.

    `running_after_terminal` used to read one source (the transaction's own
    notes, written under a 5-second flock that a sweep or the nightly pass
    holds for a whole reclaim) and had no expiry: a stop note lost to that
    flock, or a session that died mid-run, held every workspace of the agent
    FOREVER while the journal called it a RETRY and said "until the run ends"
    — a reason false the moment the run had ended. Type J of the failure
    record, in code written the day the record was published.

    Three changes, each named in the reason it produces:

      1. TWO SOURCES. `running_after_terminal` now merges the notes with the
         platform's own event log (WorkerStarted / WorkerRunEnded for this
         registration id), so a lost stop note is closed by the platform's
         row and a lost start note is opened by it.
      2. THE SESSION'S DEATH VOIDS IT. A run lives inside its session's
         process; a session provably gone (row 10a's evidence, every recorded
         pid gone or reused and no running registration) cannot have a run
         open, whatever the last note says. session_gone overrides.
      3. AGE. A run open longer than POST_TERMINAL_RUN_STALE_SECONDS is still
         a hold — this lane never deletes on a guess — but the reason stops
         saying "until the run ends" and names what a person can do: confirm
         from the process table and the event log, then record the stop the
         hooks missed (`worktree-transactions.py note-after-terminal`). That
         is an operator asserting a fact into the record, the same shape as
         `git worktree unlock`, not a flag that unlocks the class.
    """
    if not tx.running_after_terminal(transaction):
        return False, ''
    aid = transaction.get('agent_id') or ''
    gone, why_gone = session_gone(transaction, tx)
    if gone:
        return False, ('a post-terminal run of agent %s was recorded open, but %s — a run cannot outlive '
                       'its session, so the hold is void' % (aid[:8] or '?', why_gone))
    since = tx.open_run_since(transaction)
    age = (datetime.now(timezone.utc) - since).total_seconds() if since else 0.0
    stale = post_terminal_run_stale_seconds()
    if since and age > stale:
        return True, (
            'RETRY, not a verdict: the platform started agent %s again after its terminal record and '
            'neither the transaction nor the platform\'s event log shows that run ending — it has been '
            'open for %.0f s, longer than POST_TERMINAL_RUN_STALE_SECONDS (%.0f). This lane never '
            'deletes on a guess, so the workspaces stay held; the remedy is a PERSON: confirm nothing '
            'of this agent is running (`ps`, `agent-liveness.sh`, `restart-after-terminal-measure.py`), '
            'then record the stop both sources missed: `worktree-transactions.py note-after-terminal '
            '--session-id %s --agent-id %s --kind stop --detail operator`. If the whole session is '
            'over, this hold clears by itself once its processes are gone'
            % (aid[:8] or '?', age, stale, transaction.get('session_id') or '?', aid))
    return True, (
        'RETRY, not a verdict: the platform started agent %s again after its terminal record '
        'and that run is still open (the last observed lifecycle event, in the transaction or the '
        'platform\'s event log, is a start%s). Its workspaces are held until the run ends, the '
        'session ends, or the hold ages past POST_TERMINAL_RUN_STALE_SECONDS and names an operator. '
        'This is the fact round 11 assumed could not happen; it is measured, and it is refused '
        'rather than assumed away' % (aid[:8] or '?', (' at %s' % since.isoformat(timespec='seconds')) if since else ''))


# ---------------------------------------------------------------------------
# the owning session — gone, or not provably gone
# ---------------------------------------------------------------------------

def session_gone(transaction, tx=None):
    """(gone, reason). GONE requires positive evidence on every recorded
    identity: the ownership ledger recorded at least one (pid, start) for this
    session id, `process_status()` answers gone or reused for each, and the
    harness's own live-session registry (~/.claude/sessions/<pid>.json) names
    no running pid for it. A session with no recorded identity, an `alive`
    or `unknown` answer, or a running registration is NOT gone — absence of a
    record is never evidence. An adopted transaction has no owning session."""
    sid = transaction.get('session_id') or ''
    if transaction.get('kind') == 'adopted' or not sid:
        return False, 'no owning session (adopted transaction)'
    return session_id_gone(sid, tx)


def session_id_gone(sid, tx=None):
    """(gone, reason) for a bare session id — the same evidence and the same
    fail-closed rooting check as session_gone, which now calls it. Split out
    because a RESERVATION can be held by a session with no transaction of its
    own: an ownership row that names no agent id is a claim on behalf of a
    session, and the only thing that can retire it is that session ending."""
    ledger = _load('worktree-ledger')
    # HERMETIC ROOTING, FAIL-CLOSED. A transaction store away from its default
    # with the ledger AT its default is a sandbox reading the OPERATOR'S REAL
    # record — and a fixture session id that some earlier suite leaked into
    # that record, with a pid that is long dead, would read as a gone session
    # and remove the sandbox's native tree (reconcile-terminal-worktrees
    # C28c, 2026-09-10). Both stores redirected, or neither; otherwise NOT gone.
    if tx is None:
        tx = _load('worktree-transactions')
    default_tx = os.path.join(os.path.expanduser('~'), '.claude', 'state', 'worktree-transactions')
    tx_default = os.path.abspath(tx.tx_root()) == os.path.abspath(default_tx)
    ledger_default = os.path.abspath(ledger.ledger_path()) == os.path.abspath(ledger.DEFAULT_PATH)
    if tx_default != ledger_default:
        return False, 'transaction store and ownership ledger are inconsistently rooted; not provably gone'
    identities = []
    for row in ledger.read_all():
        if row.get('session_id') != sid or not row.get('session_pid'):
            continue
        identity = (str(row.get('session_pid')), row.get('pid_start') or '')
        if identity not in identities:
            identities.append(identity)
    if not identities:
        return False, 'no process identity recorded for session %s; not provably gone' % sid[:8]
    for pid, start in identities:
        status = ledger.process_status(pid, start)
        if status not in ('gone', 'reused'):
            return False, 'session %s pid %s is %s' % (sid[:8], pid, status)
    for pid, row in ledger.session_registry().items():
        if row.get('session_id') == sid and ledger._pid_running(pid):
            return False, 'session %s is registered to running pid %s' % (sid[:8], pid)
    return True, 'session %s: recorded pid(s) %s gone or reused; no running registration' % (
        sid[:8], ','.join(p for p, _s in identities))


def _lock_pid(lock_line):
    m = LOCK_PID_RE.search(lock_line or '')
    return int(m.group(1)) if m else None


def _release_dead_lock(repo, path, lock_line):
    """`git worktree unlock` ONLY when the lock names a pid that no process
    holds. A lock with no pid, or a running pid, is retained: the platform's
    own statement that the workspace may still be in use."""
    pid = _lock_pid(lock_line)
    if pid is None:
        raise RuntimeError('locked without a pid; retained: ' + (lock_line or '')[:120])
    status = _load('worktree-ledger').process_status(pid, None)
    if status != 'gone':
        raise RuntimeError('lock pid %s is %s; retained' % (pid, status))
    _git(repo, 'worktree', 'unlock', '--', path)


# ---------------------------------------------------------------------------
# THE WORKSPACE IS NOT IN USE — which is a different question from "the agent
# is over", and it is the only one of the two this platform can answer
# ---------------------------------------------------------------------------
# ROUND 12, 2026-09-10. THE PREMISE UNDER ROUND 11 WAS FALSE AND IS WITHDRAWN.
#
# Round 11 authorized removal in the terminal event on this sentence, which
# stood a few lines below: the platform's first SubagentStop "does not say the
# agent has been quiet for a while; it says the agent CANNOT BE GIVEN ANOTHER
# TURN ... structural rather than temporal." Its own section 7 named the fact
# that would refute it. That fact is on this machine ten times over:
#
#     $ python3 engine/scripts/restart-after-terminal-measure.py
#     DENOMINATOR: those that own at least one workspace : 66
#     NUMERATOR  : those with a start strictly after their terminal record : 10
#     rate       : 15.152%
#
# The earliest is sage-fable-r2 on 2026-09-08, two days before round 11 was
# written; four more restarted within a nine-millisecond span at 14:34:37Z on
# 2026-09-10, six to eight hours after their terminal records. The triggers
# are a message queued before the stop and delivered after it, and a
# background task belonging to the agent exiting, whose notification resumes
# it. No guard sees either: guard-resume-isolation.sh covers SendMessage and
# nothing else.
#
# AND THE PLATFORM PROVIDES NO EVENT THAT WOULD MAKE THE PREMISE TRUE. Its
# whole vocabulary here is WorkerStarted / WorkerRunEnded / WorkerUpdated
# (`restart-after-terminal-measure.py --census`), and worker-ended-handoff.sh
# has always said so in its own header: "`run_ended` means this RUN ended,
# never 'this worker is gone'." Eleven rounds tried to synthesize a terminal
# fact the platform does not report. There is nothing left to synthesize it
# from, so this round stops trying.
#
# WHAT REPLACES IT. Not a better guess at "finished" — a different question.
# The decision this code makes is "may this directory be removed", and that
# question has answers the platform DOES provide:
#
#   1. THE WORK IS AN ANCESTOR OF `main`. Git is outside the agent and
#      permanent, and a woken agent cannot un-merge its own commits. This gate
#      was already here, is re-verified immediately before the removal and
#      again before the branch delete, and both reviewers confirmed it held.
#      It is what makes a restart survivable instead of destructive.
#   2. NOTHING IS WRITING HERE NOW. The platform writes its lock on a native
#      worktree BEFORE the run begins — measured on two live agents on this
#      machine, 43 ms and 49 ms before the SubagentStart hook fired — so an
#      ABSENT lock is a fact about the present, not a guess about the future.
#      And the race is closed by git rather than by our timing: `git worktree
#      remove` without --force REFUSES a locked worktree ("cannot remove a
#      locked working tree", exit 128, git 2.52.0, measured) and refuses a
#      tree with modified or untracked files. If a restart begins between the
#      check and the removal, the platform re-locks and the removal FAILS.
#   3. NO PROCESS STANDS IN THE TREE, from a probe that fails closed.
#   4. THE RECORD DOES NOT SHOW AN OPEN POST-TERMINAL RUN (owner_check).
#
# SO THE HONEST SAFETY CLAIM, WHICH IS SMALLER AND TRUE: a removal cannot
# destroy work, because a workspace is only removed when its tracked bytes are
# identical to a commit `main` already contains, its ignored bytes are
# archived and verified first, and nothing holds it. A restart AFTER a removal
# is a DISRUPTION — an agent waking in a directory that is gone — not a loss,
# and it is now detected, recorded on the transaction and announced.
#
# WHAT IS NOT CLAIMED, deliberately: that a terminal agent cannot run again
# (it can, ten times over), that a released lock means an agent will not
# return (four of the ten restarted long after their locks were released), or
# that this engine can tell the last stop from the others (it cannot, and
# nothing on this platform can).
#
# The `terminal` record and its indexes are untouched. The CEO's ruling that a
# finished agent is FORBIDDEN to return is a policy and it is still enforced
# by guard-resume-isolation.sh and the write barrier. What ended is this
# engine reading that policy as a description of the platform's behavior.
#
# ---------------------------------------------------------------------------
# WHY THE AGENT-SIZED GROUND EXISTS AT ALL (round 11, 2026-09-10). Round 10 gave a platform-native
# checkout exactly one route out from under the platform: the OWNING SESSION
# provably gone. Measured on the operator's machine at 10:53 that day, with
# the orchestrator still running, six finished teammates' workspaces read
#
#     observe  .../worktrees/agent-a0af7565af1a7ae92 — d0eef867/a0af7565af1a7ae92
#              zach-fable-lc1 — platform-owned; session d0eef867 pid 8799 is alive
#
# — held not because their agent was running but because the ORCHESTRATOR was.
# A session lasts a working day; an agent lasts minutes. So the session is the
# wrong unit, and this is the agent-sized evidence beside it. It ADDS a ground;
# it removes none. Every other refusal — dirty, untracked, unintegrated,
# unverifiable residue, a process in the tree, a competing reservation, an
# inexact or locked registration, a live native lock — is untouched and is
# still evaluated after this one passes.

# The ingresses that are the PLATFORM'S OWN STATEMENT about one exact agent id:
# SubagentStop carries the id, WorktreeRemove the exact native path, a
# successful TaskStop the task id its result returned. `NativeMemberGone` and
# `Adoption` are this engine's own derivations — real terminal facts for the
# daily lane, but not the platform saying "this worker stopped", so they do not
# license taking a workspace out of the platform's hands while it still runs.
PLATFORM_TERMINAL_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'TaskStop')


def platform_recorded_a_stop(tx, transaction):
    """(recorded, reason). THIS IS A CANDIDACY TEST, NOT AN AUTHORIZATION, and
    the rename is the point: it was called `platform_said_the_agent_stopped`
    and its answer was read as "the agent is over".

    What it establishes, and all it establishes:

      1. the transaction is sealed and its terminal record names an ingress
         the PLATFORM fired about this exact agent id — never a name, a cwd or
         a sentence, and never this engine's own derivation;
      2. the terminal index for that agent id is written, so
         guard-resume-isolation.sh refuses every future SendMessage to it.

    WHAT IT DOES NOT ESTABLISH. That the agent will not run again. It does
    run again: ten of the 66 workspace-owning terminal transactions on this
    machine have a start strictly after their terminal record
    (`restart-after-terminal-measure.py`). (2) refuses one PATH back in — the
    lead's message — and the two paths that actually fired on 2026-09-10 were
    a message the platform had already queued before the stop, and a
    background task's exit notification. Neither passes through SendMessage
    and neither is refusable by any hook this platform offers.

    So a True here means only: the platform fired a stop about this exact
    agent, so this workspace is a CANDIDATE and the engine may go on to ask
    the questions that actually decide it — is it merged, is it clean, is it
    unlocked, is anything standing in it, is a post-terminal run open.
    """
    if not terminal_fact(transaction):
        return False, 'no sealed platform terminal record for this agent'
    ingress = (transaction.get('terminal') or {}).get('ingress')
    if ingress not in PLATFORM_TERMINAL_INGRESSES:
        return False, ('terminal ingress %s is this engine\'s own derivation, not the platform\'s '
                       'statement about the worker' % ingress)
    aid, sid = transaction.get('agent_id') or '', transaction.get('session_id') or ''
    if not tx.is_terminal_agent(aid, sid or None):
        return False, ('agent %s has no terminal index, so nothing refuses its resume; not a candidate'
                       % (aid[:8] or '?'))
    restarted = tx.restarted_after_terminal(transaction)
    return True, ('the platform fired a %s about agent %s and it is indexed terminal, so this '
                  'workspace is a candidate%s' % (ingress, aid[:8],
                                                  ' (NOTE: the platform has already run this agent '
                                                  'again since that record)' if restarted else ''))


def platform_lock_is_absent(member, row):
    """(absent, reason). THE ONLY LIVENESS FACT THIS PLATFORM ACTUALLY GIVES.

    Claude Code writes the lock on its native worktree and Claude Code takes
    it off; this engine reads it and NEVER removes it, on any route.

    WHAT THE LOCK MEANS, corrected 2026-09-10. Round 11 read it as a release
    signal — "the host takes it off within about a second of the stop (dir
    mtimes 0.37s and 1.06s after the two SubagentStop events measured that
    day) ... THAT REMOVAL IS THE HOST SAYING IT IS FINISHED WITH THE
    WORKSPACE", with a 5-second wait called "generous rather than hopeful".
    Two samples generalized into the safety timing of a deletion, and the
    population contradicts them: three of three own-event native attempts that
    day found the lock still held (key1 +6.0s, sage-fable-cert1 +6.2s), and
    zach-opus-unl1's lock was still held 77 minutes after its stop with no run
    in progress. Zero of five production reclaims happened in their own event.
    The lock is not a release signal and the wait was not generous.

    WHAT IT IS INSTEAD, and this is the fact worth having: the platform takes
    the lock BEFORE the run starts. Measured on this machine from the live
    admin directories, two agents, both times the lock file's mtime PRECEDES
    the SubagentStart hook:

        agent-a2de3c7d8d8590224  lock 16:07:26.643Z  start 16:07:26.692Z  (-49 ms)
        agent-a97f2c691c34e2c0f  lock 17:43:41.993Z  start 17:43:42.036Z  (-43 ms)

    agent-liveness says the same thing from the other side: "a live agent
    isolation worktree is always locked."

    So an ABSENT lock is a statement about the present — nothing is running in
    there right now — rather than a prediction that nothing will. That is
    exactly what a removal needs, because the removal is now protected against
    the future by git: `git worktree remove` without --force refuses a locked
    worktree, so a restart that re-locks between this check and the removal
    makes the removal FAIL rather than race.

    A HELD LOCK IS THEREFORE NOT A WAIT THAT EXPIRED. It is the platform
    holding this workspace, and it is journaled in those words.
    """
    if row is None:
        return False, 'exact registration required'
    if 'prunable' in row:
        return False, 'exact registration required'
    if 'locked' in row:
        holder = (row.get('locked') or '').strip()
        return False, ('the platform is holding its own lock on %s%s. This engine never removes a '
                       'lock the platform placed, on any route: while that lock is there the '
                       'workspace is in the platform\'s hands and may be running. If it is still '
                       'held long after the agent finished, the remedy is an operator releasing it '
                       'deliberately (`git worktree unlock`) — never this lane deciding on its behalf'
                       % (member.get('path'), (' (' + holder[:120] + ')') if holder else ''))
    return True, 'the platform holds no lock on this exact registration, so nothing is running in it'


def workspace_is_free_to_remove(tx, transaction, member, row):
    """(free, reason) — the workspace-sized ground that replaces the
    agent-sized one.

    It asks two things and neither of them is "is the agent finished", because
    this platform cannot answer that and eleven rounds died trying:

      1. did the platform fire a stop about this exact agent — CANDIDACY, so
         this engine only ever considers workspaces it was told about;
      2. is the platform's lock absent RIGHT NOW.

    Everything that actually protects the work is elsewhere and unchanged: the
    tracked bytes must be identical to a commit `main` contains (re-verified
    immediately before the removal and again before the branch delete), the
    ignored bytes must be archived and verified first, no process may stand in
    the tree, no post-terminal run may be open, and the removal itself is a
    non-force `git worktree remove` that git refuses on a locked or dirty
    tree.

    WHAT WAS REMOVED HERE, AND WHY. The old version had a second door: a lock
    that names no pid was accepted as "a lock nobody can be behind", and a
    companion `_release_unattributable_lock` took the platform's lock OFF and
    then deleted the workspace. Three things make that indefensible now. The
    platform holds a lock by the file's PRESENCE, not its contents, so "names
    nobody" is a fact about a string and not about a holder. The empty locks
    that motivated it were written by an operator's own `git worktree lock`
    without --reason on three LIVE agents (evidence pack 2.5/2.6) — a repair
    of an incident, generalized into a standing authority. And releasing the
    lock destroys the one property that makes the rest of this safe: it is the
    thing that would have made git refuse a removal under a restarting agent.

    The cost is real and is accepted: a workspace whose lock the platform
    never releases is HELD, indefinitely, and reported with the operator's
    remedy named. A held workspace is visible and recoverable. A deleted one
    is neither.
    """
    candidate, why = platform_recorded_a_stop(tx, transaction)
    if not candidate:
        return False, why
    absent, lock_why = platform_lock_is_absent(member, row)
    if not absent:
        return False, lock_why
    return True, why + '; ' + lock_why


# ---------------------------------------------------------------------------
# ignored bytes — disposable by policy, or archived and verified
# ---------------------------------------------------------------------------

def ignored_files(path):
    """Every ignored path under `path`, one entry per FILE -- except where git
    meets a NESTED REPOSITORY, which `ls-files --others --ignored` (without
    --directory) reports as ONE directory entry with a trailing slash and
    does not descend into. Measured 2026-09-10 under the lane's own binary
    (completion-proof.GIT = /Library/Developer/CommandLineTools/usr/bin/git,
    `git version 2.50.1 (Apple Git-155)`): a clone at `vendor/lib` inside an
    ignored `vendor/` lists as `['extra', 'vendor/lib/', 'vendor/plain-ignored']`.
    The trailing slash is therefore the signature of a nested repository, and
    is_nested_repository() reads it as exactly that."""
    raw = _load('completion-proof').git(path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z').stdout
    return [os.fsdecode(x) for x in raw.split(b'\0') if x]


def is_nested_repository(rel):
    """A trailing slash from ignored_files() is a directory git would not
    enter: a nested repository (its own `.git`, its own commits)."""
    return rel.endswith('/')


def never_disposable(rel):
    """FRANK R1 (round two, 2026-09-10), THE ONLY LOSS PATH FOUND IN TWO ROUNDS
    OF REVIEW. partition_ignored() sent a path to the dropped set when ANY of
    its components was on the disposable list -- and a nested repository under
    `vendor/`, `.cache/`, `build/` or `node_modules/` arrives here as a single
    directory entry whose parent component is on that list, so a clone an
    agent made there, WITH ITS COMMITS, was classified disposable by its
    parent's name, archived by nobody, and deleted by the non-force removal
    that follows (reproduced: `nested: (0, '') | exists after: False`). The
    disposable list's own bar is "a build reproduces it from what is
    committed"; no build reproduces somebody's commits.

    So two things are never disposable, whatever their parent is called: a
    nested repository (the trailing-slash entry), and any path carrying a
    `.git` component. Both go to the residue, which is archived and verified
    before anything is removed -- or, if the archive cannot take them, HELD.
    """
    return is_nested_repository(rel) or '.git' in rel.rstrip('/').split('/')


def partition_ignored(files, disposable):
    keep, residue = [], []
    for rel in files:
        if never_disposable(rel):
            residue.append(rel)
        elif any(component in disposable for component in rel.split('/')):
            keep.append(rel)
        else:
            residue.append(rel)
    return keep, residue


def _capture_dir(tx, transaction, index):
    return os.path.join(tx.capture_root(), tx._seg(transaction['session_id'], 'session_id'),
                        tx._seg(transaction['agent_id'], 'agent_id'), 'member-%d' % index)


def _assert_capture_rooting(tx):
    """A redirected transaction store with the capture store at its default
    would write a sandbox's residue into the operator's real capture store.
    Both away from their defaults, or both at them."""
    default_tx = os.path.join(os.path.expanduser('~'), '.claude', 'state', 'worktree-transactions')
    default_cap = os.path.join(os.path.expanduser('~'), '.claude', 'state', 'worktree-captures')
    tx_default = os.path.abspath(tx.tx_root()) == os.path.abspath(default_tx)
    cap_default = os.path.abspath(tx.capture_root()) == os.path.abspath(default_cap)
    if tx_default != cap_default:
        raise RuntimeError('transaction store and capture store are inconsistently rooted; refusing to archive residue')


def _private_dirs(root, path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    root = os.path.realpath(root)
    p = os.path.realpath(path)
    while p.startswith(root):
        os.chmod(p, 0o700)
        if p == root:
            break
        p = os.path.dirname(p)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _expand_residue(path, residue):
    """The residue as filesystem objects: every plain entry as itself, and
    every NESTED REPOSITORY entry (trailing slash) expanded to every object
    under it -- directories, files and symlinks, `.git` included, symlinks
    never followed. Returns [(rel, kind)], with `rel` never carrying a
    trailing slash. Anything that is not a directory, a regular file or a
    symlink raises: the archive cannot take it, so the workspace is HELD."""
    out = []
    for rel in sorted(residue):
        if not is_nested_repository(rel):
            out.append((rel, None))
            continue
        top = os.path.join(path, rel.rstrip('/'))
        if os.path.islink(top) or not os.path.isdir(top):
            raise RuntimeError('ignored entry %s is listed as a directory but is not one; retained' % rel)
        for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
            reldir = os.path.relpath(dirpath, path)
            out.append((reldir, 'dir'))
            # os.walk lists a symlink-to-directory in dirnames and (with
            # followlinks=False) never enters it; it is archived AS a symlink.
            for name in sorted(dirnames):
                if os.path.islink(os.path.join(dirpath, name)):
                    out.append((os.path.join(reldir, name), None))
            for name in sorted(filenames):
                out.append((os.path.join(reldir, name), None))
    return out


def residue_manifest(path, residue):
    """The manifest of the residue AS IT IS ON DISK NOW: kind, mode, size and
    digest of every object. Computed once for the archive and ONCE MORE
    immediately before the removal (Sage D3, round two, 2026-09-10): the
    archive was verified against the manifest at archive time, and nothing
    re-listed or re-digested the ignored files before the `rm`, so a writer
    that started after the process probe and wrote an ignored file inside the
    archive-to-remove window lost those bytes. The tracked side already had
    its last look; this is the ignored side's."""
    manifest = {}
    for rel, kind in _expand_residue(path, residue):
        full = os.path.join(path, rel)
        info = os.lstat(full)
        if stat.S_ISLNK(info.st_mode):
            manifest[rel] = {'kind': 'symlink', 'target': os.readlink(full), 'mode': info.st_mode & 0o7777}
        elif stat.S_ISDIR(info.st_mode) and kind == 'dir':
            manifest[rel] = {'kind': 'dir', 'mode': info.st_mode & 0o7777}
        elif stat.S_ISREG(info.st_mode):
            manifest[rel] = {'kind': 'file', 'size': info.st_size, 'mode': info.st_mode & 0o7777, 'sha256': _sha256(full)}
        else:
            raise RuntimeError('ignored residue %s is neither a file, a directory of a nested repository, nor a symlink; retained' % rel)
    return manifest


def archive_residue(tx, transaction, index, path, residue):
    """Archive every ignored, non-disposable object under `path` into the
    capture store -- a nested repository whole, `.git` and all -- re-read the
    archive and verify every entry against its manifest, and return the record
    the journal carries plus the manifest itself (for the last look before
    the removal). Raises on any mismatch — an unverified archive never
    authorizes a removal."""
    _assert_capture_rooting(tx)
    cdir = _capture_dir(tx, transaction, index)
    _private_dirs(tx.capture_root(), cdir)
    manifest = residue_manifest(path, residue)
    total = sum(e['size'] for e in manifest.values() if e['kind'] == 'file')
    tar_path = os.path.join(cdir, 'ignored-residue.tar')
    tmp = tar_path + '.tmp'
    if os.path.lexists(tmp):
        os.unlink(tmp)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as raw, tarfile.open(fileobj=raw, mode='w') as tar:
        for rel in sorted(manifest):
            entry = manifest[rel]
            if entry['kind'] == 'file':
                tar.add(os.path.join(path, rel), arcname=rel, recursive=False)
            elif entry['kind'] == 'dir':
                ti = tarfile.TarInfo(rel)
                ti.type = tarfile.DIRTYPE
                ti.mode = entry['mode']
                tar.addfile(ti)
            else:
                ti = tarfile.TarInfo(rel)
                ti.type = tarfile.SYMTYPE
                ti.linkname = entry['target']
                ti.mode = entry['mode']
                tar.addfile(ti)
        raw.flush()
        os.fsync(raw.fileno())
    os.replace(tmp, tar_path)
    verify_residue_archive(tar_path, manifest)
    nested = sorted(rel.rstrip('/') for rel in residue if is_nested_repository(rel))
    record = {'archive': tar_path,
              'files': sum(1 for e in manifest.values() if e['kind'] != 'dir'),
              'directories': sum(1 for e in manifest.values() if e['kind'] == 'dir'),
              'bytes': total,
              'manifest_sha256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode('utf-8')).hexdigest(),
              'archived_ts': tx.now_iso()}
    if nested:
        # A PERSON SHOULD KNOW A REPOSITORY WENT INTO THE ARCHIVE. Its commits
        # are in there, verified, and nowhere else the engine knows of.
        record['nested_repositories'] = nested[:20]
        record['nested_repository_count'] = len(nested)
    # WHAT WENT IN THAT A PERSON SHOULD KNOW ABOUT (Frank D13, 2026-09-10).
    # The residue archive is where a workspace's IGNORED files go, and `.env`
    # files are ignored by construction — 51 archives on this machine, at least
    # 15 holding avelor/.env.local and fitapp/.env.local. Today those carry
    # only PUBLIC_CONVEX_URL / PUBLIC_CONVEX_SITE_URL, so nothing has leaked;
    # the mechanism would archive a real secret with exactly the same care,
    # forever, in a store scan-secrets.sh does not watch.
    #
    # NOTHING IS DROPPED. "Nothing ignored is discarded without a copy" is the
    # invariant this archive exists to keep, and silently filtering a file out
    # of it would be a deletion wearing a security justification. So the
    # archive is unchanged and the FACT is surfaced: the journal names how many
    # secret-bearing filenames went in and what they were, where an operator
    # reads it. Knowing beats guessing; guessing is what made this invisible.
    secretish = sorted(rel for rel in manifest if _looks_secret_bearing(rel))
    if secretish:
        record['secret_bearing'] = secretish[:20]
        record['secret_bearing_count'] = len(secretish)
    tx.atomic_write_json(os.path.join(cdir, 'ignored-residue.json'), {'manifest': manifest, 'record': record})
    return record, manifest


def residue_last_look(path, repo, archived_manifest):
    """(unchanged, reason) — THE LAST LOOK ON THE IGNORED SIDE (Sage D3).
    Re-list the ignored files and re-derive their manifest immediately before
    `git worktree remove`; anything the archive does not hold byte for byte
    is a RETRY. `archived_manifest` is {} when nothing was archived, and a
    residue that has appeared since is a difference like any other. A new
    DISPOSABLE file is not: by the committed policy a build reproduces it."""
    _keep, residue = partition_ignored(ignored_files(path), disposable_paths(repo))
    now = residue_manifest(path, residue) if residue else {}
    archived = archived_manifest or {}
    if now == archived:
        return True, ''
    added = sorted(set(now) - set(archived))
    gone = sorted(set(archived) - set(now))
    changed = sorted(rel for rel in set(now) & set(archived) if now[rel] != archived[rel])
    return False, ('the ignored bytes changed between the archive and the removal (%d added, %d gone, '
                   '%d changed; e.g. %s); the archive no longer matches the tree, so nothing is removed'
                   % (len(added), len(gone), len(changed), (added + changed + gone)[:3]))


# Filenames that conventionally hold credentials. A NAME check, deliberately:
# reading the bytes to classify them would mean this lane parsing secrets, and
# the point is to tell an operator WHERE to look, not to judge what is inside.
SECRET_BEARING_NAMES = ('.env', '.envrc', '.netrc', 'credentials', 'id_rsa', 'id_ed25519',
                        '.pem', '.p12', '.keystore', '.jks', 'secrets')


def _looks_secret_bearing(rel):
    base = os.path.basename(rel).lower()
    return any(base == n or base.startswith(n + '.') or base.endswith(n) for n in SECRET_BEARING_NAMES)


def verify_residue_archive(tar_path, manifest):
    """Every manifest entry present in the archive with its size, digest,
    mode and symlink target, and nothing the manifest does not name."""
    with tarfile.open(tar_path, 'r') as tar:
        entries = {}
        for ti in tar:
            name = ti.name.rstrip('/')
            if name in entries:
                raise RuntimeError('residue archive holds %s twice' % name)
            entries[name] = ti
        for rel, info in manifest.items():
            ti = entries.pop(rel, None)
            if ti is None:
                raise RuntimeError('residue archive lacks %s' % rel)
            if (ti.mode & 0o7777) != info['mode']:
                raise RuntimeError('residue archive mode mismatch for %s' % rel)
            if info['kind'] == 'dir':
                if not ti.isdir():
                    raise RuntimeError('residue archive type mismatch for directory %s' % rel)
            elif info['kind'] == 'file':
                if not ti.isreg() or ti.size != info['size']:
                    raise RuntimeError('residue archive size/type mismatch for %s' % rel)
                h = hashlib.sha256()
                stream = tar.extractfile(ti)
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(chunk)
                if h.hexdigest() != info['sha256']:
                    raise RuntimeError('residue archive digest mismatch for %s' % rel)
            elif not ti.issym() or ti.linkname != info['target']:
                raise RuntimeError('residue archive symlink mismatch for %s' % rel)
        if entries:
            raise RuntimeError('residue archive holds %s which the manifest does not name' % sorted(entries)[0])


# ---------------------------------------------------------------------------
# processes standing in the tree
# ---------------------------------------------------------------------------

def processes_using(path):
    """Pids whose cwd or open files resolve inside `path` (lsof, the measured
    tool that sees a cwd `pgrep -f` cannot; 0.85 s on a 3.3 GB tree), plus
    pids whose argv names it. Never this process or its ancestors. Nothing is
    killed: a process in a terminal tree is a HOLD, written on the member.

    FAILS CLOSED, and this is the whole point of the function. Until
    2026-09-10 every exception from `lsof` or `ps` -- a timeout, a missing
    binary, a permission error -- was swallowed and the caller received an
    empty list, which it reads as "nothing is holding this" and proceeds to
    remove the workspace. A failure to LOOK became a statement that there was
    NOTHING TO SEE: type A of the failure record's own taxonomy (absence
    reading as success), sitting inside the one predicate whose entire job is
    to refuse. On this machine seven workspaces were protected from removal by
    exactly one `com.apple.Virtualization.VirtualMachine` process that only
    `lsof` can see; on the day `lsof` was slow they would have been deleted.

    So a probe that could not answer RAISES, naming the tool and the failure,
    and every caller already turns that into a hold. A hold costs a night; the
    other answer costs a workspace.

    RICHOS_DAILY_PROCESSES stands in for the table in tests ("none" = empty,
    "unavailable" = the probe itself failed): newline-separated
    "<pid> <command line>" rows.
    """
    override = os.environ.get('RICHOS_DAILY_PROCESSES')
    if override is not None:
        if override.strip() == 'unavailable':
            raise RuntimeError('RETRY, not a verdict: could not determine whether any process is '
                               'standing in %s (the process table was declared unavailable). A '
                               'probe that could not look never reports an empty tree' % path)
        rows = [line.strip().partition(' ') for line in override.splitlines() if line.strip() and line.strip() != 'none']
        return sorted({int(pid) for pid, _sep, cmd in rows if pid.isdigit() and path in cmd})
    pids = set()
    try:
        res = subprocess.run(['lsof', '-t', '+D', path], capture_output=True, text=True, timeout=120)
        # lsof exits 1 with no output when nothing holds the path: that is an
        # ANSWER, not a failure, and it is the only nonzero exit accepted here.
        if res.returncode not in (0, 1):
            raise RuntimeError('lsof exited %s: %s' % (res.returncode, (res.stderr or '').strip()[:200]))
        pids.update(int(tok) for tok in res.stdout.split() if tok.isdigit())
    except Exception as error:
        raise RuntimeError('RETRY, not a verdict: could not determine whether any process is standing '
                           'in %s -- lsof did not answer (%s: %s). A probe that could not look never '
                           'reports an empty tree, so this workspace is HELD until it can'
                           % (path, type(error).__name__, str(error)[:200]))
    try:
        res = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True, timeout=20)
        if res.returncode != 0:
            raise RuntimeError('ps exited %s' % res.returncode)
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit() and path in parts[1]:
                pids.add(int(parts[0]))
    except Exception as error:
        raise RuntimeError('RETRY, not a verdict: could not read the process table while deciding '
                           'whether anything is standing in %s (%s: %s); this workspace is HELD'
                           % (path, type(error).__name__, str(error)[:200]))
    me = os.getpid()
    ancestors = set()
    p = os.getppid()
    for _ in range(8):
        if p <= 1:
            break
        ancestors.add(p)
        try:
            r = subprocess.run(['ps', '-o', 'ppid=', '-p', str(p)], capture_output=True, text=True, timeout=5)
            p = int(r.stdout.strip() or '1')
        except Exception:
            # A walk that stops early is the SAFE direction and is therefore
            # not an error: it shrinks the exclusion set, so an ancestor whose
            # cwd is inside the tree (this lane runs inside the stop hook, so
            # that is a real shape) is counted as a holder and the workspace is
            # HELD. The failing direction would be to exclude a pid we could
            # not prove is ours, and nothing here does that.
            break
    return sorted(x for x in pids if x != me and x not in ancestors)


# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------

def describe_processes(pids):
    """`4242 (sleep), 91043 (zsh)` — the holder NAMED, not a bare number.

    A folder another process has open is a RETRY, not a judgment, and it must
    never enter the same vocabulary as liveness. Measured 2026-09-10: seven
    workspaces on this machine were held by ONE
    `com.apple.Virtualization.VirtualMachine` process with directory handles
    inside them. Reported as "undecidable" that is a shrug; reported with the
    pid and the command it is the one thing an operator can act on, and the
    hold clears by itself when they do.
    """
    out = []
    for pid in pids:
        name = ""
        try:
            res = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=10)
            name = os.path.basename((res.stdout or "").strip())
        except Exception:
            name = ""
        out.append("%s (%s)" % (pid, name) if name else str(pid))
    return ", ".join(out)


def _git(repo, *args, allowed=(0,)):
    return _load('completion-proof').git(repo, *args, allowed=allowed).stdout.decode('utf-8')


def remember_native(member):
    """Return clean facts before platform removal; this records no death."""
    if member.get('daily_cleanup'):
        return member['daily_cleanup']
    proof = _load('completion-proof').prove_member(member)
    return {'version': 1, 'phase': 'prepared', 'proof': proof}


def _checkpoint(name):
    """Tests replace this hook; production has no environment crash switch."""


# ---------------------------------------------------------------------------
# the absent native member with no receipt (P5)
# ---------------------------------------------------------------------------

def _absent_native_branch_tip(tx, transaction, index, proof_api):
    """(member, ref, tip, main) for an absent platform-native member, or a
    RuntimeError naming why it is not one. A member still at
    `platform-pending` is put to observe_platform_native first, which records
    `removed` only when the registry and the filesystem both prove absence."""
    member = transaction['members'][index]
    sid, aid = transaction['session_id'], transaction['agent_id']
    if tx.platform_native(member) and member.get('state') != 'removed':
        member = tx.observe_platform_native(sid, aid, index)['members'][index]
    repo, path = member.get('repo') or '', member.get('path') or ''
    if not (tx.platform_native(member) and member.get('state') == 'removed'
            and member.get('closed') in ('platform-removed', 'absent')):
        raise RuntimeError('removed workspace has no retained completion proof')
    if os.path.lexists(path) or path in proof_api.registry(repo):
        raise RuntimeError('removed native member has a path or registration again; retained')
    branch = member.get('branch') or ''
    ref = (branch if branch.startswith('refs/') else 'refs/heads/' + branch) if branch else ''
    if ref in ('refs/heads/main', 'refs/heads/master'):
        raise RuntimeError('canonical worktree or protected branch retained')
    main = proof_api.direct(Path(repo), 'refs/heads/main')
    tip = ''
    if ref:
        raw = _git(repo, 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', ref)
        matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == ref]
        if matches:
            if len(matches) != 1 or any(matches[0][2:]):
                raise RuntimeError('branch tip or direct-reference identity changed')
            tip = matches[0][1]
    if tip and proof_api.git(repo, 'merge-base', '--is-ancestor', tip, main, allowed=(0, 1)).returncode:
        raise RuntimeError('Current canonical main no longer contains the delivery')
    return member, ref, tip, main


def _absent_native_without_receipt(tx, transaction, index):
    """The platform removed the checkout and no TaskCompleted receipt was ever
    written, so no proof can be replayed — but a branch with no working tree
    loses nothing when it is fully merged. The branch goes only when: the
    member is platform-removed (registry AND filesystem prove absence), the
    branch's CURRENT tip is an ancestor of main, and no registered checkout
    holds the branch. Deleted by compare-and-set on the tip that was checked;
    an unintegrated tip is retained with the reason. The backup ref goes with
    it when what it pins is integrated too."""
    proof_api = _load('completion-proof')
    member, ref, tip, main = _absent_native_branch_tip(tx, transaction, index, proof_api)
    sid, aid = transaction['session_id'], transaction['agent_id']
    repo = member['repo']
    if ref and tip:
        if any(row.get('branch') == ref for row in proof_api.registry(repo).values()):
            raise RuntimeError('branch is still reserved by a registered worktree')
        _git(repo, 'update-ref', '--no-deref', '-d', ref, tip)
        _checkpoint('after-branch-delete')
    backup = member.get('backup_ref')
    if backup and backup == tx.backup_ref(sid, aid, member.get('branch')):
        raw = _git(repo, 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', backup)
        matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == backup]
        if matches and len(matches) == 1 and not any(matches[0][2:]):
            pinned = matches[0][1]
            if proof_api.git(repo, 'merge-base', '--is-ancestor', pinned, main, allowed=(0, 1)).returncode == 0:
                _git(repo, 'update-ref', '--no-deref', '-d', backup, pinned)
    journal = {'version': 1, 'phase': 'complete', 'proof_source': 'recorded-head', 'head': member.get('head') or '',
               'branch': ref, 'tip': tip, 'integration_tip': main, 'removed_ts': tx.now_iso()}
    return tx.update_member(sid, aid, index, daily_cleanup=journal, cleanup_policy='integrated-daily',
                            closed='integrated-daily-cleanup', blocked=False, retry_after_epoch=0, last_error=None)


# ---------------------------------------------------------------------------
# the lane
# ---------------------------------------------------------------------------

def _load_proof(tx, transaction, index, member, proof_api, persist):
    """The saved journal's proof, or a fresh one. `persist` False (assess) never writes."""
    sid, aid = transaction['session_id'], transaction['agent_id']
    saved = member.get('daily_cleanup')
    if saved:
        if saved.get('version') != 1 or saved.get('phase') not in ('prepared', 'worktree-removed', 'branch-deleting', 'complete'):
            raise RuntimeError('cleanup journal malformed')
        proof = saved['proof']
        if proof['original_path'] != member['path'] or proof['repo'] != member['repo']:
            raise RuntimeError('cleanup journal scope changed')
        return saved, proof
    if os.path.lexists(member['path']):
        proof = proof_api.prove_member(member)
    else:
        receipts = proof_api.receipts_for_member(sid, aid, member['path'])
        proofs = [p for receipt in receipts for p in receipt.get('members', [])
                  if p.get('original_path') == member['path']]
        if not proofs:
            return None, None
        proof = proofs[-1]
        proof_api.verify_member_proof(proof, path_present=False)
    saved = {'version': 1, 'phase': 'prepared', 'proof': proof}
    if persist:
        tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
    return saved, proof


def _check_proof_scope(member, proof):
    expected_branch = member.get('branch') or ''
    if expected_branch and not expected_branch.startswith('refs/'):
        expected_branch = 'refs/heads/' + expected_branch
    if (proof['original_path'] != member['path'] or proof['repo'] != member['repo']
            or proof['branch'] != expected_branch):
        raise RuntimeError('completion proof does not match exact terminal member')
    if proof['branch'] in ('refs/heads/main', 'refs/heads/master') or member['path'] == member['repo']:
        raise RuntimeError('canonical worktree or protected branch retained')


def assess(tx, transaction, index):
    """READ-ONLY. What reconcile() would do to this member right now, as
    (decision, reason): `remove`, `branch-only` (path already gone),
    `observe` (platform-owned, session not provably gone), or `hold`.
    Writes nothing, takes no lock, unlocks nothing, archives nothing."""
    member = transaction['members'][index]
    try:
        if member.get('class') == 'managed-image':
            return 'hold', 'managed image is not an ordinary worktree'
        if member.get('quarantine') or member.get('quarantine_path'):
            return 'hold', 'historical quarantine needs separate authorized maintenance'
        proof_api = _load('completion-proof')
        owner_check(tx, transaction, member)
        present = os.path.lexists(member['path'])
        saved, proof = _load_proof(tx, transaction, index, member, proof_api, persist=False)
        if proof is None:
            if tx.platform_native(member) and not os.path.lexists(member['path']) \
                    and member['path'] not in proof_api.registry(member['repo']):
                # read-only twin of _absent_native_branch_tip: no observe write
                branch = member.get('branch') or ''
                ref = (branch if branch.startswith('refs/') else 'refs/heads/' + branch) if branch else ''
                main = proof_api.direct(Path(member['repo']), 'refs/heads/main')
                raw = _git(member['repo'], 'for-each-ref', '--format=%(refname) %(objectname)', ref) if ref else ''
                tip = next((line.split(' ')[1] for line in raw.splitlines() if line.split(' ')[0] == ref), '')
                if tip and proof_api.git(member['repo'], 'merge-base', '--is-ancestor', tip, main, allowed=(0, 1)).returncode:
                    return 'hold', 'Current canonical main no longer contains the delivery (branch tip %s)' % tip[:12]
                return 'branch-only', 'platform-removed native member; branch %s deleted by compare-and-set on its integrated tip' % (ref or '(none)')
            return 'hold', 'removed workspace has no retained completion proof'
        _check_proof_scope(member, proof)
        proof_api.verify_member_proof(proof, path_present=present)
        if not present:
            return 'branch-only', 'workspace already gone; branch by exact compare-and-set'
        repo = member['repo']
        row = proof_api.registry(repo).get(member['path'])
        ground = 'session_gone'
        if tx.platform_native(member):
            gone, why = session_gone(transaction, tx)
            if not gone:
                # The session still runs. The WORKSPACE may still be free, and
                # that is a smaller question this platform can actually answer
                # (round 12). It is not a claim that the agent is finished.
                free, workspace_why = workspace_is_free_to_remove(tx, transaction, member, row)
                if not free:
                    return 'observe', 'platform-owned; ' + why + '; ' + workspace_why
                ground, why = 'workspace_free', workspace_why
            if not row or 'prunable' in row:
                return 'hold', 'exact registration required'
            if 'locked' in row:
                pid = _lock_pid(row['locked'])
                status = _load('worktree-ledger').process_status(pid, None) if pid else 'unknown'
                if status != 'gone':
                    return 'hold', 'lock pid %s is %s' % (pid, status)
        elif not row or 'locked' in row or 'prunable' in row:
            return 'hold', 'exact unlocked registration required'
        pids = processes_using(member['path'])
        if pids:
            return 'hold', ('RETRY, not a verdict: process(es) %s are standing in the tree. '
                            'Nothing here kills a process; the hold clears when they leave'
                            % describe_processes(pids))
        keep, residue = partition_ignored(ignored_files(member['path']), disposable_paths(repo))
        return 'remove', '%s; ignored: %d disposable dropped, %d archived first' % (why if tx.platform_native(member) else 'clean, integrated, unlocked', len(keep), len(residue))
    except Exception as error:
        return 'hold', str(error)


def reconcile(tx, transaction, index):
    """Capture, verify and remove ONE member's workspace, or refuse with a
    reason. The ingress and the nightly pass call exactly this, identically.

    THE `immediate` PARAMETER IS GONE (round 12, 2026-09-10). It existed to
    make one branch behave differently when called from the stop event — the
    ingress would not release an unattributable lock, because "in that instant
    the platform is still putting the worker down". That whole route was
    deleted with `_release_unattributable_lock`, and the parameter went on
    being declared, passed and never read: a flag that distinguished two paths
    which no longer differ. It is not in the decision table
    (docs/reclaim-decision-table.md), so it is not in the code. Eleven rounds
    added; the moves that worked were cuts.
    """
    member = transaction['members'][index]
    if member.get('class') == 'managed-image':
        raise RuntimeError('managed image is not an ordinary worktree')
    if member.get('quarantine') or member.get('quarantine_path'):
        raise RuntimeError('historical quarantine needs separate authorized maintenance')
    sid, aid = transaction['session_id'], transaction['agent_id']
    proof_api = _load('completion-proof')
    owner_check(tx, transaction, member)
    saved, proof = _load_proof(tx, transaction, index, member, proof_api, persist=True)
    if proof is None:
        return _absent_native_without_receipt(tx, transaction, index)
    _check_proof_scope(member, proof)
    present = os.path.lexists(member['path'])
    proof_api.verify_member_proof(proof, path_present=present)
    if present:
        repo = member['repo']
        registry = proof_api.registry(repo)
        row = registry.get(member['path'])
        ground = 'session_gone'
        if tx.platform_native(member):
            gone, why = session_gone(transaction, tx)
            if not gone:
                # Claude remains the owner of its native checkout while the
                # session that created it may still act on it. The WORKSPACE
                # can still be free — a smaller question, answered from the
                # platform's lock rather than from a claim about the agent's
                # future (round 12). Neither fact is inferred from quiet.
                free, workspace_why = workspace_is_free_to_remove(tx, transaction, member, row)
                if not free:
                    return tx.observe_platform_native(sid, aid, index)
                ground, why = 'workspace_free', workspace_why
            if not row or 'prunable' in row:
                raise RuntimeError('exact registration required')
            if 'locked' in row:
                # ONE route out of a lock, and it needs a DEAD PID NAMED ON IT.
                # The `lock_names_nobody` second route, and the
                # `_release_unattributable_lock` that acted on it, are gone
                # (round 12): the platform holds a lock by the file's presence,
                # not its contents, so an unattributable lock is a fact about a
                # string. Releasing it destroyed the one property that makes a
                # restart survivable — git's refusal to remove a locked tree.
                _release_dead_lock(repo, member['path'], row['locked'])
                row = proof_api.registry(repo).get(member['path'])
                if not row or 'locked' in row:
                    raise RuntimeError('lock still present after release; retained')
            saved = dict(saved, **{ground: why})
        elif not row or 'locked' in row or 'prunable' in row:
            raise RuntimeError('exact unlocked registration required')
        pids = processes_using(member['path'])
        if pids:
            raise RuntimeError('RETRY, not a verdict: process(es) %s are standing in %s. Nothing here '
                               'kills a process; the hold clears when they leave'
                               % (describe_processes(pids), member['path']))
        keep, residue = partition_ignored(ignored_files(member['path']), disposable_paths(repo))
        residue_record, residue_archived = (archive_residue(tx, transaction, index, member['path'], residue)
                                            if residue else (None, {}))
        owner_check(tx, transaction, member)
        proof_api.verify_member_proof(proof)
        # THE LAST LOOK, AFTER THE ARCHIVE AND BEFORE THE REMOVAL. Archiving a
        # large residue takes seconds, and a restart can begin inside them.
        # Re-reading the registration here is a present-tense check of the
        # lock, and `git worktree remove` without --force refuses a locked
        # worktree by itself ("fatal: cannot remove a locked working tree",
        # exit 128 -- measured 2026-09-10 under completion-proof.GIT, Apple
        # Git 2.50.1, and under Homebrew git 2.52.0; both refuse).
        #
        # WHAT THIS CHECK IS NOT (corrected round 13, 2026-09-10, after both
        # reviewers): it is NOT the thing that makes a restart survivable.
        # The sentence that stood here -- "the platform re-locks the worktree
        # BEFORE the run starts (measured, 43 ms and 49 ms ...)" -- was
        # measured on two INITIAL starts. Whether the platform re-takes a
        # RELEASED lock for a RESTARTED run has not been observed on this
        # machine, and the four restarts into trees the reaper had witnessed
        # unlocked (q1, inf1, gate1, own1 at 14:34:37Z) left no artifact that
        # says either way: `restart-after-terminal-measure.py --locks`. So
        # this look catches a lock that IS there; it promises nothing about a
        # lock that is not. What protects the unlocked-restart case is named
        # in owner_check (row 5, from two sources) and in the write barrier
        # (guard-sealed-worktree.sh refuses a terminal agent every tool), and
        # the ancestor gate re-verified on the line above.
        fresh = proof_api.registry(repo).get(member['path'])
        if not fresh or 'locked' in fresh or 'prunable' in fresh:
            raise RuntimeError(
                'RETRY, not a verdict: the platform holds this workspace again as of this instant '
                '(%s). Something started in it while the reclaim was preparing; nothing is removed'
                % ('re-locked' if fresh and 'locked' in fresh else 'registration changed'))
        # THE LAST LOOK ON THE IGNORED SIDE (Sage D3): the archive was verified
        # when it was written; the tree may have moved since. Nothing is
        # removed that the archive does not hold byte for byte.
        unchanged, why_changed = residue_last_look(member['path'], repo, residue_archived)
        if not unchanged:
            raise RuntimeError('RETRY, not a verdict: ' + why_changed)
        saved = dict(saved, ignored_disposable=len(keep), ignored_residue=residue_record)
        tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
        _git(repo, 'worktree', 'remove', '--', member['path'])
        _checkpoint('after-worktree-remove')
    registry = proof_api.registry(member['repo'])
    if member['path'] in registry or os.path.lexists(member['path']):
        raise RuntimeError('workspace removal is not complete')
    # WHEN (Sage D6): the record could say a workspace was removed and not
    # when, so ordering a restart against a removal had to be inferred from
    # grounds. It is read now. UTC, like every other stamp in this store.
    saved = dict(saved, phase='worktree-removed', worktree_removed_ts=tx.now_iso())
    tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
    proof_api.verify_member_proof(proof, path_present=False)
    owner_check(tx, transaction, member)
    branch = proof['branch']
    registry = proof_api.registry(member['repo'])
    if branch and any(row.get('branch') == branch for row in registry.values()):
        raise RuntimeError('branch is still reserved by a registered worktree')
    saved = dict(saved, phase='branch-deleting')
    backup = member.get('backup_ref')
    if backup and backup == tx.backup_ref(sid, aid, member.get('branch')) and member.get('head'):
        saved['backup_ref'] = backup
        saved['backup_head'] = member['head']
    tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
    if branch:
        raw = _git(member['repo'], 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', branch)
        matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == branch]
        if matches:
            if len(matches) != 1 or matches[0][1] != proof['head'] or any(matches[0][2:]):
                raise RuntimeError('branch tip or direct-reference identity changed')
            _git(member['repo'], 'update-ref', '--no-deref', '-d', branch, proof['head'])
            _checkpoint('after-branch-delete')
    if saved.get('backup_ref'):
        backup, head = saved['backup_ref'], saved['backup_head']
        raw = _git(member['repo'], 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', backup)
        matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == backup]
        if matches:
            if len(matches) != 1 or matches[0][1] != head or any(matches[0][2:]):
                raise RuntimeError('native recovery ref changed; retained')
            _git(member['repo'], 'merge-base', '--is-ancestor', head, proof['integration_ref'])
            _git(member['repo'], 'update-ref', '--no-deref', '-d', backup, head)
    saved = dict(saved, phase='complete', removed_ts=tx.now_iso())
    return tx.update_member(sid, aid, index, daily_cleanup=saved, state='removed',
                            closed='integrated-daily-cleanup', blocked=False,
                            retry_after_epoch=0, last_error=None)


# ---------------------------------------------------------------------------
# THE IMMEDIATE LANE — reclaim IN the terminal event, not on a timer
# ---------------------------------------------------------------------------
# The CEO, 2026-09-10: "WHEN THE FUCK WILL ALL THE FINISHED GARBAGE START
# GETTING CLEANED UP AUTOMATICALLY AND STOP WASTING MY FUCKING TIME?"
#
# The terminal ingress already fired at exactly the right moment and then
# handed the reclamation to a job that runs at 04:00. So the system learned an
# agent was finished immediately and acted on it up to 24 hours later. This is
# the same lane the nightly reconciler runs — the same proof, the same
# refusals, the same journal — called from the ingress itself. reconcile() is
# unchanged and the nightly pass is unchanged; it remains the backstop for
# everything this deliberately skips (a crash, a killed process, a machine
# that slept, a hold that clears later).


def unlock_wait_seconds(repo=None):
    """How long the ingress waits, inside the stop event, for the platform to
    take its own lock off. Committed data a reviewer can read and an entity
    can narrow, never a constant hidden in code.

    THE DEFAULT IS NOW 0, AND THE PARAGRAPH THAT JUSTIFIED 5 WAS WRONG. It
    said: "the platform removed the lock 0.37s and 1.06s after the two
    SubagentStop events on record, so the default is generous rather than
    hopeful." Two samples. The population, measured over the same day:

        zach-opus-key1        own-event attempt deferred, lock held  +6.0 s
        sage-fable-cert1      own-event attempt deferred, lock held  +6.2 s
        zach-opus-unl1        lock still held with no run in progress +77 min
        production reclaims IN their own terminal event               0 of 5

    Three of three own-event native attempts expired the wait; all five real
    reclaims came from a later sweep. Frank's reading fits every observation:
    the platform tears its worktree down only AFTER the SubagentStop hook
    returns, so a wait INSIDE that hook can never observe the release and is
    pure latency added to every stop of every workspace-owning agent.

    So the wait defaults to 0 and the sweep on the NEXT event does the work,
    which is what the record shows already happens. An entity that measures
    something different on its own machine can raise it; the number is data,
    and this time it is data with a population behind it rather than two
    samples and a hope.
    """
    try:
        return max(0.0, float(config_value('IMMEDIATE_RECLAIM_WAIT_SECONDS', '0', repo)))
    except (TypeError, ValueError):
        return 0.0


def _lock_bearing_member(transaction, member):
    """The member whose registration carries the platform's lock for this
    agent: its native isolation worktree if it has one (a cross-repository
    worktree carries NO agent lock — checking it for liveness is the 2026-08-24
    incident), else the member itself."""
    for candidate in transaction.get('members') or []:
        if candidate.get('class') == 'native':
            return candidate
    return member


def await_platform_release(tx, transaction, member, deadline):
    """(absent, reason). Look — and, if the caller gave a future deadline,
    wait — for the platform's lock to be absent. Never unlocks anything: see
    platform_lock_is_absent for who holds it and why it is not ours.

    AN EXPIRED WAIT IS NOT A WAIT THAT EXPIRED. It is the platform still
    holding this workspace, and that is what the journal now says, because
    describing it as a timeout is what let round 11 call it a "degradation"
    to be retried rather than a statement to be obeyed."""
    holder = _lock_bearing_member(transaction, member)
    proof_api = _load('completion-proof')
    repo, path = holder.get('repo') or '', holder.get('path') or ''
    if not repo or not path:
        return False, 'member has no repository or path'
    while True:
        if not os.path.lexists(path):
            return True, 'the platform has removed this workspace itself'
        absent, why = platform_lock_is_absent(holder, proof_api.registry(repo).get(path))
        if absent or time.time() >= deadline:
            return absent, why
        time.sleep(0.1)


def reclaim_now(tx, transaction, index, deadline=None):
    """Capture, verify and remove this member's workspace in the terminal
    event itself. Returns (outcome, detail) with outcome one of

        reclaimed   the workspace is gone and its branch is resolved, now
        deferred    a refusal, a hold or an expired wait — the nightly
                    reconciler retries it with everything it always did
        skipped     not this lane's member at all

    NEVER RAISES. A terminal event must not be prevented by a cleanup, and a
    worker must never be kept alive by this function's own failure. Every
    outcome is written onto the member as `immediate_reclaim` so the ingress's
    decision is a line in the record and not an inference. Nothing here weakens
    a refusal: the decision is reconcile()'s, unmodified.
    """
    member = transaction['members'][index]
    sid, aid = transaction['session_id'], transaction['agent_id']

    def journal(outcome, detail):
        # APPEND, NEVER OVERWRITE (Frank D14, 2026-09-10). This wrote a single
        # `immediate_reclaim` object, so only the LAST attempt survived: the
        # own-event outcome of zach-opus-unl1 was gone under its 18:20 sweep
        # row, and key1's own-event deferral was readable only because no
        # later sweep happened to re-run on it. "The ingress's decision is a
        # line in the record and not an inference" — one line, replaced by the
        # next one. So the finding "zero of five reclaims happened in their own
        # event" had to be established from timestamps and phases, because the
        # journal built to answer exactly that question could not.
        #
        # The latest outcome keeps its old key and shape, so every existing
        # reader is unaffected; the history goes beside it, bounded, oldest
        # dropped first with a count kept.
        entry = {'version': 1, 'outcome': outcome, 'reason': str(detail)[:400],
                 # UTC, like every other timestamp in this store. The old local
                 # +01:00 stamps here were the only ones that were not, which
                 # makes a journal row incomparable with the terminal record
                 # sitting three lines above it in the same file.
                 'ts': datetime.now(timezone.utc).isoformat()}
        try:
            current = (tx.load_tx(sid, aid) or {}).get('members') or []
            history = list((current[index].get('immediate_reclaim_history') or [])
                           if index < len(current) else [])
        except Exception:
            history = []
        history.append(entry)
        dropped = 0
        if len(history) > IMMEDIATE_RECLAIM_HISTORY_LIMIT:
            dropped = len(history) - IMMEDIATE_RECLAIM_HISTORY_LIMIT
            history = history[-IMMEDIATE_RECLAIM_HISTORY_LIMIT:]
        try:
            tx.update_member(sid, aid, index, immediate_reclaim=entry,
                             immediate_reclaim_history=history,
                             immediate_reclaim_attempts=len(history) + dropped)
        except Exception:
            pass
        return outcome, detail

    try:
        if member.get('class') == 'managed-image':
            return 'skipped', 'managed image is not an ordinary worktree'
        if member.get('quarantine') or member.get('quarantine_path'):
            return 'skipped', 'historical quarantine needs separate authorized maintenance'
        if member.get('cleanup_policy') != 'integrated-daily':
            return 'skipped', 'historical record keeps its own recovery protocol'
        if (member.get('daily_cleanup') or {}).get('phase') == 'complete':
            return 'skipped', 'already reclaimed'
        run_open, why_open = post_terminal_run_open(tx, transaction)
        if run_open:
            return journal('deferred', why_open)
        candidate, why = platform_recorded_a_stop(tx, transaction)
        if not candidate:
            return journal('deferred', why)
        if deadline is None:
            deadline = time.time() + unlock_wait_seconds(member.get('repo'))
        absent, lock_why = await_platform_release(tx, transaction, member, deadline)
        if not absent:
            return journal('deferred', lock_why)
        reconcile(tx, tx.load_tx(sid, aid), index)
    except Exception as error:
        return journal('deferred', error)
    after = tx.load_tx(sid, aid)['members'][index]
    if (after.get('daily_cleanup') or {}).get('phase') == 'complete':
        return journal('reclaimed', 'workspace removed and branch resolved in the terminal event')
    return journal('deferred', after.get('last_error') or 'the lane did not complete this member')


def sweep_seconds(repo=None):
    """Wall-clock budget for one sweep, and the shortest gap between two.
    Committed data: a hook that runs on every subagent stop must be able to
    say what it costs. Defaults are deliberately small — the sweep is a
    catch-up, and the event that owns a member reclaims it first."""
    def number(key, default):
        try:
            return max(0.0, float(config_value(key, default, repo)))
        except (TypeError, ValueError):
            return float(default)
    return number('IMMEDIATE_RECLAIM_SWEEP_SECONDS', '10'), number('IMMEDIATE_RECLAIM_SWEEP_INTERVAL_SECONDS', '15')


def sweep_max_files(repo=None):
    """The tracked-file ceiling above which a candidate is left to the nightly
    pass instead of being started inside a 20-second hook.

    WHY A CEILING AND NOT JUST A CLOCK. The sweep's deadline was checked only
    BETWEEN candidates, so one candidate could run `lsof -t +D` (2.0 s
    measured on femcboost/avelor, 60,629 files with node_modules present),
    hash every tracked file, and tar-and-verify an ignored-file archive (one
    production archive holds 2,117 files of a SwiftPM .build tree) with the
    whole budget already spent. A clock cannot stop work that has started; a
    ceiling stops it from starting. Nothing is lost — the nightly pass has no
    budget and takes exactly the same members with exactly the same refusals.
    """
    try:
        return int(float(config_value('IMMEDIATE_RECLAIM_SWEEP_MAX_FILES', '20000', repo)))
    except (TypeError, ValueError):
        return 20000


def tracked_file_count(path):
    """How many files the index holds, or None when it cannot be asked. None
    is NOT zero: an unanswerable count skips the candidate in the sweep rather
    than admitting it, for the same reason processes_using fails closed."""
    try:
        res = subprocess.run(['git', '-C', path, 'ls-files', '-z'],
                             capture_output=True, timeout=20)
        if res.returncode != 0:
            return None
        return res.stdout.count(b'\0')
    except Exception:
        return None


def _sweep_marker(tx, session_id):
    return os.path.join(tx.session_dir(session_id), 'last-sweep')


def sweep_session(tx, session_id, deadline=None):
    """Finish what an EARLIER terminal event could not, from THIS one.

    RUNS LAST, NEVER FIRST (round 12, 2026-09-10). It used to run at the top
    of terminalize-agent-worktrees.sh, BEFORE this event's own
    `claim_terminal` — inside a hook the harness kills at 20 seconds, with the
    budget checked only between candidates. So a slow sweep could consume the
    whole hook and THIS event's irrevocable terminal record would silently
    never be written, in a hook that exits 0 by design and therefore could not
    say so. The catch-up for an earlier agent was placed ahead of the one
    thing this event alone can do. That ordering is inverted; the hook's own
    header had promised the correct order all along ("writes the irrevocable
    `terminal` record BEFORE mutating any worktree").

    `deadline` is an absolute time.time() the caller has left. It is checked
    before each candidate AND before any expensive phase begins, and a
    candidate whose tree is bigger than sweep_max_files is not started at all.
    An expired budget is REPORTED, as a ('', 'budget-expired', reason) row —
    a control that runs out of time and says nothing is how the 20-second
    failure stayed invisible.

    WHY IT EXISTS AT ALL. An event's own member can be refused — the platform
    still held its lock, a process was in the tree, git was busy — and would
    then sit until the 04:00 job, which is the 24-hour gap again for the
    unlucky case. So every terminal event, including one for an agent that
    owns no worktree at all (over a thousand helper stops a session on this
    machine, which is what gives the sweep its cadence), spends a small budget
    finishing this session's deferred members. It is the same reclaim_now on
    members already recorded terminal, refusing everything it always refused,
    and it is not new authority. It never waits for a lock: a sweep takes what
    is already free and leaves the rest to the next event.

    Returns [(path, outcome, reason)] for what it touched. Never raises.
    """
    out = []
    try:
        budget, interval = sweep_seconds()
        ceiling = sweep_max_files()
        marker = _sweep_marker(tx, session_id)
        now = time.time()
        if deadline is not None and now >= deadline:
            out.append(('', 'budget-expired',
                        'the terminal event had no time left for the catch-up sweep; the nightly '
                        'pass takes these members with the same refusals'))
            return out
        try:
            if interval > 0 and now - os.path.getmtime(marker) < interval:
                return out
        except OSError:
            pass
        candidates = []
        for name in sorted(os.listdir(tx.session_dir(session_id))):
            if not name.endswith('.json'):
                continue
            transaction = tx.read_json(os.path.join(tx.session_dir(session_id), name))
            if not transaction or transaction.get('record') != 'transaction' or not terminal_fact(transaction):
                continue
            # a workspace given to this agent after its manifest sealed joins
            # here, so the catch-up sees it like any other member
            transaction = tx.bind_late_members(transaction['session_id'], transaction['agent_id']) or transaction
            for index, member in enumerate(transaction.get('members') or []):
                if member.get('cleanup_policy') != 'integrated-daily':
                    continue
                if (member.get('daily_cleanup') or {}).get('phase') == 'complete':
                    continue
                if not os.path.lexists(member.get('path') or ''):
                    continue
                candidates.append((transaction['agent_id'], index, member.get('path')))
        if not candidates:
            return out
        try:
            with open(marker, 'a'):
                os.utime(marker, None)
        except OSError:
            pass
        # The sweep's own budget, never longer than what the CALLER has left.
        # A hook with 4 seconds remaining does not get to start a 10-second
        # sweep just because the config says 10.
        stop_at = now + budget
        if deadline is not None:
            stop_at = min(stop_at, deadline)
        for aid, index, path in candidates:
            if time.time() >= stop_at:
                out.append(('', 'budget-expired',
                            'the catch-up sweep ran out of its %.1fs budget with %d candidate(s) '
                            'unexamined; the nightly pass takes them with the same refusals'
                            % (budget, len(candidates) - len(out))))
                break
            # THE CEILING, CHECKED BEFORE ANY EXPENSIVE PHASE BEGINS. A clock
            # cannot stop work that has already started, and the work this
            # skips (lsof over the tree, a hash of every tracked file, a
            # verified archive of every ignored file) is measured in seconds
            # on a real repository. An unanswerable count is not zero.
            count = tracked_file_count(path or '')
            if count is None:
                out.append((path, 'deferred',
                            'could not count the tracked files of this workspace, so the in-event '
                            'sweep does not start it; the nightly pass has no budget and will'))
                continue
            if count > ceiling:
                out.append((path, 'deferred',
                            'this workspace holds %d tracked files, above the in-event ceiling of '
                            '%d (IMMEDIATE_RECLAIM_SWEEP_MAX_FILES); a 20-second hook is the wrong '
                            'place to start it and the nightly pass is the right one'
                            % (count, ceiling)))
                continue
            try:
                with tx.tx_lock(session_id, aid, timeout=1):
                    transaction = tx.load_tx(session_id, aid)
                    if not transaction:
                        continue
                    # deadline in the PAST: a sweep never waits for a lock,
                    # it takes what the platform has already released.
                    outcome, reason = reclaim_now(tx, transaction, index, deadline=0)
            except Exception as error:
                outcome, reason = 'deferred', str(error)
            out.append((path, outcome, reason))
    except Exception:
        return out
    return out

