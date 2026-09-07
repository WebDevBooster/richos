#!/usr/bin/env python3
"""Lifecycle crash and real filesystem acceptance tests."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import time
import unittest
from unittest.mock import Mock, patch
import uuid
import tarfile

spec = importlib.util.spec_from_file_location('manager', Path(__file__).with_name('managed-workspace-manager.py'))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos-manager-test-')
        self.addCleanup(self.temp.cleanup)
        self.top = Path(self.temp.name).resolve()
        self.m = manager.WorkspaceManager(self.top / 'private', self.top / 'active', require_root=False)
        self.ident = str(uuid.uuid4())
        self.base = self.m._base(self.ident)
        self.base.mkdir(mode=0o700)
        self.image = self.base / 'image.sparsebundle'
        self.image.mkdir(mode=0o700)
        (self.image / 'band').write_bytes(b'active data')
        self.archive = self.base / 'recovery.dmg'
        self.archive.write_bytes(b'verified recovery data')
        self.record = dict(version=1, id=self.ident, state='archived', owner_uid=os.getuid(),
                           owner_gid=os.getgid(), source_repo=str(self.top), source_commit='a'*40,
                           agent_id='agent1', session_id='session1', agent_name='dev-opus-test',
                           archive_identity=self.m._identity(self.archive, manager.stat.S_ISREG),
                           archive_sha256=self.m._digest(self.archive),
                           image_identity=self.m._identity(self.image, manager.stat.S_ISDIR),
                           expires_at=time.time()+100, retention_days=14,
                           has_uncommitted_data=False,
                           handoff_refs=[dict(source='HEAD', destination='refs/richos/x', oid='a'*40)])
        self.m._save(self.ident, self.record)
        self.attached = patch.object(self.m.provider, '_attached', return_value=None)
        self.attached.start()
        self.addCleanup(self.attached.stop)

    def test_archive_reclamation_survives_device_renumber_with_stable_filesystem(self):
        original = Path.lstat
        def renumber(path):
            info = original(path)
            if path in (self.image, self.archive):
                return types.SimpleNamespace(st_mode=info.st_mode, st_uid=info.st_uid,
                    st_dev=info.st_dev+42, st_ino=info.st_ino)
            return info
        token = self.record['image_identity'][0]
        with patch.object(Path, 'lstat', renumber), patch.object(manager.volumes.fs_identity,
                'filesystem_token', return_value=token):
            result = self.m.reconcile(self.ident)
        self.assertEqual(result['state'], 'retained', result)
        self.assertFalse(self.image.exists())
        self.assertTrue(self.archive.exists())

    def test_different_filesystem_or_old_numeric_pin_cannot_authorize_reclamation(self):
        with patch.object(manager.volumes.fs_identity, 'filesystem_token', return_value='different-volume'):
            result = self.m.reconcile(self.ident)
        self.assertIn('identity changed', result['last_error'])
        self.assertTrue(self.image.exists())
        info = self.archive.stat()
        self.record['archive_identity'] = [info.st_dev, info.st_ino]
        self.m._save(self.ident, self.record)
        result = self.m.reconcile(self.ident)
        self.assertIn('identity changed', result['last_error'])
        self.assertTrue(self.image.exists())
        self.assertTrue(self.archive.exists())

    def test_mismatched_terminal_owner_cannot_claim(self):
        self.record['state'] = 'active'
        self.m._save(self.ident, self.record)
        for session, agent in [('wrong', 'agent1'), ('session1', 'wrong'), ('session1', '')]:
            with self.assertRaises(manager.ManagerError):
                self.m.terminal(self.ident, session_id=session, agent_id=agent)
        self.assertEqual(self.m._load(self.ident)['state'], 'active')

    def test_busy_image_keeps_active_storage(self):
        with patch.object(self.m.provider, '_attached', return_value={'device': 'busy'}):
            result = self.m.reconcile(self.ident)
        self.assertIn('attached', result['last_error'])
        self.assertTrue((self.image / 'band').exists())

    def test_corrupted_recovery_cannot_authorize_reclamation(self):
        self.archive.write_bytes(b'corrupt')
        result = self.m.reconcile(self.ident)
        self.assertIn('bytes changed', result['last_error'])
        self.assertTrue(self.image.exists())

    def test_replaced_image_is_not_deleted(self):
        self.image.rename(self.base / 'original')
        self.image.mkdir(mode=0o700)
        result = self.m.reconcile(self.ident)
        self.assertIn('identity changed', result['last_error'])
        self.assertTrue(self.image.exists())

    def test_crash_after_band_removal_retries_same_image(self):
        original = self.m._save
        def crash(ident, record):
            if record['state'] == 'retained':
                raise KeyboardInterrupt('crash after remove')
            return original(ident, record)
        with patch.object(self.m, '_save', side_effect=crash), self.assertRaises(KeyboardInterrupt):
            self.m.reconcile(self.ident)
        self.assertFalse(self.image.exists())
        self.assertEqual(self.m.inspect(self.ident)['state'], 'reclaiming')
        self.assertEqual(self.m.reconcile(self.ident)['state'], 'retained')
        self.assertTrue(self.archive.exists())

    def test_missing_active_image_without_intent_does_not_invent_reclamation(self):
        manager.shutil.rmtree(self.image)
        result = self.m.reconcile(self.ident)
        self.assertEqual(result['state'], 'archived')

    def test_crash_after_archive_unlink_retries_expiry(self):
        self.record['state'] = 'retained'
        self.m._save(self.ident, self.record)
        original = self.m._save
        def crash(ident, record):
            if record['state'] == 'expired':
                raise KeyboardInterrupt('crash after unlink')
            return original(ident, record)
        with patch.object(self.m, '_verify_handoff'), patch.object(self.m, '_save', side_effect=crash), self.assertRaises(KeyboardInterrupt):
            self.m.reconcile(self.ident, now=self.record['expires_at']+1)
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.m.inspect(self.ident)['state'], 'expiring')
        with patch.object(self.m, '_verify_handoff'):
            self.assertEqual(self.m.reconcile(self.ident, now=self.record['expires_at']+1)['state'], 'expired')

    def test_missing_handoff_blocks_expiry(self):
        self.record['state'] = 'retained'
        self.m._save(self.ident, self.record)
        with patch.object(self.m, '_verify_source'), patch.object(self.m, '_user_git', return_value=b'b'*40+b'\n'):
            result = self.m.reconcile(self.ident, now=self.record['expires_at']+1)
        self.assertIn('handoff reference', result['last_error'])
        self.assertTrue(self.archive.exists())

    def test_uncommitted_data_cannot_expire_without_authorization(self):
        self.record.update(state='retained', has_uncommitted_data=True)
        self.m._save(self.ident, self.record)
        result = self.m.reconcile(self.ident, now=self.record['expires_at']+1)
        self.assertIn('no expiry authorization', result['last_error'])
        self.assertTrue(self.archive.exists())

    def test_failed_create_remains_owned_and_visible(self):
        with patch.object(self.m, '_source_fingerprint', return_value={'fixture': True}), \
                patch.object(self.m.provider, 'create', side_effect=RuntimeError('failed clone')):
            with self.assertRaises(RuntimeError):
                self.m.create(request_id='failed-create', source_repo=self.top, commit='a'*40, owner_uid=os.getuid(), owner_gid=os.getgid(),
                              session_id='session2', agent_name='dev-opus-test')
        requests = list(self.m.root.glob('*.request.json'))
        self.assertEqual(len(requests), 1)
        data = json.loads(requests[0].read_text())
        self.assertEqual(data['session_id'], 'session2')
        rows = self.m.sweep()
        self.assertTrue(any(row.get('id') == data['id'] and row['state'] == 'creation-blocked' for row in rows))
        self.assertFalse(self.m._base(data['id']).exists(), 'speculative recovery must not cancel the request')
        inventory = self.m.status(os.getuid())
        self.assertTrue(any(row['id'] == data['id'] and row['state'] == 'creation-incomplete' for row in inventory))

    def test_cancel_incomplete_creation_is_durable_and_prevents_reactivation(self):
        kwargs = dict(request_id='failed-create', source_repo=self.top, commit='a'*40,
                      owner_uid=os.getuid(), owner_gid=os.getgid(), session_id='session2', agent_name='dev-opus-test')
        with patch.object(self.m, '_source_fingerprint', return_value={'fixture': True}), \
                patch.object(self.m.provider, 'create', side_effect=RuntimeError('failed clone')):
            with self.assertRaises(RuntimeError):
                self.m.create(**kwargs)
        data = json.loads(next(self.m.root.glob('*.request.json')).read_text())
        self.assertEqual(self.m.owner_uid(data['id']), os.getuid())
        with self.assertRaises(manager.ManagerError):
            self.m.cancel_preparation(data['id'], session_id='different')
        result = self.m.cancel_preparation(data['id'], session_id='session2')
        self.assertEqual(result['state'], 'creation-cancelled')
        with patch.object(self.m.provider, 'create') as create:
            self.assertEqual(self.m.create(**kwargs)['state'], 'creation-cancelled')
        create.assert_not_called()
        self.assertTrue(any(row['id'] == data['id'] and row['state'] == 'creation-cancelled'
                            for row in self.m.status(os.getuid())))
        with patch.object(self.m.provider, '_boot_id', return_value=str(uuid.uuid4())):
            rows = self.m.sweep()
        self.assertTrue(any(row.get('id') == data['id'] and row['state'] == 'creation-empty' for row in rows), rows)

    def test_session_recovery_reaches_raw_reclamation_through_broker_and_sweep(self):
        broker = manager._module('broker_fixture', 'managed-workspace-broker.py')
        bridge = manager._module('bridge_fixture', 'managed-workspace-integration.py')
        (self.base / 'lifecycle.json').unlink()
        uid, gid = os.getuid(), os.getgid()
        key = self.m._request_key(uid, 'incomplete')
        request = dict(version=1, id=self.ident, request_id='incomplete', request_key=key,
                       owner_uid=uid, owner_gid=gid, session_id='gone-session', agent_id=None,
                       source_commit='a'*40, source_repo=str(self.top), state='creating')
        pending = self.m.root / (key+'.request.json')
        pending.write_text(json.dumps(request)); pending.chmod(0o600)
        boot = str(uuid.uuid4())
        self.m.provider._save(self.ident, dict(version=1, id=self.ident, owner_uid=uid, owner_gid=gid,
                    commit='a'*40, boot_id=boot, state='detached', operation=None,
                    image_identity=self.m._identity(self.image, manager.stat.S_ISDIR)))
        service = broker.Broker(self.m, dict(version=1, private_root=str(self.m.root),
                    active_root=str(self.m.provider.active_root), owners={str(uid): {'gid': gid}},
                    repositories={'fixture': dict(path=str(self.top), owners=[uid], size='128m', retention_days=14)}))
        ledger = Mock()
        ledger.session_gone_by_exhaustion.return_value = ('gone', 'accounted')
        with patch.object(bridge, 'config', return_value={}), patch.object(bridge, '_module', return_value=ledger), \
                patch.object(bridge, 'request', side_effect=lambda payload: service.dispatch(uid, payload)), \
                patch.object(self.m.provider, '_boot_id', return_value=boot):
            self.assertEqual(bridge.recover_preparations(), [dict(id=self.ident, state='terminal')])
            self.assertTrue(self.image.exists(), 'client path must not capture or reclaim')
            rows = self.m.sweep()
        self.assertEqual(rows[0]['state'], 'creation-retained', rows)
        self.assertFalse(self.image.exists())
        with tarfile.open(self.base / 'failed-creation.tar.gz') as archive:
            self.assertEqual(archive.extractfile('image.sparsebundle/band').read(), b'active data')
        with patch.object(self.m.provider, 'create') as create:
            self.assertEqual(self.m._recover_create(request, start=True)['state'], 'creation-retained')
        create.assert_not_called()

    def test_inventory_filters_other_owners_without_publishing_paths(self):
        self.assertEqual(self.m.status(os.getuid()+1), [])
        record = self.m.status(os.getuid())[0]
        self.assertEqual(set(record), {'id', 'owner_uid', 'state', 'session_id', 'agent_id'})
        self.assertEqual(record['id'], self.ident)

    def test_abandoned_preparation_keeps_bytes_and_can_be_retried(self):
        self.record.update(state='active', agent_id=None)
        self.m._save(self.ident, self.record)
        result = self.m.cancel_preparation(self.ident, session_id='session1')
        self.assertEqual(result['state'], 'terminal')
        self.assertTrue(self.image.exists())
        self.assertEqual(self.m.cancel_preparation(self.ident, session_id='session1')['state'], 'terminal')
        with self.assertRaises(manager.ManagerError):
            self.m.bind(self.ident, session_id='session1', agent_id='late-worker')

    def test_bound_or_foreign_preparation_cannot_be_cancelled(self):
        self.record['state'] = 'active'
        self.m._save(self.ident, self.record)
        with self.assertRaisesRegex(manager.ManagerError, 'bound or session'):
            self.m.cancel_preparation(self.ident, session_id='session1')
        self.record['agent_id'] = None
        self.m._save(self.ident, self.record)
        with self.assertRaisesRegex(manager.ManagerError, 'bound or session'):
            self.m.cancel_preparation(self.ident, session_id='other')
        self.assertEqual(self.m._load(self.ident)['state'], 'active')

    def test_corrupt_inventory_is_not_reported_as_empty_success(self):
        (self.m.root / ('f'*64+'.request.json')).write_text('broken')
        with self.assertRaisesRegex(manager.ManagerError, 'inventory is incomplete'):
            self.m.status(os.getuid())



class FrozenContent(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos-frozen-check-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.m = manager.WorkspaceManager(self.root / 'private', self.root / 'active', require_root=False)
        self.owner = (os.getuid(), os.getgid())
        self.git('init', '-q'); self.git('config', 'user.name', 'x'); self.git('config', 'user.email', 'x@example.invalid')
        (self.repo / 'tracked').write_text('original')
        self.git('add', '.'); self.git('commit', '-qm', 'original')

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        return subprocess.check_output(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(self.repo), *args], env=env, stderr=subprocess.PIPE)

    def dirty(self):
        return self.m._has_uncommitted_data(self.repo, self.owner)

    def delivery_record(self, *, modern=True):
        ident = str(uuid.uuid4())
        tip = self.git('rev-parse', 'HEAD').decode().strip()
        ref = 'refs/richos/handoffs/managed/' + ident + '/HEAD'
        self.git('update-ref', ref, tip)
        record = dict(version=1, id=ident, state='retained', source_repo=str(self.repo),
                      owner_uid=self.owner[0], owner_gid=self.owner[1], agent_name='same-worker',
                      handoff_verified=True, handoff_refs=[dict(source='HEAD', destination=ref, oid=tip)])
        record['source_identity'] = self.m._source_fingerprint(record)
        if modern:
            record['delivery_mode'] = 'handoff-ref-v1'
        self.m._base(ident).mkdir(mode=0o700)
        self.m._save(ident, record)
        return record

    def test_delivery_refs_allow_same_name_and_exact_merge_without_source_branches(self):
        first = self.delivery_record()
        self.git('checkout', '--detach', '-q')
        (self.repo / 'delivered').write_text('unique committed work')
        self.git('add', '.'); self.git('commit', '-qm', 'worker commit')
        second = self.delivery_record()
        self.git('checkout', '-q', '-')
        before = self.git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/')
        for record in (first, second):
            self.m._verify_handoff(record)
            self.m._publish_terminal_branch(record)
            self.m._save(record['id'], record)
            result = self.m.delivery(record['id'])
            self.assertEqual(result, record['delivery'])
            self.assertNotIn('branch_published', record)
        self.assertNotEqual(first['delivery']['ref'], second['delivery']['ref'])
        self.assertNotEqual(first['delivery']['tip'], second['delivery']['tip'])
        self.assertEqual(self.git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/'), before)
        self.git('merge', '--ff-only', second['delivery']['tip'])
        self.assertEqual((self.repo / 'delivered').read_text(), 'unique committed work')
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/heads/same-worker'), b'')

    def test_delivery_rechecks_current_ref_and_source_identity(self):
        record = self.delivery_record()
        self.m._publish_terminal_branch(record); self.m._save(record['id'], record)
        self.git('update-ref', '-d', record['delivery']['ref'])
        with self.assertRaises(manager.ManagerError):
            self.m.delivery(record['id'])
        self.assertEqual(self.m._load(record['id'])['delivery'], record['delivery'])

    def test_legacy_publication_and_reused_name_are_preserved(self):
        old = self.delivery_record(modern=False)
        self.m._publish_terminal_branch(old)
        self.assertTrue(old['branch_published'])
        self.assertEqual(self.git('rev-parse', old['published_ref']).decode().strip(), old['published_tip'])
        (self.repo / 'new').write_text('other owner')
        self.git('add', '.'); self.git('commit', '-qm', 'other work')
        tip = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('update-ref', old['published_ref'], tip)
        self.m._publish_terminal_branch(old)
        new = self.delivery_record()
        self.m._publish_terminal_branch(new)
        self.assertEqual(self.git('rev-parse', old['published_ref']).decode().strip(), tip)
        self.assertEqual(old['published_tip'], old['delivery']['tip'])

    def test_pending_or_malformed_delivery_is_not_returned(self):
        record = self.delivery_record()
        record['handoff_verified'] = False; self.m._save(record['id'], record)
        with self.assertRaisesRegex(manager.ManagerError, 'pending'):
            self.m.delivery(record['id'])
        record['handoff_verified'] = True
        record['handoff_refs'][0]['destination'] = 'refs/heads/' + record['agent_name']
        self.git('update-ref', record['handoff_refs'][0]['destination'], record['handoff_refs'][0]['oid'])
        self.m._save(record['id'], record)
        with self.assertRaisesRegex(manager.ManagerError, 'exact managed'):
            self.m.delivery(record['id'])

    def test_clean_checkout_is_proved(self):
        self.assertFalse(self.dirty())

    def test_assume_unchanged_cannot_hide_unique_bytes(self):
        self.git('update-index', '--assume-unchanged', 'tracked')
        (self.repo / 'tracked').write_text('hidden work')
        self.assertEqual(self.git('status', '--porcelain'), b'')
        self.assertTrue(self.dirty())

    def test_skip_worktree_cannot_hide_unique_bytes(self):
        self.git('update-index', '--skip-worktree', 'tracked')
        (self.repo / 'tracked').write_text('hidden work')
        self.assertEqual(self.git('status', '--porcelain'), b'')
        self.assertTrue(self.dirty())

    def test_same_size_and_mtime_are_not_content_evidence(self):
        self.git('config', 'core.trustctime', 'false')
        self.git('config', 'core.checkstat', 'minimal')
        self.git('status', '--porcelain')
        p = self.repo / 'tracked'; st = p.stat()
        p.write_text('modified'); os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        self.assertTrue(self.dirty())

    def test_pending_index_lock_keeps_recovery(self):
        (self.repo / '.git/index.lock').write_bytes(b'partial staged data')
        self.assertTrue(self.dirty())

    def test_ignored_private_files_keep_recovery(self):
        (self.repo / '.git/info/exclude').write_text('.private-secret\n')
        (self.repo / '.private-secret').write_text('unique private work')
        self.assertTrue(self.dirty())

    def test_recreated_canonical_repository_is_not_the_original_source(self):
        record = dict(source_repo=str(self.repo), owner_uid=self.owner[0], owner_gid=self.owner[1])
        record['source_identity'] = self.m._source_fingerprint(record)
        self.repo.rename(self.root / 'old-source')
        self.repo.mkdir()
        self.git('init', '-q')
        with self.assertRaisesRegex(manager.ManagerError, 'identity changed'):
            self.m._verify_source(record)

    def test_reserved_worker_branch_rejected_before_creation(self):
        with patch.object(self.m.provider, 'create') as create, self.assertRaises(manager.ManagerError):
            self.m.create(request_id='invalid-head', source_repo=self.repo,
                          commit=self.git('rev-parse', 'HEAD').decode().strip(),
                          owner_uid=self.owner[0], owner_gid=self.owner[1],
                          session_id='fixture', agent_name='HEAD')
        create.assert_not_called()
        self.assertEqual(list(self.m.root.glob('*.request.json')), [])


@unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('RICHOS_TEST_REAL_VOLUMES') == '1', 'actual macOS image opt-in')
class ActualFilesystem(unittest.TestCase):
    def test_dirty_state_capture_handoff_reclamation_and_expiry(self):
        # Leave the exact fixture for diagnosis if a mount cannot be detached.
        root = Path(tempfile.mkdtemp(prefix='richos-manager-real-')).resolve()
        m = manager.WorkspaceManager(root / 'private', root / 'active', require_root=False)
        source = root / 'source'
        source.mkdir()
        def git(cwd, *args):
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
            return subprocess.check_output(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(cwd), *args], env=env, stderr=subprocess.PIPE).decode().strip()
        git(source, 'init', '-q')
        git(source, 'config', 'user.name', 'fixture')
        git(source, 'config', 'user.email', 'fixture@example.invalid')
        (source / 'tracked').write_text('original')
        git(source, 'add', '.')
        git(source, 'commit', '-qm', 'original')
        head = git(source, 'rev-parse', 'HEAD')
        record = m.create(request_id='fixture-create', source_repo=source, commit=head, owner_uid=os.getuid(), owner_gid=os.getgid(),
                          session_id='fixture', agent_name='dev-opus-fixture', size='128m')
        ident = record['id']
        work = m.provider.active_root / ident / 'repo'
        git(work, 'config', 'user.name', 'fixture')
        git(work, 'config', 'user.email', 'fixture@example.invalid')
        (work / 'delivered').write_text('terminal commit')
        git(work, 'add', '.')
        git(work, 'commit', '-qm', 'terminal work')
        terminal = git(work, 'rev-parse', 'HEAD')
        (work / 'abandoned').write_text('reflog-only work')
        git(work, 'add', '.'); git(work, 'commit', '-qm', 'reflog only')
        abandoned = git(work, 'rev-parse', 'HEAD')
        git(work, 'reset', '--hard', terminal)
        git(work, 'reflog', 'delete', 'dev-opus-fixture@{1}')
        git(work, 'reflog', 'delete', 'HEAD@{1}')
        self.assertNotIn(abandoned, git(work, 'reflog', '--all', '--format=%H'))
        (work / 'tracked').write_text('index version')
        git(work, 'add', 'tracked')
        (work / 'tracked').write_text('working version')
        (work / 'untracked').write_text('unique untracked')
        m.bind(ident, session_id='fixture', agent_id='agent-fixture')
        m.terminal(ident, session_id='fixture', agent_id='agent-fixture')
        result = m.reconcile(ident)
        self.assertEqual(result['state'], 'retained', result)
        self.assertFalse((m._base(ident) / 'image.sparsebundle').exists())
        self.assertEqual(git(source, 'rev-parse', 'refs/richos/handoffs/managed/'+ident+'/HEAD'), terminal)
        self.assertEqual(git(source, 'rev-parse', 'refs/richos/handoffs/managed/'+ident+'/reflog/'+abandoned), abandoned)
        self.assertEqual(git(source, 'show', abandoned+':abandoned'), 'reflog-only work')
        self.assertEqual(git(source, 'for-each-ref', '--format=%(refname)', 'refs/heads/dev-opus-fixture'), '')
        self.assertEqual(m.delivery(ident)['tip'], terminal)
        self.assertEqual(result['delivery_mode'], 'handoff-ref-v1')
        recovery = m._base(ident) / 'recovery.dmg'
        mount = root / 'inspect'
        mount.mkdir()
        mounted = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-plist', '-readonly', '-mountpoint', str(mount), str(recovery)]))
        device = m.provider._device(mounted)
        try:
            self.assertEqual((mount / 'repo/tracked').read_text(), 'working version')
            self.assertEqual((mount / 'repo/untracked').read_text(), 'unique untracked')
            self.assertEqual(git(mount / 'repo', 'show', ':tracked'), 'index version')
            try:
                (mount / 'repo/tracked').write_text('illegal late write')
                self.fail('recovery writable')
            except OSError:
                pass
        finally:
            subprocess.check_call(['/usr/bin/hdiutil', 'detach', device], stdout=subprocess.DEVNULL)
        result = m.reconcile(ident, now=result['expires_at']+1)
        self.assertEqual(result['state'], 'retained', result)
        self.assertIn('no expiry authorization', result['last_error'])
        self.assertTrue(recovery.exists())
        self.assertEqual(git(source, 'show', terminal+':delivered'), 'terminal commit')
        manager.shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
