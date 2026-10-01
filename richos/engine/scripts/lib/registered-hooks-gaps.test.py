#!/usr/bin/env python3
"""registered-hooks.sh must not return a SHORT inventory as a whole one.

Hunt P5-08 (part 5): when hooks.json registers the PreToolUse dispatcher but its
manifest (the list of rule modules the dispatcher runs) was missing or could not
be read, registered_hook_scripts and registered_hook_rows still printed an
inventory that lacked every dispatcher rule, and exited 0. Now they exit 2, the
same "cannot answer" code they already use for unparseable input.

Kept, because the library's own header gives the reason: a surface that does NOT
register the dispatcher needs no manifest, and "no manifest" stays an empty
expansion there (rc 0).

The library is COPIED into a scratch directory so its own-directory fallback
manifest (scripts/lib/../hooks/dispatch-pretooluse.manifest) does not exist;
otherwise the real engine's manifest always answers and the case cannot occur.
"""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "registered-hooks.sh")
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0


def hooks_json(use_dispatcher):
    cmd = ("bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/dispatch-pretooluse.sh chain1"
           if use_dispatcher else "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-own.sh")
    return {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": cmd},
        {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-plain.sh"}]}]}}


class RegisteredHooksGaps(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="rh-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.makedirs(os.path.join(self.tmp, "lib"))
        os.makedirs(os.path.join(self.tmp, "hooks"))
        shutil.copy(SRC, os.path.join(self.tmp, "lib", "registered-hooks.sh"))
        shutil.copy(os.path.join(HERE, "hook_command.py"), os.path.join(self.tmp, "lib", "hook_command.py"))
        self.lib = os.path.join(self.tmp, "lib", "registered-hooks.sh")
        self.manifest_dir = os.path.join(self.tmp, "scripts", "hooks")
        self.manifest = os.path.join(self.manifest_dir, "dispatch-pretooluse.manifest")

    def surface(self, use_dispatcher):
        p = os.path.join(self.tmp, "hooks", "hooks.json")
        with open(p, "w") as fh:
            json.dump(hooks_json(use_dispatcher), fh)
        return p

    def write_manifest(self):
        os.makedirs(self.manifest_dir, exist_ok=True)
        with open(self.manifest, "w") as fh:
            fh.write("# chain\nchain1|rule-a.sh\nchain1|rule-b.sh\n")

    def call(self, fn, *args):
        res = subprocess.run(["bash", "-c", 'source "$1"; shift; "$@"', "_", self.lib, fn, *args],
                             capture_output=True, text=True)
        return res.returncode, res.stdout.split()

    def rows(self, p):
        rc, out = self.call("registered_hook_rows", p)
        return rc, out

    def test_1_control_the_dispatcher_rules_are_in_the_inventory(self):
        p = self.surface(True)
        self.write_manifest()
        rc, names = self.call("registered_hook_scripts", p)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(set(names) & {"rule-a.sh", "rule-b.sh", "guard-plain.sh"}),
                         ["guard-plain.sh", "rule-a.sh", "rule-b.sh"])
        rc, out = self.rows(p)
        self.assertEqual(rc, 0)
        self.assertIn("rule-a.sh", " ".join(out))

    def test_2_a_missing_manifest_with_the_dispatcher_registered_is_rc_2(self):
        p = self.surface(True)
        self.assertEqual(self.call("registered_hook_scripts", p)[0], 2)
        self.assertEqual(self.call("registered_hook_scripts", p, "PreToolUse")[0], 2)
        self.assertEqual(self.rows(p)[0], 2)

    @unittest.skipIf(ROOT_USER, "root reads everything")
    def test_3_an_unreadable_manifest_with_the_dispatcher_registered_is_rc_2(self):
        p = self.surface(True)
        self.write_manifest()
        os.chmod(self.manifest, 0)
        self.addCleanup(os.chmod, self.manifest, stat.S_IRUSR | stat.S_IWUSR)
        self.assertEqual(self.call("registered_hook_scripts", p)[0], 2)
        self.assertEqual(self.rows(p)[0], 2)

    def test_4_no_dispatcher_no_manifest_needed_the_header_reason_is_kept(self):
        p = self.surface(False)
        rc, names = self.call("registered_hook_scripts", p)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(names), ["guard-own.sh", "guard-plain.sh"])
        self.assertEqual(self.rows(p)[0], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
