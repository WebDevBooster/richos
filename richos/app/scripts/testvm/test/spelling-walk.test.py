#!/usr/bin/env python3
"""spelling-walk.py's verdict, offline. The live walk is its own proof.

Every British word here comes from the declared British test-input file the walk itself reads
(engine/scripts/lib/dialect/fixtures/stream-a-app.txt); this file carries none.
"""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('spelling_walk', HERE / 'spelling-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

SENTENCE = walk.section('vm-sentence')
BRITISH = walk.section('vm-british-words').split()
AMERICAN = walk.section('vm-american-words').split()


def american(text):
    for b, a in zip(BRITISH, AMERICAN):
        text = re.sub(r'(?<![A-Za-z])' + b + r'(?![A-Za-z])', a, text)
    return text


def evidence(**over):
    value = {'ended': 'TurnCompleted', 'prompt_stored': 'copy this: ' + SENTENCE,
             'model_words': 'x1 ' + SENTENCE, 'reply_stored': 'x1 ' + american(SENTENCE),
             'reply_shown': 'x1 ' + american(SENTENCE)}
    value.update(over)
    return value


def verdict(value, expect='american'):
    return walk.verdict(value, SENTENCE, BRITISH, AMERICAN, expect)


class Verdict(unittest.TestCase):
    def test_the_fixture_is_what_the_walk_needs(self):
        self.assertEqual(len(BRITISH), len(AMERICAN))
        self.assertEqual(walk.words_in(SENTENCE, BRITISH), BRITISH)
        self.assertEqual(walk.words_in(american(SENTENCE), BRITISH), [])

    def test_a_british_model_reply_stored_and_shown_american_passes(self):
        self.assertEqual(verdict(evidence()), [])

    def test_a_reply_still_british_where_he_reads_it_fails_on_that_surface(self):
        failures = verdict(evidence(reply_shown='x1 ' + SENTENCE))
        self.assertTrue(any(f.startswith('reply_shown: still British') for f in failures), failures)
        failures = verdict(evidence(reply_stored='x1 ' + SENTENCE))
        self.assertTrue(any(f.startswith('reply_stored: still British') for f in failures), failures)

    def test_a_model_that_wrote_american_itself_proves_nothing(self):
        failures = verdict(evidence(model_words='x1 ' + american(SENTENCE)))
        self.assertTrue(any(f.startswith('INCONCLUSIVE') for f in failures), failures)

    def test_his_words_rewritten_fail_even_on_the_baseline(self):
        for expect in ('american', 'as-written'):
            failures = verdict(evidence(prompt_stored='copy this: ' + american(SENTENCE)), expect)
            self.assertIn('his words were not stored as he wrote them', failures)

    def test_a_write_made_british_that_ran_american_passes_as_vm_run_4_did(self):
        # Run 4 (walk-6293ecb03c58): PreToolUse content British, PostToolUse content American.
        self.assertEqual(walk.document_verdict(SENTENCE + '\n', american(SENTENCE) + '\n', BRITISH, AMERICAN), [])

    def test_a_write_that_ran_british_fails(self):
        failures = walk.document_verdict(SENTENCE, SENTENCE, BRITISH, AMERICAN)
        self.assertTrue(any(f.startswith('the write ran British') for f in failures), failures)

    def test_a_document_never_seen_by_a_write_hook_or_written_american_proves_nothing(self):
        self.assertTrue(walk.document_verdict(None, american(SENTENCE), BRITISH, AMERICAN)[0].startswith('INCONCLUSIVE'))
        failures = walk.document_verdict(american(SENTENCE), american(SENTENCE), BRITISH, AMERICAN)
        self.assertTrue(any(f.startswith('INCONCLUSIVE') for f in failures), failures)
        self.assertTrue(any('unknown' in f for f in walk.document_verdict(SENTENCE, None, BRITISH, AMERICAN)))

    def test_body_of_reads_each_write_tool(self):
        self.assertEqual(walk.body_of({'content': 'a'}), 'a')
        self.assertEqual(walk.body_of({'old_string': 'x', 'new_string': 'b'}), 'b')
        self.assertEqual(walk.body_of({'edits': [{'new_string': 'c'}, {'new_string': 'd'}]}), 'cd')
        self.assertIsNone(walk.body_of(None))

    def test_the_baseline_only_needs_a_completed_turn(self):
        self.assertEqual(verdict(evidence(reply_stored='x1 ' + SENTENCE), 'as-written'), [])
        self.assertTrue(verdict(evidence(ended='TurnInterrupted'), 'as-written'))


if __name__ == '__main__':
    unittest.main()
