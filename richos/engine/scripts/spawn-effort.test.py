"""The spawn payload carries `effort` only when --effort is given, and only a level Claude Code 2.1.292 accepts."""
import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS / "lib"))
spec = importlib.util.spec_from_file_location("spawn_lib", SCRIPTS / "lib" / "spawn.py")
spawn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spawn)

BASE = ["zach-opus-t1", "--repo", "/tmp/r", "--type", "zach", "--brief", "b"]


class Effort(unittest.TestCase):
    def payload(self, extra):
        args = spawn.parse_args(BASE + extra)
        return spawn.build_payload(args, "Build it", [])

    def test_effort_is_in_the_payload_with_the_option(self):
        self.assertEqual(self.payload(["--effort", "high"])["effort"], "high")

    def test_no_effort_key_without_the_option(self):
        self.assertNotIn("effort", self.payload([]))

    def test_only_the_five_levels_are_accepted(self):
        for level in ("low", "medium", "high", "xhigh", "max"):
            self.assertEqual(self.payload(["--effort", level])["effort"], level)
        with self.assertRaises(spawn.Refusal):
            spawn.parse_args(BASE + ["--effort", "ultra"])


if __name__ == "__main__":
    unittest.main()
