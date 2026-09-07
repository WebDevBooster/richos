#!/usr/bin/env python3
"""Prepare additive object recovery refs from a revalidated frozen capture.

No held writes or object copies. Publication and registration removal remain
separate operations with their own durable journals and approvals.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


shadow = _load('recovery_shadow', 'terminal-branch-shadow.py')
capture = _load('recovery_capture', 'legacy-workspace-capture.py')
MAX_OBJECTS = 100000


class RecoveryError(RuntimeError):
    pass


def _capture_authority(path, gate):
    raw = Path(path)
    if not raw.is_absolute() or str(raw) != path or raw.resolve(strict=True) != raw:
        raise RecoveryError('canonical non-symlink capture path required')
    directory = shadow._private_directory(raw, gate)
    for name in ('receipt.json', 'manifest.json', 'recovery.tar.gz'):
        item = directory / name; info = item.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.geteuid() or info.st_mode & 0o022):
            raise RecoveryError('capture files are not protected independent regular files')
        if gate.require_root:
            gate._no_acl(item)
    return directory


def _selection(value, approved):
    required = {'version', 'gate_id', 'gate_sha256', 'repo_alias', 'ref_snapshot_sha256',
                'registry_sha256', 'capture_path', 'capture_receipt_sha256', 'approval_kind'}
    if not isinstance(value, dict) or set(value) != required or value['version'] != 1:
        raise RecoveryError('complete captured recovery selection required')
    for name in required - {'version'}:
        limit = 4096 if name == 'capture_path' else 128
        if not isinstance(value[name], str) or not 1 <= len(value[name]) <= limit:
            raise RecoveryError('bounded scalar recovery selection required')
    if len(json.dumps(value, sort_keys=True).encode()) > 8192:
        raise RecoveryError('recovery selection exceeds byte limit')
    if value['approval_kind'] != 'exact-captured-recovery' or shadow.digest(value) != approved:
        raise RecoveryError('exact captured recovery approval required')


def _closure(binary, directory, objects, oids):
    # Consume Git traversal without collecting the potentially large closure in
    # memory. Every selected endpoint and every reachable commit/tree/blob must
    # exist. The controlled metadata shadow has no source config or alternates.
    env = {'PATH': '/usr/bin:/bin', 'HOME': '/var/empty', 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_SYSTEM': '/dev/null',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_NO_REPLACE_OBJECTS': '1',
           'GIT_TERMINAL_PROMPT': '0', 'GIT_OBJECT_DIRECTORY': str(objects),
           'GIT_EXEC_PATH': str(Path(binary).parent)}
    result = subprocess.run([binary, '--no-replace-objects', '--git-dir', str(directory),
        '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never',
        'rev-list', '--objects', '--no-object-names', '--missing=error', '--stdin'],
        cwd=directory, env=env, input=('\n'.join(oids) + '\n').encode(),
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        raise RecoveryError('incomplete captured object closure: ' + result.stderr.decode('utf-8', 'replace')[-1000:])


def prepare(gate, selection, *, approved_selection_sha256, scratch_root, trusted_git=shadow.TRUSTED_GIT):
    """Return a publisher-compatible additive ref delta, never authorize erasure."""
    _selection(selection, approved_selection_sha256)
    scratch, binary = shadow._authority(gate, scratch_root, trusted_git)
    artifact_path = _capture_authority(selection['capture_path'], gate)
    directory = Path(tempfile.mkdtemp(prefix='recovery-ref-delta-', dir=scratch))
    try:
        with gate.frozen_view(selection['gate_id'], approved_sha256=selection['gate_sha256']) as view:
            receipt = capture.validate_capture(view, artifact_path, directory, binary)
            if (shadow.digest(receipt) != selection['capture_receipt_sha256']
                    or receipt['gate_id'] != selection['gate_id']
                    or receipt['gate_sha256'] != selection['gate_sha256']
                    or receipt['repo_alias'] != selection['repo_alias']):
                raise RecoveryError('capture does not match the exact approved recovery selection')
            dependencies = receipt['dependencies']
            if (dependencies['missing_objects'] or dependencies['external_gitlinks']
                    or dependencies['unparsed_git_state']):
                raise RecoveryError('capture has unresolved or external Git dependencies')
            endpoints = dependencies['required_objects']
            if not isinstance(endpoints, list) or not 1 <= len(endpoints) <= MAX_OBJECTS:
                raise RecoveryError('bounded nonempty captured object inventory required')
            oids = [row['oid'] for row in endpoints]
            if oids != sorted(set(oids)) or any(not shadow.OID.fullmatch(oid) or set(oid) == {'0'} for oid in oids):
                raise RecoveryError('canonical complete captured object inventory required')
            common = shadow._resolve(view, selection['repo_alias']); metadata = directory / 'view.git'
            before, objects, registry, refs = shadow._shadow(common, metadata, binary)
            if (shadow.digest(shadow._file_manifest(before)) != selection['ref_snapshot_sha256']
                    or shadow.digest(registry) != selection['registry_sha256']):
                raise RecoveryError('frozen refs or attachment inventory changed since selection')
            output = shadow._git(binary, metadata, objects, 'cat-file', '--batch-check=%(objectname) %(objecttype)',
                input=('\n'.join(oids) + '\n').encode()).decode().splitlines()
            if len(output) != len(oids):
                raise RecoveryError('incomplete captured object reader')
            types = {}
            for oid, line in zip(oids, output):
                fields = line.split(' ')
                if len(fields) != 2 or fields[0] != oid or fields[1] not in ('commit', 'tree', 'blob', 'tag'):
                    raise RecoveryError('captured object is missing or unreadable')
                types[oid] = fields[1]
            _closure(binary, metadata, objects, oids)
            transaction = ['start']; expected = dict(refs); preserved = []
            for endpoint in endpoints:
                oid = endpoint['oid']
                ref = 'refs/richos/recovery/' + selection['gate_id'] + '/' + selection['capture_receipt_sha256'] + '/' + oid
                shadow._git(binary, metadata, objects, 'check-ref-format', ref)
                if ref in refs:
                    raise RecoveryError('recovery namespace already exists; replay its durable publication')
                transaction.append('create ' + ref + ' ' + oid)
                expected[ref] = {'oid': oid, 'symbolic': None}
                preserved.append(dict(oid=oid, type=types[oid], ref=ref, sources=endpoint['sources']))
            transaction += ['prepare', 'commit']
            shadow._git(binary, metadata, objects, 'update-ref', '--no-deref', '--stdin',
                input=('\n'.join(transaction) + '\n').encode())
            after = shadow._metadata(metadata)
            if shadow._logical_refs(binary, metadata, objects, after) != expected:
                raise RecoveryError('Git changed refs outside additive recovery selection')
            if shadow._metadata(common) != before or shadow._registry(common) != registry:
                raise RecoveryError('held refs changed during recovery preparation')
            allowed = {row['ref'] for row in preserved}; changes = []
            for name in sorted(set(before) | set(after)):
                if before.get(name) == after.get(name):
                    continue
                if name not in allowed or name in before or name not in after:
                    raise RecoveryError('Git changed existing or unrelated ref storage')
                output_path = directory / 'after' / name
                output_path.parent.mkdir(parents=True, exist_ok=True); output_path.write_bytes(after[name])
                changes.append(dict(path=name, before=None, after=shadow._file_manifest({name: after[name]})[name]))
            artifact = dict(version=1, mode='prepared-ref-delta-only', purpose='captured-recovery',
                gate_id=selection['gate_id'], gate_sha256=selection['gate_sha256'], repo_alias=selection['repo_alias'],
                approved_selection_sha256=approved_selection_sha256, selection=selection,
                source_ref_snapshot_sha256=selection['ref_snapshot_sha256'],
                expected_ref_snapshot_sha256=shadow.digest(shadow._file_manifest(after)),
                registry_sha256=selection['registry_sha256'], retired_branches=[], changes=changes,
                preserved_objects=preserved, capture_receipt_sha256=selection['capture_receipt_sha256'],
                transitive_closure_verified=True, execution_authorized=False, held_storage_modified=False,
                publication_implemented=False, registration_removal_authorized=False)
            shutil.rmtree(metadata)
            (directory / 'delta.json').write_text(json.dumps(artifact, sort_keys=True, indent=2) + '\n')
            return dict(artifact, artifact_path=str(directory))
    except BaseException:
        shutil.rmtree(directory)
        raise
