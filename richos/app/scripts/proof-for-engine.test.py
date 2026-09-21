"""Execute the selector's engine commands through the shipped unit runner."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parents[2]
ENGINE = ROOT / "richos/engine"


class EngineCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proof-engine-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        (self.config / "state").mkdir(parents=True)
        self.env = {**os.environ, "CLAUDE_CONFIG_DIR": str(self.config)}

    def commands(self, path):
        result = subprocess.run(["bash", str(SCRIPTS / "proof-for.sh"), "--paths", path],
                                cwd=ROOT, env=self.env, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [line.strip() for line in result.stdout.splitlines()
                    if line.startswith("  cd richos/engine && ")]
        self.assertTrue(commands, result.stdout)
        return commands

    def execute(self, command, cwd, expected):
        receipt = self.root / "receipt.jsonl"
        result = subprocess.run(["bash", "-c", command + " --receipt " + shlex.quote(str(receipt))],
                                cwd=cwd, env=self.env, capture_output=True,
                                text=True, timeout=45)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        rows = [json.loads(line) for line in receipt.read_text().splitlines()]
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def test_generated_command_executes_a_real_suite(self):
        commands = self.commands("richos/engine/scripts/locate-engine.test.sh")
        selected = [command for command in commands
                    if shlex.split(command)[-1] == "scripts/locate-engine.test.sh"]
        self.assertEqual(len(selected), 1, commands)
        row = self.execute(selected[0], ROOT, 0)
        self.assertEqual(row["unit"], "scripts/locate-engine.test.sh")
        self.assertEqual(row["verdict"], "PASS")

    def test_section_command_preserves_expected_scoped_verdict(self):
        commands = self.commands("richos/engine/scripts/hooks/contract-integrity.test.sh")
        # Preserve the mapper's entire selection, including indirect consumers.
        # Execute a section below rather than re-scan the inventory for every unit.
        units = [shlex.split(command)[-1] for command in commands]
        affected = subprocess.run(["bash", str(ENGINE / "scripts/ci-affected-units.sh"),
                                   "--paths", "richos/engine/scripts/hooks/contract-integrity.test.sh"],
                                  cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(affected.returncode, 0, affected.stderr)
        self.assertEqual(sorted(units), sorted(affected.stdout.splitlines()))

        # Keep the actual executor, inventory and canaries. Replace only the
        # expensive suite body so the selected section can return 3, 0 and 1.
        engine = self.root / "richos/engine"
        (engine / "scripts/lib").mkdir(parents=True)
        (engine / "scripts/hooks").mkdir()
        for name in ("ci-shard.sh", "ci-units.sh", "lib/ci-receipts.py",
                     "lib/leak-canary.sh", "lib/record-canary.sh", "lib/tree-witness.sh"):
            shutil.copyfile(ENGINE / "scripts" / name, engine / "scripts" / name)
        index = next(i for i, unit in enumerate(units)
                     if unit.startswith("scripts/hooks/contract-integrity.test.sh:"))
        section = units[index].split(":", 1)[1]
        suite = engine / "scripts/hooks/contract-integrity.test.sh"
        for code, expected, verdict in ((3, 0, "PASS"), (0, 1, "SCOPE-LOST"), (1, 1, "FAIL")):
            with self.subTest(suite_exit=code):
                suite.write_text("#!/bin/bash\n_section() { return 1; }\n"
                                 f"if _section {section}; then\n  :\nfi\n"
                                 f'[ "$1" = --only ] && [ "$2" = {shlex.quote(section)} ] || exit 91\n'
                                 f"exit {code}\n")
                row = self.execute(commands[index], self.root, expected)
                self.assertEqual(row["unit"], units[index])
                self.assertEqual(row["verdict"], verdict)


if __name__ == "__main__":
    unittest.main()
