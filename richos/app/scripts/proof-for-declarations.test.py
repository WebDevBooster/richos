"""Contract tests for dependency selection versus behavioral coverage."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parents[2]
sys.path.insert(0, str(SCRIPTS / "lib"))
from proof_declarations import InvalidDeclaration, read_declarations


class Declarations(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="proof-declarations-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.suites = self.root / "suites"
        self.suites.mkdir()
        (self.root / "src").mkdir()
        (self.root / "src/tool.py").write_text("pass\n")

    def write(self, rows):
        (self.suites / "fixture.test.sh").write_text(rows)

    def test_dependency_directory_and_explicit_empty_coverage(self):
        self.write("# run-tests: inputs src\n# run-tests: covers -\n")
        self.assertEqual(read_declarations(self.root, self.suites),
                         [("fixture.test.sh", ["src"], [])])
        (self.root / "src/new.py").write_text("pass\n")
        self.assertEqual(read_declarations(self.root, self.suites)[0][1], ["src"])

    def test_exact_coverage_must_select_the_claiming_suite(self):
        self.write("# run-tests: inputs src\n# run-tests: covers src/tool.py\n")
        self.assertEqual(read_declarations(self.root, self.suites)[0][2], ["src/tool.py"])
        self.write("# run-tests: inputs elsewhere\n# run-tests: covers src/tool.py\n")
        with self.assertRaisesRegex(InvalidDeclaration, "fixture.test.sh:2:.*not selected"):
            read_declarations(self.root, self.suites)

    def test_missing_duplicate_and_implicit_empty_rows_refuse(self):
        inputs = "# run-tests: inputs src\n"
        covers = "# run-tests: covers -\n"
        for rows in [inputs, covers, "", inputs + covers * 2, inputs * 2 + covers,
                     inputs + "# run-tests: covers\n", inputs + "# run-tests: covers - src/tool.py\n"]:
            with self.subTest(rows=rows):
                self.write(rows)
                with self.assertRaisesRegex(InvalidDeclaration, "fixture.test.sh"):
                    read_declarations(self.root, self.suites)

    def test_invalid_or_stale_coverage_refuses(self):
        for path in ["/src/tool.py", "src/../src/tool.py", "src//tool.py",
                     "src/*.py", "src/missing.py"]:
            with self.subTest(path=path):
                self.write(f"# run-tests: inputs src\n# run-tests: covers {path}\n")
                with self.assertRaisesRegex(InvalidDeclaration, "fixture.test.sh:2:"):
                    read_declarations(self.root, self.suites)

    def select(self, path, directory=None):
        env = dict(os.environ)
        if directory is not None:
            env["PROOF_FOR_SCRIPT_DIR"] = str(directory)
        return subprocess.run(["/bin/bash", str(SCRIPTS / "proof-for.sh"), "--paths", path],
                              cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)

    def test_real_tree_reconciles_and_orphans_still_select_dependencies(self):
        rows = read_declarations(ROOT, SCRIPTS)
        self.assertEqual(len(rows), len(list(SCRIPTS.glob("*.test.sh"))))
        for path in ["richos/app/.proof-for-probe/orphan.sh",
                     "richos/app/scripts/review-orphan-probe.sh"]:
            with self.subTest(path=path):
                result = self.select(path)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("UNCOVERED", result.stdout + result.stderr)
                self.assertIn(path, result.stdout + result.stderr)
                self.assertIn("lint.test.sh", result.stdout)
        result = self.select("docs/a-file-that-is-only-prose.md")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_selector_refuses_inputs_without_coverage(self):
        for suite in SCRIPTS.glob("*.test.sh"):
            shutil.copy2(suite, self.suites / suite.name)
        suite = self.suites / "lint.test.sh"
        suite.write_text("\n".join(line for line in suite.read_text().splitlines()
                                   if not line.startswith("# run-tests: covers")) + "\n")
        result = self.select("docs/a-file-that-is-only-prose.md", self.suites)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lint.test.sh", result.stderr)
        self.assertIn("covers", result.stderr)


if __name__ == "__main__":
    unittest.main()
