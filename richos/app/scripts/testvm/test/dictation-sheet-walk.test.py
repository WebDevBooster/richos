#!/usr/bin/env python3
"""dictation-sheet-walk.py's verdicts and the words it reads, offline. The live walk is its own proof."""
import importlib.util
from pathlib import Path
import plistlib
import unittest

HERE = Path(__file__).resolve().parent.parent
APP = HERE.parent.parent
spec = importlib.util.spec_from_file_location('dictation_sheet_walk', HERE / 'dictation-sheet-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class TheWordsItReads(unittest.TestCase):
    """A walk that looks for words the product no longer draws fails for the wrong reason; each
    is checked against the source it comes from."""

    def test_iris_sentence_is_the_microphone_usage_string(self):
        plist = plistlib.loads((APP / 'src-tauri/Info.plist').read_bytes())
        sentence = plist['NSMicrophoneUsageDescription']
        self.assertEqual(sentence, 'So you can talk instead of typing. I listen only after you tap F1 or press the talk button.')
        for fragment in walk.IRIS_FRAGMENTS:
            self.assertIn(fragment, sentence)

    def test_the_sheet_lines_are_the_ones_dictation_js_draws(self):
        source = (APP / 'ui/dictation.js').read_text()
        self.assertIn('On. Tap ${kcap(k)} ' + walk.ON_RUN, source)
        self.assertIn(walk.DENIED_LINE, source)
        self.assertIn('["' + walk.OTHER_ROW + '", false]', source)
        self.assertIn(walk.OTHER_ROW + '. Tap ${kcap(k)} in any app and talk.', source)


class TheSteps(unittest.TestCase):
    def test_each_step_is_defined_once(self):
        """A helper given a step's method name replaces the step or is replaced by it (walk
        490c9ae819b3: a helper named open_settings was shadowed by the open-settings step, so
        opening the sheet pressed Open System Settings)."""
        source = (HERE / 'dictation-sheet-walk.py').read_text()
        for step in walk.STEPS:
            name = step.replace('-', '_')
            self.assertTrue(hasattr(walk.SheetWalk, name), name)  # here or inherited (identity)
            self.assertLessEqual(source.count(f'    def {name}(self'), 1, name)


class TheVerdicts(unittest.TestCase):
    def test_within_two_seconds_allows_one_round_trip(self):
        self.assertTrue(walk.grant_seconds_ok(0.4))
        self.assertTrue(walk.grant_seconds_ok(2.9))
        self.assertFalse(walk.grant_seconds_ok(3.2))
        self.assertFalse(walk.grant_seconds_ok(None))

    def test_the_steps_start_from_no_grants_and_end_with_the_second_copy(self):
        self.assertEqual(walk.STEPS[:3], ['identity', 'stage', 'relaunch'])
        self.assertLess(walk.STEPS.index('mic-prompt'), walk.STEPS.index('ax-prompt'))
        self.assertLess(walk.STEPS.index('ax-prompt'), walk.STEPS.index('granted'))
        self.assertEqual(walk.STEPS[-1], 'second-copy')

    def test_the_grant_rows_name_only_this_app(self):
        sql = walk.GRANT.format(svc='kTCCServiceAccessibility')
        self.assertIn("'kTCCServiceAccessibility', 'com.richos.app'", sql)


if __name__ == '__main__':
    unittest.main()
