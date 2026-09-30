#!/usr/bin/env python3
"""operator-fences-admin-exec.test.py — the fence admin's reachability checks
count the executable bit (P5-44).

Git runs a hook only when it is executable. chain_reachable and check_one used to
judge a dispatcher, launcher, program and chain member by their text alone.
"""

import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("operator_fences_admin",
                                              os.path.join(HERE, "operator_fences_admin.py"))
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)
F = A.F


def sh(*cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fences-exec.")
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tmp]))
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        sh("git", "init", "-q", cwd=self.repo)
        self.repo = os.path.realpath(self.repo)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        self.addCleanup(self._restore_home)

    def _restore_home(self):
        if self.old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.old_home

    def chmod(self, path, mode):
        os.chmod(path, mode)


class ChainReachable(Fixture):
    def dispatcher(self, mode):
        d = os.path.join(self.tmp, "dispatch")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "reference-transaction")
        with open(p, "w") as fh:
            fh.write('#!/bin/sh\nexec "$(git rev-parse --git-common-dir)/hooks/x"\n')
        os.chmod(p, mode)
        sh("git", "config", "core.hooksPath", d, cwd=self.repo)

    def test_executable_chaining_dispatcher_is_reachable(self):
        self.dispatcher(0o755)
        ok, _ = A.chain_reachable(self.repo)
        self.assertTrue(ok)

    def test_non_executable_chaining_dispatcher_is_not_reachable(self):
        self.dispatcher(0o644)
        ok, _ = A.chain_reachable(self.repo)
        self.assertFalse(ok, "a mode-0644 dispatcher was called reachable")


class CheckOne(Fixture):
    def install_fake(self, launcher_mode, member_mode):
        common = os.path.join(self.repo, ".git")
        hooks = os.path.join(common, "hooks")
        os.makedirs(os.path.join(hooks, F.CHAIN_DIR), exist_ok=True)
        program = os.path.join(self.tmp, "operator_fences.py")
        with open(program, "w") as fh:
            fh.write("# program\n")
        os.chmod(program, 0o755)
        launcher = os.path.join(hooks, "reference-transaction")
        home, key = F.keyed_paths(self.repo)
        with open(launcher, "w") as fh:
            fh.write("#!/bin/sh\n# %s\n" % F.MARKER)
            fh.write('OPERATOR_FENCES_STATE="on"\n')
            fh.write('OPERATOR_FENCES_PROGRAM="%s"\n' % program)
            fh.write('OPERATOR_FENCES_HOME="%s"\n' % home)
            fh.write('OPERATOR_FENCES_KEY="%s"\n' % key)
        os.chmod(launcher, launcher_mode)
        member = os.path.join(hooks, F.CHAIN_DIR, "20-recorder.sh")
        with open(member, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(member, member_mode)
        reg = {"repositories": {self.repo: {"chain": ["20-recorder.sh"]}}}
        F.write_json_atomic(A.registry_path(), reg)
        return launcher, member

    def problems(self):
        return A.check_one(self.repo, "on-ready")

    def test_executable_launcher_and_member_raise_no_exec_problem(self):
        self.install_fake(0o755, 0o755)
        bad = [p for p in self.problems() if "executable" in p]
        self.assertEqual(bad, [])

    def test_non_executable_launcher_is_a_problem(self):
        self.install_fake(0o644, 0o755)
        self.assertTrue(any("launcher" in p and "not executable" in p for p in self.problems()),
                        self.problems())

    def test_non_executable_chain_member_is_a_problem(self):
        self.install_fake(0o755, 0o644)
        self.assertTrue(any("20-recorder.sh" in p and "not executable" in p for p in self.problems()),
                        self.problems())


if __name__ == "__main__":
    unittest.main()
