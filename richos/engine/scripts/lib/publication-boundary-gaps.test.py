#!/usr/bin/env python3
"""publication-boundary.py must not call CLEAN a scan that skipped what it was given.

Hunt P5-08 (part 5): a declared private source that was oversized or unreadable
was skipped while the corpus was built (so a published quotation of it came
back CLEAN), and a published path it could not read was skipped with a comment
saying it was "reported" and no report. Now: an unreadable or oversized private
source is BROKEN (the guards already refuse on BROKEN), and an unreadable
published path ends the output with `UNREAD<TAB>path<TAB>why`, which both guards
print beside their CLEAN. What has nothing to compare against stays skipped: a
dangling link in a private tree, and a published path that was deleted.

Invented content only.
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
SCANNER = os.path.join(HERE, "publication-boundary.py")
SHELL = os.path.join(HERE, "publication-boundary.sh")
ROOT = os.geteuid() == 0 if hasattr(os, "geteuid") else False


class PublicationBoundaryGaps(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="pb-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.private = os.path.join(self.tmp, "private")
        os.makedirs(self.private)
        self.write(self.private, "notes.txt", "a short private note about nothing in particular\n")
        self.pub = self.write(self.tmp, "published.md", "hello, this is fine\n")

    def write(self, d, name, text):
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write(text)
        return p

    def scan(self, items=None, sources=None):
        job = {"min_speech_lines": 8, "min_quote_words": 10, "corpus_max_files": 4000,
               "corpus_max_bytes": 67108864, "corpus_may_be_empty": True,
               "sources": sources if sources is not None else [self.private],
               "private_files": [],
               "items": items if items is not None else [{"path": self.pub, "label": "published.md"}]}
        jp = os.path.join(self.tmp, "job.json")
        with open(jp, "w") as fh:
            json.dump(job, fh)
        res = subprocess.run([sys.executable, SCANNER, jp], capture_output=True, text=True)
        return res.stdout.splitlines()

    def test_1_control_a_readable_scan_is_clean_with_no_unread_line(self):
        out = self.scan()
        self.assertEqual(out[0], "CLEAN")
        self.assertFalse([l for l in out if l.startswith("UNREAD")])

    def test_2_an_oversized_private_source_is_broken_not_clean(self):
        self.write(self.private, "huge.txt", "word " * 1_700_000)        # > 8,000,000 bytes
        out = self.scan()
        self.assertEqual(out[0].split("\t")[0], "BROKEN", out[:2])
        self.assertIn("huge.txt", out[0])

    @unittest.skipIf(ROOT, "root reads everything")
    def test_3_an_unreadable_private_source_is_broken_not_clean(self):
        p = self.write(self.private, "locked.txt", "a private recording line\n")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, stat.S_IRUSR | stat.S_IWUSR)
        out = self.scan()
        self.assertEqual(out[0].split("\t")[0], "BROKEN", out[:2])
        self.assertIn("locked.txt", out[0])

    def test_4_a_dangling_link_in_a_private_tree_has_nothing_to_compare_and_stays_skipped(self):
        os.symlink(os.path.join(self.tmp, "gone.txt"), os.path.join(self.private, "dangling.txt"))
        self.assertEqual(self.scan()[0], "CLEAN")

    @unittest.skipIf(ROOT, "root reads everything")
    def test_5_an_unreadable_published_path_is_named_not_silent(self):
        p = self.write(self.tmp, "locked.md", "hello\n")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, stat.S_IRUSR | stat.S_IWUSR)
        out = self.scan(items=[{"path": p, "label": "locked.md"}])
        self.assertEqual(out[0], "CLEAN")                       # reported, not blocked: the code's own reason
        unread = [l.split("\t") for l in out if l.startswith("UNREAD")]
        self.assertEqual([u[1] for u in unread], ["locked.md"])

    def test_6_a_deleted_published_path_is_not_an_unread_path(self):
        out = self.scan(items=[{"path": os.path.join(self.tmp, "deleted.md"), "label": "deleted.md"}])
        self.assertEqual(out[0], "CLEAN")
        self.assertFalse([l for l in out if l.startswith("UNREAD")])

    def test_7_the_guards_print_the_unread_line_beside_their_clean(self):
        result = "CLEAN\nCORPUS\t1\t9\nIDENTITY\t0\nUNREAD\tdocs/a.md\tPermission denied\nUNREAD\tdocs/b.md\tPermission denied"
        res = subprocess.run(["bash", "-c", 'source "$1"; pb_unread_note guard-x.sh "$2"', "_", SHELL, result],
                             capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("2 path(s) could not be read", res.stderr)
        self.assertIn("docs/a.md", res.stderr)
        quiet = subprocess.run(["bash", "-c", 'source "$1"; pb_unread_note guard-x.sh "$2"', "_", SHELL, "CLEAN\nCORPUS\t1\t9"],
                               capture_output=True, text=True)
        self.assertEqual(quiet.stderr, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
