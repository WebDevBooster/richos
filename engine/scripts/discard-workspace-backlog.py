#!/usr/bin/env python3
"""One-time operator-authorized discard, not the daily completion policy.

The caller supplies an exact reviewed list of dead worktrees and branch tips.
No content capture, dirty-file check, branch-name heuristic or age heuristic is
used. Active work and canonical repositories must be listed as protected roots.
Ordinary daily reclamation instead requires the workspace delivery receipt.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import threading
import time


def module(name):
    path = Path(__file__).parent / 'lib' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


filesystem = module('durable-filesystem-identity')


def excluded_by_ceo_ruling(path='', branch=''):
    """(excluded, why) — ceo-decisions.md section 31, AT THIS DOOR (Sage D2,
    round two, 2026-09-10). This tool removes with `--force --force` from an
    operator-typed manifest whose `authorization` is a free string; a manifest
    naming the nine Codex trees on the operator's machine would have removed
    all nine, locked or dirty, in one run, and the decision table's row 1
    claimed "every door" while this one had no refusal. The classifier is the
    ONE in daily-workspace-cleanup (`ceo_owned_workspace`) so the class has
    one definition; if it cannot be loaded this door refuses rather than
    guesses, because a deletion tool that cannot evaluate a ruling must not
    proceed."""
    try:
        daily = module('daily-workspace-cleanup')
        return daily.ceo_owned_workspace({'path': path, 'branch': branch})
    except Exception as error:
        return True, ('the section-31 classifier could not be loaded (%s); refusing rather than guessing'
                      % error)


def refuse_ceo_owned(path='', branch=''):
    excluded, why = excluded_by_ceo_ruling(path, branch)
    if excluded:
        raise ValueError('EXCLUDED BY CEO RULING (ceo-decisions.md section 31): %s. There is no flag, no '
                         'authorization string and no manifest that unlocks the class; nothing is removed'
                         % why)


def git(repo, *args, input=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_NO_REPLACE_OBJECTS='1', GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
                             '-c', 'core.fsmonitor=false', '-C', str(repo), *args],
                            input=input, capture_output=True, text=True,
                            env=env, timeout=600)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[:2000] or 'Git operation failed')
    return result.stdout.strip()


def identity(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or path.resolve() != path:
        raise ValueError('An exact physical directory is required: ' + str(path))
    return {'volume': filesystem.filesystem_token(path, info), 'inode': info.st_ino}


def inventory(repo):
    rows = []
    for record in git(repo, 'worktree', 'list', '--porcelain', '-z').split('\0\0'):
        fields = {}
        for line in record.split('\0'):
            if line:
                key, _, value = line.partition(' ')
                fields[key] = value
        if fields:
            rows.append(fields)
    return rows


def validate(manifest):
    if (manifest.get('version') != 1 or manifest.get('discard_dead_contents') is not True
            or not manifest.get('authorization') or not manifest.get('deadness_evidence')):
        raise ValueError('Explicit discard authority and deadness evidence are required')
    if not 0 < manifest.get('expires_at', 0) - time.time() <= 900:
        raise ValueError('Discard inventory must be freshly reviewed within fifteen minutes')
    protected = [Path(p) for p in manifest['protected_roots']]
    if not protected or any(not p.is_absolute() or p.resolve() != p for p in protected):
        raise ValueError('Exact protected roots are required')
    paths = set()
    repos = set()
    canonical_roots = {Path(g['path']) for g in manifest['repositories']}
    for group in manifest['repositories']:
        repo = Path(group['path'])
        if repo in repos or repo not in protected or identity(repo) != group['identity']:
            raise ValueError('Canonical repository identity/protection mismatch')
        repos.add(repo)
        if git(repo, 'symbolic-ref', 'HEAD') != group['integration_ref']:
            raise ValueError('Canonical checkout changed branches')
        if git(repo, 'rev-parse', 'HEAD') != group['integration_tip']:
            raise ValueError('Canonical integration tip changed')
        current = {r['worktree']: r for r in inventory(repo)}
        if not current or next(iter(current)) != str(repo):
            raise ValueError('Repository is not its canonical worktree')
        for row in group['worktrees']:
            path = Path(row['path'])
            # SECTION 31, BEFORE ANYTHING ELSE ABOUT THIS ROW IS ACCEPTED: the
            # path, and the branch git says is checked out there (never only
            # what the manifest says).
            refuse_ceo_owned(str(path), (current.get(str(path)) or {}).get('branch', ''))
            if (path in paths or not path.is_absolute() or path.resolve() != path
                    or any(path == p or path in p.parents
                           or (p not in canonical_roots and p in path.parents) for p in protected)):
                raise ValueError('Selected worktree overlaps protected work or another selection')
            if any(path in p.parents or p in path.parents for p in paths):
                raise ValueError('Selected worktrees overlap')
            paths.add(path)
            if current.get(str(path)) != row['registration']:
                raise ValueError('Worktree registration changed: ' + str(path))
            actual = identity(path) if path.exists() else None
            if actual != row['identity']:
                raise ValueError('Worktree physical identity changed: ' + str(path))
        seen_refs = set()
        for row in group['branches']:
            ref = row['ref']
            refuse_ceo_owned(branch=ref)
            if (not ref.startswith('refs/heads/') or ref == group['integration_ref']
                    or ref in seen_refs):
                raise ValueError('Duplicate or protected branch')
            seen_refs.add(ref)
            git(repo, 'check-ref-format', ref)
            if git(repo, 'for-each-ref', '--format=%(objectname) %(symref)', ref) != row['tip']:
                raise ValueError('Branch changed or became symbolic: ' + ref)
            users = [r['worktree'] for r in current.values() if r.get('branch') == ref]
            if any(p not in {r['path'] for r in group['worktrees']} for p in users):
                raise ValueError('Branch is checked out outside the approved dead list')


def discard(manifest, emit):
    # Validate the whole batch before the first removal. This caller-controlled
    # maintenance window is distinct from automatic daily completion authority.
    validate(manifest)
    sink, journal_lock = emit, threading.Lock()
    def emit(row):
        with journal_lock:
            sink(row)
    def remove(item):
        group, row = item
        try:
            current = {r['worktree']: r for r in inventory(group['path'])}
            if current.get(row['path']) != row['registration']:
                raise ValueError('Worktree registration changed before removal')
            actual = identity(row['path']) if Path(row['path']).exists() else None
            if actual != row['identity']:
                raise ValueError('Worktree identity changed before removal')
            emit({'path': row['path'], 'status': 'removal-started',
                  'identity': row['identity'], 'registration': row['registration']})
            # Native Git owns registration removal, including locked dead
            # worktrees explicitly included in this discard authorization.
            git(group['path'], 'worktree', 'remove', '--force', '--force', '--', row['path'])
            return {'path': row['path'], 'status': 'removed'}
        except Exception as error:
            return {'path': row['path'], 'status': 'held', 'reason': str(error)}

    # One worker per repository: Git owns each common directory serially while
    # independent repositories can reclaim space concurrently.
    def group_worktrees(group):
        results = []
        for row in group['worktrees']:
            result = remove((group, row))
            emit(result)
            results.append(result)
        return results

    results = []
    with ThreadPoolExecutor(max_workers=min(4, max(1, len(manifest['repositories'])))) as pool:
        for rows in pool.map(group_worktrees, manifest['repositories']):
            for row in rows:
                results.append(row)
    for group in manifest['repositories']:
        try:
            current = inventory(group['path'])
            occupied = {r.get('branch') for r in current}
            branches = [r for r in group['branches'] if r['ref'] not in occupied]
            if git(group['path'], 'symbolic-ref', 'HEAD') != group['integration_ref']:
                raise ValueError('Canonical checkout changed branches before branch cleanup')
            if git(group['path'], 'rev-parse', 'HEAD') != group['integration_tip']:
                raise ValueError('Canonical integration tip changed before branch cleanup')
            if branches:
                commands = ['start', 'option no-deref']
                for row in branches:
                    if git(group['path'], 'for-each-ref', '--format=%(objectname) %(symref)', row['ref']) != row['tip']:
                        raise ValueError('Branch changed or became symbolic before cleanup')
                    commands.append('delete ' + row['ref'] + ' ' + row['tip'])
                commands += ['prepare', 'commit', '']
                emit({'repository': group['path'], 'status': 'branch-transaction-started',
                      'branches': branches})
                git(group['path'], 'update-ref', '--stdin', input='\n'.join(commands))
            result = {'repository': group['path'], 'status': 'branches-removed',
                      'refs': [r['ref'] for r in branches],
                      'held_refs': [r['ref'] for r in group['branches'] if r['ref'] in occupied]}
        except Exception as error:
            result = {'repository': group['path'], 'status': 'branches-held', 'reason': str(error)}
        emit(result)
        results.append(result)
    return results


def journal_path(path, manifest):
    path = path.absolute()
    if path.parent.resolve() != path.parent:
        raise ValueError('Journal parent must be an exact physical directory')
    for group in manifest['repositories']:
        for row in group['worktrees']:
            target = Path(row['path'])
            if path == target or target in path.parents:
                raise ValueError('Operation journal must be outside every selected worktree')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--journal', type=Path)
    args = parser.parse_args()
    data = args.manifest.read_bytes()
    if hashlib.sha256(data).hexdigest() != args.sha256:
        raise ValueError('Reviewed manifest hash mismatch')
    manifest = json.loads(data)
    validate(manifest)
    if not args.execute:
        print(json.dumps({'status': 'validated', 'deletion_performed': False}))
        return 0
    if args.journal is None:
        raise ValueError('An exclusive new operation journal is required')
    path = journal_path(args.journal, manifest)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, 'w') as journal:
        def emit(row):
            record = dict(row, at=time.time(), manifest_sha256=args.sha256)
            journal.write(json.dumps(record, sort_keys=True) + '\n')
            journal.flush()
            os.fsync(journal.fileno())
            print(json.dumps(record), flush=True)
        emit({'status': 'authorized-discard-started'})
        try:
            results = discard(manifest, emit)
        except Exception as error:
            emit({'status': 'interrupted', 'reason': str(error)})
            raise
        failed = any(r['status'] in ('held', 'branches-held') or r.get('held_refs') for r in results)
        emit({'status': 'incomplete' if failed else 'complete'})
        return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
