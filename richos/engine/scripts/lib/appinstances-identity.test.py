#!/usr/bin/env python3
"""appinstances-identity.test.py — P5-47: the ps shortlist took the basename of
EVERY argument, so a shell whose arguments merely mention the app
(`bash -c "cargo run -p richos-tauri"`) was shortlisted, and a scratch cwd then
made it COLLECT. Only a process whose executable (comm or argv[0]) is an app
binary is an app instance.
"""

import importlib.util
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("appinstances", os.path.join(HERE, "appinstances.py"))
A = importlib.util.module_from_spec(spec)
sys.modules["appinstances"] = A
spec.loader.exec_module(A)


class FakePs(object):
    returncode = 0

    def __init__(self, stdout):
        self.stdout = stdout


def with_ps(lines):
    return mock.patch.object(A.subprocess, "run", return_value=FakePs("\n".join(lines) + "\n"))


class Shortlist(unittest.TestCase):
    def setUp(self):
        self.names = mock.patch.object(A, "app_process_names", return_value={"richos-tauri"})
        self.names.start()
        self.addCleanup(self.names.stop)

    def shortlisted(self, lines):
        with with_ps(lines):
            return A.candidate_pids()

    def test_the_app_binary_is_shortlisted(self):
        got = self.shortlisted(["  4001 /x/target/debug/richos-tauri /x/target/debug/richos-tauri --flag"])
        self.assertIn(4001, got)

    def test_argv0_naming_the_app_is_shortlisted(self):
        got = self.shortlisted(["  4002 /opt/launcher richos-tauri --flag"])
        self.assertIn(4002, got)

    def test_a_shell_whose_argument_mentions_the_app_is_not(self):
        got = self.shortlisted(["  4003 /bin/bash bash -c cargo run -p richos-tauri"])
        self.assertNotIn(4003, got, "a wrapper shell was shortlisted by an argument")

    def test_an_editor_with_the_app_path_as_an_argument_is_not(self):
        got = self.shortlisted(["  4004 /usr/bin/vim vim /x/target/debug/richos-tauri"])
        self.assertNotIn(4004, got)


if __name__ == "__main__":
    unittest.main()
