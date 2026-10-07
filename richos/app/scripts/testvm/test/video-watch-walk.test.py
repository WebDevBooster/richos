#!/usr/bin/env python3
"""video-watch-walk.py's setup verdicts, offline. The live walk is its own proof.

The walk of candidate 44 found its setup step calling setup_walk.run_outcome, which setup-walk.py
no longer has since 3c614b443 (an AttributeError, outside the walk's caught failures), and
waiting for a setup sheet that a build downloading the video tools in the background
(a4facb643) never shows for them."""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('video_watch_walk', HERE / 'video-watch-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class BackgroundDownload(unittest.TestCase):
    def test_the_boot_line_is_read(self):
        text = ('[richos] first-run setup: my video tools is NOT installed\n'
                '[richos] video tools: downloading in the background\n')
        self.assertTrue(walk.background_download(text))

    def test_a_build_without_it_is_not_background(self):
        self.assertFalse(walk.background_download('[richos] first-run setup: my video tools is NOT installed\n'))
        self.assertFalse(walk.background_download('[richos] video tools in the background 1/1 started: Getting my video tools.\n'))


class SetupWalkNames(unittest.TestCase):
    def test_every_setup_walk_name_this_walk_calls_exists(self):
        source = (HERE / 'video-watch-walk.py').read_text()
        for name in set(re.findall(r'setup_walk\.(\w+)', source)):
            self.assertTrue(hasattr(walk.setup_walk, name), f'setup-walk.py has no {name}')

    def test_the_outcome_it_waits_for(self):
        done = '[richos] video tools in the background 1/1 done: My video tools are installed.\n'
        self.assertEqual(walk.setup_walk.tools_outcome(done), 'done')


if __name__ == '__main__':
    unittest.main()
