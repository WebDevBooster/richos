#!/usr/bin/env python3
"""Cooperative terminal cleanup. No forced removal or hostile-writer claim.

Caller holds the existing transaction lock. A durable per-member proof precedes
removal, native Git checks cleanliness again and branch deletion uses exact CAS.
Incomplete/ambiguous ownership stays pending. Historical quarantine is separate.
"""
import importlib.util
from datetime import datetime
import json
import os
from pathlib import Path
import stat

HERE = Path(__file__).resolve().parent


def _load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
            and transaction['terminal'].get('ingress') in ('SubagentStop', 'WorktreeRemove', 'NativeMemberGone'))


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
                own = key == (sid, aid)
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


def _git(repo, *args):
    return _load('completion-proof').git(repo, *args).stdout.decode('utf-8')


def remember_native(member):
    """Return clean facts before platform removal; this records no death."""
    if member.get('daily_cleanup'):
        return member['daily_cleanup']
    proof = _load('completion-proof').prove_member(member)
    return {'version': 1, 'phase': 'prepared', 'proof': proof}


def _checkpoint(name):
    """Tests replace this hook; production has no environment crash switch."""


def reconcile(tx, transaction, index):
    member = transaction['members'][index]
    if member.get('class') == 'managed-image':
        raise RuntimeError('managed image is not an ordinary worktree')
    if member.get('quarantine') or member.get('quarantine_path'):
        raise RuntimeError('historical quarantine needs separate authorized maintenance')
    sid, aid = transaction['session_id'], transaction['agent_id']
    proof_api = _load('completion-proof')
    owner_check(tx, transaction, member)
    saved = member.get('daily_cleanup')
    if saved:
        if saved.get('version') != 1 or saved.get('phase') not in ('prepared', 'worktree-removed', 'branch-deleting', 'complete'):
            raise RuntimeError('cleanup journal malformed')
        proof = saved['proof']
        if proof['original_path'] != member['path'] or proof['repo'] != member['repo']:
            raise RuntimeError('cleanup journal scope changed')
    else:
        if os.path.lexists(member['path']):
            proof = proof_api.prove_member(member)
        else:
            receipts = proof_api.receipts_for_member(sid, aid, member['path'])
            proofs = [p for receipt in receipts for p in receipt.get('members', [])
                      if p.get('original_path') == member['path']]
            if not proofs:
                raise RuntimeError('removed workspace has no retained completion proof')
            proof = proofs[-1]
            proof_api.verify_member_proof(proof, path_present=False)
        saved = {'version': 1, 'phase': 'prepared', 'proof': proof}
        tx.update_member(sid, aid, index, daily_cleanup=saved, cleanup_policy='integrated-daily')
    expected_branch = member.get('branch') or ''
    if expected_branch and not expected_branch.startswith('refs/'):
        expected_branch = 'refs/heads/' + expected_branch
    if (proof['original_path'] != member['path'] or proof['repo'] != member['repo']
            or proof['branch'] != expected_branch):
        raise RuntimeError('completion proof does not match exact terminal member')
    present = os.path.lexists(member['path'])
    proof_api.verify_member_proof(proof, path_present=present)
    if proof['branch'] in ('refs/heads/main', 'refs/heads/master') or member['path'] == member['repo']:
        raise RuntimeError('canonical worktree or protected branch retained')
    if present:
        if tx.platform_native(member):
            # Claude remains the sole owner of its native checkout removal.
            return tx.observe_platform_native(sid, aid, index)
        registry = proof_api.registry(member['repo'])
        row = registry.get(member['path'])
        if not row or 'locked' in row or 'prunable' in row:
            raise RuntimeError('exact unlocked registration required')
        owner_check(tx, transaction, member)
        proof_api.verify_member_proof(proof)
        _git(member['repo'], 'worktree', 'remove', '--', member['path'])
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
