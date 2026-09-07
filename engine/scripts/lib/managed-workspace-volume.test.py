#!/usr/bin/env python3
"""Provider safety tests; opt-in macOS integration uses only disposable images."""
import importlib.util
import array
import json
import mmap
import os
from pathlib import Path
import plistlib
import subprocess
import socket
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location('volumes', Path(__file__).with_name('managed-workspace-volume.py'))
volumes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(volumes)


class ProviderSafety(unittest.TestCase):
    def test_active_namespace_remains_traversable_under_daemon_umask(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous = os.umask(0o077)
            try:
                store = volumes.VolumeStore(Path(tmp) / 'private', Path(tmp) / 'active', require_root=False)
            finally:
                os.umask(previous)
            self.assertEqual(store.active_root.stat().st_mode & 0o777, 0o711)
            self.assertEqual(store.root.stat().st_mode & 0o777, 0o700)

    def test_existing_masked_export_namespace_is_repaired_without_exposing_private_root(self):
        exports = self.store.active_root / 'handoffs'; exports.mkdir(mode=0o700)
        inode = exports.stat().st_ino
        self.store._ensure_traversable_directory(exports)
        self.assertEqual(exports.stat().st_mode & 0o777, 0o711)
        self.assertEqual(exports.stat().st_ino, inode)
        self.assertEqual(self.store.root.stat().st_mode & 0o777, 0o700)
        with self.assertRaises(volumes.VolumeError):
            self.store._ensure_traversable_directory(self.store.root)
        self.assertEqual(self.store.root.stat().st_mode & 0o777, 0o700)

    def test_unsafe_export_namespace_or_parent_is_never_chmodded(self):
        exports = self.store.active_root / 'handoffs'
        outside = self.root / 'outside'; outside.mkdir(mode=0o700)
        exports.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(volumes.VolumeError):
            self.store._ensure_traversable_directory(exports)
        self.assertEqual(outside.stat().st_mode & 0o777, 0o700)
        exports.unlink(); exports.mkdir(); exports.chmod(0o777)
        with self.assertRaises(volumes.VolumeError):
            self.store._ensure_traversable_directory(exports)
        self.assertEqual(exports.stat().st_mode & 0o777, 0o777)
        exports.chmod(0o700); self.store.active_root.chmod(0o777)
        with self.assertRaises(volumes.VolumeError):
            self.store._ensure_traversable_directory(exports)
        self.assertEqual(exports.stat().st_mode & 0o777, 0o700)

    def test_overlapping_private_root_is_refused_before_permission_change(self):
        with self.assertRaises(volumes.VolumeError):
            volumes.VolumeStore(self.store.root, self.store.root, require_root=False)
        self.assertEqual(self.store.root.stat().st_mode & 0o777, 0o700)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos-volume-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.store = volumes.VolumeStore(self.root / 'vault', self.root / 'active', require_root=False)
        self.boot = str(uuid.uuid4())
        boot = patch.object(self.store, '_boot_id', return_value=self.boot)
        boot.start();self.addCleanup(boot.stop)
        self.ident = str(uuid.uuid4())
        base, image, active, readonly = self.store._paths(self.ident)
        for p in (base, image, active, readonly):
            p.mkdir(mode=0o700)
        st = image.stat()
        self.record = dict(version=1, id=self.ident, image_identity=[volumes.fs_identity.filesystem_token(image, st), st.st_ino],
                           state='attached_writable', operation=None, device='/dev/disk999',
                           owner_uid=os.getuid(), owner_gid=os.getgid(), boot_id=self.boot)
        self.store._save(self.ident, self.record)
        self.attachment = {'image-path': str(image), 'writeable': True, 'system-entities': [
            {'dev-entry': '/dev/disk999', 'content-hint': 'GUID_partition_scheme'},
            {'dev-entry': '/dev/disk1000s1', 'mount-point': str(active)}]}

    def test_durable_image_pin_survives_device_renumber_but_not_replacement(self):
        image = self.store._paths(self.ident)[1]
        original = Path.lstat
        info = original(image)
        def observed(path):
            if path == image:
                return types.SimpleNamespace(st_mode=info.st_mode, st_uid=info.st_uid,
                    st_dev=info.st_dev+42, st_ino=info.st_ino)
            return original(path)
        with patch.object(Path, 'lstat', observed), patch.object(volumes.fs_identity, 'filesystem_token',
                return_value=self.record['image_identity'][0]):
            self.assertEqual(self.store._load(self.ident)['id'], self.ident)
        with patch.object(volumes.fs_identity, 'filesystem_token', return_value='different-filesystem'):
            with self.assertRaisesRegex(volumes.VolumeError, 'identity changed'):
                self.store._load(self.ident)
        legacy = dict(self.record, image_identity=[info.st_dev, info.st_ino])
        self.store._save(self.ident, legacy)
        with self.assertRaisesRegex(volumes.VolumeError, 'identity changed'):
            self.store._load(self.ident)
        self.assertTrue(image.is_dir())

    def test_arbitrary_identifiers_cannot_select_images(self):
        for ident in ('../outside', '/dev/disk4', 'bad', None):
            with self.subTest(ident=ident), self.assertRaises(volumes.VolumeError):
                self.store.inspect(ident)

    def test_root_alias_is_canonicalized_before_hdiutil_matching(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        store = volumes.VolumeStore(alias / 'vault', alias / 'active', require_root=False)
        self.assertEqual(store.root, self.store.root)
        self.assertEqual(store.active_root, self.store.active_root)
        self.assertEqual(store._paths(self.ident), self.store._paths(self.ident))

    def test_replaced_image_is_refused_before_any_hdiutil(self):
        image = self.store._paths(self.ident)[1]
        image.rename(image.with_name('preserved'))
        image.mkdir(mode=0o700)
        with patch.object(self.store, '_run') as run, self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        run.assert_not_called()

    def test_detach_never_forces_and_verifies_image_disappears(self):
        with patch.object(self.store, '_attached', side_effect=[self.attachment, None]), \
                patch.object(self.store, '_run', return_value=b'') as run:
            result = self.store.detach(self.ident)
        self.assertEqual(run.call_args.args[0], ['/usr/bin/hdiutil', 'detach', '/dev/disk999'])
        self.assertEqual(result['state'], 'detached')
        self.assertIsNone(result['operation'])

    def test_busy_detach_retains_retry_journal_and_image(self):
        with patch.object(self.store, '_attached', return_value=self.attachment), \
                patch.object(self.store, '_run', side_effect=volumes.VolumeError('busy')), \
                self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        self.assertEqual(self.store._load(self.ident)['operation'], 'detach')
        self.assertTrue(self.store._paths(self.ident)[1].exists())

    def test_success_status_without_detachment_is_refused(self):
        with patch.object(self.store, '_attached', return_value=self.attachment), \
                patch.object(self.store, '_run', return_value=b''), self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        self.assertNotEqual(self.store._load(self.ident)['state'], 'detached')

    def test_reused_device_identity_is_refused(self):
        other = dict(self.attachment, **{'system-entities': [
            {'dev-entry': '/dev/disk123', 'content-hint': 'GUID_partition_scheme'}]})
        with patch.object(self.store, '_attached', return_value=other), \
                patch.object(self.store, '_run') as run, self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        run.assert_not_called()

    def test_unknown_disappearance_cannot_establish_clean_cutoff(self):
        with patch.object(self.store, '_attached', return_value=None), self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)

    def test_pending_detach_absence_does_not_invent_execution_receipt(self):
        self.record['operation'] = 'detach'
        self.store._save(self.ident, self.record)
        with patch.object(self.store, '_attached', return_value=None), self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        self.assertEqual(self.store._load(self.ident)['operation'], 'detach')

    def test_new_boot_and_absent_image_establishes_cutoff(self):
        next_boot = str(uuid.uuid4())
        self.record['operation'] = 'attach_writable'
        self.store._save(self.ident, self.record)
        with patch.object(self.store, '_attached', return_value=None), \
                patch.object(self.store, '_boot_id', return_value=next_boot):
            result = self.store.detach(self.ident)
        self.assertEqual(result['state'], 'detached')
        self.assertEqual(result['cutoff'], dict(kind='new-boot', previous_boot_id=self.boot, boot_id=next_boot))

    def test_missing_or_malformed_old_boot_cannot_authorize_cutoff(self):
        for old in (None, 'invalid', 42):
            self.record['boot_id'] = old
            self.store._save(self.ident, self.record)
            with self.subTest(old=old), patch.object(self.store, '_attached', return_value=None), \
                    self.assertRaises(volumes.VolumeError):
                self.store.detach(self.ident)

    def test_new_boot_does_not_hide_attached_image_or_force_it(self):
        with patch.object(self.store, '_boot_id', return_value=str(uuid.uuid4())), \
                patch.object(self.store, '_attached', return_value=self.attachment), \
                patch.object(self.store, '_run', side_effect=volumes.VolumeError('busy')), \
                self.assertRaises(volumes.VolumeError):
            self.store.detach(self.ident)
        self.assertNotEqual(self.store._load(self.ident)['state'], 'detached')

    def test_boot_identity_requires_valid_kernel_output(self):
        for raw in (b'', b'invalid', b'\xff'):
            with self.subTest(raw=raw), patch.object(self.store, '_run', return_value=raw), \
                    self.assertRaises(volumes.VolumeError):
                volumes.VolumeStore._boot_id(self.store)

    def test_acl_grants_and_unknown_metadata_are_not_protection(self):
        outputs = [('drwx------ fixture\n', True),
                   ('drwx------+ fixture\n 0: group:everyone deny delete\n', True),
                   ('drwx------+ fixture\n 0: user:someone allow add_file,delete_child\n', False),
                   ('drwx------+ fixture\n unexpected ACL\n', False), ('', False)]
        for output, allowed in outputs:
            with self.subTest(output=output), patch.object(volumes.sys, 'platform', 'darwin'), \
                    patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                if allowed:
                    volumes.reject_unsafe_acl(self.root)
                else:
                    with self.assertRaises(volumes.VolumeError):
                        volumes.reject_unsafe_acl(self.root)

    @unittest.skipUnless(sys.platform == 'darwin', 'actual macOS ACL fixture')
    def test_actual_acl_grant_is_rejected_even_with_private_mode(self):
        import pwd
        fixture = self.root / 'acl';fixture.mkdir(mode=0o700)
        username = pwd.getpwuid(os.getuid()).pw_name
        subprocess.run(['/bin/chmod', '+a', 'user:' + username + ' allow add_file,delete_child', str(fixture)], check=True)
        self.assertEqual(fixture.stat().st_mode & 0o777, 0o700)
        try:
            with self.assertRaises(volumes.VolumeError):
                volumes.reject_unsafe_acl(fixture)
        finally:
            subprocess.run(['/bin/chmod', '-N', str(fixture)], check=True)

    def test_interrupted_attach_absence_cannot_establish_clean_cutoff(self):
        self.record.update(state='detached', operation='attach_writable', device=None)
        self.store._save(self.ident, self.record)
        with patch.object(self.store, '_attached', return_value=None):
            with self.assertRaises(volumes.VolumeError):
                self.store.detach(self.ident)
            with self.assertRaises(volumes.VolumeError):
                self.store.attach(self.ident, readonly=True)

    def test_readonly_mount_cannot_skip_detach(self):
        with patch.object(self.store, '_attached', return_value=self.attachment), \
                patch.object(self.store, '_run') as run, self.assertRaises(volumes.VolumeError):
            self.store.attach(self.ident, readonly=True)
        run.assert_not_called()

    def test_owner_readable_capture_still_requires_readonly_mode(self):
        with self.assertRaises(volumes.VolumeError):
            self.store.attach(self.ident, owner_readable=True)

    def test_root_git_is_rejected(self):
        with self.assertRaises(volumes.VolumeError):
            self.store._git(['version'], (0, 0))

    def test_git_child_drops_root_and_discards_inherited_environment(self):
        completed = subprocess.CompletedProcess([], 0, b'ok', b'')
        with patch.object(os, 'geteuid', return_value=0), \
                patch.dict(os.environ, {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath',
                                        'GIT_CONFIG_VALUE_0': '/untrusted', 'DYLD_INSERT_LIBRARIES': '/untrusted'}), \
                patch.object(subprocess, 'run', return_value=completed) as run:
            self.store._git(['version'], (501, 20))
        options = run.call_args.kwargs
        self.assertEqual((options['user'], options['group'], options['extra_groups']), (501, 20, []))
        self.assertNotIn('GIT_CONFIG_COUNT', options['env'])
        self.assertNotIn('DYLD_INSERT_LIBRARIES', options['env'])
        self.assertEqual(options['env']['GIT_CONFIG_GLOBAL'], '/dev/null')
        self.assertGreater(options['timeout'], 0)

    def test_ambiguous_image_attachments_are_refused(self):
        output = plistlib.dumps({'images': [self.attachment, self.attachment]})
        with patch.object(self.store, '_run', return_value=output), self.assertRaises(volumes.VolumeError):
            self.store.inspect(self.ident)

    def test_incomplete_attachment_inventory_cannot_authorize_boot_cutoff(self):
        malformed = ({}, [], {'images': {}}, {'images': [{}]}, {'images': ['bad']},
                     {'images': [{'image-path': ''}]}, {'images': [{'image-path': 'relative'}]},
                     {'images': [{'image-path': 42}]})
        for value in malformed:
            with self.subTest(value=value), patch.object(self.store, '_run', return_value=plistlib.dumps(value)), \
                    patch.object(self.store, '_boot_id', return_value=str(uuid.uuid4())), \
                    self.assertRaises(volumes.VolumeError):
                self.store.detach(self.ident)
            self.assertEqual(self.store._load(self.ident), self.record)

    def test_explicit_empty_inventory_still_allows_verified_reboot_cutoff(self):
        with patch.object(self.store, '_run', return_value=plistlib.dumps({'images': []})), \
                patch.object(self.store, '_boot_id', return_value=str(uuid.uuid4())):
            result = self.store.detach(self.ident)
        self.assertEqual(result['state'], 'detached')
        self.assertEqual(result['cutoff']['kind'], 'new-boot')


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('RICHOS_VOLUME_INTEGRATION') == '1',
                     'requires opt-in disposable macOS disk image test')
class ActualMacOSVolume(unittest.TestCase):
    def test_independent_clone_busy_cutoff_and_readonly_recovery(self):
        # Preserve the fixture on any cleanup failure rather than recursively
        # removing a directory which could still contain a mounted filesystem.
        root = Path(tempfile.mkdtemp(prefix='richos-volume-actual-')).resolve()
        store = volumes.VolumeStore(root / 'vault', root / 'active', require_root=False)
        ident = str(uuid.uuid4())
        source = root / 'source'
        source.mkdir()
        def git(*args):
            return subprocess.check_output(['/usr/bin/git', '-C', str(source), *args],
                env=dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null'))
        git('init', '-q');git('config', 'user.name', 'Fixture');git('config', 'user.email', 'fixture@example.invalid')
        (source / 'file').write_text('committed\n')
        git('add', 'file');git('commit', '-qm', 'fixture')
        commit = git('rev-parse', 'HEAD').decode().strip()
        try:
            result = store.create(ident, str(source), commit, owner_uid=os.getuid(),
                                  owner_gid=os.getgid(), size='128m')
            self.assertTrue(result['initialized'])
            self.assertEqual(result['boot_id'], store._boot_id())
            repo = store._paths(ident)[2] / 'repo'
            self.assertTrue((repo / '.git').is_dir())
            self.assertFalse((repo / '.git/objects/info/alternates').exists())
            (repo / 'file').write_text('staged-only\n')
            store._git(['-C', str(repo), 'add', 'file'], (os.getuid(), os.getgid()))
            (repo / 'file').write_text('working-only\n')
            fd = os.open(repo / 'file', os.O_WRONLY)
            try:
                with self.assertRaises(volumes.VolumeError):
                    store.detach(ident)
                os.write(fd, b'late-write')
            finally:
                os.close(fd)
            # A queued descriptor is invisible to ordinary process FD scans.
            # The filesystem boundary must still refuse to detach underneath it.
            sender, receiver = socket.socketpair()
            fd = os.open(repo / 'file', os.O_RDWR)
            sender.sendmsg([b'x'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])
            os.close(fd)
            try:
                with self.assertRaises(volumes.VolumeError):
                    store.detach(ident)
                _, ancillary, _, _ = receiver.recvmsg(1, socket.CMSG_SPACE(array.array('i').itemsize))
                received = array.array('i')
                received.frombytes(ancillary[0][2])
                try:
                    os.write(received[0], b'queued-fd')
                finally:
                    os.close(received[0])
            finally:
                sender.close();receiver.close()
            fd = os.open(repo / 'file', os.O_RDWR)
            mapping = mmap.mmap(fd, 0)
            os.close(fd)
            try:
                with self.assertRaises(volumes.VolumeError):
                    store.detach(ident)
                mapping[:4] = b'mmap'
                mapping.flush()
            finally:
                mapping.close()
            working = (repo / 'file').read_bytes()
            store.detach(ident)
            # Source disappearance cannot affect the private clone's index.
            source.rename(root / 'source-unavailable')
            readonly = Path(store.attach(ident, readonly=True)['mountpoint']) / 'repo'
            self.assertEqual((readonly / 'file').read_bytes(), working)
            staged = store._git(['-C', str(readonly), 'show', ':file'], (os.getuid(), os.getgid()))
            self.assertEqual(staged, b'staged-only\n')
            with self.assertRaises(OSError):
                (readonly / 'file').write_text('must fail')
            store.detach(ident)
            # A missing namespace root can be recreated after maintenance,
            # and attach recreates only the exact missing UUID mountpoint.
            store._paths(ident)[2].rmdir()
            store.active_root.rmdir()
            store = volumes.VolumeStore(root / 'vault', root / 'active', require_root=False)
            public = Path(store.attach(ident, readonly=True, owner_readable=True)['mountpoint'])
            self.assertEqual(public, store._paths(ident)[2])
            self.assertEqual((public / 'repo/file').read_bytes(), working)
            with self.assertRaises(OSError):
                (public / 'repo/file').write_text('still readonly')
            bundle = store._git(['-C', str(public / 'repo'), 'bundle', 'create', '-', '--all', 'HEAD'],
                                (os.getuid(), os.getgid()))
            self.assertTrue(bundle.startswith(b'# v2 git bundle') or bundle.startswith(b'# v3 git bundle'))
            store.detach(ident)
            shallow = root / 'shallow-source'
            subprocess.run(['/usr/bin/git', 'clone', '-q', '--depth', '1',
                            (root / 'source-unavailable').as_uri(), str(shallow)], check=True,
                           env=dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null'))
            self.assertTrue((shallow / '.git/shallow').exists())
            rejected = str(uuid.uuid4())
            with self.assertRaisesRegex(volumes.VolumeError, 'external object dependencies'):
                store.create(rejected, str(shallow), commit, owner_uid=os.getuid(),
                             owner_gid=os.getgid(), size='128m')
            failed = store.inspect(rejected)
            self.assertEqual(failed['state'], 'detached')
            self.assertFalse(failed.get('initialized'))
        finally:
            for base in store.root.iterdir():
                image = store._paths(base.name)[1]
                if image.exists() and store._attached(image):
                    store.detach(base.name)
                if image.exists() and store._attached(image):
                    raise AssertionError('fixture remains attached: ' + str(root))
            import shutil
            shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
