#!/usr/bin/env python3
"""workspace_scope.test.py — when a test run is an engineer's workspace iteration, and ci-shard.sh's
default there (CEO, 2026-10-01: the narrow run is the default, `--full` is one flag away, and the
merge gate, proof-run.py and the nightlies are never narrowed).

Every case builds a fixture repository (a `main` checkout plus linked worktrees) in TMPDIR.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(HERE))
import workspace_scope as ws  # noqa: E402

CLEAN = {k: v for k, v in os.environ.items() if k != ws.ENV}


def git(cwd, *args):
    out = subprocess.run(['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                          '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args],
                         cwd=cwd, capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError('git %s: %s' % (' '.join(args), out.stderr))
    return out.stdout.strip()


def repo(tmp, files):
    main = Path(tmp) / 'main'
    main.mkdir()
    git(main, 'init', '-q', '-b', 'main')
    for rel, text in files.items():
        p = main / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(0o755)
    git(main, 'add', '-A')
    git(main, 'commit', '-q', '-m', 'main')
    return main


def worktree(main, name, branch, detach=False):
    path = main.parent / name
    if detach:
        git(main, 'worktree', 'add', '-q', '--detach', str(path), 'main')
    else:
        git(main, 'worktree', 'add', '-q', '-b', branch, str(path), 'main')
    return path


class Decide(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='workspace-scope.')
        self.main = repo(self.tmp, {'a.txt': 'one\ntwo\nthree\nfour\n'})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_w1_a_cc_branch_in_a_linked_worktree_is_a_workspace(self):
        wt = worktree(self.main, 'wt', 'cc/fixture-one')
        got = ws.decide(str(wt), environ={})
        self.assertEqual((got['scope'], got['branch'], got['base']),
                         ('narrow', 'cc/fixture-one', git(self.main, 'rev-parse', 'main')))
        self.assertIn('teammate workspace cc/fixture-one', got['why'])

    def test_w2_the_main_checkout_another_branch_and_a_detached_head_are_full(self):
        self.assertEqual(ws.decide(str(self.main), environ={})['scope'], 'full')
        self.assertEqual(ws.decide(str(worktree(self.main, 'other', 'feature/x')), environ={})['scope'], 'full')
        detached = ws.decide(str(worktree(self.main, 'nightly', None, detach=True)), environ={})
        self.assertEqual((detached['scope'], detached['why']), ('full', 'detached HEAD'))
        git(self.main, 'checkout', '-q', '-b', 'cc/in-the-main-checkout')
        self.assertEqual(ws.decide(str(self.main), environ={})['why'], 'the main checkout, not a teammate workspace')
        self.assertEqual(ws.decide(self.tmp, environ={})['why'], 'not a git checkout')

    def test_w3_full_and_the_gate_variable_win_and_a_typo_is_refused(self):
        wt = worktree(self.main, 'wt', 'cc/fixture-two')
        self.assertEqual(ws.decide(str(wt), full=True, environ={})['scope'], 'full')
        self.assertEqual(ws.decide(str(wt), environ={ws.ENV: 'full'})['scope'], 'full')
        self.assertEqual(ws.decide(str(self.main), environ={ws.ENV: 'narrow'})['scope'], 'narrow')
        with self.assertRaises(ValueError):
            ws.decide(str(wt), environ={ws.ENV: 'fulll'})
        cli = subprocess.run([sys.executable, str(HERE / 'workspace_scope.py'), 'decide', str(wt)],
                             capture_output=True, text=True, env={**CLEAN, ws.ENV: 'fulll'})
        self.assertEqual(cli.returncode, 64)

    def test_w4_changed_paths_and_lines_cover_committed_uncommitted_and_new_work(self):
        wt = worktree(self.main, 'wt', 'cc/fixture-three')
        base = git(self.main, 'rev-parse', 'main')
        (wt / 'committed.txt').write_text('x\n')
        git(wt, 'add', '-A')
        git(wt, 'commit', '-q', '-m', 'c')
        (wt / 'a.txt').write_text('one\nTWO\nthree\n')        # line 2 changed, line 4 deleted
        (wt / 'new.txt').write_text('a\nb\n')
        self.assertEqual(ws.changed(str(wt), base), ['a.txt', 'committed.txt', 'new.txt'])
        self.assertEqual(ws.lines(str(wt), base, 'a.txt'), [2, 3, 4])
        self.assertEqual(ws.lines(str(wt), base, 'new.txt'), [1, 2])
        self.assertEqual(ws.lines(str(wt), base, 'gone.txt'), [])

    def test_w5_a_suites_inputs_claim_files_and_whole_directories(self):
        suite = Path(self.tmp) / 's.test.sh'
        suite.write_text('#!/bin/bash\n# run-tests: inputs dir/sub file.sh\n')
        declared = ws.inputs(str(suite))
        self.assertEqual(declared, ['dir/sub', 'file.sh'])
        self.assertTrue(ws.claimed('dir/sub/x.swift', declared))
        self.assertTrue(ws.claimed('file.sh', declared))
        self.assertFalse(ws.claimed('dir/subway.swift', declared))


if __name__ == '__main__':
    unittest.main(verbosity=2)
