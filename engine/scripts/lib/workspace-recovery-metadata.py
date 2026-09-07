#!/usr/bin/env python3
"""Bounded compact recovery metadata. No source mutation or deletion authority."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat

spec = importlib.util.spec_from_file_location('metadata_attrs', Path(__file__).with_name('managed-workspace-failed-creation.py'))
attrs = importlib.util.module_from_spec(spec); spec.loader.exec_module(attrs)
MAX_BYTES = 64 * 1024 * 1024
MAX_PATHS = 100000


class MetadataError(RuntimeError):
    pass


def encode(value):
    data = (json.dumps(value, sort_keys=True) + '\n').encode()
    if len(data) > MAX_BYTES:
        raise MetadataError('compact metadata exceeds byte budget')
    return data


def _content(path, remaining):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > remaining:
        raise MetadataError('metadata file exceeds budget or is not regular')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise MetadataError('metadata file was replaced')
        data = stream.read(remaining + 1)
        after = os.fstat(stream.fileno())
    stamp = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
    if len(data) > remaining or stamp(before) != stamp(after) or stamp(after) != stamp(path.lstat()):
        raise MetadataError('metadata bytes changed or exceeded budget')
    return data


def from_capture(manifest, sources):
    """Keep full frozen manifest and every admin/pointer byte, excluding work blobs."""
    if len(manifest) > MAX_PATHS:
        raise MetadataError('compact metadata exceeds path budget')
    contents = {}; used = len(encode(manifest))
    for name, row in sorted(manifest.items()):
        if row['kind'] == 'file' and (name.startswith('git-admin/') or name == 'worktree/.git'):
            data = _content(sources[name], max(0, (MAX_BYTES-used)*3//4))
            if hashlib.sha256(data).hexdigest() != row['sha256'] or len(data) != row['size']:
                raise MetadataError('Git metadata differs from captured manifest')
            contents[name] = base64.b64encode(data).decode('ascii'); used += len(contents[name])
    result = dict(version=1, kind='linked-worktree-metadata', manifest=manifest, contents=contents)
    encode(result)
    return result


def _object_storage(relative):
    # Only files that Git fsck has validated as object storage may be omitted.
    # Unknown files, bitmaps, reverse indexes and retention markers are retained.
    return bool(re.fullmatch(r'objects/[0-9a-f]{2}/(?:[0-9a-f]{38}|[0-9a-f]{62})', relative)
                or re.fullmatch(r'objects/pack/pack-(?:[0-9a-f]{40}|[0-9a-f]{64})\.(?:pack|idx)', relative))


def from_managed_tree(root, *, object_storage_verified=False):
    """Preserve filesystem metadata and non-object Git bytes from a frozen image.

    Caller must verify full object storage with owner-credential Git fsck before
    granting the omission flag. Existing verified refs/reflogs preserve history;
    this does not retain unreachable Git object garbage indefinitely.
    """
    root = Path(root); gitdir = root / '.git'
    if not object_storage_verified or gitdir.is_symlink() or not gitdir.is_dir():
        raise MetadataError('verified independent Git object storage required')
    manifest = {}; contents = {}; used = 0
    def collect(path):
        nonlocal used
        if len(manifest) >= MAX_PATHS:
            raise MetadataError('compact metadata exceeds path budget')
        info = path.lstat(); name = path.relative_to(root).as_posix()
        kind = ('directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode)
                else 'symlink' if stat.S_ISLNK(info.st_mode) else None)
        if kind is None:
            raise MetadataError('unsupported compact metadata object')
        try:
            attributes = attrs._xattrs(path, max_bytes=max(0, MAX_BYTES-used))
        except (attrs.RecoveryError, OSError) as error:
            raise MetadataError('attribute inventory unavailable or over budget: ' + str(error)) from error
        row = dict(kind=kind, uid=info.st_uid, gid=info.st_gid, mode=stat.S_IMODE(info.st_mode),
                   mtime_ns=info.st_mtime_ns, xattrs=attributes)
        if kind == 'symlink': row['target'] = os.readlink(path)
        if path == gitdir or gitdir in path.parents:
            relative = path.relative_to(gitdir).as_posix()
            if kind == 'symlink':
                raise MetadataError('symlink in independent Git metadata')
            if kind == 'file':
                if _object_storage(relative): row['content'] = 'verified-git-object-storage'
                else:
                    data = _content(path, max(0, (MAX_BYTES-used)*3//4))
                    contents[name] = base64.b64encode(data).decode('ascii')
                    row.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                    used += len(contents[name])
        manifest[name] = row; used += len(json.dumps({name: row}, sort_keys=True).encode())
        if used > MAX_BYTES: raise MetadataError('compact metadata exceeds byte budget')
    collect(root)
    def failed(error): raise error
    for current, dirs, files in os.walk(root, followlinks=False, onerror=failed):
        for name in sorted(dirs + files): collect(Path(current) / name)
    result = dict(version=1, kind='managed-workspace-metadata', manifest=manifest, contents=contents)
    encode(result)
    return result
