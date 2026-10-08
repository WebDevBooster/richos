#!/usr/bin/env python3
"""dictation-walk.py's verdicts, offline. The live walk is its own proof."""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent.parent
APP = HERE.parent.parent
spec = importlib.util.spec_from_file_location('dictation_walk', HERE / 'dictation-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class ExpectedWords(unittest.TestCase):
    def test_the_decode_flags_are_stt_rs_decode_args_without_a_prompt(self):
        # The expected words come from the same settings the tool decodes with, or the walk
        # judges a dictation against a decode the tool never ran.
        source = (APP / 'crates/richos-voice/src/stt.rs').read_text()
        body = source[source.index('pub fn decode_args('):]
        body = body[:body.index('];')]  # the vec literal: what every call gets, a prompt aside
        literals = re.findall(r'"([^"]+)"\.into\(\)', body)
        self.assertEqual(literals, ['-l', 'en', '-t', '4', '-fa', '-np', '-nt', '-mc'])
        self.assertIn('MAX_CONTEXT_NO_PROMPT', body)
        no_prompt = re.search(r'const MAX_CONTEXT_NO_PROMPT: &str = "(\d+)"', source).group(1)
        self.assertEqual(walk.DECODE_ARGS, literals + [no_prompt])

    def test_annotations_are_removed_as_stt_rs_removes_them(self):
        self.assertEqual(walk.strip_annotations(' Hi Dana, [BLANK_AUDIO] thanks. '), 'Hi Dana, thanks.')
        self.assertEqual(walk.strip_annotations('(upbeat music) Talk soon.'), 'Talk soon.')
        self.assertEqual(walk.strip_annotations('[BLANK_AUDIO]'), '')

    def test_words_ignore_case_and_punctuation_only(self):
        self.assertEqual(walk.words_of('Please send the numbers to Dana, by Friday.'),
                         ['please', 'send', 'the', 'numbers', 'to', 'dana', 'by', 'friday'])
        self.assertNotEqual(walk.words_of('Talk soon.'), walk.words_of('Talk soon now.'))


class ReadingTheGuest(unittest.TestCase):
    def test_ax_sh_phase_lines_are_not_the_answer(self):
        # walk-15a88cf29d54 read these framing lines as the clipboard and failed a restored one.
        framed = '{"ax_phase": "guest"}\nclipboard-before-0\n{"ax_guest_seconds": 0.1728}\n'
        self.assertEqual(walk.answer_of(framed), 'clipboard-before-0')
        self.assertEqual(walk.answer_of('box:Talk soon.'), 'box:Talk soon.')

    def walk_with(self, guest_answers):
        w = object.__new__(walk.DictationWalk)
        w.vm = 'walk-test'
        w.payload = '/Users/admin/testvm/payload'
        w.dlog = '/x/dictation.log'
        walk.guest = lambda vm, command, timeout=30: guest_answers(command)
        return w

    def test_only_the_tool_of_this_payload_is_the_tool(self):
        rows = '\n'.join([
            ' 501 1 /Users/admin/testvm/payload/RichOS.app/Contents/MacOS/richos-tauri',
            ' 502 501 /Users/admin/testvm/payload/RichOS.app/Contents/MacOS/richos-tauri --richos-dictation --data-dir /d --parent 501',
            ' 600 1 /Applications/RichOS.app/Contents/MacOS/richos-tauri --richos-dictation --data-dir /e',
            ' 700 650 /bin/zsh -c grep --richos-dictation',
        ])
        w = self.walk_with(lambda command: rows)
        self.assertEqual(w.tool_pids(), [{'pid': 502, 'ppid': 501, 'command': rows.splitlines()[1].split(None, 2)[2]}])

    def test_a_finished_dictation_is_a_line_with_its_model_or_its_refusal(self):
        log = '\n'.join([
            '2026-10-08T10:00:00.000Z dictation tool started: key F1, accuracy large-v3-turbo-q5_0, as the app\'s child',
            '2026-10-08T10:00:01.000Z key tap created for F1',
            '2026-10-08T10:00:09.000Z large-v3-turbo-q5_0 is not verified on this Mac yet; using small.en for this dictation',
            '2026-10-08T10:00:10.000Z dictation: model small.en, 3.42 s of audio, written in 911 ms, pasted, spacing read',
            '2026-10-08T10:00:30.000Z dictation of 0.20 s (200 ms tapped): nothing written, did-not-catch',
            '2026-10-08T10:00:40.000Z listening (injected wav (/x.wav))',
            # walk-770929407d2d waited 240 s past this line: an outcome that is not a paste.
            '2026-10-08T10:01:49.000Z whisper-cli did not write the words (bound 64 s): stt io: decoder deadline',
        ])
        w = self.walk_with(lambda command: log)
        lines = w.dictated_lines()
        self.assertEqual(len(lines), 3)
        self.assertIn('pasted', lines[0])
        self.assertIn('nothing written', lines[1])
        self.assertIn('did not write the words', lines[2])

    def test_every_step_is_a_method(self):
        for step in walk.STEPS:
            self.assertTrue(callable(getattr(walk.DictationWalk, step.replace('-', '_'), None)), step)


if __name__ == '__main__':
    unittest.main()
