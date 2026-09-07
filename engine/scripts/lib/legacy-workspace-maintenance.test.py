#!/usr/bin/env python3
"""Read-only maintenance planning in disposable real repositories."""
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('legacy_plan', Path(__file__).with_name('legacy-workspace-maintenance.py'))
planner = importlib.util.module_from_spec(spec);spec.loader.exec_module(planner)


class LegacyPlan(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='legacy-maintenance-plan-');self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve();self.repo = self.root / 'repo';self.repo.mkdir()
        self.git('init', '-q', '-b', 'main');self.git('config', 'user.name', 'fixture');self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'file').write_text('base');self.git('add', 'file');self.git('commit', '-qm', 'base')
        self.head = self.git('rev-parse', 'HEAD');self.work = self.root / 'external-worker'
        self.git('worktree', 'add', '-qb', 'worker', str(self.work))
        self.policy = {'version': 1, 'repositories': {'approved': {'path': str(self.repo)}}}
        self.tx = dict(record='transaction', sealed=True, session_id='session', agent_id='agent',
            sealed_ts='2026-09-01T10:00:00Z', terminal={'ts': '2026-09-01T11:00:00Z'},
            members=[dict(path=str(self.work), repo=str(self.repo), branch='worker', head=self.head)])

    def git(self, *args):
        return subprocess.check_output(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(self.repo), *args],
            env=dict(PATH='/usr/bin:/bin', HOME='/var/empty', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null'),
            stderr=subprocess.PIPE).decode().strip()

    def plan(self, transactions=None, records=(), **kwargs):
        return planner.plan(self.policy, [self.tx] if transactions is None else transactions, records, **kwargs)

    def test_every_registered_workspace_gated_but_only_exact_terminal_is_candidate(self):
        other = self.root / 'active-other';self.git('worktree', 'add', '-qb', 'active-other', str(other))
        before = (self.git('worktree', 'list', '--porcelain'), self.git('show-ref'))
        report = self.plan(active_paths=[str(other)])
        row = report['repositories'][0]
        self.assertEqual({gate['path'] for gate in row['gate_paths']}, {str(self.repo), str(self.work), str(other)})
        self.assertEqual([member['path'] for member in row['removal_candidates']], [str(self.work)])
        self.assertTrue(any('live-owner:' + str(other) == b for b in row['blockers']))
        self.assertFalse(report['execution_ready']);self.assertFalse(row['maintenance_ready'])
        self.assertEqual(before, (self.git('worktree', 'list', '--porcelain'), self.git('show-ref')))
        self.assertEqual(row['common_git_directory']['inode'], (self.repo / '.git').stat().st_ino)

    def test_current_live_process_on_another_registered_workspace_vetoes(self):
        record = dict(event='registered', cwd=str(self.repo), session_id='running', session_pid=os.getpid(),
                      pid_start=planner.ledger.pid_start(os.getpid()))
        row = self.plan(records=[record])['repositories'][0]
        self.assertIn('live-owner:' + str(self.repo), row['blockers'])

    def test_resumed_session_elsewhere_cannot_hide_live_owner(self):
        records = [dict(event='registered', worktree=str(self.work), repo=str(self.repo), session_id='same',
                        session_pid=999999999, pid_start='legacy'),
                   dict(event='session', cwd='/unrelated', session_id='same', session_pid=os.getpid(),
                        pid_start=planner.ledger.pid_start(os.getpid()))]
        self.assertIn('live-owner:' + str(self.work), self.plan(records=records)['repositories'][0]['blockers'])

    def test_unknown_ownership_and_incomplete_terminal_are_blockers(self):
        self.tx['terminal'] = None
        row = self.plan()['repositories'][0]
        self.assertIn('unknown-owner:' + str(self.work), row['blockers'])
        self.assertEqual(row['removal_candidates'], [])

    def test_terminal_head_or_repository_mismatch_is_not_a_candidate(self):
        for change in ({'head': 'a'*40}, {'repo': str(self.root / 'unknown')}):
            tx = copy.deepcopy(self.tx);tx['members'][0].update(change)
            row = self.plan([tx])['repositories'][0]
            self.assertEqual(row['removal_candidates'], [])
            self.assertIn('terminal-member-identity-mismatch:' + str(self.work), row['blockers'])

    def test_nested_registered_workspace_keeps_identity_under_consolidated_root(self):
        nested = self.repo / 'nested';self.git('worktree', 'add', '-qb', 'nested', str(nested))
        row = self.plan()['repositories'][0]
        self.assertFalse(any(b.startswith('overlapping-gate-paths:') for b in row['blockers']))
        self.assertEqual({g['path'] for g in row['gate_roots']},{str(self.repo),str(self.work)})
        target=next(g for g in row['gate_paths'] if g['path']==str(nested))
        self.assertEqual((target['gate_root'],target['relative_path']),(str(self.repo),'nested'))
        self.assertIn('unknown-owner:'+str(nested),row['blockers'])

    def test_shared_parent_scope_includes_unrelated_sibling_entries(self):
        sibling=self.root/'unrelated-active-repo';sibling.mkdir()
        row=self.plan()['repositories'][0]
        parent=next(p for p in row['temporary_parent_gates'] if p['path']==str(self.root))
        self.assertIn(sibling.name,parent['affected_entries'])
        self.assertIn('sibling',row['required_downtime'])

    def test_nested_independent_repository_is_still_an_overlapping_gate_error(self):
        nested=self.repo/'separate-repository';self.git('init','-q','-b','main',str(nested))
        self.git('-C',str(nested),'config','user.name','fixture');self.git('-C',str(nested),'config','user.email','fixture@example.invalid')
        (nested/'file').write_text('separate');self.git('-C',str(nested),'add','file');self.git('-C',str(nested),'commit','-qm','separate')
        self.policy['repositories']['separate']={'path':str(nested)}
        report=self.plan()
        self.assertTrue(all(any(b.startswith('overlapping-gate-paths:') for b in row['blockers']) for row in report['repositories']))

    def test_external_object_alternates_are_not_covered_by_common_directory_gate(self):
        external = self.root / 'external-objects';external.mkdir()
        (self.repo / '.git/objects/info/alternates').write_text(str(external) + '\n')
        row = self.plan()['repositories'][0]
        self.assertIn('external-object-dependencies-need-separate-gates', row['blockers'])
        self.assertTrue(row['object_storage']['external_dependencies'])
        self.assertFalse(row['maintenance_ready'])

    def test_promisor_configuration_requires_dependency_review(self):
        self.git('config', 'remote.origin.promisor', 'true')
        row = self.plan()['repositories'][0]
        self.assertIn('external-object-dependencies-need-separate-gates', row['blockers'])

    def test_symlinked_loose_object_bucket_is_an_external_dependency(self):
        objects = self.repo / '.git/objects'
        bucket = next(path for path in objects.iterdir() if path.is_dir() and len(path.name) == 2)
        external = self.root / 'external-bucket';bucket.rename(external)
        bucket.symlink_to(external, target_is_directory=True)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        row = self.plan()['repositories'][0]
        self.assertIn('external-object-dependencies-need-separate-gates', row['blockers'])
        self.assertIn('external-object-path:' + str(bucket), row['object_storage']['external_dependencies'])

    def test_symlinked_individual_object_is_an_external_dependency(self):
        objects = self.repo / '.git/objects'
        bucket = next(path for path in objects.iterdir() if path.is_dir() and len(path.name) == 2)
        original = next(bucket.iterdir());external = self.root / 'external-object'
        original.rename(external);original.symlink_to(external)
        row = self.plan()['repositories'][0]
        self.assertIn('external-object-path:' + str(original), row['object_storage']['external_dependencies'])

    def test_symlink_policy_is_not_silently_canonicalized(self):
        alias = self.root / 'alias';alias.symlink_to(self.repo, target_is_directory=True)
        self.policy['repositories']['approved']['path'] = str(alias)
        self.assertIn('symlink path component', self.plan()['repositories'][0]['blockers'][0])

    def test_missing_registered_path_is_retained_as_review_blocker(self):
        other = self.root / 'later-worker';self.git('worktree', 'add', '-qb', 'later', str(other))
        self.work.rename(self.root / 'preserved')
        row = self.plan()['repositories'][0]
        self.assertTrue(any(b.startswith('inventory-unavailable:') for b in row['blockers']))
        self.assertTrue(any(gate['path'] == str(self.work) for gate in row['gate_paths']))
        self.assertTrue((self.root / 'preserved/file').exists())
        self.assertFalse(row['inventory_complete'])
        self.assertEqual(len(row['registered_worktrees']), 3)
        remaining = next(gate for gate in row['gate_paths'] if gate['path'] == str(other))
        self.assertEqual(remaining['identity']['inode'], other.stat().st_ino)

    def test_same_inode_git_pointer_change_invalidates_inventory(self):
        original = planner.registry;calls = []
        pointer = self.work / '.git';before = pointer.stat().st_ino
        def changed(repo):
            result = original(repo);calls.append(repo)
            if len(calls) == 2:
                with pointer.open('a') as stream:
                    stream.write('\n')
            return result
        with patch.object(planner, 'registry', side_effect=changed):
            row = self.plan()['repositories'][0]
        self.assertEqual(before, pointer.stat().st_ino)
        self.assertFalse(row['inventory_complete'])
        self.assertTrue(any('Git pointer changed' in blocker for blocker in row['blockers']))

    def test_malformed_registry_cannot_yield_complete_inventory(self):
        original = planner.history._git
        def git(repo, *args):
            if args[:2] == ('worktree', 'list'):
                return subprocess.CompletedProcess([], 0, 'malformed\0\0', '')
            return original(repo, *args)
        with patch.object(planner.history, '_git', side_effect=git):
            row = self.plan()['repositories'][0]
        self.assertTrue(any(b.startswith('inventory-unavailable:') for b in row['blockers']))

    def test_incomplete_history_and_unapproved_active_path_veto(self):
        elsewhere = self.root / 'outside';elsewhere.mkdir()
        report = self.plan(active_paths=[str(elsewhere)], input_errors=['corrupt ledger'])
        self.assertIn('corrupt ledger', report['errors'])
        self.assertTrue(any('outside approved' in error for error in report['errors']))
        self.assertFalse(report['execution_authorized'])

    def test_duplicate_repo_aliases_are_not_two_independent_gate_sets(self):
        self.policy['repositories']['duplicate'] = {'path': str(self.repo)}
        report = self.plan()
        self.assertTrue(any('same Git repository' in b for r in report['repositories'] for b in r['blockers']))

    def test_policy_pointing_at_linked_checkout_is_refused(self):
        self.policy['repositories']['approved']['path'] = str(self.work)
        self.assertTrue(any('canonical checkout' in b for b in self.plan()['repositories'][0]['blockers']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
