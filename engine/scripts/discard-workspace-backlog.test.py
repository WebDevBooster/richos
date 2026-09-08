#!/usr/bin/env python3
"""Actual-Git controls for the explicit one-time discard boundary."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('discard', Path(__file__).with_name('discard-workspace-backlog.py'))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class DiscardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='richos-discard-test-')
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'main'
        self.repo.mkdir()
        d.git(self.repo, 'init', '-b', 'main')
        (self.repo / 'tracked').write_text('baseline\n')
        d.git(self.repo, 'add', 'tracked')
        d.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
              'commit', '-m', 'baseline')
        self.dead = self.root / 'dead'
        self.active = self.root / 'active'
        d.git(self.repo, 'worktree', 'add', '-b', 'finished', str(self.dead))
        d.git(self.repo, 'worktree', 'add', '-b', 'ongoing', str(self.active))
        tip = d.git(self.repo, 'rev-parse', 'HEAD')
        rows = {r['worktree']: r for r in d.inventory(self.repo)}
        self.manifest = {'version': 1, 'discard_dead_contents': True,
                         'authorization': 'Disposable fixture test authority',
                         'deadness_evidence': 'This test owns and has no worker in dead',
                         'expires_at': time.time() + 600,
                         'protected_roots': [str(self.repo), str(self.active)],
                         'repositories': [{'path': str(self.repo), 'identity': d.identity(self.repo),
                                           'integration_ref': 'refs/heads/main', 'integration_tip': tip,
                                           'worktrees': [{'path': str(self.dead), 'identity': d.identity(self.dead),
                                                          'registration': rows[str(self.dead)]}],
                                           'branches': [{'ref': 'refs/heads/finished', 'tip': tip}]}]}

    def tearDown(self):
        self.tmp.cleanup()

    def run_discard(self):
        events = []
        results = d.discard(self.manifest, events.append)
        self.assertEqual([e for e in events if e['status'] not in
                         ('removal-started', 'branch-transaction-started')], results)
        return results

    def test_explicit_discard_removes_dirty_staged_ignored_bytes_and_branch(self):
        (self.dead / 'tracked').write_text('uncommitted\n')
        (self.dead / 'staged').write_text('unpublished\n')
        d.git(self.dead, 'add', 'staged')
        (self.dead / '.gitignore').write_text('cache/\n')
        (self.dead / 'cache').mkdir()
        (self.dead / 'cache' / 'data').write_bytes(b'ignored bytes')
        results = self.run_discard()
        self.assertFalse(self.dead.exists())
        self.assertEqual(results[-1]['refs'], ['refs/heads/finished'])
        self.assertTrue((self.active / 'tracked').exists())
        self.assertEqual((self.repo / 'tracked').read_text(), 'baseline\n')

    def test_active_and_canonical_selection_refused_before_mutation(self):
        for protected in (self.active, self.repo):
            manifest = copy.deepcopy(self.manifest)
            row = manifest['repositories'][0]['worktrees'][0]
            row['path'] = str(protected)
            row['identity'] = d.identity(protected)
            row['registration'] = next(r for r in d.inventory(self.repo) if r['worktree'] == str(protected))
            with self.assertRaises(ValueError):
                d.discard(manifest, lambda _: self.fail('Unexpected mutation event'))
            self.assertTrue(self.dead.exists())

    def test_replaced_directory_refused(self):
        self.dead.rename(self.root / 'original-dead')
        self.dead.mkdir()
        with self.assertRaisesRegex(ValueError, '(identity|registration) changed'):
            self.run_discard()
        self.assertTrue(self.dead.exists())

    def test_symbolic_branch_refused_without_removing_target(self):
        d.git(self.repo, 'symbolic-ref', 'refs/heads/finished', 'refs/heads/ongoing')
        with self.assertRaises(ValueError):
            self.run_discard()
        self.assertTrue(self.dead.exists())
        self.assertTrue(d.git(self.repo, 'rev-parse', 'refs/heads/ongoing'))

    def test_newly_checked_out_branch_refused(self):
        self.manifest['repositories'][0]['branches'].append({
            'ref': 'refs/heads/ongoing', 'tip': d.git(self.repo, 'rev-parse', 'refs/heads/ongoing')})
        with self.assertRaisesRegex(ValueError, 'outside the approved dead list'):
            self.run_discard()
        self.assertTrue(self.dead.exists())

    def test_stale_manifest_refused(self):
        self.manifest['expires_at'] = time.time() - 1
        with self.assertRaisesRegex(ValueError, 'freshly reviewed'):
            self.run_discard()

    def test_journal_inside_discarded_tree_refused(self):
        with self.assertRaisesRegex(ValueError, 'outside every selected worktree'):
            d.journal_path(self.dead / 'operation.jsonl', self.manifest)
        self.assertEqual(d.journal_path(self.root / 'operation.jsonl', self.manifest),
                         self.root / 'operation.jsonl')

    def test_unmerged_commit_discarded_under_explicit_authority(self):
        (self.dead / 'tracked').write_text('unmerged change\n')
        d.git(self.dead, 'add', 'tracked')
        d.git(self.dead, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
              'commit', '-m', 'never merged')
        group = self.manifest['repositories'][0]
        group['worktrees'][0]['registration'] = next(r for r in d.inventory(self.repo)
                                                     if r['worktree'] == str(self.dead))
        group['branches'][0]['tip'] = d.git(self.dead, 'rev-parse', 'HEAD')
        self.run_discard()
        self.assertFalse(self.dead.exists())
        self.assertEqual(d.git(self.repo, 'for-each-ref', '--format=%(refname)',
                              'refs/heads/finished'), '')

    def test_interruption_after_removal_has_per_target_receipt(self):
        events = []
        class Interrupted(BaseException):
            pass
        def emit(row):
            events.append(row)
            if row['status'] == 'removed':
                raise Interrupted()
        with self.assertRaises(Interrupted):
            d.discard(self.manifest, emit)
        self.assertFalse(self.dead.exists())
        self.assertEqual([e['status'] for e in events], ['removal-started', 'removed'])
        self.assertTrue(d.git(self.repo, 'rev-parse', 'refs/heads/finished'))


if __name__ == '__main__':
    unittest.main()
