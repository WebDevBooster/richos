#!/usr/bin/env python3
"""Read-only legacy repository maintenance inventory. No mutation API exists."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat


HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    result = importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result


history = module('terminal-branch-cleanup')
ledger = module('worktree-ledger')


def pin(path, *, directory=True):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('absolute non-traversing path required')
    for component in (*reversed(path.parents), path):
        if stat.S_ISLNK(component.lstat().st_mode):
            raise ValueError('symlink path component: ' + str(component))
    info = path.lstat()
    if directory and not stat.S_ISDIR(info.st_mode):
        raise ValueError('directory required: ' + str(path))
    result = dict(path=str(path), device=info.st_dev, inode=info.st_ino,
                  mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if not directory and stat.S_ISREG(info.st_mode):
        result['contents'] = history._file_snapshot(path)
        if (result['contents']['device'], result['contents']['inode']) != (info.st_dev, info.st_ino):
            raise ValueError('path changed while being pinned: ' + str(path))
    return result


def registry(repo):
    result = history._git(repo, 'worktree', 'list', '--porcelain', '-z')
    if result is None or result.returncode or not result.stdout.endswith('\0\0'):
        raise ValueError('complete Git worktree registry unavailable')
    rows, paths = [], set()
    for record in result.stdout[:-2].split('\0\0'):
        fields = record.split('\0');row = {}
        for field in fields:
            key, _, value = field.partition(' ')
            if key not in ('worktree', 'HEAD', 'branch', 'detached', 'bare', 'locked', 'prunable') or key in row:
                raise ValueError('malformed Git registry record')
            row[key] = value
        path = row.get('worktree')
        if not path or not os.path.isabs(path) or path in paths or not fields[0].startswith('worktree '):
            raise ValueError('malformed or duplicate registered path')
        if 'bare' in row:
            raise ValueError('bare canonical repositories need a separate maintenance design')
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', row.get('HEAD', '')):
            raise ValueError('registered HEAD unavailable')
        if ('branch' in row) == ('detached' in row) or row.get('detached', ''):
            raise ValueError('registered branch identity ambiguous')
        if 'branch' in row:
            if not row['branch'].startswith('refs/heads/') or history._out(repo, 'check-ref-format', row['branch']) is None:
                raise ValueError('invalid registered branch')
        paths.add(path);rows.append(row)
    return rows


def terminal(tx):
    end = tx.get('terminal')
    sealed = history._time(tx.get('sealed_ts'))
    ended = history._time(end.get('ts')) if isinstance(end, dict) else None
    return (tx.get('sealed') is True and all(isinstance(tx.get(k), str) and tx[k] for k in ('session_id', 'agent_id'))
            and sealed is not None and ended is not None and ended >= sealed)


def object_storage(repo, common):
    objects = Path(common) / 'objects'
    identity = pin(objects)
    dependencies = []
    # Git follows symlinked loose buckets, individual objects and pack paths.
    # A gate on the common directory cannot revoke access to those targets.
    def scan_error(error):
        raise error
    for directory, dirs, files in os.walk(objects, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            path = Path(directory) / name
            entry = path.lstat()
            if stat.S_ISLNK(entry.st_mode) or entry.st_dev != identity['device']:
                dependencies.append('external-object-path:' + str(path))
                if name in dirs:
                    dirs.remove(name)
            elif (path.parent == objects / 'info' and name in ('alternates', 'http-alternates')
                  or path.parent == objects / 'pack' and name.endswith('.promisor')):
                dependencies.append(str(path))
    config = history._git(repo, 'config', '--local', '--get-regexp',
                          r'^(extensions\.partialclone|remote\..*\.promisor)$')
    if config is None or config.returncode not in (0, 1):
        raise ValueError('object dependency configuration unavailable')
    if config.returncode == 0:
        dependencies.append('promisor-configuration:' + config.stdout.strip())
    return {'identity': identity, 'external_dependencies': sorted(dependencies)}


def ownership(path, transactions, records, active_paths):
    statuses, witnesses = [], []
    if path in active_paths:
        statuses.append('live');witnesses.append({'kind': 'explicit-user-active-path'})
    matching = [r for r in records if history._path(r.get('worktree') or r.get('cwd')) == path]
    sessions = {r.get('session_id') for r in matching if r.get('session_id')}
    identities = {(str(r.get('session_pid')), repr(r.get('pid_start'))): r for r in records
                  if r.get('session_pid') and (r in matching or r.get('session_id') in sessions)}
    for record in identities.values():
        status = ledger.process_status(record['session_pid'], record.get('pid_start'))
        statuses.append('live' if status == 'alive' else 'unknown' if status == 'unknown' else 'gone')
        witnesses.append({'kind': 'process', 'session_id': record.get('session_id'),
                          'pid': record['session_pid'], 'status': status})
    txs = [tx for tx in transactions if any(history._path(m.get('path')) == path for m in tx['members'])]
    for tx in txs:
        state = 'terminal' if terminal(tx) else 'unknown'
        statuses.append(state)
        witnesses.append({'kind': 'transaction', 'session_id': tx.get('session_id'),
                          'agent_id': tx.get('agent_id'), 'status': state})
    # Missing identities cannot be cleared by another owner's terminal record.
    for record in matching:
        if record.get('event') not in ('registered', 'prepared'):
            continue
        owner = (record.get('session_id'), record.get('agent_id'))
        exact_terminal = any(terminal(tx) and (tx['session_id'], tx['agent_id']) == owner
                             and history._time(record.get('ts')) is not None
                             and history._time(record['ts']) <= history._time(tx['terminal']['ts']) for tx in txs)
        known_process = bool(record.get('session_pid') or any(r.get('session_pid') and r.get('session_id') == owner[0]
                                                            for r in records if owner[0]))
        if not exact_terminal and not known_process:
            statuses.append('unknown')
    state = ('live' if 'live' in statuses else 'unknown' if not statuses or 'unknown' in statuses
             else 'terminal' if 'terminal' in statuses else 'gone')
    return {'state': state, 'evidence': witnesses,
            'caveat': 'Recorded worker evidence does not exclude editors or other unrecorded writers.'}


def plan(policy, transactions, records, *, active_paths=(), input_errors=()):
    """Explicit repositories only. Output can never authorize maintenance."""
    errors = list(input_errors);transactions = list(transactions);records = list(records)
    history_digest = history._digest({'transactions': transactions, 'ledger': records})
    repositories = policy.get('repositories') if isinstance(policy, dict) else None
    if not isinstance(repositories, dict) or not repositories:
        errors.append('explicit approved repository aliases required');repositories = {}
    if any(not isinstance(tx, dict) or tx.get('record') != 'transaction' or not isinstance(tx.get('members'), list)
           or any(not isinstance(m, dict) for m in tx['members']) for tx in transactions):
        errors.append('malformed transaction history');transactions = []
    if any(not isinstance(r, dict) or not isinstance(r.get('event'), str) for r in records):
        errors.append('malformed ownership history');records = []
    if any(r.get('event') in ('registered', 'prepared') and not (history._path(r.get('repo')) or history._path(r.get('worktree')))
           for r in records):
        errors.append('ownership history lacks repository and path identity')
    active = set()
    for value in active_paths:
        try:
            active.add(pin(value)['path'])
        except (OSError, ValueError, TypeError) as error:
            errors.append('active path identity unavailable: ' + str(error))
    result = [];all_gates = [];common_seen = set()
    for alias, config in repositories.items():
        row = {'alias': alias, 'gate_paths': [], 'removal_candidates': [], 'blockers': [],
               'inventory_complete': False}
        result.append(row)
        try:
            if not isinstance(alias, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', alias):
                raise ValueError('invalid explicit repository alias')
            if not isinstance(config, dict) or not isinstance(config.get('path'), str):
                raise ValueError('approved repository path missing')
            repo_pin = pin(config['path']);repo = repo_pin['path']
            top = history._out(repo, 'rev-parse', '--show-toplevel')
            common = history._out(repo, 'rev-parse', '--git-common-dir')
            if top != repo or not common:
                raise ValueError('approved path is not an exact readable repository root')
            common_pin = pin(os.path.normpath(os.path.join(repo, common)))
            if common_pin['path'] in common_seen:
                raise ValueError('two aliases select the same Git repository')
            common_seen.add(common_pin['path'])
            rows = registry(repo)
            if not rows or rows[0]['worktree'] != repo:
                raise ValueError('policy must identify the canonical checkout, not a linked workspace')
            row.update(canonical_repository=repo_pin, common_git_directory=common_pin,
                       registry_sha256=history._digest(rows), registered_worktrees=rows)
            storage = None
            try:
                storage = object_storage(repo, common_pin['path'])
                row['object_storage'] = storage
                if storage['external_dependencies']:
                    row['blockers'].append('external-object-dependencies-need-separate-gates')
            except (OSError, ValueError, TypeError) as error:
                row['blockers'].append('object-storage-unavailable:' + str(error))
            for entry in rows:
                path = entry['worktree']
                gate = {'kind': 'canonical-checkout' if path == repo else 'registered-linked-worktree',
                        'path': path, 'head': entry['HEAD'], 'branch': entry.get('branch'),
                        'registry_flags': {k: entry[k] for k in ('locked', 'prunable', 'detached') if k in entry}}
                row['gate_paths'].append(gate);all_gates.append((alias, path))
                try:
                    gate['identity'] = pin(path)
                    actual_common = history._out(path, 'rev-parse', '--git-common-dir')
                    if not actual_common or os.path.normpath(os.path.join(path, actual_common)) != common_pin['path']:
                        raise ValueError('registered worktree belongs to another Git repository: ' + path)
                    gitdir = history._out(path, 'rev-parse', '--absolute-git-dir')
                    gate['git_directory'] = pin(gitdir)
                    gate['git_pointer'] = pin(Path(path) / '.git', directory=False)
                    if history._out(path, 'rev-parse', '--verify', 'HEAD') != entry['HEAD']:
                        raise ValueError('registered HEAD differs from workspace: ' + path)
                    branch = history._git(path, 'symbolic-ref', '-q', 'HEAD')
                    if branch is None or branch.returncode not in (0, 1) or (branch.stdout.strip() if branch.returncode == 0 else None) != entry.get('branch'):
                        raise ValueError('registered branch differs from workspace: ' + path)
                    gate['ownership'] = ownership(path, transactions, records, active)
                    if gate['ownership']['state'] in ('live', 'unknown'):
                        row['blockers'].append(gate['ownership']['state'] + '-owner:' + path)
                    if 'locked' in entry or 'prunable' in entry:
                        row['blockers'].append('registered-worktree-needs-review:' + path)
                    if path == repo:
                        continue
                    for tx in transactions:
                        if not terminal(tx):
                            continue
                        for member in tx['members']:
                            if history._path(member.get('path')) != path:
                                continue
                            ref = history._ref(member.get('branch'))
                            if (history._path(member.get('repo')) != repo or member.get('head') != entry['HEAD']
                                    or ref != entry.get('branch')):
                                row['blockers'].append('terminal-member-identity-mismatch:' + path)
                                continue
                            row['removal_candidates'].append(dict(path=path, session_id=tx['session_id'],
                                agent_id=tx['agent_id'], head=entry['HEAD'], branch=entry.get('branch'),
                                identity=gate['identity'], execution_authorized=False,
                                status='exact-terminal-member-requires-offline-revalidation'))
                except (OSError, ValueError, TypeError) as error:
                    gate['inventory_error'] = str(error)
                    row['blockers'].append('inventory-unavailable:' + str(error))
            # Shared objects/admin outside the checkout need their own gate.
            if not Path(common_pin['path']).is_relative_to(Path(repo)):
                row['gate_paths'].append(dict(kind='external-common-git-directory', **common_pin))
                all_gates.append((alias, common_pin['path']))
            if registry(repo) != rows:
                raise ValueError('Git registry changed during inventory')
            for gate in row['gate_paths']:
                if 'identity' in gate and 'inventory_error' not in gate:
                    if pin(gate['path']) != gate['identity'] or pin(gate['git_directory']['path']) != gate['git_directory']:
                        raise ValueError('workspace or Git identity changed during inventory')
                    if pin(Path(gate['path']) / '.git', directory=False) != gate['git_pointer']:
                        raise ValueError('workspace Git pointer changed during inventory')
                    current_common = history._out(gate['path'], 'rev-parse', '--git-common-dir')
                    if not current_common or os.path.normpath(os.path.join(gate['path'], current_common)) != common_pin['path']:
                        raise ValueError('workspace repository changed during inventory')
            if pin(common_pin['path']) != common_pin:
                raise ValueError('Git common directory changed during inventory')
            if storage is not None and object_storage(repo, common_pin['path']) != storage:
                raise ValueError('Git object storage changed during inventory')
            row['inventory_complete'] = storage is not None and not any('inventory_error' in gate for gate in row['gate_paths'])
        except (OSError, ValueError, TypeError) as error:
            row['blockers'].append('inventory-unavailable:' + str(error))
    for index, (alias, path) in enumerate(all_gates):
        for other_alias, other in all_gates[index + 1:]:
            if alias != other_alias and (path == other or Path(path) in Path(other).parents or Path(other) in Path(path).parents):
                for row in result:
                    if row['alias'] in (alias, other_alias):
                        row['blockers'].append('overlapping-gate-paths:' + path + ':' + other)
    covered = {path for _, path in all_gates}
    for path in active - covered:
        errors.append('explicit active path outside approved registered inventory:' + path)
    for row in result:
        # Native checkouts often live below the canonical checkout. Move that
        # ancestor once, while retaining every registered target's identity.
        gates = row['gate_paths']
        roots = [gate for gate in gates if not any(Path(other['path']) in Path(gate['path']).parents
                                                  for other in gates if other is not gate)]
        for gate in gates:
            containing = [root for root in roots if gate['path'] == root['path']
                          or Path(root['path']) in Path(gate['path']).parents]
            if len(containing) != 1:
                row['blockers'].append('ambiguous-consolidated-root:' + gate['path'])
                continue
            gate['gate_root'] = containing[0]['path']
            gate['relative_path'] = str(Path(gate['path']).relative_to(containing[0]['path']))
        row['gate_roots'] = [dict(root) for root in roots]
        row['temporary_parent_gates'] = []
        for parent in sorted({str(Path(root['path']).parent) for root in roots}):
            try:
                identity = pin(parent)
                names = sorted(os.listdir(parent))
                if pin(parent) != identity or sorted(os.listdir(parent)) != names:
                    raise ValueError('temporary parent namespace changed')
                row['temporary_parent_gates'].append(dict(path=parent, identity=identity,
                    affected_entries=names, scope='Briefly denies access through this parent to every listed child, including unrelated repositories.'))
            except (OSError, ValueError, TypeError) as error:
                row['blockers'].append('temporary-parent-inventory-unavailable:' + str(error))
        for candidate in row['removal_candidates']:
            target = next(g for g in gates if g['path'] == candidate['path'])
            candidate.update(gate_root=target.get('gate_root'), relative_path=target.get('relative_path'),
                             contained_registered_targets=[g['path'] for g in gates
                                 if Path(candidate['path']) in Path(g['path']).parents])
        row['blockers'] = sorted(set(row['blockers'] + errors))
        row['maintenance_ready'] = False
        row['required_downtime'] = ('Entire canonical repository, shared Git objects/admin and every listed workspace must be offline together. '
            'Temporary parent gates also interrupt access to all listed sibling entries; explicit offline approval must cover that shared-parent scope.')
    return dict(version=1, mode='planning-only', execution_ready=False, execution_authorized=False,
                repositories=result, errors=sorted(set(errors)),
                history_sha256=history_digest,
                limits=['No gating, permission changes, process termination, Git mutations or deletion is implemented.',
                        'A pre-reboot protected gate and a subsequent verified boot are required; daemon startup order is not a cutoff.',
                        'Active or unknown workers veto maintenance. Finish all work and obtain separate explicit downtime authorization.',
                        'Directory and Git snapshots are review evidence, not an exclusive-access or approval token.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', required=True)
    parser.add_argument('--active-path', action='append', default=[])
    args = parser.parse_args()
    with open(args.policy, encoding='utf-8') as stream:
        policy = json.load(stream)
    transactions, records, errors = history.load_history()
    report = plan(policy, transactions, records, active_paths=args.active_path, input_errors=errors)
    print(json.dumps(report, sort_keys=True))
    return 1 if report['errors'] or any(row['blockers'] for row in report['repositories']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
