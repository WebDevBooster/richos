#!/usr/bin/env python3
"""Lossless recovery of unpublished provider storage. No raw archive expiry.

The caller holds the permanent request lock. This module takes the provider
lock and only accepts the matching durable request plus explicit cancellation
or a verified new boot. It never mounts an image or touches a published workspace.
"""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import uuid


class RecoveryError(RuntimeError):
    pass


def _uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _json(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RecoveryError('recovery record is not a private regular manager file')
    with path.open(encoding='utf-8') as stream:
        result = json.load(stream)
    if not isinstance(result, dict):
        raise RecoveryError('invalid recovery record')
    return result


def _save(provider, path, record):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with temporary.open('x', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(record, stream, sort_keys=True)
        stream.flush();os.fsync(stream.fileno())
    os.replace(temporary, path)
    provider._sync_dir(path.parent)


def _identity(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RecoveryError('private recovery asset type, owner or permissions changed')
    if not directory and info.st_nlink != 1:
        raise RecoveryError('recovery file has external hardlinks')
    return [info.st_dev, info.st_ino]


def _hash(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise RecoveryError('regular recovery file required')
        result = hashlib.sha256()
        while True:
            data = os.read(fd, 1024 * 1024)
            if not data:
                break
            result.update(data)
        after = os.fstat(fd)
        stamp = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if stamp(before) != stamp(after) or stamp(after) != stamp(path.lstat()):
            raise RecoveryError('recovery bytes changed while reading')
        return result.hexdigest()
    finally:
        os.close(fd)


def _xattrs(path):
    """Preserve binary outer attributes using the native macOS ABI when needed."""
    if sys.platform != 'darwin':
        return {name: base64.b64encode(os.getxattr(path, name, follow_symlinks=False)).decode('ascii')
                for name in sorted(os.listxattr(path, follow_symlinks=False))}
    library = ctypes.CDLL(None, use_errno=True)
    listing = library.listxattr
    listing.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    listing.restype = ctypes.c_ssize_t
    getter = library.getxattr
    getter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    getter.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    size = listing(encoded, None, 0, 1)  # XATTR_NOFOLLOW
    if size < 0:
        raise OSError(ctypes.get_errno(), 'extended attribute inventory unavailable')
    buffer = ctypes.create_string_buffer(size)
    if listing(encoded, buffer, size, 1) != size:
        raise RecoveryError('extended attribute inventory changed')
    raw = buffer.raw[:size]
    if raw and not raw.endswith(b'\0'):
        raise RecoveryError('incomplete extended attribute inventory')
    result = {}
    for name in raw[:-1].split(b'\0') if raw else []:
        if not name or os.fsdecode(name) in result:
            raise RecoveryError('invalid extended attribute identity')
        length = getter(encoded, name, None, 0, 0, 1)
        if length < 0:
            raise OSError(ctypes.get_errno(), 'extended attribute bytes unavailable')
        value = ctypes.create_string_buffer(length)
        if getter(encoded, name, value, length, 0, 1) != length:
            raise RecoveryError('extended attribute bytes changed')
        result[os.fsdecode(name)] = base64.b64encode(value.raw[:length]).decode('ascii')
    return dict(sorted(result.items()))


def _tree(image):
    """Pin raw bundle entries without following links or crossing devices."""
    root = _identity(image, True)
    rows = []
    def visit(path):
        info = path.lstat()
        if info.st_dev != root[0] or info.st_uid != os.geteuid():
            raise RecoveryError('raw image contains an external filesystem or owner')
        if stat.S_ISDIR(info.st_mode):
            kind = 'directory'
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            kind = 'file'
        else:
            raise RecoveryError('raw image contains unsupported links or special files')
        relative = path.relative_to(image).as_posix()
        row = dict(path=relative, kind=kind, device=info.st_dev, inode=info.st_ino,
                   mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid,
                   mtime_ns=info.st_mtime_ns,
                   xattrs=_xattrs(path))
        if kind == 'file':
            row.update(size=info.st_size, sha256=_hash(path))
        rows.append(row)
        if kind == 'directory':
            for child in sorted(path.iterdir()):
                visit(child)
    visit(image)
    return rows


def _capture(image, candidate, manifest):
    with candidate.open('xb') as output:
        os.chmod(candidate, 0o600)
        with tarfile.open(fileobj=output, mode='w:gz', format=tarfile.PAX_FORMAT) as archive:
            for row in manifest:
                name = 'image.sparsebundle' + ('' if row['path'] == '.' else '/' + row['path'])
                entry = tarfile.TarInfo(name)
                entry.mode, entry.uid, entry.gid = row['mode'], row['uid'], row['gid']
                entry.mtime = row['mtime_ns'] // 1_000_000_000
                entry.pax_headers = {'RICHOS.mtime_ns': str(row['mtime_ns']),
                                     'RICHOS.xattrs': json.dumps(row['xattrs'], sort_keys=True)}
                if row['kind'] == 'directory':
                    entry.type = tarfile.DIRTYPE
                    archive.addfile(entry)
                else:
                    entry.size = row['size']
                    fd = os.open(image / row['path'], os.O_RDONLY | os.O_NOFOLLOW)
                    with os.fdopen(fd, 'rb') as content:
                        archive.addfile(entry, content)
        output.flush();os.fsync(output.fileno())


def _verify_archive(archive, manifest):
    expected = {'image.sparsebundle' + ('' if row['path'] == '.' else '/' + row['path']): row for row in manifest}
    seen = set()
    with tarfile.open(archive, 'r:gz') as captured:
        for entry in captured:
            row = expected.get(entry.name)
            if row is None or entry.name in seen:
                raise RecoveryError('raw archive contains unexpected or duplicate entries')
            seen.add(entry.name)
            if (entry.mode, entry.uid, entry.gid, entry.pax_headers.get('RICHOS.mtime_ns')) != (
                    row['mode'], row['uid'], row['gid'], str(row['mtime_ns'])):
                raise RecoveryError('raw archive metadata mismatch')
            if entry.pax_headers.get('RICHOS.xattrs') != json.dumps(row['xattrs'], sort_keys=True):
                raise RecoveryError('raw archive extended attributes mismatch')
            if row['kind'] == 'directory':
                if not entry.isdir():
                    raise RecoveryError('raw archive directory mismatch')
            else:
                if not entry.isfile() or entry.size != row['size']:
                    raise RecoveryError('raw archive file mismatch')
                digest = hashlib.sha256()
                with captured.extractfile(entry) as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
                if digest.hexdigest() != row['sha256']:
                    raise RecoveryError('raw archive bytes mismatch')
    if seen != set(expected):
        raise RecoveryError('raw archive is incomplete')


def _absent(provider, image):
    if provider._attached(image):
        raise RecoveryError('unpublished image is still attached')


def _publish_empty_directory(provider, source, destination):
    """Atomically publish a complete reservation without replacing any path."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        rename = library.renameatx_np
        flags = 0x00000004  # RENAME_EXCL, <sys/stdio.h>
    elif sys.platform.startswith('linux'):
        rename = library.renameat2
        flags = 1  # RENAME_NOREPLACE
    else:
        raise RecoveryError('exclusive empty reservation publication unavailable')
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    fd = os.open(provider.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if rename(fd, os.fsencode(source.name), fd, os.fsencode(destination.name), flags) != 0:
            raise OSError(ctypes.get_errno(), 'exclusive empty reservation publication failed')
        os.fsync(fd)
    finally:
        os.close(fd)


def recover_failed_creation(provider, request, *, authorization):
    """Return a request-shaped status; preserve bytes on every uncertain path.

    authorization is exactly {kind:'owner-cancel',session_id:<exact session>} or
    {kind:'new-boot'}. The broker authenticates the owner; the provider supplies
    the actual boot and attachment evidence. Call only under its request lock.
    """
    ident = request.get('id') if isinstance(request, dict) else None
    if not _uuid(ident):
        raise RecoveryError('canonical request UUID required')
    key = request.get('request_key')
    uid, token = request.get('owner_uid'), request.get('request_id')
    if type(uid) is not int or uid <= 0 or not isinstance(token, str) or not 1 <= len(token) <= 128:
        raise RecoveryError('complete permanent creation request required')
    expected_key = hashlib.sha256((str(uid) + '\0' + token).encode()).hexdigest()
    if key != expected_key or _json(provider.root / (key + '.request.json')) != request:
        raise RecoveryError('creation request is not the exact durable owner request')
    if authorization not in ({'kind': 'owner-cancel', 'session_id': request.get('session_id')}, {'kind': 'new-boot'}):
        raise RecoveryError('exact cancellation or new-boot authorization required')
    if not isinstance(request.get('session_id'), str) or not request['session_id']:
        raise RecoveryError('exact request session required')
    base, image, *_ = provider._paths(ident)
    if not os.path.lexists(base):
        if authorization['kind'] != 'owner-cancel':
            return dict(request, state='creation-blocked', last_error='provider reservation has no prior boot evidence')
        temporary = provider.root / ('.failed-empty-' + uuid.uuid4().hex)
        try:
            current_boot = provider._boot_id()
            if not _uuid(current_boot):
                raise RecoveryError('current boot identity is unavailable')
            _absent(provider, image)
            # Provider creation reserves its UUID before launching hdiutil and
            # never removes that directory. Under the caller's request lock,
            # an absent reservation cannot have an outstanding creator.
            temporary.mkdir(mode=0o700)
            state = dict(version=1, id=ident, request_key=key, owner_uid=uid,
                         session_id=request['session_id'], phase='empty', authorization=authorization,
                         cutoff={'kind':'never-reserved', 'boot_id':current_boot})
            _save(provider, temporary / 'failed-creation.json', state)
            _absent(provider, image)
            _publish_empty_directory(provider, temporary, base)
        except Exception as error:
            return dict(request, state='creation-blocked', last_error=str(error), raw_recovery_expiry=None)
        finally:
            if temporary.exists():
                # Only our unpublished receipt metadata, never image content.
                for item in temporary.iterdir():
                    if not item.is_file() or item.is_symlink():
                        raise RecoveryError('unexpected empty receipt staging asset')
                    item.unlink()
                temporary.rmdir()
    provider._check_directory(base)
    journal = base / 'failed-creation.json'
    archive = base / 'failed-creation.tar.gz'
    candidate = base / 'failed-creation.partial.tar.gz'
    with provider._locked(ident):
        if os.path.lexists(base / 'lifecycle.json'):
            raise RecoveryError('published lifecycle cannot use raw creation recovery')
        raw = _json(base / 'journal.json') if os.path.lexists(base / 'journal.json') else {}
        if raw and (raw.get('version') != 1 or raw.get('id') != ident or raw.get('owner_uid') != uid
                    or raw.get('owner_gid') != request.get('owner_gid') or raw.get('commit') != request.get('source_commit')):
            raise RecoveryError('provider journal differs from exact creation request')
        if raw.get('initialized'):
            raise RecoveryError('initialized workspace needs normal terminal recovery')
        state = _json(journal) if os.path.lexists(journal) else dict(version=1, id=ident, request_key=key,
            owner_uid=uid, session_id=request['session_id'], phase='reserved', authorization=authorization)
        if state.get('version') != 1 or state.get('id') != ident or state.get('request_key') != key:
            raise RecoveryError('failed creation journal identity mismatch')
        if state.get('phase') not in ('reserved', 'detaching', 'detached', 'captured', 'reclaiming', 'retained', 'empty'):
            raise RecoveryError('failed creation journal phase is invalid')
        if state['phase'] in ('detached', 'captured', 'reclaiming', 'retained', 'empty'):
            cutoff = state.get('cutoff')
            if not isinstance(cutoff, dict) or cutoff.get('kind') not in ('normal-detach', 'new-boot', 'provider-detached', 'never-reserved') or not _uuid(cutoff.get('boot_id')):
                raise RecoveryError('failed creation journal lacks a valid cutoff receipt')
        # A speculative sweeper check cannot become cancellation intent.
        # Reject absent, malformed or unchanged boot evidence without writing.
        if authorization['kind'] == 'new-boot':
            try:
                observed_boot = provider._boot_id()
                if not _uuid(observed_boot) or not _uuid(raw.get('boot_id')) or raw['boot_id'] == observed_boot:
                    raise RecoveryError('different verified boot required')
            except Exception as error:
                return dict(request, state='creation-blocked', last_error=str(error), raw_recovery_expiry=None)
        try:
            current_boot = observed_boot if authorization['kind'] == 'new-boot' else provider._boot_id()
            if not _uuid(current_boot):
                raise RecoveryError('current boot identity is unavailable')
            previous = raw.get('boot_id')
            changed_boot = _uuid(previous) and previous != current_boot
            # Publish cancellation intent before any cutoff/capture work. Even
            # blocked recovery permanently vetoes reactivation of this UUID.
            _save(provider, journal, state)
            if state['phase'] not in ('detached', 'captured', 'reclaiming', 'retained', 'empty'):
                attached = provider._attached(image)
                if attached:
                    device = provider._device(attached)
                    if raw.get('device') and raw['device'] != device:
                        raise RecoveryError('unpublished image device changed')
                    state.update(phase='detaching', cutoff=None)
                    _save(provider, journal, state)
                    provider._run(['/usr/bin/hdiutil', 'detach', device])
                    _absent(provider, image)
                    cutoff = {'kind': 'normal-detach', 'boot_id': current_boot}
                elif changed_boot:
                    cutoff = {'kind': 'new-boot', 'boot_id': current_boot, 'previous_boot_id': previous}
                elif state['phase'] != 'detaching' and raw.get('state') == 'detached' and raw.get('operation') is None:
                    cutoff = {'kind': 'provider-detached', 'boot_id': current_boot}
                else:
                    raise RecoveryError('interrupted creation lacks a verified write cutoff')
                state.update(phase='detached', cutoff=cutoff)
                _save(provider, journal, state)
            _absent(provider, image)
            if state['phase'] == 'empty':
                if os.path.lexists(image):
                    raise RecoveryError('image appeared after empty reservation recovery')
            elif state['phase'] == 'detached':
                if not os.path.lexists(image):
                    state.update(phase='empty')
                    _save(provider, journal, state)
                else:
                    identity = _identity(image, True)
                    if raw.get('image_identity') and raw['image_identity'] != identity:
                        raise RecoveryError('unpublished image identity changed')
                    if state.get('image_identity') and state['image_identity'] != identity:
                        raise RecoveryError('raw recovery image identity changed')
                    state['image_identity'] = identity
                    _save(provider, journal, state)
                    if os.path.lexists(candidate):
                        _identity(candidate);candidate.unlink();provider._sync_dir(base)
                    if os.path.lexists(archive):
                        raise RecoveryError('unexpected completed raw archive')
                    manifest = _tree(image)
                    _capture(image, candidate, manifest)
                    _verify_archive(candidate, manifest)
                    if _tree(image) != manifest:
                        raise RecoveryError('raw image changed during capture')
                    state.update(phase='captured', manifest=manifest, archive_sha256=_hash(candidate),
                                 archive_identity=_identity(candidate))
                    _save(provider, journal, state)
            if state['phase'] == 'captured':
                if os.path.lexists(archive):
                    if os.path.lexists(candidate) or _identity(archive) != state['archive_identity']:
                        raise RecoveryError('unexpected raw archive promotion identity')
                else:
                    if _identity(candidate) != state['archive_identity'] or _hash(candidate) != state['archive_sha256']:
                        raise RecoveryError('raw archive candidate changed')
                    os.rename(candidate, archive);provider._sync_dir(base)
                if _tree(image) != state['manifest']:
                    raise RecoveryError('raw image changed before reclamation intent')
                state['phase'] = 'reclaiming'
                _save(provider, journal, state)
            if state['phase'] in ('reclaiming', 'retained'):
                if _identity(archive) != state['archive_identity'] or _hash(archive) != state['archive_sha256']:
                    raise RecoveryError('verified raw archive changed')
                _verify_archive(archive, state['manifest'])
                _absent(provider, image)
                if state['phase'] == 'reclaiming' and os.path.lexists(image):
                    if _identity(image, True) != state['image_identity']:
                        raise RecoveryError('refuse reclaiming a replacement raw image')
                    shutil.rmtree(image);provider._sync_dir(base)
                elif state['phase'] == 'retained' and os.path.lexists(image):
                    raise RecoveryError('image reappeared after raw reclamation')
                state['phase'] = 'retained'
                _save(provider, journal, state)
            state.pop('last_error', None)
            _save(provider, journal, state)
            return dict(request, state='creation-empty' if state['phase'] == 'empty' else 'creation-retained',
                        raw_recovery_archive=str(archive) if state['phase'] == 'retained' else None,
                        raw_recovery_expiry=None)
        except Exception as error:
            state['last_error'] = str(error)
            _save(provider, journal, state)
            return dict(request, state='creation-blocked', last_error=str(error), raw_recovery_expiry=None)


def inspect_failed_creation(provider, request):
    """Read durable progress without asserting mount readiness or taking locks."""
    ident = request.get('id') if isinstance(request, dict) else None
    if not _uuid(ident):
        raise RecoveryError('canonical request UUID required')
    uid, token = request.get('owner_uid'), request.get('request_id')
    if type(uid) is not int or uid <= 0 or not isinstance(token, str) or not 1 <= len(token) <= 128:
        raise RecoveryError('complete permanent creation request required')
    key = hashlib.sha256((str(uid) + '\0' + token).encode()).hexdigest()
    if key != request.get('request_key') or _json(provider.root / (key + '.request.json')) != request:
        raise RecoveryError('creation request is not the exact durable owner request')
    base, *_ = provider._paths(ident)
    provider._check_directory(base)
    path = base / 'failed-creation.json'
    if not os.path.lexists(path):
        return dict(request, state='creation-incomplete')
    record = _json(path)
    if record.get('version') != 1 or record.get('id') != ident or record.get('request_key') != key:
        raise RecoveryError('failed creation journal identity mismatch')
    phase = record.get('phase')
    states = {'reserved':'creation-blocked', 'detaching':'creation-blocked', 'detached':'creation-blocked',
              'captured':'creation-reclaiming', 'reclaiming':'creation-reclaiming',
              'retained':'creation-retained', 'empty':'creation-empty'}
    if phase not in states:
        raise RecoveryError('failed creation journal phase is invalid')
    return dict(request, state='creation-blocked' if record.get('last_error') else states[phase],
                last_error=record.get('last_error'), raw_recovery_expiry=None,
                raw_recovery_archive=str(base / 'failed-creation.tar.gz') if phase == 'retained' else None)
