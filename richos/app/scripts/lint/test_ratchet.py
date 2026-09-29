import copy
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from common import Refusal
import driver
from ratchet import NOTE, check, compare, lower


def record():
    return dict(schema=1, limitation=NOTE, commands={'scan': ['scanner']},
                versions={'scanner': '1'}, rules={'a': 'blocking', 'b': 'blocking'},
                inventory={'one.sh': {'language': 'shell', 'role': 'production'}},
                counts={'a': 2, 'b': 0})


class Ratchet(unittest.TestCase):
    def test_filesystem_check_and_trusted_git_baseline(self):
        with tempfile.TemporaryDirectory(prefix='lint-ratchet-') as tmp:
            root = Path(tmp)
            def git(*args):
                subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Lint fixture',
                                '-c', 'user.email=lint@example.invalid', *args], cwd=root, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            git('init', '-q', '--initial-branch=main')
            path = root / driver.BASE / 'fixture.json'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(record()))
            git('add', '.')
            git('commit', '-qm', 'Fixture integration baseline')
            args = argparse.Namespace(trusted_ref='refs/heads/main', bootstrap=False, lower=False)
            before = (path.read_bytes(), path.stat().st_mtime_ns)
            actual = record()
            actual['counts']['a'] = 1
            driver.enforce(root, 'fixture', actual, args)
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
            args.lower = True
            driver.enforce(root, 'fixture', actual, args)
            self.assertEqual(json.loads(path.read_text())['counts']['a'], 1)
            raised = record()
            raised['counts']['a'] = 3
            path.write_text(json.dumps(raised))
            args.lower = False
            with self.assertRaisesRegex(Refusal, 'raised ceiling'):
                driver.enforce(root, 'fixture', raised, args)
            path.unlink()
            args.bootstrap = True
            with self.assertRaisesRegex(Refusal, 'already on integration'):
                driver.enforce(root, 'fixture', record(), args)

    def test_check_does_not_mutate(self):
        baseline = record()
        before = copy.deepcopy(baseline)
        actual = record()
        actual['counts']['a'] = 1
        check(actual, baseline)
        self.assertEqual(baseline, before)
        self.assertEqual(lower(actual, baseline)['counts']['a'], 1)

    def test_defeats(self):
        for change in ('growth', 'rule', 'inventory', 'classification', 'tool', 'command', 'count'):
            candidate = record()
            if change == 'growth': candidate['counts']['a'] = 3
            if change == 'rule': del candidate['rules']['b']
            if change == 'inventory': candidate['inventory'] = {'other.sh': {}}
            if change == 'classification': candidate['rules']['a'] = 'advisory'
            if change == 'tool': candidate['versions']['scanner'] = '2'
            if change == 'command': candidate['commands']['scan'] = ['true']
            if change == 'count': del candidate['counts']['b']
            with self.subTest(change=change), self.assertRaises(Refusal):
                compare(candidate, record())

    def test_lower_refuses_growth(self):
        actual = record()
        actual['counts']['a'] = 3
        with self.assertRaises(Refusal):
            lower(actual, record())

    def test_deleted_or_renamed_file_leaves_the_inventory(self):
        """A path gone from the tree leaves the inventory through check, lower and compare;
        a path that still exists keeps every refusal (hunt 2026-09-29, part 2, section 03)."""
        with tempfile.TemporaryDirectory(prefix='lint-ratchet-gone-') as tmp:
            root = Path(tmp)
            def git(*args):
                subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Lint fixture',
                                '-c', 'user.email=lint@example.invalid', *args], cwd=root, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            row = {'language': 'shell', 'role': 'production'}
            trusted = record()
            trusted['inventory'] = {'one.sh': row, 'two.sh': row}
            for name in trusted['inventory']:
                (root / name).write_text('#!/bin/sh\n')
            path = root / driver.BASE / 'fixture.json'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(trusted))
            git('init', '-q', '--initial-branch=main')
            git('add', '.')
            git('commit', '-qm', 'Fixture integration baseline with two scanned files')
            git('checkout', '-qb', 'topic')
            args = argparse.Namespace(trusted_ref='refs/heads/main', bootstrap=False, lower=False)
            def scan(*paths, a=2):
                actual = record()
                actual['inventory'] = {p: row for p in paths}
                actual['counts']['a'] = a
                return actual

            # Deleted: check passes, lower records the removal, and the lowered baseline
            # passes compare against integration, which still lists the path.
            git('rm', '-q', 'two.sh')
            driver.enforce(root, 'fixture', scan('one.sh'), args)
            args.lower = True
            driver.enforce(root, 'fixture', scan('one.sh'), args)
            self.assertEqual(sorted(json.loads(path.read_text())['inventory']), ['one.sh'])
            args.lower = False
            driver.enforce(root, 'fixture', scan('one.sh'), args)

            # Still on disk but no longer scanned (untracked here): refused by check, and a
            # candidate baseline that drops it is refused by compare.
            (root / 'two.sh').write_text('#!/bin/sh\n')
            with self.assertRaisesRegex(Refusal, 'shrunk or reclassified inventory: two.sh'):
                driver.enforce(root, 'fixture', scan('one.sh'), args)
            path.write_text(json.dumps(trusted))
            with self.assertRaisesRegex(Refusal, 'shrunk or reclassified scan inventory: two.sh'):
                driver.enforce(root, 'fixture', scan('one.sh'), args)
            (root / 'two.sh').unlink()

            # Renamed: a removal plus a new file, and the new file is scanned. Its diagnostics
            # count against the ceiling at once; lower then records it in the inventory.
            (root / 'three.sh').write_text('#!/bin/sh\n')
            with self.assertRaisesRegex(Refusal, 'lint growth: a: 3 > 2'):
                driver.enforce(root, 'fixture', scan('one.sh', 'three.sh', a=3), args)
            args.lower = True
            driver.enforce(root, 'fixture', scan('one.sh', 'three.sh'), args)
            self.assertEqual(sorted(json.loads(path.read_text())['inventory']), ['one.sh', 'three.sh'])
            args.lower = False
            driver.enforce(root, 'fixture', scan('one.sh', 'three.sh'), args)

            # Reclassified while present, and an existing path dropped from the candidate,
            # stay refused even beside a genuine deletion.
            reclassified = scan('one.sh', 'three.sh')
            reclassified['inventory']['one.sh'] = {'language': 'shell', 'role': 'suite'}
            with self.assertRaisesRegex(Refusal, 'scan inventory: one.sh'):
                driver.enforce(root, 'fixture', reclassified, args)
            dropped = json.loads(path.read_text())
            del dropped['inventory']['one.sh']
            path.write_text(json.dumps(dropped))
            with self.assertRaisesRegex(Refusal, 'shrunk or reclassified inventory: one.sh'):
                driver.enforce(root, 'fixture', scan('three.sh'), args)

    def test_gone_predicate_is_the_only_exemption(self):
        trusted = record()
        trusted['inventory']['two.sh'] = trusted['inventory']['one.sh']
        gone = {'two.sh'}.__contains__
        # Without a tree to consult, nothing counts as gone: the old refusals hold.
        with self.assertRaises(Refusal):
            check(record(), trusted)
        with self.assertRaises(Refusal):
            compare(record(), trusted)
        check(record(), trusted, gone=gone)
        compare(record(), trusted, gone=gone)
        self.assertEqual(lower(record(), trusted, gone=gone)['inventory'], record()['inventory'])
        # A gone path that the candidate still lists under another role is not a removal.
        reclassified = copy.deepcopy(trusted)
        reclassified['inventory']['two.sh'] = {'language': 'shell', 'role': 'suite'}
        with self.assertRaises(Refusal):
            compare(reclassified, trusted, gone=gone)
        with self.assertRaises(Refusal):
            check(reclassified, trusted, gone=gone)
        # Every other weakening is refused whatever is gone.
        for change in ('rule', 'classification', 'tool', 'command', 'count', 'growth'):
            candidate = record()
            if change == 'growth': candidate['counts']['a'] = 3
            if change == 'rule': del candidate['rules']['b']
            if change == 'classification': candidate['rules']['a'] = 'advisory'
            if change == 'tool': candidate['versions']['scanner'] = '2'
            if change == 'command': candidate['commands']['scan'] = ['true']
            if change == 'count': del candidate['counts']['b']
            with self.subTest(change=change), self.assertRaises(Refusal):
                compare(candidate, trusted, gone=gone)

    def test_new_file_is_not_exempt(self):
        actual = record()
        actual['inventory']['two.sh'] = actual['inventory']['one.sh']
        actual['counts']['new-rule'] = 1
        with self.assertRaises(Refusal):
            check(actual, record())
