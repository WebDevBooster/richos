#!/usr/bin/env python3
"""Exact managed-image membership bridge for the existing worktree lifecycle."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import stat
import sys
import time
import uuid

CLIENT_CONFIG = Path('/Library/Application Support/RichOS/ManagedWorkspaces/client.json')


def _module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), Path(__file__).with_name(filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def config():
    if not CLIENT_CONFIG.exists() and not CLIENT_CONFIG.is_symlink():
        return None
    reject_acl = _module('managed-workspace-volume.py').reject_unsafe_acl
    for path in (CLIENT_CONFIG, *CLIENT_CONFIG.parents):
        st = path.lstat()
        if st.st_uid != 0 or st.st_mode & 0o022 or stat.S_ISLNK(st.st_mode):
            raise RuntimeError('managed workspace client policy is not root protected')
        reject_acl(path)
    data = json.loads(CLIENT_CONFIG.read_text())
    if data.get('version') != 1 or not isinstance(data.get('repositories'), dict):
        raise RuntimeError('invalid managed workspace client policy')
    return data


def alias_for(repo):
    data = config()
    if data is None:
        return None
    matches = [name for name, path in data['repositories'].items()
               if str(Path(path).resolve()) == str(Path(repo).resolve())]
    if len(matches) != 1:
        raise RuntimeError('repository has no unique managed workspace policy')
    return matches[0]


def request(payload, *, timeout=10):
    data = config()
    if data is None:
        raise RuntimeError('managed workspace broker is not installed')
    return _module('managed-workspace-client.py').call(payload, socket_path=data['socket'], timeout=timeout)


def inspect_path(path, *, session_id=None, agent_name=None):
    data = config()
    if data is None:
        raise RuntimeError('managed workspace broker is not installed')
    # Do not resolve through a worker-replaceable symlink before checking the
    # manager namespace. Only the broker's returned exact path has authority.
    given = Path(os.path.abspath(path))
    active = Path(data['active_root']).resolve()
    if given.name != 'repo' or given.parent.parent != active:
        raise RuntimeError('path is outside the managed workspace namespace')
    ident = given.parent.name
    if str(uuid.UUID(ident)) != ident:
        raise RuntimeError('managed workspace UUID required')
    record = request(dict(operation='inspect', id=ident))
    if (record.get('manager_id') != ident or record.get('workspace_class') != 'managed-image'
            or record.get('path') != str(given) or given.is_symlink()
            or record.get('state') != 'active'):
        raise RuntimeError('managed workspace identity or active state mismatch')
    if session_id is not None and record.get('session_id') != session_id:
        raise RuntimeError('managed workspace session mismatch')
    if agent_name is not None and record.get('agent_name') != agent_name:
        raise RuntimeError('managed workspace teammate mismatch')
    return record


def verify_member(member):
    record = inspect_path(member['path'], session_id=member.get('session_id'), agent_name=member.get('agent_name'))
    if member.get('manager_id') != record['manager_id'] or str(Path(member['repo']).resolve()) != record['source_repo']:
        raise RuntimeError('prepared managed workspace identity changed')
    return record


def bind_member(member, session_id, agent_id):
    record = verify_member(member)
    bound = request(dict(operation='bind', id=record['manager_id'], session_id=session_id, agent_id=agent_id))
    if bound.get('agent_id') != agent_id or bound.get('session_id') != session_id:
        raise RuntimeError('managed workspace binding was not acknowledged')
    return bound



def validate_delivery(delivery, ident, repo):
    if (not isinstance(delivery, dict) or set(delivery) != {'manager_id', 'source_repo', 'ref', 'tip'}
            or delivery.get('manager_id') != ident
            or delivery.get('source_repo') != str(Path(repo).resolve())
            or delivery.get('ref') != 'refs/richos/handoffs/managed/' + ident + '/HEAD'
            or not isinstance(delivery.get('tip'), str)
            or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', delivery['tip'])):
        raise RuntimeError('managed delivery identity mismatch')
    return delivery


def delivery_for(ident, repo):
    # The broker verifies current canonical identity and every recovery ref.
    # Merge the exact returned tip, never a reused teammate branch name.
    result = request(dict(operation='delivery', id=ident))
    return validate_delivery(result, ident, repo)


def terminal_member(member, session_id, agent_id, *, reconcile=False):
    ident = member['manager_id']
    record = request(dict(operation='terminal', id=ident, session_id=session_id, agent_id=agent_id))
    if (record.get('id') != ident or record.get('manager_id') != ident
            or record.get('agent_id') != agent_id or record.get('session_id') != session_id
            or record.get('state') == 'active'):
        raise RuntimeError('managed workspace terminal claim was not acknowledged')
    if reconcile:
        record = request(dict(operation='reconcile', id=ident), timeout=330)
        if record.get('id') != ident or record.get('manager_id') != ident:
            raise RuntimeError('managed reconciliation receipt identity mismatch')
    if record.get('delivery') is not None:
        validate_delivery(record['delivery'], ident, member['repo'])
    if record.get('delivery_mode') == 'handoff-ref-v1' and record.get('state') in ('retained', 'expired'):
        if record.get('delivery') is None:
            raise RuntimeError('reclaimed managed workspace has no delivery receipt')
    return record


def create(*, repo, commit, session_id, agent_name, request_id):
    alias = alias_for(repo)
    if alias is None:
        raise RuntimeError('managed workspaces are not configured')
    record = request(dict(operation='create', repository=alias, commit=commit,
                          session_id=session_id, agent_name=agent_name,
                          request_id=request_id), timeout=330)
    verified = inspect_path(record['path'], session_id=session_id, agent_name=agent_name)
    if (verified.get('source_repo') != str(Path(repo).resolve()) or verified.get('source_commit') != commit
            or record.get('id') != verified.get('id') or record.get('manager_id') != verified.get('manager_id')):
        raise RuntimeError('managed creation receipt source or identity mismatch')
    return verified


def recover_preparations(*, deadline=None):
    """Conservatively close unused preparations; the daemon captures later."""
    if config() is None:
        return []
    ledger = _module('worktree-ledger.py')
    results, after = [], ''
    while not deadline or time.time() < deadline:
        inventory = request(dict(operation='preparations', after=after))
        rows = inventory.get('records')
        if not isinstance(rows, list):
            raise RuntimeError('preparation inventory unavailable')
        for row in rows:
            if deadline and time.time() >= deadline:
                return results
            ident, session = row.get('id'), row.get('session_id')
            if not ident or not session:
                raise RuntimeError('preparation identity unavailable')
            # Current time includes resumed sessions too. Using creation time
            # would incorrectly ignore a process that resumed this session later.
            state, reason = ledger.session_gone_by_exhaustion(session, time.time())
            if state != 'gone':
                results.append(dict(id=ident, state='retained', reason=reason))
                continue
            receipt = request(dict(operation='cancel_preparation', id=ident, session_id=session))
            if (receipt.get('id') != ident or receipt.get('session_id') != session
                    or receipt.get('agent_id') is not None or receipt.get('state') == 'active'
                    or receipt.get('terminal_ingress') != 'abandoned-preparation'):
                raise RuntimeError('preparation cancellation not acknowledged')
            results.append(dict(id=ident, state='terminal'))
        cursor = inventory.get('next_cursor')
        if cursor is None:
            break
        if not isinstance(cursor, str) or cursor <= after or not rows or rows[-1].get('id') != cursor:
            raise RuntimeError('preparation inventory cursor did not advance')
        after = cursor

    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='op', required=True)
    p = sub.add_parser('configured'); p.add_argument('--repo', required=True)
    p = sub.add_parser('inspect'); p.add_argument('--path', required=True)
    p = sub.add_parser('delivery'); p.add_argument('--id', required=True); p.add_argument('--repo', required=True)
    p = sub.add_parser('create')
    for name in ('repo', 'commit', 'session-id', 'agent-name', 'request-id'):
        p.add_argument('--'+name, required=True)
    args = parser.parse_args()
    try:
        if args.op == 'configured':
            alias = alias_for(args.repo)
            if alias is None:
                return 3
            print(alias)
        elif args.op == 'delivery':
            print(json.dumps(delivery_for(args.id, args.repo), sort_keys=True))
        elif args.op == 'inspect':
            print(json.dumps(inspect_path(args.path), sort_keys=True))
        else:
            verified = create(repo=args.repo, commit=args.commit, session_id=args.session_id,
                              agent_name=args.agent_name, request_id=args.request_id)
            print(json.dumps(verified, sort_keys=True))
        return 0
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
