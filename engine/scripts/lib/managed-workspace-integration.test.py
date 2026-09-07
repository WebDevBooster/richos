#!/usr/bin/env python3
"""Managed membership and terminal routing contract tests."""
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import uuid


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HERE = Path(__file__).parent
bridge = load('bridge', HERE / 'managed-workspace-integration.py')
tx = load('tx', HERE / 'worktree-transactions.py')
reconciler = load('reconciler', HERE.parent / 'reconcile-terminal-worktrees.py')


class Membership(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='richos-managed-membership-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.ident = str(uuid.uuid4())
        self.work = self.root / 'active' / self.ident / 'repo'
        self.work.mkdir(parents=True)
        self.record = dict(manager_id=self.ident, id=self.ident, workspace_class='managed-image',
                           path=str(self.work), state='active', source_repo=str(self.root / 'canonical'),
                           session_id='session', agent_name='dev-opus-test', agent_id=None)
        self.config = dict(version=1, socket='/fixed/socket', active_root=str(self.root / 'active'),
                           repositories={'canonical': str(self.root / 'canonical')})
        self.member = dict(manager_id=self.ident, **{'class':'managed-image'}, path=str(self.work),
                           repo=self.record['source_repo'], session_id='session', agent_name='dev-opus-test', branch='dev-opus-test')
        self.patches = [patch.object(bridge, 'config', return_value=self.config),
                        patch.object(bridge, 'request', side_effect=lambda *a, **k: copy.deepcopy(self.record))]
        for p in self.patches:
            p.start(); self.addCleanup(p.stop)

    def test_delivery_query_binds_exact_repo_manager_ref_and_tip(self):
        delivery = dict(manager_id=self.ident, source_repo=self.member['repo'],
                        ref='refs/richos/handoffs/managed/'+self.ident+'/HEAD', tip='a'*40)
        bridge.request.side_effect = lambda *a, **k: copy.deepcopy(delivery)
        self.assertEqual(bridge.delivery_for(self.ident, self.member['repo']), delivery)
        for key, wrong in [('manager_id', str(uuid.uuid4())), ('source_repo', '/wrong'),
                           ('ref', 'refs/heads/reused'), ('tip', 'HEAD')]:
            altered = dict(delivery); altered[key] = wrong
            bridge.request.side_effect = lambda *a, **k: copy.deepcopy(altered)
            with self.assertRaisesRegex(RuntimeError, 'delivery identity'):
                bridge.delivery_for(self.ident, self.member['repo'])

    def test_new_reclaimed_record_requires_exact_delivery(self):
        self.record.update(state='retained', agent_id='agent-one', delivery_mode='handoff-ref-v1')
        with self.assertRaisesRegex(RuntimeError, 'no delivery'):
            bridge.terminal_member(self.member, 'session', 'agent-one')
        self.record['delivery'] = dict(manager_id=self.ident, source_repo=self.member['repo'],
                        ref='refs/richos/handoffs/managed/'+self.ident+'/HEAD', tip='a'*40)
        self.assertEqual(bridge.terminal_member(self.member, 'session', 'agent-one')['delivery'], self.record['delivery'])

    def test_exact_prepared_identity_is_accepted(self):
        self.assertEqual(bridge.verify_member(self.member)['manager_id'], self.ident)

    def test_same_shape_outside_namespace_is_refused(self):
        with self.assertRaises(RuntimeError):
            bridge.inspect_path(str(self.root / 'outside' / self.ident / 'repo'))
        bridge.request.assert_not_called()

    def test_same_name_different_session_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'session mismatch'):
            bridge.inspect_path(str(self.work), session_id='other')

    def test_replaced_symlink_is_refused(self):
        self.work.rmdir(); self.work.symlink_to(self.root)
        with self.assertRaises(RuntimeError):
            bridge.verify_member(self.member)

    def test_prepared_canonical_repo_drift_is_refused(self):
        self.member['repo'] = str(self.root / 'different')
        with self.assertRaises(RuntimeError):
            bridge.verify_member(self.member)

    def test_terminal_workspace_cannot_be_spawned_into(self):
        self.record['state'] = 'terminal'
        with self.assertRaises(RuntimeError):
            bridge.verify_member(self.member)

    def test_broker_unavailable_never_falls_back_to_git_shape(self):
        bridge.request.side_effect = OSError('broker down')
        with self.assertRaises(OSError):
            bridge.verify_member(self.member)

    def test_changed_binding_acknowledgement_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            bridge.bind_member(self.member, 'session', 'agent-one')

    def test_unbound_or_wrong_terminal_acknowledgement_is_refused(self):
        self.record.update(state='terminal', agent_id='wrong')
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            bridge.terminal_member(self.member, 'session', 'agent-one')

    def test_wrong_terminal_receipt_id_is_refused(self):
        self.record.update(state='terminal', agent_id='agent-one', id=str(uuid.uuid4()))
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            bridge.terminal_member(self.member, 'session', 'agent-one')

    def test_stale_alias_cannot_authorize_seeding_another_repository(self):
        self.record.update(source_repo=str(self.root / 'another'), source_commit='a'*40)
        with self.assertRaisesRegex(RuntimeError, 'source or identity mismatch'):
            bridge.create(repo=self.root / 'canonical', commit='a'*40, session_id='session',
                          agent_name='dev-opus-test', request_id='request')

    def test_creation_receipt_must_match_requested_commit(self):
        self.record['source_commit'] = 'b'*40
        with self.assertRaisesRegex(RuntimeError, 'source or identity mismatch'):
            bridge.create(repo=self.root / 'canonical', commit='a'*40, session_id='session',
                          agent_name='dev-opus-test', request_id='request')


class LifecycleRouting(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='richos-managed-routing-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        p = patch.dict(os.environ, {'RICHOS_WORKTREE_TX_DIR': str(self.root / 'tx')})
        p.start(); self.addCleanup(p.stop)
        self.sid, self.aid = 'session-test', 'agent-test'
        self.member = dict(**{'class':'managed-image'}, manager_id=str(uuid.uuid4()),
                           path=str(self.root / 'workspace'), repo=str(self.root / 'canonical'),
                           branch='dev-opus-test', state='bound')
        self.record = dict(record='transaction', session_id=self.sid, agent_id=self.aid,
                           teammate='dev-opus-test', sealed=True, state='terminal',
                           terminal=dict(ts=tx.now_iso()), members=[self.member])
        tx.atomic_write_json(tx.tx_path(self.sid, self.aid), self.record)
        self.service = Mock()
        self.service.terminal_member.return_value = dict(id=self.member['manager_id'], state='terminal')

    def test_terminal_routing_never_renames_or_runs_legacy_ref_capture(self):
        with patch.object(tx, '_managed_workspaces', return_value=self.service), \
                patch.object(tx, 'save_ref') as save, patch.object(tx, 'quarantine') as quarantine:
            result = tx.terminalize(self.sid, self.aid)
        save.assert_not_called(); quarantine.assert_not_called()
        self.service.terminal_member.assert_called_once_with(self.member, self.sid, self.aid)
        self.assertEqual(result['members'][0]['state'], 'managed-terminal')

    def test_failed_terminal_notification_preserves_member_for_retry(self):
        self.service.terminal_member.side_effect = OSError('broker down')
        with patch.object(tx, '_managed_workspaces', return_value=self.service):
            result = tx.terminalize(self.sid, self.aid)
        self.assertEqual(result['members'][0]['state'], 'bound')
        self.assertIn('broker down', result['members'][0]['last_error'])

    def test_repeated_terminal_ingress_does_not_reopen_completed_member(self):
        self.record['members'][0]['state'] = 'removed'
        self.record['state'] = 'removed'
        tx.atomic_write_json(tx.tx_path(self.sid, self.aid), self.record)
        with patch.object(tx, '_managed_workspaces', return_value=self.service):
            result = tx.terminalize(self.sid, self.aid)
        self.service.terminal_member.assert_not_called()
        self.assertEqual(result['members'][0]['state'], 'removed')

    def test_managed_retry_obeys_persistent_backoff(self):
        self.record['members'][0]['retry_after_epoch'] = time.time()+600
        tx.atomic_write_json(tx.tx_path(self.sid, self.aid), self.record)
        with patch.object(reconciler, 'retry_backoff', return_value=(10, 600)), \
                patch.object(reconciler.tx, '_managed_workspaces', return_value=self.service):
            reconciler.reconcile_transaction(self.record)
        self.service.terminal_member.assert_not_called()

    def test_reconciler_waits_for_actual_reclamation(self):
        with patch.object(reconciler.tx, '_managed_workspaces', return_value=self.service):
            reconciler.reconcile_transaction(self.record)
        self.assertNotEqual(tx.load_tx(self.sid, self.aid)['members'][0]['state'], 'removed')
        self.assertNotIn('reconcile', self.service.terminal_member.call_args.kwargs)

    def test_reconciler_acknowledges_verified_reclamation(self):
        delivery = dict(manager_id=self.member['manager_id'], source_repo=self.member['repo'],
                        ref='refs/richos/handoffs/managed/'+self.member['manager_id']+'/HEAD', tip='a'*40)
        self.service.terminal_member.return_value = dict(id=self.member['manager_id'], state='retained', delivery=delivery)
        with patch.object(reconciler.tx, '_managed_workspaces', return_value=self.service):
            reconciler.reconcile_transaction(self.record)
        self.assertEqual(tx.load_tx(self.sid, self.aid)['members'][0]['state'], 'removed')
        self.assertEqual(tx.load_tx(self.sid, self.aid)['members'][0]['delivery'], delivery)

    def test_seal_refuses_branch_drift(self):
        self.service.verify_member.return_value = dict(id=self.member['manager_id'])
        with patch.object(tx, '_managed_workspaces', return_value=self.service), \
                patch.object(tx, 'branch_of', return_value='someone-else'):
            member, reason = tx._verify_external_member(self.member)
        self.assertIsNone(member)
        self.assertIn('branch changed', reason)


class Preparation(unittest.TestCase):
    def test_live_and_unknown_sessions_keep_unused_preparations(self):
        service = Mock()
        service.session_gone_by_exhaustion.side_effect = [('alive', 'resumed'), ('unknown', 'unreadable')]
        rows = [dict(id=str(uuid.uuid4()), session_id='session'+str(i)) for i in range(2)]
        with patch.object(bridge, 'config', return_value={}), \
                patch.object(bridge, '_module', return_value=service), \
                patch.object(bridge, 'request', return_value={'records': rows}) as call:
            result = bridge.recover_preparations()
        self.assertEqual([row['state'] for row in result], ['retained', 'retained'])
        self.assertEqual(call.call_count, 1)

    def test_gone_session_closes_only_exact_preparation_without_slow_capture(self):
        service = Mock()
        service.session_gone_by_exhaustion.return_value = ('gone', 'accounted')
        ident = str(uuid.uuid4())
        before = time.time()
        with patch.object(bridge, 'config', return_value={}), \
                patch.object(bridge, '_module', return_value=service), \
                patch.object(bridge, 'request', side_effect=[
                    {'records': [dict(id=ident, session_id='session', created_at=1)]},
                    dict(id=ident, session_id='session', agent_id=None, state='terminal',
                         terminal_ingress='abandoned-preparation')]) as call:
            self.assertEqual(bridge.recover_preparations(), [dict(id=ident, state='terminal')])
        self.assertGreaterEqual(service.session_gone_by_exhaustion.call_args.args[1], before)
        call.assert_called_with(dict(operation='cancel_preparation', id=ident, session_id='session'))

    def test_live_first_page_does_not_hide_later_abandoned_preparation(self):
        service = Mock()
        service.session_gone_by_exhaustion.side_effect = [('alive', 'active'), ('gone', 'accounted')]
        first, second = str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        with patch.object(bridge, 'config', return_value={}), \
                patch.object(bridge, '_module', return_value=service), \
                patch.object(bridge, 'request', side_effect=[
                    dict(records=[dict(id=first, session_id='live')], next_cursor=first),
                    dict(records=[dict(id=second, session_id='gone')], next_cursor=None),
                    dict(id=second, session_id='gone', agent_id=None, state='terminal',
                         terminal_ingress='abandoned-preparation')]) as call:
            results = bridge.recover_preparations()
        self.assertEqual([row['state'] for row in results], ['retained', 'terminal'])
        self.assertEqual(call.call_args_list[1].args[0], dict(operation='preparations', after=first))

    def test_scoped_reconciliation_does_not_cancel_other_preparations(self):
        service = Mock()
        with patch.object(reconciler.tx, '_managed_workspaces', return_value=service), \
                patch.object(reconciler, 'process_pending_terminals', return_value=0), \
                patch.object(reconciler, 'orphan_backstop_pass', return_value=0), \
                patch.object(reconciler.tx, 'iter_transactions', return_value=[]), \
                patch.object(reconciler, 'retention_pass'), patch.object(reconciler.tx, 'atomic_write_json'):
            reconciler.run(only='session/worker')
        service.recover_preparations.assert_not_called()

    def test_creation_helper_keeps_existing_source_branch_and_reports_delivery_query(self):
        with tempfile.TemporaryDirectory(prefix='richos-delivery-helper-') as directory:
            root = Path(directory).resolve()
            repo = root / 'repo'; repo.mkdir()
            scripts = root / 'scripts'; (scripts / 'lib').mkdir(parents=True)
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
            def git(*args):
                return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *args], env=env,
                                               stderr=subprocess.PIPE).decode().strip()
            git('init', '-q'); git('-c', 'user.name=fixture', '-c', 'user.email=x@example.invalid',
                                  'commit', '--allow-empty', '-qm', 'initial')
            name = 'dev-opus-fixture'; git('branch', name)
            original = git('rev-parse', 'refs/heads/'+name)
            ident = str(uuid.uuid4()); work = root / 'active' / ident / 'repo'; work.mkdir(parents=True)
            record = dict(manager_id=ident, path=str(work))
            (scripts / 'lib' / 'managed-workspace-integration.py').write_text(
                'import json,sys\nprint('+repr(__import__('json').dumps(record))+')\n')
            (scripts / 'lib' / 'worktree-ledger.py').write_text('import sys\nprint("fixture")\n')
            helper = scripts / 'create-teammate-worktree.sh'
            helper.write_bytes((HERE.parent / helper.name).read_bytes())
            result = subprocess.run(['bash', str(helper), str(repo), name, '--session', 'session', '--pid', '123'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('delivery --id '+ident, result.stdout)
            self.assertIn('Merge the returned exact tip', result.stdout)
            self.assertEqual(git('rev-parse', 'refs/heads/'+name), original)
            self.assertEqual(git('worktree', 'list', '--porcelain').count('worktree '), 1)

    def test_missing_bridge_cannot_fall_back_when_managed_mode_is_enabled(self):
        with tempfile.TemporaryDirectory(prefix='richos-preparation-refusal-') as directory:
            root = Path(directory)
            repo = root / 'repo'; repo.mkdir()
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
            subprocess.check_call(['/usr/bin/git', 'init', '-q', str(repo)], env=env)
            scripts = root / 'scripts'; (scripts / 'lib').mkdir(parents=True)
            (scripts / 'lib/worktree-ledger.py').write_text('# fixture asset\n')
            config = root / 'client.json'; config.write_text('{}')
            helper = scripts / 'create-teammate-worktree.sh'
            source = (HERE.parent / 'create-teammate-worktree.sh').read_text()
            source = source.replace('/Library/Application Support/RichOS/ManagedWorkspaces/client.json', str(config))
            helper.write_text(source)
            result = subprocess.run(['bash', str(helper), str(repo), 'dev-opus-fixture', '--session', 'session'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertIn('integration module is missing', result.stderr)
            self.assertFalse((root / 'repo-wt').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
