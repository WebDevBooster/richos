"""Regression coverage for the Mega Lander directory boundary."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

ENGINE = Path(__file__).resolve().parents[2]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Relocation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mega lander ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.engine = self.root / "engine with spaces"
        for directory in ("scripts/lib", "mega-lander"):
            shutil.copytree(ENGINE / directory, self.engine / directory,
                            ignore=shutil.ignore_patterns("__pycache__", "*.sha256"))
        for name in ("workspaces.sh", "create-teammate-worktree.sh", "workspace-probes.py"):
            shutil.copy2(ENGINE / "scripts" / name, self.engine / "scripts" / name)
        self.env = dict(os.environ, HOME=str(self.root / "home"),
                        CLAUDE_CONFIG_DIR=str(self.root / "config"),
                        RICHOS_WORKSPACES_DIR=str(self.root / "state"),
                        PYTHONDONTWRITEBYTECODE="1")

    def run_command(self, *args):
        return subprocess.run(args, env=self.env, capture_output=True, text=True)

    def test_old_commands_forward_with_arguments_and_exit_codes(self):
        for filename, interpreter, expected in (
            ("workspaces.sh", "bash", 0),
            ("create-teammate-worktree.sh", "bash", 2),
            ("workspace-probes.py", "python3", 0),
        ):
            with self.subTest(filename=filename):
                new = self.run_command(interpreter, str(self.engine / "mega-lander" / filename), "--help")
                old = self.run_command(interpreter, str(self.engine / "scripts" / filename), "--help")
                self.assertEqual(new.returncode, expected, new.stderr)
                self.assertEqual((old.returncode, old.stdout, old.stderr),
                                 (new.returncode, new.stdout, new.stderr))
        self.assertFalse((self.root / "state").exists())

    def test_legacy_import_executes_canonical_code_in_callers_module(self):
        old = load(self.engine / "scripts/lib/workspaces.py", "old_workspaces")
        canonical = str((self.engine / "mega-lander/workspaces.py").resolve())
        self.assertEqual(old.__file__, canonical)
        self.assertEqual(old.land.__code__.co_filename, canonical)
        old.state_dir = lambda: "sentinel"
        self.assertEqual(old._p("agents"), os.path.join("sentinel", "agents"))

    def test_historical_in_tree_probe_uses_selected_library(self):
        runner = load(self.engine / "mega-lander/workspace-probes.py", "probe_runner")
        selected = self.root / "selected.py"
        selected.write_text((self.engine / "mega-lander/workspaces.py").read_text() +
                            "\nMEGA_LANDER_SELECTED = True\n")
        probe = self.root / "historical.probe.py"
        probe.write_text('''import importlib.util
from pathlib import Path
p = Path(__file__).resolve().parents[2] / "engine/scripts/lib/workspaces.test.py"
s = importlib.util.spec_from_file_location("old_tests", p)
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
assert m.ws.MEGA_LANDER_SELECTED
''')
        staged = self.root / "staged"
        path = runner.stage_in_tree(str(self.root), str(selected), str(staged),
                                   SimpleNamespace(name="docs/verification/historical.probe.py", path=str(probe)))
        result = self.run_command("python3", path)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hook_dependency_closure_includes_feature(self):
        result = self.run_command("python3", str(ENGINE / "scripts/lib/hook-dependencies.py"), str(ENGINE))
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = set(result.stdout.splitlines())
        self.assertTrue({"mega-lander/workspaces.py", "mega-lander/workspaces.sh"} <= paths)

    def test_ci_selects_feature_local_suite_without_a_text_reference(self):
        scripts = self.engine / "scripts"
        for name in ("ci-units.sh", "ci-affected-units.sh"):
            shutil.copy2(ENGINE / "scripts" / name, scripts / name)
        feature = self.engine / "isolated-feature"
        (feature / "tests").mkdir(parents=True)
        (feature / "worker.py").write_text("pass\n")
        suite = feature / "tests/worker.test.sh"
        suite.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.run_command("git", "init", "-q", str(self.engine))
        result = self.run_command("bash", str(scripts / "ci-affected-units.sh"),
                                  "--paths", "isolated-feature/worker.py", "--strict")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "isolated-feature/tests/worker.test.sh")

    def test_probe_runner_accepts_a_commit_before_the_move(self):
        self.engine = self.engine.rename(self.root / "engine")
        scripts = self.engine / "scripts/lib"
        scripts.joinpath("workspaces.py").write_text("CC_PREFIX = 'historical'\n")
        docs = self.root / "docs/verification"
        docs.mkdir(parents=True)
        name = "docs/verification/certification-relocation.probe.py"
        self.root.joinpath(name).write_text('''import importlib.util, sys
CASES = ["old"]
def main(argv):
    s = importlib.util.spec_from_file_location("ws", argv[0])
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return 0 if m.CC_PREFIX == "historical" else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
''')
        docs.joinpath("workspace-probes.manifest").write_text(name + "\n")
        self.run_command("git", "init", "-q", "-b", "main", str(self.root))
        self.run_command("git", "-C", str(self.root), "add", "engine/scripts/lib/workspaces.py", "docs")
        result = self.run_command("git", "-C", str(self.root), "-c", "user.name=Test",
                                  "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                                  "-c", "core.hooksPath=/dev/null", "commit", "-qm", "before move")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_command("python3", str(self.engine / "mega-lander/workspace-probes.py"),
                                  "--at", "HEAD", "--tree-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("certification-relocation.probe.py", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
