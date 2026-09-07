#!/usr/bin/env python3
"""Journaled publication of a trusted frozen branch shadow.

Only this module creates mutation.json. Its presence blocks gate restoration
until replay has verified the complete resulting ref snapshot and refreshed the
gate's inode inventory. No repository object or working file is deleted here.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('branch_shadow', Path(__file__).with_name('terminal-branch-shadow.py'))
shadow = importlib.util.module_from_spec(spec); spec.loader.exec_module(shadow)


class MutationError(RuntimeError):
    pass


def _sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def _atomic(path, data, *, staging_directory=None):
    # Held Git namespaces can contain arbitrary valid ref names, including
    # '*.next'. Stage replacements outside held content, never at a predictable
    # sibling name. Exclusively created leftovers remain in private recovery.
    fd, name = tempfile.mkstemp(prefix='.publication-', dir=staging_directory or path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp, path)
        _sync(path.parent)
        if tmp.parent != path.parent: _sync(tmp.parent)
    finally:
        if tmp.exists(): tmp.unlink()


def _save(path, value):
    _atomic(path, (json.dumps(value, sort_keys=True) + '\n').encode())


def _manifest(path):
    if not os.path.lexists(path):
        return None
    data = shadow._bytes(path, shadow.MAX_METADATA_BYTES)
    return {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def _relative(name):
    path = Path(name)
    if path.is_absolute() or not path.parts or any(p in ('.', '..') for p in path.parts) or path.as_posix() != name:
        raise MutationError('noncanonical mutation path')
    return path


def _view(gate, base, record):
    report = json.loads((base / 'plan.json').read_text())
    if shadow.digest(report) != record['approved_sha256']:
        raise MutationError('gate plan identity changed')
    previous = record.get('gated_boot_id')
    if record.get('phase') != 'gated' or not isinstance(previous, str) or str(uuid.UUID(previous)) != previous or gate._boot() == previous:
        raise MutationError('verified later-boot closed gate required')
    return {'plan': report, 'roots': [dict(row, held_path=str(base / row['held'])) for row in record['roots']]}


def _archive_completed(gate, base):
    """Durably retain prior payloads before starting another repo selection."""
    marker = base / 'mutation.json'
    journal = json.loads(marker.read_text())
    if journal.get('phase') != 'complete':
        raise MutationError('incomplete mutation requires replay')
    history = base / 'mutation-history'; history.mkdir(mode=0o700, exist_ok=True); _sync(base)
    if 'archive_id' not in journal:
        journal['archive_id'] = str(uuid.uuid4())
        _save(marker, journal)
    ident = journal['archive_id']
    if str(uuid.UUID(ident)) != ident: raise MutationError('invalid archived mutation identity')
    destination = history / ident; destination.mkdir(mode=0o700, exist_ok=True); _sync(history)
    source = base / 'mutation-data'
    if source.exists():
        if (destination / 'data').exists(): raise MutationError('duplicate mutation recovery payload')
        os.rename(source, destination / 'data'); _sync(destination); _sync(base)
    elif not (destination / 'data').is_dir():
        raise MutationError('prior mutation recovery data unavailable')
    _save(destination / 'receipt.json', journal)
    marker.unlink(); _sync(base)


def publish(gate, selection, *, approved_selection_sha256, scratch_root, trusted_git=shadow.TRUSTED_GIT):
    """Prepare internally, revalidate under the gate lock then publish/replay."""
    artifact = shadow.prepare(gate, selection, approved_selection_sha256=approved_selection_sha256,
                              scratch_root=scratch_root, trusted_git=trusted_git)
    prepared = Path(artifact['artifact_path'])
    try:
        ident = selection['gate_id']
        with gate._lock(ident) as base:
            record = gate._load(base)
            if record['approved_sha256'] != selection['gate_sha256']:
                raise MutationError('different gate approval')
            view = _view(gate, base, record)
            gate._verify_held(base, record, gate._entries(base))
            common = shadow._resolve(view, selection['repo_alias'])
            if (shadow.digest(shadow._file_manifest(shadow._metadata(common))) != selection['ref_snapshot_sha256']
                    or shadow.digest(shadow._registry(common)) != selection['registry_sha256']):
                raise MutationError('frozen branch evidence changed')
            if (base / 'mutation.json').exists():
                _archive_completed(gate, base)
            directory = base / 'mutation-data'
            if directory.exists():
                # The frozen snapshot was just revalidated and there is no
                # intent marker, so held refs were never changed by this
                # preparation. Preserve incomplete payloads and retry.
                if directory.is_symlink() or not directory.is_dir():
                    raise MutationError('invalid orphaned mutation storage')
                history = base / 'preparation-history'
                history.mkdir(mode=0o700, exist_ok=True); _sync(base)
                os.rename(directory, history / str(uuid.uuid4()))
                _sync(history); _sync(base)
            directory.mkdir(mode=0o700)
            # Private staged data is complete and durable before the intent
            # marker. A crash before that marker never modifies held storage.
            for side in ('before', 'after'):
                for change in artifact['changes']:
                    if change[side] is None:
                        continue
                    relative = _relative(change['path'])
                    source = prepared / side / relative
                    if _manifest(source) != change[side]:
                        raise MutationError('prepared payload changed')
                    target = directory / side / relative
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    _atomic(target, source.read_bytes())
            _atomic(directory / 'original-metadata.jsonl', (base / 'metadata.jsonl').read_bytes())
            for current, dirs, files in os.walk(directory, topdown=False):
                _sync(Path(current))
            _sync(base)
            journal = {'version': 1, 'phase': 'applying', 'gate_id': ident,
                       'artifact': {k:v for k,v in artifact.items() if k != 'artifact_path'},
                       'common_relative': common.relative_to(base).as_posix(), 'created_directories': {}}
            _save(base / 'mutation.json', journal)
            return _replay_locked(gate, base, record, journal)
    finally:
        shutil.rmtree(prepared)


def replay(gate, ident, *, approved_selection_sha256):
    with gate._lock(ident) as base:
        record = gate._load(base)
        journal = json.loads((base / 'mutation.json').read_text())
        if journal['artifact']['approved_selection_sha256'] != approved_selection_sha256:
            raise MutationError('matching branch mutation approval required')
        return _replay_locked(gate, base, record, journal)


def _replay_locked(gate, base, record, journal):
    view = _view(gate, base, record)
    artifact = journal['artifact']; selection = artifact['selection']
    if journal.get('version') != 1 or journal.get('gate_id') != base.name or shadow.digest(selection) != artifact['approved_selection_sha256']:
        raise MutationError('invalid branch mutation journal')
    if selection['gate_sha256'] != record['approved_sha256']:
        raise MutationError('mutation belongs to a different gate plan')
    common = shadow._resolve(view, selection['repo_alias'])
    if common.relative_to(base).as_posix() != journal['common_relative']:
        raise MutationError('frozen common directory mapping changed')
    if shadow.digest(shadow._registry(common)) != selection['registry_sha256']:
        raise MutationError('worktree attachment inventory changed')
    if journal['phase'] == 'complete':
        gate._verify_held(base, record, gate._entries(base))
        if shadow.digest(shadow._file_manifest(shadow._metadata(common))) != artifact['expected_ref_snapshot_sha256']:
            raise MutationError('completed mutation snapshot changed')
        return {'gate_id': base.name, 'phase': 'complete', 'retired_branches': artifact['retired_branches'],
                'held_storage_modified': True, 'working_directories_deleted': False}
    original = {}
    for line in (base / 'mutation-data/original-metadata.jsonl').read_bytes().splitlines():
        row = json.loads(line)
        if row['relative'] in original:
            raise MutationError('duplicate original metadata entry')
        original[row['relative']] = row
    baseline = original[common.relative_to(base).as_posix()]
    changes = artifact['changes']
    # Validate every payload and affected current file before the first write.
    for change in changes:
        relative = _relative(change['path']); target = common / relative
        if _manifest(target) not in (change['before'], change['after']):
            raise MutationError('unexpected ref contents during replay')
        for side in ('before', 'after'):
            if change[side] is not None and _manifest(base / 'mutation-data' / side / relative) != change[side]:
                raise MutationError('private ref recovery payload changed')
    # A partial prior write may legitimately change these specific inodes.
    # Every unrelated object must still match the original frozen inventory
    # before replay performs any further mutation.
    transient = dict(original)
    for key, metadata in journal['created_directories'].items():
        if os.path.lexists(base / key):
            transient[key] = dict(gate._metadata(base / key), **metadata, relative=key)
    for change in changes:
        target = common / _relative(change['path']); key = target.relative_to(base).as_posix()
        if _manifest(target) == change['after']:
            if change['after'] is None: transient.pop(key, None)
            else: transient[key] = dict(gate._metadata(target), relative=key)
    gate._verify_held(base, record, transient)
    for change in changes:
        relative = _relative(change['path']); target = common / relative
        if _manifest(target) == change['after']:
            continue
        parents = []
        parent = target.parent
        while parent != common:
            parents.append(parent); parent = parent.parent
        for parent in reversed(parents):
            key = parent.relative_to(base).as_posix()
            if key not in original and key not in journal['created_directories']:
                # Record intended ownership before mkdir, so a crash after
                # mkdir can recognize and finish that exact private path.
                journal['created_directories'][key] = {'uid': baseline['uid'], 'gid': baseline['gid'], 'mode': 0o755}
                _save(base / 'mutation.json', journal)
            if not parent.exists():
                parent.mkdir(mode=0o700); gate._sync(parent.parent)
            info = parent.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != gate.uid or stat.S_IMODE(info.st_mode) != 0o700:
                raise MutationError('ref parent is not protected')
        if change['after'] is None:
            target.unlink(); gate._sync(target.parent)
        else:
            _atomic(target, (base / 'mutation-data/after' / relative).read_bytes(), staging_directory=base / 'mutation-data')
    if shadow.digest(shadow._file_manifest(shadow._metadata(common))) != artifact['expected_ref_snapshot_sha256']:
        raise MutationError('published ref snapshot does not match approved result')
    effective = dict(original)
    for key, metadata in journal['created_directories'].items():
        effective[key] = dict(gate._metadata(base / key), **metadata, relative=key)
    for change in changes:
        target = common / _relative(change['path']); key = target.relative_to(base).as_posix()
        if change['after'] is None:
            effective.pop(key, None)
        else:
            ownership = {name: original.get(key, dict(baseline, mode=0o644))[name] for name in ('uid','gid','mode')}
            effective[key] = dict(gate._metadata(target), **ownership, relative=key)
    gate._verify_held(base, record, effective)
    _atomic(base / 'metadata.jsonl', b''.join((json.dumps(row,sort_keys=True)+'\n').encode() for _,row in sorted(effective.items())))
    journal['phase'] = 'complete'
    _save(base / 'mutation.json', journal)
    return {'gate_id': base.name, 'phase': 'complete', 'retired_branches': artifact['retired_branches'],
            'held_storage_modified': True, 'working_directories_deleted': False}
