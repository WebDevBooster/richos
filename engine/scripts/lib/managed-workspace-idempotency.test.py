#!/usr/bin/env python3
"""Stable request replay and creation interruption in isolated real Git fixtures."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('manager', Path(__file__).with_name('managed-workspace-manager.py'))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class CreationReplay(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos-create-replay-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.m = manager.WorkspaceManager(self.root / 'private', self.root / 'active', require_root=False)
        self.source = self.root / 'source';self.source.mkdir()
        self.git(self.source, 'init', '-q')
        self.git(self.source, 'config', 'user.name', 'fixture')
        self.git(self.source, 'config', 'user.email', 'fixture@example.invalid')
        (self.source / 'file').write_text('original')
        self.git(self.source, 'add', 'file');self.git(self.source, 'commit', '-qm', 'fixture')
        self.head = self.git(self.source, 'rev-parse', 'HEAD')
        self.args = dict(request_id='stable-caller-request', source_repo=self.source, commit=self.head,
                         owner_uid=os.getuid(), owner_gid=os.getgid(), session_id='session',
                         agent_name='dev-opus-fixture', size='128m')
        self.created = []
        self.provider_records = {}
        self.boot = str(uuid.uuid4())
        boot = patch.object(self.m.provider, '_boot_id', return_value=self.boot)
        boot.start();self.addCleanup(boot.stop)

        def provider_create(ident, source, commit, *, owner_uid, owner_gid, size):
            self.created.append(ident)
            self.m._base(ident).mkdir(mode=0o700)
            mount = self.m.provider.active_root / ident;mount.mkdir(mode=0o700)
            self.git(self.root, 'clone', '-q', '--no-local', '--no-checkout', str(source), str(mount / 'repo'))
            self.git(mount / 'repo', 'checkout', '-q', '--detach', commit)
            self.provider_records[ident] = dict(initialized=True, state='attached_writable', operation=None,
                                               owner_uid=owner_uid, owner_gid=owner_gid, commit=commit,
                                               boot_id=self.boot, device='/dev/disk999',
                                               attachment={'writeable': True, 'system-entities': [
                                                   {'content-hint': 'GUID_partition_scheme', 'dev-entry': '/dev/disk999'},
                                                   {'mount-point': str(mount), 'dev-entry': '/dev/disk1000s1'}]})
            return self.provider_records[ident]
        self.provider_create = provider_create
        for name, replacement in (('create', provider_create), ('inspect', lambda ident: self.provider_records[ident])):
            mocked = patch.object(self.m.provider, name, side_effect=replacement)
            mocked.start();self.addCleanup(mocked.stop)
        # These fixtures can run as root in Linux CI without granting root to
        # production Git. Substitute only credential execution, using real Git.
        def user_git(args, owner, *, cwd, **kwargs):
            return self.run_git(cwd, *args).stdout
        mocked = patch.object(self.m, '_user_git', side_effect=user_git)
        mocked.start();self.addCleanup(mocked.stop)

    @staticmethod
    def run_git(repo, *args):
        return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(repo), *args],
                              env=dict(PATH='/usr/bin:/bin', HOME='/var/empty', GIT_CONFIG_GLOBAL='/dev/null',
                                       GIT_CONFIG_NOSYSTEM='1'), capture_output=True, check=True)

    def git(self, repo, *args):
        return self.run_git(repo, *args).stdout.decode().strip()

    def test_identical_retry_returns_one_initialized_worker_branch(self):
        first = self.m.create(**self.args)
        second = self.m.create(**self.args)
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(len(self.created), 1)
        self.assertTrue(second['branch_initialized'])
        self.assertEqual(self.git(self.m.provider.active_root / first['id'] / 'repo',
                                  'symbolic-ref', '--short', 'HEAD'), self.args['agent_name'])
        self.assertEqual(len(list(self.m.root.glob('*.request.json'))), 1)

    def test_changed_payload_is_refused_without_a_second_provider_call(self):
        self.m.create(**self.args)
        for change in (dict(commit='b'*40), dict(size='256m'), dict(agent_name='another'),
                       dict(retention_days=30), dict(session_id='another')):
            with self.subTest(change=change), self.assertRaises(manager.ManagerError):
                self.m.create(**dict(self.args, **change))
        self.assertEqual(len(self.created), 1)

    def test_concurrent_same_request_cannot_allocate_two_images(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.m.create(**self.args), range(2)))
        self.assertEqual(results[0]['id'], results[1]['id'])
        self.assertEqual(len(self.created), 1)

    def test_same_request_string_from_other_owner_has_distinct_namespace(self):
        first = self.m.create(**self.args)
        second = self.m.create(**dict(self.args, owner_uid=self.args['owner_uid'] + 1))
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(len(self.created), 2)

    def test_invalid_request_ids_fail_before_provider_side_effects(self):
        for token in ('', None, 42, 'x' * 129):
            with self.subTest(token=token), self.assertRaises(manager.ManagerError):
                self.m.create(**dict(self.args, request_id=token))
        self.assertEqual(self.created, [])

    def test_crash_after_provider_initialization_recovers_same_workspace(self):
        original = self.m._save
        with patch.object(self.m, '_save', side_effect=KeyboardInterrupt('journal crash')):
            with self.assertRaises(KeyboardInterrupt):
                self.m.create(**self.args)
        ident = self.created[0]
        result = self.m.create(**self.args)
        self.assertEqual(result['id'], ident)
        self.assertEqual(result['state'], 'active')
        self.assertEqual(self.created, [ident])

    def test_cancel_initialized_unpublished_workspace_uses_normal_terminal_recovery(self):
        with patch.object(self.m, '_save', side_effect=KeyboardInterrupt('journal crash')):
            with self.assertRaises(KeyboardInterrupt):
                self.m.create(**self.args)
        ident = self.created[0]
        self.m.cancel_preparation(ident, session_id='session')
        request = json.loads(next(self.m.root.glob('*.request.json')).read_text())
        recovered = self.m._recover_create(request)
        self.assertEqual(recovered['state'], 'terminal')
        self.assertEqual(recovered['terminal_ingress'], 'abandoned-preparation')
        self.assertFalse((self.m._base(ident) / 'failed-creation.json').exists())
        self.assertEqual(self.git(self.m.provider.active_root / ident / 'repo', 'rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.m.create(**self.args)['state'], 'terminal')
        recovered['state'] = 'retained'
        self.m._save(ident, recovered)
        self.provider_records.pop(ident)
        self.assertEqual(self.m.create(**self.args)['state'], 'retained')

    def test_cancel_between_branch_journal_and_active_prevents_activation(self):
        original = self.m._save
        def save(ident, record):
            if record['state'] == 'active':
                raise KeyboardInterrupt('activation crash')
            original(ident, record)
        with patch.object(self.m, '_save', side_effect=save), self.assertRaises(KeyboardInterrupt):
            self.m.create(**self.args)
        ident = self.created[0]
        self.assertEqual(self.m.cancel_preparation(ident, session_id='session')['state'], 'terminal')
        self.assertEqual(self.m.create(**self.args)['state'], 'terminal')

    def test_crash_between_branch_journal_and_active_recovers(self):
        original = self.m._save
        def save(ident, record):
            if record['state'] == 'active':
                raise KeyboardInterrupt('activation crash')
            original(ident, record)
        with patch.object(self.m, '_save', side_effect=save), self.assertRaises(KeyboardInterrupt):
            self.m.create(**self.args)
        ident = self.created[0]
        self.assertEqual(self.m.inspect(ident)['state'], 'creating')
        self.assertEqual(self.m.create(**self.args)['state'], 'active')
        self.assertEqual(self.created, [ident])

    def test_incomplete_provider_is_pending_and_never_duplicated(self):
        def incomplete(ident, *args, **kwargs):
            self.created.append(ident)
            self.m._base(ident).mkdir(mode=0o700)
            self.provider_records[ident] = dict(initialized=False)
            raise RuntimeError('image creation interrupted')
        with patch.object(self.m.provider, 'create', side_effect=incomplete), self.assertRaises(RuntimeError):
            self.m.create(**self.args)
        result = self.m.create(**self.args)
        self.assertEqual(result['state'], 'creation-incomplete')
        self.assertEqual(result['id'], self.created[0])
        self.assertEqual(len(self.created), 1)

    def test_sweep_recovers_initialized_provider_after_process_crash(self):
        with patch.object(self.m, '_save', side_effect=KeyboardInterrupt('journal crash')), self.assertRaises(KeyboardInterrupt):
            self.m.create(**self.args)
        result = self.m.sweep()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['id'], self.created[0])
        self.assertEqual(result[0]['state'], 'active')

    def test_retry_of_terminal_workspace_does_not_reactivate_it(self):
        first = self.m.create(**self.args)
        self.m.bind(first['id'], session_id='session', agent_id='agent')
        self.m.terminal(first['id'], session_id='session', agent_id='agent')
        retried = self.m.create(**self.args)
        self.assertEqual(retried['state'], 'terminal')
        self.assertEqual(len(self.created), 1)

    def test_reboot_retry_terminalizes_bound_and_unbound_without_reattach(self):
        for bound in (False, True):
            with self.subTest(bound=bound):
                args = dict(self.args, request_id='bound-' + str(bound))
                first = self.m.create(**args)
                if bound:
                    self.m.bind(first['id'], session_id='session', agent_id='agent')
                with patch.object(self.m.provider, '_boot_id', return_value=str(uuid.uuid4())), \
                        patch.object(self.m.provider, 'attach') as attach:
                    result = self.m.create(**args)
                self.assertEqual(result['state'], 'terminal')
                self.assertEqual(result['terminal_ingress'], 'machine-reboot')
                self.assertEqual(result['previous_boot_id'], self.boot)
                attach.assert_not_called()

    def test_unknown_boot_cannot_terminalize_or_report_active_retry(self):
        first = self.m.create(**self.args)
        for old in (None, 'invalid', 42):
            self.provider_records[first['id']]['boot_id'] = old
            with self.subTest(old=old), self.assertRaises(manager.ManagerError):
                self.m.create(**self.args)
            self.assertEqual(self.m._load(first['id'])['state'], 'active')

    def test_sweep_closes_old_boot_owner_before_reconciliation(self):
        first = self.m.create(**self.args)
        observed = []
        def reconcile(ident):
            record = self.m.inspect(ident);observed.append(record['state']);return record
        with patch.object(self.m.provider, '_boot_id', return_value=str(uuid.uuid4())), \
                patch.object(self.m, 'reconcile', side_effect=reconcile):
            result = self.m.sweep()
        self.assertEqual(observed, ['terminal'])
        self.assertEqual(result[0]['id'], first['id'])

    def test_old_boot_initialized_but_unpublished_create_never_reactivates(self):
        with patch.object(self.m, '_save', side_effect=KeyboardInterrupt('journal crash')), self.assertRaises(KeyboardInterrupt):
            self.m.create(**self.args)
        with patch.object(self.m.provider, '_boot_id', return_value=str(uuid.uuid4())), \
                patch.object(self.m.provider, 'attach') as attach:
            result = self.m.create(**self.args)
        self.assertEqual(result['state'], 'terminal')
        attach.assert_not_called()

    def test_same_boot_missing_or_wrong_mount_cannot_be_published(self):
        first = self.m.create(**self.args)
        original = self.provider_records[first['id']]['attachment']
        for attachment in (None, dict(original, writeable=False),
                           {'writeable': True, 'system-entities': [
                               {'content-hint': 'GUID_partition_scheme', 'dev-entry': '/dev/disk123'},
                               {'mount-point': str(self.root / 'wrong')}]}):
            self.provider_records[first['id']]['attachment'] = attachment
            with self.subTest(attachment=attachment):
                with self.assertRaises(manager.ManagerError):
                    self.m.create(**self.args)
                with self.assertRaises(manager.ManagerError):
                    self.m.inspect(first['id'])
                self.assertEqual(self.m._load(first['id'])['state'], 'active')

    def test_replaced_repository_cannot_be_published(self):
        first = self.m.create(**self.args)
        repo = self.m.provider.active_root / first['id'] / 'repo'
        repo.rename(repo.with_name('preserved'))
        repo.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(manager.ManagerError):
            self.m.inspect(first['id'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
