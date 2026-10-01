#!/usr/bin/env python3
"""named-persons.py must not call CLEAN a scan that left a file or message unread.

Hunt P5-08 (part 5): an oversized or unreadable file in --scan-files /
--scan-file-list, and an oversized or unreadable `-F <message file>` in a
--scan-payload Bash command, were dropped from the scan and the verdict was
CLEAN. They are now BROKEN (the guards already refuse on BROKEN). What has
nothing to read stays skipped, because that was the code's own reason: a binary
blob (its PATH is still scanned), a path that does not exist (a deletion, or a
file the same command writes) and a `-F` that is not a file.

The token below is invented; no real name appears in this suite.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PRED = os.path.join(HERE, "named-persons.py")
CAP = 8 * 1024 * 1024
NAME = "zzqxfixtureword"


class NamedPersonsGaps(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="np-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.list = os.path.join(self.tmp, "deny-list")
        with open(self.list, "w") as fh:
            fh.write("token: %s\n" % NAME)
        os.chmod(self.list, 0o600)

    def write(self, name, data, binary=False):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as fh:
            fh.write(data if binary else data.encode())
        return p

    def run_pred(self, mode, paths=(), stdin=None):
        if mode == "--scan-file-list":
            stdin = "\0".join(paths) + "\0"
            args = [sys.executable, PRED, mode, "--list", self.list]
        elif mode == "--scan-files":
            args = [sys.executable, PRED, mode] + list(paths) + ["--list", self.list]
        else:
            args = [sys.executable, PRED, mode, "--list", self.list]
        res = subprocess.run(args, input=stdin, capture_output=True, text=True)
        return res.stdout.splitlines()[0].split("\t")[0] if res.stdout else "NOOUTPUT:" + res.stderr

    def payload(self, command):
        return json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})

    # ---- files ---------------------------------------------------------
    def test_1_controls_a_listed_name_is_found_and_plain_text_is_clean(self):
        hit = self.write("hit.txt", "hello %s\n" % NAME)
        ok = self.write("ok.txt", "nothing here\n")
        self.assertEqual(self.run_pred("--scan-files", [hit]), "FOUND")
        self.assertEqual(self.run_pred("--scan-files", [ok]), "CLEAN")

    def test_2_an_oversized_text_file_is_broken_not_clean(self):
        big = self.write("big.txt", "a" * (CAP + 1))
        for mode in ("--scan-files", "--scan-file-list"):
            self.assertEqual(self.run_pred(mode, [big]), "BROKEN", mode)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads everything")
    def test_3_an_unreadable_file_is_broken_not_clean(self):
        p = self.write("locked.txt", "text\n")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, stat.S_IRUSR | stat.S_IWUSR)
        for mode in ("--scan-files", "--scan-file-list"):
            self.assertEqual(self.run_pred(mode, [p]), "BROKEN", mode)

    def test_4_what_has_no_text_to_read_stays_skipped(self):
        blob = self.write("blob.bin", b"\0" + b"a" * (CAP + 1), binary=True)   # large AND binary
        self.assertEqual(self.run_pred("--scan-files", [blob]), "CLEAN")
        self.assertEqual(self.run_pred("--scan-files", [os.path.join(self.tmp, "deleted.txt")]), "CLEAN")
        self.assertEqual(self.run_pred("--scan-files", [self.tmp]), "CLEAN")   # a directory

    def test_5_a_found_name_outranks_an_unread_file(self):
        hit = self.write("hit.txt", "hello %s\n" % NAME)
        big = self.write("big.txt", "a" * (CAP + 1))
        self.assertEqual(self.run_pred("--scan-files", [big, hit]), "FOUND")

    # ---- a commit message file named in a Bash command -------------------
    def test_6_an_oversized_message_file_is_broken_not_clean(self):
        big = self.write("msg-big.txt", "a" * (CAP + 1))
        self.assertEqual(self.run_pred("--scan-payload", stdin=self.payload("git commit -F %s" % big)), "BROKEN")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads everything")
    def test_7_an_unreadable_message_file_is_broken_not_clean(self):
        p = self.write("msg-locked.txt", "text\n")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, stat.S_IRUSR | stat.S_IWUSR)
        self.assertEqual(self.run_pred("--scan-payload", stdin=self.payload("git commit -F %s" % p)), "BROKEN")

    def test_8_message_file_controls(self):
        hit = self.write("msg-hit.txt", "subject %s\n" % NAME)
        ok = self.write("msg-ok.txt", "subject\n")
        self.assertEqual(self.run_pred("--scan-payload", stdin=self.payload("git commit -F %s" % hit)), "FOUND")
        self.assertEqual(self.run_pred("--scan-payload", stdin=self.payload("git commit -F %s" % ok)), "CLEAN")
        # Not a file at all: stdin, a file this same command writes, `grep -F pattern`.
        for cmd in ("git commit -F -", "git commit -F %s/not-yet" % self.tmp, "grep -F pattern somewhere"):
            self.assertEqual(self.run_pred("--scan-payload", stdin=self.payload(cmd)), "CLEAN", cmd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
