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


class ToolsOutcome(unittest.TestCase):
    def test_still_running_progress_is_none(self):
        self.assertIsNone(walk.tools_outcome('[richos] video tools in the background 1/1 started: Getting my video tools. 42%\n'))

    def test_done_from_the_background_or_a_press(self):
        for source in ('video tools in the background', 'setup'):
            self.assertEqual(walk.tools_outcome(f'[richos] {source} 1/1 done: My video tools are installed.\n'), 'done')
        self.assertEqual(walk.tools_outcome('[richos] video tools in the background 1/1 FAILED — no internet\n'), 'failed')

    def test_the_pins_file_is_found(self):
        self.assertTrue(walk.PINS.is_file(), walk.PINS)
        self.assertEqual(walk.pinned_bytes(), {walk.VOICE: 487614201, walk.TRANSCRIPTION: 574041195})


class DownloadProgress(unittest.TestCase):
    want = {walk.VOICE: 100, walk.TRANSCRIPTION: 200}

    def test_partials_count_and_are_not_done(self):
        p = walk.download_progress({walk.VOICE: 100, walk.TRANSCRIPTION + '.part': 50}, self.want)
        self.assertEqual(p, {'bytes': 150, 'of': 300, 'done': False})

    def test_both_whole_is_done(self):
        p = walk.download_progress({walk.VOICE: 100, walk.TRANSCRIPTION: 200, 'other.bin': 9}, self.want)
        self.assertEqual(p, {'bytes': 300, 'of': 300, 'done': True})


def row(event, got, done=False, pressed=False):
    return {'event': event, 'since_launch_s': 0, 'downloaded_bytes': got, 'download_done': done, 'pressed': pressed}


USER = [row(name, 10, pressed=True) for name in walk.USER_MOMENTS]


class MeanwhileVerdict(unittest.TestCase):
    def test_running_from_launch_and_through_first_setup_passes(self):
        self.assertIsNone(walk.meanwhile_verdict([row('walk begins', 0), row('models arriving', 5)] + USER))

    def test_a_download_that_needs_a_press_fails(self):
        t = [row('walk begins', 0), row('setup sheet: "Set it up" pressed', 0, pressed=True), row('x', 5)] + USER
        self.assertIn('only after a press', walk.meanwhile_verdict(t))

    def test_first_setup_after_the_download_fails(self):
        t = [row('walk begins', 1)] + [row(name, 99, done=True, pressed=True) for name in walk.USER_MOMENTS]
        self.assertIn('after the download had finished', walk.meanwhile_verdict(t))


if __name__ == '__main__':
    unittest.main()
