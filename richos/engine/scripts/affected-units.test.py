#!/usr/bin/env python3
"""Planning fixtures execute no selected suite or hook command."""
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from affected_units import GLOBAL_CONFIG, SECTIONED, Selection, validate_config
from verification_inputs import Unsupported


class Planner(unittest.TestCase):
    def test_python_audience_wrapper_keeps_complete_pretooluse_inventory(self):
        root = HERE.parent
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        suite = 'scripts/lib/spawn-guard-audience.test.sh'
        def read(path):
            file = root / path
            return file.read_text() if file.is_file() else None
        before = (root / 'hooks/hooks.json').read_text()
        for event, expected in (('PreToolUse', {suite}), ('Stop', set())):
            after = json.loads(before)
            after['hooks'][event].append({'matcher': 'Agent', 'hooks': [
                {'type': 'command', 'command': 'bash ${CLAUDE_PLUGIN_ROOT}/new-hook.sh'}]})
            plan = Selection(root, [suite], read, document)
            plan.hooks(before, json.dumps(after))
            self.assertEqual(set(plan.selected), expected)
        document['hook_readers'][suite]['sources']['scripts/lib/spawn-guard-audience.test.py'] = 'changed'
        plan = Selection(root, [suite], read, document)
        plan.hooks(before, json.dumps(after))
        self.assertEqual(set(plan.selected), {suite})

    def test_private_todo_and_removal_suites_keep_adoption_and_source_obligations(self):
        root = HERE.parent
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        suites = ['scripts/hooks/guard-worktree-removal.test.sh',
                  'scripts/cold-open.test.sh', 'scripts/hooks/ceo-todos.test.sh', GLOBAL_CONFIG]
        def read(path):
            file = root / path
            return file.read_text() if file.is_file() else None
        plan = Selection(root, suites, read, document)
        plan.configuration('PROTECTED_PATHS=old', 'PROTECTED_PATHS=new')
        self.assertEqual(set(plan.selected), {GLOBAL_CONFIG})
        plan = Selection(root, suites, read, document)
        plan.configuration(None, 'PROTECTED_PATHS=new')
        self.assertEqual(set(plan.selected), {GLOBAL_CONFIG, suites[2]})
        for source, unit in (('scripts/hooks/guard-worktree-removal.sh', suites[0]),
                             ('scripts/cold-open.sh', suites[1]),
                             ('scripts/lib/ceo-todos.py', suites[2])):
            plan = Selection(root, suites, read, document)
            plan.ordinary(source)
            self.assertIn(unit, plan.selected)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="affected-inputs.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = {}
        self.map = {"schema": 1, "config_keys": ["A", "B"], "nodes": {}, "units": {}}
        self.node(GLOBAL_CONFIG, "validate_config\n", whole="global validation")

    def node(self, path, text, **fields):
        self.sources[path] = text
        self.map["nodes"][path] = {"source": path, "sha256": hashlib.sha256(text.encode()).hexdigest(),
                                   "evidence": "fixture input contract", "keys": [], "edges": [], **fields}
        if path.endswith(".test.sh"):
            self.map["units"][path] = path

    def selection(self):
        return Selection(self.root, sorted(self.map["units"]), self.sources.get, self.map)

    def test_changed_key_selects_exact_transitive_readers_and_global_validator(self):
        self.node("helper.sh", 'printf "%s" "$A"\n', keys=["A"])
        self.node("reader.test.sh", "bash helper.sh\n", edges=[{"to": "helper.sh"}])
        self.node("other.test.sh", 'printf "%s" "$B"\n', keys=["B"])
        plan = self.selection()
        plan.configuration("A=one\nB=two\n", "A=changed\nB=two\n")
        self.assertEqual(set(plan.selected), {"reader.test.sh", GLOBAL_CONFIG})
        self.assertIn("changed key A", " ".join(plan.selected["reader.test.sh"]))
        plan = self.selection()
        plan.configuration("A=one\nB=two\n", "A=one\nB=two\nUNUSED=new\n")
        self.assertEqual(set(plan.selected), {GLOBAL_CONFIG})

    def test_unknown_reader_and_path_only_requests_explain_conservative_selection(self):
        self.node("reader.test.sh", 'printf "%s" "$A"\n', keys=["A"])
        self.node("unknown.test.sh", "bash missing.sh\n", edges=[{"to": "missing.sh"}])
        plan = self.selection()
        plan.configuration("A=one", "A=two")
        self.assertIn("unqualified reader missing.sh", " ".join(plan.selected["unknown.test.sh"]))
        plan = self.selection()
        plan.configuration(None, "A=one", unknown=True)
        self.assertIn("path-only request", " ".join(plan.selected["reader.test.sh"]))

    def test_missing_global_validator_cannot_emit_green_empty_plan(self):
        plan = Selection(self.root, [], self.sources.get, self.map)
        with self.assertRaisesRegex(Unsupported, "global config validation unit is missing"):
            plan.configuration("A=one", "A=two")

    def test_sections_keep_shared_helper_fallback_and_per_section_narrowing(self):
        self.sources[SECTIONED] = ('source shared.sh\nif _section A; then\nbash alpha.sh\nfi  # _section\n'
                                  'if _section B; then\nbash beta.sh\nfi  # _section\n')
        plan = Selection(self.root, [SECTIONED], self.sources.get, self.map)
        plan.ordinary("alpha.sh")
        self.assertEqual(set(plan.selected), {SECTIONED + ":A"})
        plan = Selection(self.root, [SECTIONED], self.sources.get, self.map)
        plan.ordinary("shared.sh")
        self.assertEqual(set(plan.selected), {SECTIONED + ":A", SECTIONED + ":B"})
        self.assertTrue(all("ALL sections" in " ".join(reasons) for reasons in plan.selected.values()))

    def test_global_validation_rejects_unknown_keys_and_executable_syntax(self):
        directory = self.root / "scripts/lib"
        directory.mkdir(parents=True)
        (directory / "verification-dependencies.json").write_text(json.dumps(self.map))
        config = self.root / "orchestration.config"
        config.write_text("A=ok\n")
        self.assertEqual(validate_config(self.root), 1)
        config.write_text("UNDECLARED=ok\n")
        with self.assertRaisesRegex(Unsupported, "unknown config keys"):
            validate_config(self.root)
        marker = self.root / "must-not-execute"
        config.write_text('A="$(touch %s)"\n' % marker)
        with self.assertRaises(Unsupported):
            validate_config(self.root)
        self.assertFalse(marker.exists())

    def hook_fixture(self):
        self.node('alpha.test.sh', 'bash alpha.sh\n')
        self.node('beta.test.sh', 'bash beta.sh\n')
        self.node('registration.test.sh', 'read hooks.json for alpha\n')
        self.node('inventory.test.sh', 'read every command in hooks.json\n')
        self.node('unrelated.test.sh', 'read hooks.json for gamma\n')
        self.node('helper.sh', 'read supplied manifest\n')
        self.map['hook_readers'] = {}
        for suite, command in (('registration.test.sh', 'alpha.sh'), ('unrelated.test.sh', 'gamma.sh')):
            self.map['hook_readers'][suite] = {
                'commands': [command], 'text_needles': [command], 'evidence': 'fixed registration fixture',
                'sources': {p: self.map['nodes'][p]['sha256'] for p in (suite, 'helper.sh')}}

    @staticmethod
    def hooks_document(commands, matcher='Write', event='PreToolUse'):
        return json.dumps({'hooks': {event: [{'matcher': matcher, 'hooks': [
            {'type': 'command', 'command': 'bash ${CLAUDE_PLUGIN_ROOT}/' + command}
            for command in commands]}]}}, indent=2)

    def test_hook_replacement_selects_both_behaviors_and_relevant_registration(self):
        self.hook_fixture()
        plan = self.selection()
        plan.hooks(self.hooks_document(['alpha.sh']), self.hooks_document(['beta.sh']))
        self.assertEqual(set(plan.selected), {'alpha.test.sh', 'beta.test.sh',
                                             'registration.test.sh', 'inventory.test.sh'})

    def test_matcher_and_first_group_order_remain_obligations(self):
        self.hook_fixture()
        old = self.hooks_document(['alpha.sh'])
        plan = self.selection()
        plan.hooks(old, self.hooks_document(['alpha.sh'], matcher='Edit'))
        self.assertEqual(set(plan.selected), {'alpha.test.sh', 'registration.test.sh', 'inventory.test.sh'})
        self.map['hook_readers']['registration.test.sh']['events'] = ['PreToolUse']
        plan = self.selection()
        plan.hooks(self.hooks_document(['beta.sh']), self.hooks_document(['beta.sh'], matcher='AskUserQuestion'))
        self.assertIn('registration.test.sh', plan.selected)
        self.assertNotIn('unrelated.test.sh', plan.selected)

    def test_registration_text_and_helper_changes_cannot_be_hidden(self):
        self.hook_fixture()
        old = self.hooks_document(['beta.sh'])
        changed = json.loads(old)
        changed['description'] = 'alpha.sh is named here, which a grep also reads'
        plan = self.selection()
        plan.hooks(old, json.dumps(changed, indent=2))
        self.assertEqual(set(plan.selected), {'registration.test.sh', 'inventory.test.sh'})
        self.sources['helper.sh'] += 'changed behavior\n'
        plan = self.selection()
        plan.hooks(old, self.hooks_document(['beta.sh'], matcher='Edit'))
        self.assertIn('unrelated.test.sh', plan.selected)
        self.assertIn('changed hook reader', ' '.join(plan.selected['unrelated.test.sh']))

    def test_unknown_hook_command_or_structure_is_explicit_and_never_executes(self):
        self.hook_fixture()
        old = self.hooks_document(['alpha.sh'])
        marker = self.root / 'not-executed'
        for changed in ('{"hooks":[]}', self.hooks_document(['alpha.sh; touch ' + str(marker)])):
            plan = self.selection()
            plan.hooks(old, changed)
            self.assertEqual(set(plan.selected), set(plan.units))
            self.assertTrue(all('fallback' in ' '.join(reasons) for reasons in plan.selected.values()))
        self.assertFalse(marker.exists())

    def test_real_fixed_readers_exclude_unrelated_hook_without_losing_inventory(self):
        root = HERE.parent
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        suites = sorted(document['hook_readers']) + ['scripts/check-census.test.sh']
        old = (root / 'hooks/hooks.json').read_text()
        changed = json.loads(old)
        group = changed['hooks']['Stop'][-1]
        group['hooks'].append({'type': 'command', 'command': 'bash ${CLAUDE_PLUGIN_ROOT}/new-fixture-hook.sh'})
        plan = Selection(root, suites, lambda p: (root / p).read_text() if (root / p).is_file() else None, document)
        plan.hooks(old, json.dumps(changed, indent=2))
        # JSON escapes in the description remain outside these registration needles.
        self.assertEqual(set(plan.selected), {'scripts/check-census.test.sh'})

    def test_real_fixture_suites_skip_config_changes_but_keep_source_changes(self):
        root = HERE.parent
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        suites = ['scripts/collect-worktree-artifacts.test.sh',
                  'scripts/hooks/turn-manifest.test.sh', GLOBAL_CONFIG]
        def read(path):
            file = root / path
            return file.read_text() if file.is_file() else None
        for before, after in (('SHOW_TURN_MANIFEST=1', 'SHOW_TURN_MANIFEST=0'),
                              ('ARTIFACT_MERGE_DIRS=a', 'ARTIFACT_MERGE_DIRS=b')):
            plan = Selection(root, suites, read, document)
            plan.configuration(before, after)
            self.assertEqual(set(plan.selected), {GLOBAL_CONFIG})
        for source, unit in (('scripts/collect-worktree-artifacts.sh', suites[0]),
                             ('scripts/hooks/turn-manifest.sh', suites[1]),
                             ('scripts/hooks/turn-manifest.py', suites[1])):
            plan = Selection(root, suites, read, document)
            plan.ordinary(source)
            self.assertIn(unit, plan.selected)


class SnapshotCLI(unittest.TestCase):
    def test_real_cli_distinguishes_commit_index_and_worktree_without_execution(self):
        with tempfile.TemporaryDirectory(prefix="selection-versions.") as directory:
            root = Path(directory)
            engine = root / "richos/engine"
            library = engine / "scripts/lib"
            library.mkdir(parents=True)
            env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
                   "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                   "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], env=env, text=True).strip()
            for name in ("affected_units.py", "verification_inputs.py"):
                shutil.copyfile(HERE / "lib" / name, library / name)
            shutil.copyfile(HERE / "ci-affected-units.sh", engine / "scripts/ci-affected-units.sh")
            document = {"schema": 1, "config_keys": ["A", "B"], "nodes": {}, "units": {}}
            for unit, keys in (("scripts/a.test.sh", ["A"]), ("scripts/b.test.sh", ["B"]), (GLOBAL_CONFIG, [])):
                text = 'echo must-not-execute > "' + str(root / 'executed') + '"\n'
                (engine / unit).write_text(text)
                document["units"][unit] = unit
                document["nodes"][unit] = {"source": unit, "sha256": hashlib.sha256(text.encode()).hexdigest(),
                                             "evidence": "fixture contract", "keys": keys, "edges": []}
            (library / "verification-dependencies.json").write_text(json.dumps(document))
            configuration = engine / "orchestration.config"
            configuration.write_text("A=old\nB=old\n")
            git("init", "-q"); git("add", "."); git("commit", "-qm", "base")
            configuration.write_text("A=committed\nB=old\n")
            git("add", "."); git("commit", "-qm", "changed A")
            configuration.write_text("A=committed\nB=staged\n")
            git("add", ".")
            configuration.write_text("A=working\nB=staged\n")
            for args, expected in ((["--range", "HEAD^..HEAD"], {"scripts/a.test.sh"}),
                                   (["--staged"], {"scripts/b.test.sh"}),
                                   (["--working", "--base", "HEAD"], {"scripts/a.test.sh", "scripts/b.test.sh"}),
                                   (["--paths", "richos/engine/orchestration.config", "--staged"], {"scripts/b.test.sh"})):
                with self.subTest(args=args):
                    result = subprocess.run(["bash", str(engine / "scripts/ci-affected-units.sh"), *args, "--explain"],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(set(result.stdout.splitlines()), expected | {GLOBAL_CONFIG})
                    self.assertIn("changed key", result.stderr)
            self.assertFalse((root / "executed").exists())
            hooks = engine / 'hooks/hooks.json'
            hooks.parent.mkdir()
            hooks.write_text(Planner.hooks_document(['scripts/a.sh']))
            git('add', '.'); git('commit', '-qm', 'hook base')
            hooks.write_text(Planner.hooks_document(['scripts/b.sh']))
            git('add', '.'); git('commit', '-qm', 'hook replacement')
            hooks.write_text(Planner.hooks_document(['scripts/a.sh']))
            git('add', '.')
            hooks.write_text(Planner.hooks_document(['scripts/b.sh'], matcher='Edit'))
            for args, expected in ((['--range', 'HEAD^..HEAD'], {'scripts/a.test.sh', 'scripts/b.test.sh'}),
                                   (['--staged'], {'scripts/a.test.sh', 'scripts/b.test.sh'}),
                                   (['--working', '--base', 'HEAD'], {'scripts/b.test.sh'})):
                with self.subTest(hooks=args):
                    result = subprocess.run(['bash', str(engine / 'scripts/ci-affected-units.sh'), *args],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(set(result.stdout.splitlines()), expected)
            self.assertFalse((root / 'executed').exists())


if __name__ == "__main__":
    unittest.main()
