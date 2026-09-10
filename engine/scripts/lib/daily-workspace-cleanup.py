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
    its branch deleted only when the tip equals the head the record saved at
    terminal time, that head is an ancestor of `main`, and no checkout holds
    the branch.

A process standing in the tree holds it (nothing is killed). An untracked
file, an unmerged commit, a live lock, a running owner, a changed tip or an
unverifiable archive holds it. Every hold is written on the member.
"""
import hashlib
import importlib.util
from datetime import datetime
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile

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


def owner_check(tx, transaction, member):
    """Positive terminal fact plus fresh complete competing-reservation veto."""
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
                        and bool(transaction.get('teammate'))):
                    # A name can be reused after an earlier terminal record.
                    # Only the preparation predating this exact seal belongs
                    # to it; absent/ambiguous timestamps retain the reservation.
                    try:
                        own = datetime.fromisoformat(row['ts'].replace('Z', '+00:00')) <= datetime.fromisoformat(transaction['sealed_ts'].replace('Z', '+00:00'))
                    except (KeyError, TypeError, ValueError):
                        own = False
                other = records.get(key)
                if not own and not (other and terminal_fact(other)):
                    raise RuntimeError('active or unbound preparation reservation')
    # Terminal ingress is positive death evidence, but an actual native live
    # lock still vetoes it. Never use the cross-repository worktree as that lock.
    native = [m for m in transaction['members'] if m.get('class') == 'native']
    entity = native[0]['repo'] if native else member['repo']
    live = _load('agent-liveness').resolve(entity, aid)
    if live.get('verdict') != 'NOT-ALIVE':
        raise RuntimeError('native owner is live or unknown: ' + str(live.get('reason')))


# ---------------------------------------------------------------------------
# the owning session — gone, or not provably gone
# ---------------------------------------------------------------------------

def session_gone(transaction):
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
    ledger = _load('worktree-ledger')
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
# ignored bytes — disposable by policy, or archived and verified
# ---------------------------------------------------------------------------

def ignored_files(path):
    raw = _load('completion-proof').git(path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z').stdout
    return [os.fsdecode(x) for x in raw.split(b'\0') if x]


def partition_ignored(files, disposable):
    keep, residue = [], []
    for rel in files:
        if any(component in disposable for component in rel.split('/')):
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


def archive_residue(tx, transaction, index, path, residue):
    """Archive every ignored, non-disposable file under `path` into the
    capture store, re-read the archive and verify every entry against its
    manifest, and return the record the journal carries. Raises on any
    mismatch — an unverified archive never authorizes a removal."""
    _assert_capture_rooting(tx)
    cdir = _capture_dir(tx, transaction, index)
    _private_dirs(tx.capture_root(), cdir)
    manifest = {}
    total = 0
    for rel in sorted(residue):
        full = os.path.join(path, rel)
        info = os.lstat(full)
        if stat.S_ISLNK(info.st_mode):
            manifest[rel] = {'kind': 'symlink', 'target': os.readlink(full), 'mode': info.st_mode & 0o7777}
        elif stat.S_ISREG(info.st_mode):
            manifest[rel] = {'kind': 'file', 'size': info.st_size, 'mode': info.st_mode & 0o7777, 'sha256': _sha256(full)}
            total += info.st_size
        else:
            raise RuntimeError('ignored residue %s is neither a file nor a symlink; retained' % rel)
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
    record = {'archive': tar_path, 'files': len(manifest), 'bytes': total,
              'manifest_sha256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode('utf-8')).hexdigest(),
              'archived_ts': tx.now_iso()}
    tx.atomic_write_json(os.path.join(cdir, 'ignored-residue.json'), {'manifest': manifest, 'record': record})
    return record


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
            if info['kind'] == 'file':
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
    RICHOS_DAILY_PROCESSES stands in for the table in tests ("none" = empty):
    newline-separated "<pid> <command line>" rows."""
    override = os.environ.get('RICHOS_DAILY_PROCESSES')
    if override is not None:
        rows = [line.strip().partition(' ') for line in override.splitlines() if line.strip() and line.strip() != 'none']
        return sorted({int(pid) for pid, _sep, cmd in rows if pid.isdigit() and path in cmd})
    pids = set()
    try:
        res = subprocess.run(['lsof', '-t', '+D', path], capture_output=True, text=True, timeout=120)
        pids.update(int(tok) for tok in res.stdout.split() if tok.isdigit())
    except Exception:
        pass
    try:
        res = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True, timeout=20)
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit() and path in parts[1]:
                pids.add(int(parts[0]))
    except Exception:
        pass
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
            break
    return sorted(x for x in pids if x != me and x not in ancestors)


# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------

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

def _absent_native_without_receipt(tx, transaction, index):
    """The platform removed the checkout and no TaskCompleted receipt was ever
    written, so no proof can be replayed. What the record DOES hold is the
    head observe_platform_native read from the registry at terminal time and
    the backup ref it saved. The branch goes only when: the tip is exactly
    that head, that head is an ancestor of main, no registered checkout holds
    the branch, and the recorded head is real. Same compare-and-set as the
    receipt path; a moved tip or an unintegrated head is retained."""
    member = transaction['members'][index]
    sid, aid = transaction['session_id'], transaction['agent_id']
    proof_api = _load('completion-proof')
    repo, path, head = member.get('repo') or '', member.get('path') or '', member.get('head') or ''
    if not (tx.platform_native(member) and member.get('state') == 'removed'
            and member.get('closed') == 'platform-removed' and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', head)):
        raise RuntimeError('removed workspace has no retained completion proof')
    if os.path.lexists(path) or path in proof_api.registry(repo):
        raise RuntimeError('removed native member has a path or registration again; retained')
    branch = member.get('branch') or ''
    if not branch:
        return tx.update_member(sid, aid, index, daily_cleanup={'version': 1, 'phase': 'complete', 'proof_source': 'recorded-head', 'branch': ''},
                                cleanup_policy='integrated-daily', closed='integrated-daily-cleanup', blocked=False, retry_after_epoch=0, last_error=None)
    ref = branch if branch.startswith('refs/') else 'refs/heads/' + branch
    if ref in ('refs/heads/main', 'refs/heads/master'):
        raise RuntimeError('canonical worktree or protected branch retained')
    main = proof_api.direct(Path(repo), 'refs/heads/main')
    if proof_api.git(repo, 'merge-base', '--is-ancestor', head, main, allowed=(0, 1)).returncode:
        raise RuntimeError('Current canonical main no longer contains the delivery')
    if any(row.get('branch') == ref for row in proof_api.registry(repo).values()):
        raise RuntimeError('branch is still reserved by a registered worktree')
    raw = _git(repo, 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', ref)
    matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == ref]
    if matches:
        if len(matches) != 1 or matches[0][1] != head or any(matches[0][2:]):
            raise RuntimeError('branch tip or direct-reference identity changed')
        _git(repo, 'update-ref', '--no-deref', '-d', ref, head)
        _checkpoint('after-branch-delete')
    backup = member.get('backup_ref')
    if backup and backup == tx.backup_ref(sid, aid, member.get('branch')):
        raw = _git(repo, 'for-each-ref', '--format=%(refname) %(objectname) %(symref)', backup)
        matches = [line.split(' ') for line in raw.splitlines() if line.split(' ')[0] == backup]
        if matches and len(matches) == 1 and matches[0][1] == head and not any(matches[0][2:]):
            _git(repo, 'update-ref', '--no-deref', '-d', backup, head)
    journal = {'version': 1, 'phase': 'complete', 'proof_source': 'recorded-head', 'head': head, 'branch': ref, 'integration_tip': main}
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
            if tx.platform_native(member) and member.get('state') == 'removed' and member.get('closed') == 'platform-removed':
                head = member.get('head') or ''
                main = proof_api.direct(Path(member['repo']), 'refs/heads/main')
                if proof_api.git(member['repo'], 'merge-base', '--is-ancestor', head, main, allowed=(0, 1)).returncode:
                    return 'hold', 'recorded head %s is not an ancestor of main' % head[:12]
                return 'branch-only', 'platform-removed native member; branch deleted by recorded head'
            return 'hold', 'removed workspace has no retained completion proof'
        _check_proof_scope(member, proof)
        proof_api.verify_member_proof(proof, path_present=present)
        if not present:
            return 'branch-only', 'workspace already gone; branch by exact compare-and-set'
        repo = member['repo']
        row = proof_api.registry(repo).get(member['path'])
        if tx.platform_native(member):
            gone, why = session_gone(transaction)
            if not gone:
                return 'observe', 'platform-owned; ' + why
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
            return 'hold', 'process(es) %s still use the tree' % ','.join(str(p) for p in pids)
        keep, residue = partition_ignored(ignored_files(member['path']), disposable_paths(repo))
        return 'remove', '%s; ignored: %d disposable dropped, %d archived first' % (why if tx.platform_native(member) else 'clean, integrated, unlocked', len(keep), len(residue))
    except Exception as error:
        return 'hold', str(error)


def reconcile(tx, transaction, index):
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
        if tx.platform_native(member):
            gone, why = session_gone(transaction)
            if not gone:
                # Claude remains the owner of its native checkout while the
                # session that created it may still act on it.
                return tx.observe_platform_native(sid, aid, index)
            if not row or 'prunable' in row:
                raise RuntimeError('exact registration required')
            if 'locked' in row:
                _release_dead_lock(repo, member['path'], row['locked'])
                row = proof_api.registry(repo).get(member['path'])
                if not row or 'locked' in row:
                    raise RuntimeError('lock still present after release; retained')
            saved = dict(saved, session_gone=why)
        elif not row or 'locked' in row or 'prunable' in row:
            raise RuntimeError('exact unlocked registration required')
        pids = processes_using(member['path'])
        if pids:
            raise RuntimeError('process(es) %s still use %s; retained' % (','.join(str(p) for p in pids), member['path']))
        keep, residue = partition_ignored(ignored_files(member['path']), disposable_paths(repo))
        residue_record = archive_residue(tx, transaction, index, member['path'], residue) if residue else None
        owner_check(tx, transaction, member)
        proof_api.verify_member_proof(proof)
        saved = dict(saved, ignored_disposable=len(keep), ignored_residue=residue_record)
        tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
        _git(repo, 'worktree', 'remove', '--', member['path'])
        _checkpoint('after-worktree-remove')
    registry = proof_api.registry(member['repo'])
    if member['path'] in registry or os.path.lexists(member['path']):
        raise RuntimeError('workspace removal is not complete')
    saved = dict(saved, phase='worktree-removed')
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
    saved = dict(saved, phase='complete')
    return tx.update_member(sid, aid, index, daily_cleanup=saved, state='removed',
                            closed='integrated-daily-cleanup', blocked=False,
                            retry_after_epoch=0, last_error=None)
