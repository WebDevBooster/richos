#!/usr/bin/env python3
"""Low-level macOS workspace volumes. Authorization and expiry belong to the broker.

No method accepts a caller-provided device or removes an image. require_root=False
exists for disposable provider tests and provides NO privilege boundary.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid


class VolumeError(RuntimeError):
    pass


def reject_unsafe_acl(path):
    """macOS mode bits do not bound ACL grants. Accept only no ACL or deny-only ACLs."""
    if sys.platform != 'darwin':
        return
    try:
        result = subprocess.run(['/bin/ls', '-lde', str(path)], capture_output=True,
                                text=True, timeout=5, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
        raise VolumeError('ACL metadata unavailable: ' + str(path)) from exc
    lines = result.stdout.splitlines()
    if result.returncode != 0 or not lines:
        raise VolumeError('ACL metadata unavailable: ' + str(path))
    for line in lines[1:]:
        if not re.fullmatch(r'\s*\d+: .+ deny [A-Za-z_,]+', line):
            raise VolumeError('ACL grants or unreadable ACL on protected path: ' + str(path))


class VolumeStore:
    def __init__(self, root, active_root, *, require_root=True):
        if not Path(root).is_absolute() or not Path(active_root).is_absolute():
            raise VolumeError('absolute managed roots required')
        # macOS exposes /var through /private/var; hdiutil reports the latter.
        # Resolve once, then validate and retain the actual protected ancestors.
        self.root = Path(root).resolve()
        self.active_root = Path(active_root).resolve()
        self.require_root = require_root
        if require_root and os.geteuid() != 0:
            raise VolumeError('root broker required')
        for path, mode in ((self.root, 0o700), (self.active_root, 0o711)):
            if not path.is_absolute():
                raise VolumeError('absolute managed roots required')
            path.mkdir(mode=mode, parents=False, exist_ok=True)
            self._check_directory(path, private=(mode == 0o700))
        if self.root == self.active_root or self.root in self.active_root.parents:
            raise VolumeError('active mount root must be outside private image root')

    def _check_directory(self, path, *, private=True):
        st = path.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
            raise VolumeError('managed directory identity/owner invalid')
        if stat.S_IMODE(st.st_mode) & (0o077 if private else 0o022):
            raise VolumeError('managed directory permissions invalid')
        # Every ancestor must resist replacement by the workspace owner.
        if self.require_root:
            reject_unsafe_acl(path)
            for parent in path.parents:
                ps = parent.lstat()
                if not stat.S_ISDIR(ps.st_mode) or ps.st_uid != 0 or ps.st_mode & 0o022:
                    raise VolumeError('managed ancestor is not root protected')
                reject_unsafe_acl(parent)

    def _paths(self, ident):
        try:
            if str(uuid.UUID(ident)) != ident:
                raise ValueError()
        except (ValueError, AttributeError, TypeError):
            raise VolumeError('canonical UUID required')
        base = self.root / ident
        return base, base / 'image.sparsebundle', self.active_root / ident, base / 'readonly'

    @contextlib.contextmanager
    def _locked(self, ident):
        base, *_ = self._paths(ident)
        self._check_directory(base)
        fd = os.open(base / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    @staticmethod
    def _sync_dir(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _save(self, ident, record):
        base, *_ = self._paths(ident)
        tmp = base / ('journal.' + uuid.uuid4().hex)
        with tmp.open('x', encoding='utf-8') as out:
            os.chmod(tmp, 0o600)
            json.dump(record, out, sort_keys=True)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, base / 'journal.json')
        self._sync_dir(base)

    def _load(self, ident):
        base, image, *_ = self._paths(ident)
        with (base / 'journal.json').open(encoding='utf-8') as stream:
            record = json.load(stream)
        if record.get('id') != ident or record.get('version') != 1:
            raise VolumeError('invalid journal identity')
        st = image.lstat()
        if not stat.S_ISDIR(st.st_mode) or [st.st_dev, st.st_ino] != record.get('image_identity'):
            raise VolumeError('image identity changed or creation incomplete')
        if st.st_uid != os.geteuid() or st.st_mode & 0o077:
            raise VolumeError('image is not private to manager')
        return record

    @staticmethod
    def _run(argv, *, owner=None):
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C',
               'HOME': '/var/empty', 'GIT_CONFIG_NOSYSTEM': '1',
               'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}
        kw = {}
        if owner is not None and os.geteuid() == 0:
            kw = dict(user=owner[0], group=owner[1], extra_groups=[])
        try:
            result = subprocess.run(argv, capture_output=True, env=env, timeout=300, **kw)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise VolumeError(f'{Path(argv[0]).name} could not complete: {exc}') from exc
        if result.returncode:
            raise VolumeError(f'{Path(argv[0]).name} failed ({result.returncode}): ' +
                              result.stderr.decode('utf-8', 'replace')[-2000:])
        return result.stdout

    def _git(self, args, owner):
        if owner[0] == 0:
            raise VolumeError('Git must run as an unprivileged workspace owner')
        return self._run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
                          '-c', 'protocol.allow=never', '-c', 'protocol.file.allow=always',
                          *args], owner=owner)

    def _boot_id(self):
        raw = self._run(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'])
        try:
            return str(uuid.UUID(raw.decode('ascii').strip()))
        except (ValueError, UnicodeError, AttributeError) as exc:
            raise VolumeError('kernel boot identity unavailable') from exc

    def _boot_cutoff(self, ident, record):
        """Only call after the exact image is verified absent from hdiutil."""
        previous = record.get('boot_id')
        try:
            valid = isinstance(previous, str) and str(uuid.UUID(previous)) == previous
        except ValueError:
            valid = False
        if not valid:
            return False
        current = self._boot_id()
        if current == previous:
            return False
        record.update(state='detached', operation=None, device=None, boot_id=current,
                      cutoff={'kind': 'new-boot', 'previous_boot_id': previous, 'boot_id': current})
        self._save(ident, record)
        return True

    def _attached(self, image):
        info = plistlib.loads(self._run(['/usr/bin/hdiutil', 'info', '-plist']))
        found = [item for item in info.get('images', [])
                 if os.path.realpath(item.get('image-path', '')) == str(image.resolve())]
        if len(found) > 1:
            raise VolumeError('image has ambiguous attachments')
        return found[0] if found else None

    @staticmethod
    def _device(attachment):
        entities = attachment.get('system-entities', [])
        disks = [item['dev-entry'] for item in entities
                 if item.get('content-hint') == 'GUID_partition_scheme'
                 and re.fullmatch(r'/dev/disk[0-9]+', item.get('dev-entry', ''))]
        if len(disks) != 1:
            raise VolumeError('cannot identify exact backing device')
        return disks[0]

    def inspect(self, ident):
        with self._locked(ident):
            record = self._load(ident)
            record['attachment'] = self._attached(self._paths(ident)[1])
            return record

    def create(self, ident, source_repo, commit, *, owner_uid, owner_gid, size='32g'):
        owner = (owner_uid, owner_gid)
        if not isinstance(owner_uid, int) or owner_uid <= 0 or not isinstance(owner_gid, int) or owner_gid < 0:
            raise VolumeError('unprivileged numeric owner required')
        if not self.require_root and owner != (os.getuid(), os.getgid()):
            raise VolumeError('prototype cannot impersonate another owner')
        source = Path(source_repo)
        if not source.is_absolute() or not source.is_dir():
            raise VolumeError('absolute source repository required')
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', commit):
            raise VolumeError('full commit object ID required')
        if not re.fullmatch(r'[1-9][0-9]*[mg]', size):
            raise VolumeError('invalid sparse capacity')
        base, image, mount, readonly = self._paths(ident)
        base.mkdir(mode=0o700)  # Exclusive reservation; never reuse arbitrary contents.
        self._sync_dir(self.root)
        with self._locked(ident):
            record = dict(version=1, id=ident, state='creating', operation='create',
                          owner_uid=owner_uid, owner_gid=owner_gid, commit=commit, boot_id=self._boot_id())
            self._save(ident, record)
            self._run(['/usr/bin/hdiutil', 'create', '-size', size, '-fs', 'APFS',
                       '-type', 'SPARSEBUNDLE', '-volname', 'RichOS-' + ident, str(image)])
            os.chmod(image, 0o700)
            st = image.lstat()
            record.update(image_identity=[st.st_dev, st.st_ino], state='detached', operation=None)
            mount.mkdir(mode=0o700)
            readonly.mkdir(mode=0o700)
            self._save(ident, record)
            self._attach_locked(ident)
            try:
                self._git(['clone', '--no-local', '--no-hardlinks', '--no-checkout',
                           '--', str(source), str(mount / 'repo')], owner)
                self._git(['-C', str(mount / 'repo'), 'checkout', '--detach', commit], owner)
                gitdir = mount / 'repo' / '.git'
                if not gitdir.is_dir() or gitdir.is_symlink():
                    raise VolumeError('independent Git directory missing')
                if (gitdir / 'shallow').exists() or (gitdir / 'objects/info/alternates').exists() or list((gitdir / 'objects/pack').glob('*.promisor')):
                    raise VolumeError('clone has external object dependencies')
                config = (gitdir / 'config').read_text()
                if re.search(r'(?im)^\s*(promisor|partialclone|alternaterefscommand)\s*=', config):
                    raise VolumeError('clone has deferred object dependencies')
                self._git(['-C', str(mount / 'repo'), 'fsck', '--full'], owner)
                record = self._load(ident)
                record['initialized'] = True
                self._save(ident, record)
            except Exception:
                # Retain the image and journal on failure. No force-detach or deletion.
                self._detach_locked(ident)
                raise
            return dict(record, attachment=self._attached(image))

    def attach(self, ident, *, readonly=False, owner_readable=False):
        with self._locked(ident):
            return self._attach_locked(ident, readonly=readonly, owner_readable=owner_readable)

    def _attach_locked(self, ident, *, readonly=False, owner_readable=False):
        if owner_readable and not readonly:
            raise VolumeError('owner-readable capture must be readonly')
        record = self._load(ident)
        base, image, active, private = self._paths(ident)
        if self._attached(image):
            raise VolumeError('detach required before attach')
        self._boot_cutoff(ident, record)
        if record.get('state') != 'detached' or record.get('operation') is not None:
            raise VolumeError('verified clean detach required before attach')
        mount = private if readonly and not owner_readable else active
        # /var/run is cleared at reboot. The namespace parent is protected;
        # only recreate this exact manager-issued mountpoint, never contents.
        self._check_directory(self.active_root, private=False)
        mount.mkdir(mode=0o700, exist_ok=True)
        self._check_directory(mount)
        if any(mount.iterdir()):
            raise VolumeError('mountpoint is not empty')
        record.update(operation='attach_readonly' if readonly else 'attach_writable', boot_id=self._boot_id())
        self._save(ident, record)
        args = ['/usr/bin/hdiutil', 'attach', '-plist', '-nobrowse', '-owners', 'on',
                '-mountpoint', str(mount)]
        if readonly:
            args.append('-readonly')
        self._run([*args, str(image)])
        current = self._attached(image)
        if not current or current.get('writeable') is not (not readonly):
            raise VolumeError('attachment mode verification failed')
        points = [item.get('mount-point') for item in current.get('system-entities', [])
                  if item.get('mount-point')]
        if points != [str(mount)]:
            raise VolumeError('attachment mountpoint mismatch')
        record['device'] = self._device(current)
        if not readonly:
            os.chown(mount, record['owner_uid'], record['owner_gid'])
            os.chmod(mount, 0o700)
        record.update(state='attached_readonly' if readonly else 'attached_writable', operation=None)
        self._save(ident, record)
        return dict(record, mountpoint=str(mount))

    def detach(self, ident):
        with self._locked(ident):
            return self._detach_locked(ident)

    def _detach_locked(self, ident):
        record = self._load(ident)
        image = self._paths(ident)[1]
        current = self._attached(image)
        if current:
            device = self._device(current)
            if record.get('device') and record['device'] != device:
                raise VolumeError('attachment device changed')
            record.update(operation='detach', device=device, boot_id=self._boot_id())
            self._save(ident, record)
            self._run(['/usr/bin/hdiutil', 'detach', device])
            if self._attached(image):
                raise VolumeError('image remains attached after detach')
        elif not (record.get('state') == 'detached' and record.get('operation') is None) and not self._boot_cutoff(ident, record):
            # Intent is not an execution receipt. Another actor may have forced
            # a detach after our intent was saved. An interrupted operation whose
            # image is now absent needs the broker's stronger recovery boundary.
            raise VolumeError('missing clean detach provenance')
        record.update(state='detached', operation=None, device=None)
        self._save(ident, record)
        return record
