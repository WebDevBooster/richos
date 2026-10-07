#!/usr/bin/env python3
"""voice-walk.py's verdicts, offline. The live walk is its own proof."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('voice_walk', HERE / 'voice-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class SpokenPrompt(unittest.TestCase):
    def test_an_internal_reprime_is_never_the_transcript(self):
        # The walk's first live run read this row as a transcript and passed.
        rows = [{'event': 'PromptReceived', 'source': 'internal', 'text': '[re-prime]'}]
        self.assertIsNone(walk.spoken_prompt(rows))

    def test_typed_and_empty_voice_prompts_are_not_it(self):
        rows = [{'event': 'PromptReceived', 'source': 'text', 'text': 'typed'},
                {'event': 'PromptReceived', 'source': 'jam', 'text': '  '}]
        self.assertIsNone(walk.spoken_prompt(rows))

    def test_the_first_voice_prompt_with_words_is_it(self):
        rows = [{'event': 'PromptReceived', 'source': 'internal', 'text': '[re-prime]'},
                {'event': 'PromptReceived', 'source': 'jam', 'text': 'Ship the new build tomorrow morning.'}]
        self.assertEqual(walk.spoken_prompt(rows)['text'], 'Ship the new build tomorrow morning.')


class DecoderIdentity(unittest.TestCase):
    def test_the_readiness_line_names_the_decoder_by_sha(self):
        line = ('[richos] voice: ready on this machine (ready) — whisper.cpp 1.9.1 bin:fe7b744a4b31 '
                'model:small.en@c6138d6d58ec | model:small.en (env-override)')
        self.assertEqual(walk.decoder_sha12(line), 'fe7b744a4b31')
        self.assertIsNone(walk.decoder_sha12('[richos] voice: ready on this machine (ready) — no sha'))


if __name__ == '__main__':
    unittest.main()
