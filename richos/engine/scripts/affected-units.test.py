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


if __name__ == "__main__":
    unittest.main()
