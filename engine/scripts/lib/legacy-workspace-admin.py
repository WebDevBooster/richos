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
import stat
import uuid
import sys


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def persist_attestation(runtime, private_root, document):
    private = runtime.protected_path(private_root, regular=False)
    directory = private / 'legacy-authorizations'
    if os.path.lexists(directory):
        runtime.protected_path(directory, regular=False)
        info = directory.lstat()
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('dedicated protected authorization directory required')
    else:
        directory.mkdir(mode=0o700)
        fd = os.open(private, os.O_RDONLY | os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    path = directory / (str(uuid.uuid4()) + '.json')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(document, stream, sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)
    return path


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
    descriptor_path = getattr(args, 'operator_attestation', None)
    descriptor_hash = getattr(args, 'operator_attestation_sha256', None)
    if descriptor_path or descriptor_hash:
        if not descriptor_path or not descriptor_hash or args.operation == 'attest-maintenance':
            raise ValueError('matching operator attestation path/hash required; no nested attestation')
        context['operator_attestation'] = {'path': descriptor_path, 'sha256': descriptor_hash}
    context = gate.inspection.normalized_context(context)
    if args.operation in ('plan', 'stage', 'attest-maintenance'):
        report = None
        if args.operation in ('stage', 'attest-maintenance'):
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
        if args.operation == 'attest-maintenance':
            if not getattr(args, 'decisions', None) or not getattr(args, 'authorization', None):
                raise ValueError('explicit complete remove/retain decisions and operator authorization text required')
            with Path(args.decisions).open('rb') as stream: raw = stream.read(1024*1024+1)
            if len(raw) > 1024*1024:
                raise ValueError('operator decision input exceeds byte limit')
            operator = load('legacy_admin_operator', 'legacy-workspace-operator.py')
            document = operator.build_attestation(current, json.loads(raw), args.authorization)
            transformed = operator.validate_and_apply(current, document)
            if transformed.get('errors') or any(row.get('blockers') or not row.get('inventory_complete') for row in transformed['repositories']):
                raise ValueError('operator downtime does not override active or incomplete inventory')
            path = persist_attestation(runtime, policy['private_root'], document)
            descriptor = {'path': str(path), 'sha256': gate.planner.history._digest(document)}
            context['operator_attestation'] = descriptor
            return {'operator_attestation': descriptor, 'report': gate.owner_report({'repositories': repositories}, context),
                    'staged': False, 'activated': False}
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
    if args.operation in ('arm-job','job-status','advance-job'):
        job = load('legacy_admin_job','legacy-workspace-job.py')
        if args.operation == 'job-status':
            # state.json is atomically replaced and its owner context is
            # immutable. A read-only status request must not wait for capture.
            base=runtime.protected_path(store._base(args.gate_id),regular=False)
            store._load(base)
            return job.status(store,args.gate_id)
        # Validate the recorded owner context without demanding a frozen view:
        # an armed job must be able to replay an incomplete primitive journal.
        with store._lock(args.gate_id) as base:
            store._load(base)
        selection=None
        if args.operation == 'arm-job':
            if not args.report or not args.approved_sha256 or not args.approved_selection_sha256:
                raise ValueError('arming requires approved gate and exact job selection hashes')
            with Path(args.report).open('rb') as stream:raw=stream.read(256*1024+1)
            if len(raw)>256*1024:raise ValueError('job selection exceeds bounded input size')
            selection=json.loads(raw)
            if selection.get('gate_id')!=args.gate_id or selection.get('gate_sha256')!=args.approved_sha256:
                raise ValueError('job selection targets a different gate')
            job._scope(selection,args.approved_selection_sha256)
        scratch=base/'job-scratch'
        if scratch.is_symlink():raise ValueError('legacy job scratch must not be a symlink')
        scratch.mkdir(mode=0o700,exist_ok=True)
        if args.operation == 'arm-job':
            return job.arm(store,selection,approved_selection_sha256=args.approved_selection_sha256,scratch_root=scratch)
        return job.advance(store,args.gate_id,scratch_root=scratch)
    if args.operation == 'restore':
        if not args.approved_sha256:
            raise ValueError('restore requires explicit approved gate SHA256')
        return store.restore(args.gate_id, approved_sha256=args.approved_sha256)
    if args.operation in ('branches', 'publish-branches', 'replay-branches', 'capture', 'publish-recovery', 'retire', 'replay-retirement'):
        if args.operation in ('replay-branches', 'replay-retirement'):
            if not args.approved_selection_sha256:
                raise ValueError('explicit matching branch selection approval required')
            if args.operation == 'replay-retirement':
                scratch = private / 'legacy-scratch'
                if scratch.is_symlink(): raise ValueError('legacy scratch must not be a symlink')
                scratch.mkdir(mode=0o700, exist_ok=True)
                retirement = load('legacy_admin_retirement', 'legacy-workspace-retirement.py')
                return retirement.replay(store, args.gate_id, approved_selection_sha256=args.approved_selection_sha256,
                                         scratch_root=scratch)
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
        if args.operation == 'capture':
            if len(args.repository) != 1 or not args.candidate_path:
                raise ValueError('capture requires one repository alias and exact candidate path')
            capture = load('legacy_admin_capture', 'legacy-workspace-capture.py')
            return capture.prepare(store, args.gate_id, approved_gate_sha256=args.approved_sha256,
                                   repo_alias=args.repository[0], candidate_path=args.candidate_path, scratch_root=scratch)
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
        if args.operation == 'retire':
            retirement = load('legacy_admin_retirement', 'legacy-workspace-retirement.py')
            return retirement.retire(store, selection, approved_selection_sha256=args.approved_selection_sha256,
                                     scratch_root=scratch)
        mutation = load('legacy_admin_mutation', 'legacy-workspace-mutation.py')
        publish = mutation.publish_recovery if args.operation == 'publish-recovery' else mutation.publish
        return publish(store, selection, approved_selection_sha256=args.approved_selection_sha256,scratch_root=scratch)
    return getattr(store, args.operation)(args.gate_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan','stage','attest-maintenance','inspect','resume','restore','branches','publish-branches','replay-branches',
                                             'capture','publish-recovery','retire','replay-retirement','arm-job','job-status','advance-job'))
    parser.add_argument('--owner-uid', type=int, required=True)
    parser.add_argument('--transactions', required=True)
    parser.add_argument('--ledger', required=True)
    parser.add_argument('--repository', action='append', default=[])
    parser.add_argument('--report')
    parser.add_argument('--approved-sha256')
    parser.add_argument('--approved-selection-sha256')
    parser.add_argument('--gate-id')
    parser.add_argument('--candidate-path')
    parser.add_argument('--operator-attestation')
    parser.add_argument('--operator-attestation-sha256')
    parser.add_argument('--decisions')
    parser.add_argument('--authorization')
    args = parser.parse_args()
    print(json.dumps(run(args), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
