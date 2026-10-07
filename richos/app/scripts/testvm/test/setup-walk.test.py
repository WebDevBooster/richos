#!/usr/bin/env python3
"""setup-walk.py's verdicts, offline. The live walk is its own proof."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('setup_walk', HERE / 'setup-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class BootSetup(unittest.TestCase):
    def test_no_verdict_yet_is_none(self):
        self.assertIsNone(walk.boot_setup('[richos] this app: built from abc\n'))

    def test_the_video_tools_alone_missing(self):
        text = ('[richos] first-run setup: my video tools is NOT installed — 2 place(s) looked:\n'
                '[richos]   looked in /h/Library/Application Support/RichOS/tools/yt-dlp — no yt-dlp\n')
        self.assertEqual(walk.boot_setup(text), {'nothing_missing': False, 'missing': ['my video tools']})

    def test_nothing_missing(self):
        self.assertEqual(walk.boot_setup('[richos] first-run setup: nothing missing.\n'),
                         {'nothing_missing': True, 'missing': []})


class RunOutcome(unittest.TestCase):
    def test_still_running_progress_is_none(self):
        self.assertIsNone(walk.run_outcome('[richos] setup 1/1 started: Getting my video tools. 42%\n'))

    def test_finished_and_failed(self):
        self.assertEqual(walk.run_outcome('[richos] setup 1/1 finished: The software is installed.\n'), 'finished')
        self.assertEqual(walk.run_outcome('[richos] setup 1/1 FAILED — I couldn\'t reach the internet\n'), 'failed')

    def test_the_pins_file_is_found(self):
        self.assertTrue(walk.PINS.is_file(), walk.PINS)


if __name__ == '__main__':
    unittest.main()
