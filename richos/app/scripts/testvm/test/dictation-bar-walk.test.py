#!/usr/bin/env python3
"""dictation-bar-walk.py's verdicts, offline. The live walk is its own proof."""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent.parent
APP = HERE.parent.parent
spec = importlib.util.spec_from_file_location('dictation_bar_walk', HERE / 'dictation-bar-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class ReadingTheToolsLog(unittest.TestCase):
    def test_a_bar_line_with_fix_it(self):
        line = ('2026-10-08T09:00:00.000Z bar shown: problem no-microphone at 412,780 616x138; '
                'Fix it at 896,812 61x34')
        self.assertEqual(walk.bar_shown(line), {'view': 'problem no-microphone', 'frame': [412, 780, 616, 138],
                                                'fix': [896, 812, 61, 34]})
        self.assertEqual(walk.center([896, 812, 61, 34]), (926.5, 829.0))

    def test_a_bar_line_without_fix_it(self):
        self.assertEqual(walk.bar_shown('x bar shown: listening at 520,718 400x100'),
                         {'view': 'listening', 'frame': [520, 718, 400, 100]})
        self.assertIsNone(walk.bar_shown('x menu shown at 800,28 346x300'))

    def test_the_pattern_is_what_tool_rs_writes(self):
        # The walk reads tool.rs's own format string; a change there must be a change here.
        source = (APP / 'src-tauri/src/dictation/tool.rs').read_text()
        self.assertIn('"bar shown: {} at {:.0},{:.0} {:.0}x{:.0}{}"', source)
        self.assertIn('"; Fix it at {:.0},{:.0} {:.0}x{:.0}"', source)
        for said in ('menu shown at', 'menu closed', 'Fix it pressed', 'accuracy set to {model} from the menu bar',
                     'the words flew to', 'built as the {} type'):
            self.assertIn(said, source + (APP / 'src-tauri/src/dictation/bar.rs').read_text(), said)


class ReadingFrames(unittest.TestCase):
    def test_ocr_is_compared_by_letters(self):
        self.assertTrue(walk.read_contains('I need the micro-\nphone to hear you.', 'need the microphone to hear you'))
        self.assertTrue(walk.read_contains("I can’t hear anything.", walk.READ['no-sound']))
        self.assertFalse(walk.read_contains('Listening', walk.READ['writing']))

    def test_every_frame_fragment_is_a_drawn_line(self):
        page = (APP / 'ui/dictation-bar.js').read_text()
        squash = lambda s: re.sub(r'[^a-z]', '', s.lower())
        for fragment in walk.READ.values():
            self.assertIn(squash(fragment), squash(page), fragment)


class TheSteps(unittest.TestCase):
    def test_the_window_check_comes_before_the_bar_steps(self):
        steps = walk.STEPS
        self.assertLess(steps.index('check-panel'), steps.index('frames'))
        self.assertLess(steps.index('check-window'), steps.index('relaunch'))
        for step in steps:
            self.assertTrue(hasattr(walk.BarWalk, step.replace('-', '_')), step)


if __name__ == '__main__':
    unittest.main()
