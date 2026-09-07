#!/usr/bin/env python3
"""Filesystem tokens for durable inode pins, without caching mount identity.

Darwin st_dev is a live mount number and may change across reboot. The native
volume UUID is durable; callers still check inode identity and live st_dev for
race/mount-boundary checks. A token is not authorization to cross a boot cutoff.
Linux fallback is deliberately boot-scoped and is not cross-boot identity.

Native definitions: CLTools SDK sys/attr.h (attrlist, ATTR_VOL_INFO,
ATTR_VOL_UUID, FSOPT_NOFOLLOW), sys/fcntl.h (O_SYMLINK/O_EVTONLY) and unistd.h
(fgetattrlist). The attribute result is a 32-bit length followed by uuid_t.
"""
import ctypes
import os
from pathlib import Path
import stat
import sys
import uuid

DARWIN_PREFIX = 'darwin-volume-uuid-v1:'
LINUX_PREFIX = 'linux-boot-device-v1:'
ATTR_VOL_INFO = 0x80000000
ATTR_VOL_UUID = 0x00040000
FSOPT_NOFOLLOW = 0x00000001
O_EVTONLY = 0x00008000
O_SYMLINK = 0x00200000


class FilesystemIdentityError(OSError):
    pass


class AttrList(ctypes.Structure):
    _fields_ = [('bitmapcount', ctypes.c_uint16), ('reserved', ctypes.c_uint16),
                ('commonattr', ctypes.c_uint32), ('volattr', ctypes.c_uint32),
                ('dirattr', ctypes.c_uint32), ('fileattr', ctypes.c_uint32),
                ('forkattr', ctypes.c_uint32)]


def _stamp(info):
    # ctime detects metadata/name changes in addition to inode substitution.
    # Neither this live stamp nor raw st_dev is persisted as cross-boot proof.
    return (info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode), info.st_ctime_ns)


def _canonical_uuid(raw):
    try:
        value = uuid.UUID(bytes=raw) if isinstance(raw, bytes) else uuid.UUID(raw)
    except (ValueError, TypeError, AttributeError) as error:
        raise FilesystemIdentityError('invalid filesystem or boot UUID') from error
    if value.int == 0:
        raise FilesystemIdentityError('zero filesystem or boot UUID')
    return str(value)


def _decode_volume(raw):
    if len(raw) != 20 or int.from_bytes(raw[:4], sys.byteorder) != 20:
        raise FilesystemIdentityError('incomplete native volume UUID result')
    return DARWIN_PREFIX + _canonical_uuid(raw[4:])


def _darwin_token(fd):
    library = ctypes.CDLL(None, use_errno=True)
    query = library.fgetattrlist
    query.argtypes = [ctypes.c_int, ctypes.POINTER(AttrList), ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.c_ulong]
    query.restype = ctypes.c_int
    attributes = AttrList(5, 0, 0, ATTR_VOL_INFO | ATTR_VOL_UUID, 0, 0, 0)
    result = ctypes.create_string_buffer(20)
    if query(fd, ctypes.byref(attributes), result, len(result), FSOPT_NOFOLLOW) != 0:
        code = ctypes.get_errno()
        raise FilesystemIdentityError(code, 'native volume UUID query failed: ' + os.strerror(code))
    return _decode_volume(result.raw)


def _linux_token(info):
    value = Path('/proc/sys/kernel/random/boot_id').read_text(encoding='ascii').strip()
    # Procfs supplies canonical text. Do not accept malformed/abbreviated input.
    normalized = _canonical_uuid(value)
    if value.lower() != normalized:
        raise FilesystemIdentityError('noncanonical Linux boot identity')
    return LINUX_PREFIX + normalized + ':' + str(info.st_dev)


def filesystem_token(path, info=None):
    """Return the filesystem of this exact no-follow inode or refuse on change.

    `info`, when supplied, must be a fresh lstat result for `path`. A pinned
    descriptor binds the UUID query to that inode, including dangling symlinks.
    O_SYMLINK opens the link itself on Darwin; combining it with O_NOFOLLOW
    incorrectly refuses symlink opens. Path and descriptor are rechecked before
    returning. No identity lookup result is cached, even within one process.
    """
    path = os.fspath(path)
    before = os.lstat(path)
    if info is not None and _stamp(info) != _stamp(before):
        raise FilesystemIdentityError('filesystem target differs from supplied lstat')
    if sys.platform == 'darwin':
        flags = O_EVTONLY | O_SYMLINK
    elif sys.platform.startswith('linux'):
        flags = os.O_PATH | os.O_NOFOLLOW
    else:
        raise FilesystemIdentityError('durable filesystem identity unavailable on this platform')
    fd = os.open(path, flags | getattr(os, 'O_CLOEXEC', 0))
    try:
        opened = os.fstat(fd)
        if _stamp(opened) != _stamp(before):
            raise FilesystemIdentityError('filesystem target changed while opening')
        token = _darwin_token(fd) if sys.platform == 'darwin' else _linux_token(opened)
        if _stamp(os.fstat(fd)) != _stamp(opened) or _stamp(os.lstat(path)) != _stamp(before):
            raise FilesystemIdentityError('filesystem target changed during identity query')
        return token
    finally:
        os.close(fd)
