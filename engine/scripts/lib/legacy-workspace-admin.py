#!/usr/bin/env python3
"""Explicit root legacy maintenance commands. Never activates or reboots.

Invoke only from the installed protected release with the fixed Command Line
Tools Python and -I -S -B. Plan output never grants permission to stage.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import pwd
import sys


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def run(args):
    runtime = load('legacy_admin_runtime', 'managed-workspace-broker.py')
    release = runtime.validate_runtime()
    interpreter = Path('/Library/Developer/CommandLineTools/usr/bin/python3')
    if Path(sys.executable).resolve() != interpreter.resolve():
        raise ValueError('fixed Command Line Tools interpreter required')
    policy_path = runtime.protected_path(release.parent.parent / 'policy.json', regular=True)
    policy = runtime.validate_policy(json.loads(policy_path.read_text()))
    owner = policy['owners'].get(str(args.owner_uid))
    if owner is None:
        raise ValueError('inspection owner is not approved in installed policy')
    account = pwd.getpwuid(args.owner_uid)
    context = dict(version=1, owner_uid=args.owner_uid, owner_gid=owner['gid'],
                   owner_home=os.path.normpath(account.pw_dir), transactions=args.transactions, ledger=args.ledger)
    gate = load('legacy_admin_gate', 'legacy-workspace-gate.py')
    context = gate.inspection.normalized_context(context)
    if args.operation in ('plan', 'stage'):
        report = None
        if args.operation == 'stage':
            if not args.report or not args.approved_sha256:
                raise ValueError('stage requires the reviewed report and explicit approved SHA256')
            report = json.loads(Path(args.report).read_text())
            if gate.planner.history._digest(report) != args.approved_sha256:
                raise ValueError('reviewed report hash differs from explicit authorization')
            aliases = [row['alias'] for row in report['repositories']]
        else:
            aliases = args.repository
        if not aliases or len(set(aliases)) != len(aliases):
            raise ValueError('explicit unique approved repository aliases required')
        repositories = {}
        for alias in aliases:
            repository = policy['repositories'].get(alias)
            if repository is None or args.owner_uid not in repository['owners']:
                raise ValueError('repository alias is not approved for this owner')
            repositories[alias] = {'path': repository['path']}
        current = gate.owner_report({'repositories': repositories}, context)
        if args.operation == 'plan':
            return current
        if current != report:
            raise ValueError('current owner inventory differs from the approved report')
        if current.get('errors') or any(row.get('blockers') or not row.get('inventory_complete') for row in current['repositories']):
            raise ValueError('incomplete or active inventory cannot be gated')
        # No privileged directory is created until the approved report has been
        # regenerated under the exact owner and installed repository policy.
        private = runtime.protected_path(policy['private_root'], regular=False)
        vault = private / 'legacy-gates'
        if vault.is_symlink():
            raise ValueError('legacy vault may not be a symlink')
        vault.mkdir(mode=0o700, exist_ok=True)
        store = gate.LegacyGate(vault, inspection_context=context)
        return store.stage(report, approved_sha256=args.approved_sha256)
    if not args.gate_id:
        raise ValueError('existing gate UUID required')
    private = runtime.protected_path(policy['private_root'], regular=False)
    store = gate.LegacyGate(private / 'legacy-gates', inspection_context=context)
    if args.operation == 'restore':
        if not args.approved_sha256:
            raise ValueError('restore requires explicit approved gate SHA256')
        return store.restore(args.gate_id, approved_sha256=args.approved_sha256)
    if args.operation in ('branches', 'publish-branches', 'replay-branches'):
        if args.operation == 'replay-branches':
            if not args.approved_selection_sha256:
                raise ValueError('explicit matching branch selection approval required')
            mutation = load('legacy_admin_mutation', 'legacy-workspace-mutation.py')
            return mutation.replay(store, args.gate_id, approved_selection_sha256=args.approved_selection_sha256)
        if not args.approved_sha256:
            raise ValueError('explicit gate plan SHA256 required')
        with store.frozen_view(args.gate_id, approved_sha256=args.approved_sha256):
            pass  # Validate the closed gate before reserving private scratch.
        scratch = private / 'legacy-scratch'
        if scratch.is_symlink():
            raise ValueError('legacy scratch must not be a symlink')
        scratch.mkdir(mode=0o700, exist_ok=True)
        if args.operation == 'branches':
            if len(args.repository) != 1:
                raise ValueError('one repository alias required for branch observation')
            shadow = load('legacy_admin_shadow', 'terminal-branch-shadow.py')
            return shadow.observe(store, args.gate_id, approved_gate_sha256=args.approved_sha256,
                                  repo_alias=args.repository[0], scratch_root=scratch)
        if not args.report or not args.approved_selection_sha256:
            raise ValueError('reviewed branch selection and its explicit SHA256 required')
        with Path(args.report).open('rb') as stream:
            raw = stream.read(128 * 1024 + 1)
        if len(raw) > 128 * 1024:
            raise ValueError('branch selection exceeds bounded input size')
        selection = json.loads(raw)
        if selection.get('gate_id') != args.gate_id or selection.get('gate_sha256') != args.approved_sha256:
            raise ValueError('branch selection targets a different gate')
        mutation = load('legacy_admin_mutation', 'legacy-workspace-mutation.py')
        return mutation.publish(store, selection, approved_selection_sha256=args.approved_selection_sha256,
                                scratch_root=scratch)
    return getattr(store, args.operation)(args.gate_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan','stage','inspect','resume','restore','branches','publish-branches','replay-branches'))
    parser.add_argument('--owner-uid', type=int, required=True)
    parser.add_argument('--transactions', required=True)
    parser.add_argument('--ledger', required=True)
    parser.add_argument('--repository', action='append', default=[])
    parser.add_argument('--report')
    parser.add_argument('--approved-sha256')
    parser.add_argument('--approved-selection-sha256')
    parser.add_argument('--gate-id')
    args = parser.parse_args()
    print(json.dumps(run(args), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
