#!/usr/bin/env python3
"""asked-again-walk.py's fixture and verdict helpers, offline. The live walk is its own proof."""
import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('asked_again_walk', HERE / 'asked-again-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)


class DeskLines(unittest.TestCase):
    def test_two_proposals_for_the_entity_with_a_torn_answer_between(self):
        lines = walk.desk_lines('ent_acme', 71, 1_790_000_000_000)
        self.assertEqual(len(lines), 3)
        asked, torn, ordinary = lines
        a, o = json.loads(asked), json.loads(ordinary)
        self.assertEqual((a['rec'], a['id'], a['entity_id'], a['state']), ('proposed', 'prop-71', 'ent_acme', 'awaiting-ceo'))
        self.assertEqual((o['id'], o['write']['recordRef']), ('prop-72', walk.REF_NEW))
        self.assertEqual(a['write']['recordRef'], walk.REF_ASKED)
        # The torn line is damage: it does not parse, and it starts as the answer to prop-71 would.
        with self.assertRaises(json.JSONDecodeError):
            json.loads(torn)
        self.assertTrue(torn.startswith('{"rec": "declined", "id": "prop-71"'))
        self.assertNotIn('\n', ''.join(lines))

    def test_refuses_a_proposal_scoped_to_nobody(self):
        with self.assertRaises(ValueError):
            walk.desk_lines('', 1, 0)
        with self.assertRaises(ValueError):
            walk.desk_lines(None, 1, 0)
        with self.assertRaises(ValueError):
            walk.desk_lines('ent_acme', 0, 0)


class Readers(unittest.TestCase):
    def test_numbers_already_in_the_log(self):
        self.assertEqual(walk.proposal_numbers('{"id":"prop-3"}\n{"id":"prop-12"}\n'), [3, 12])
        self.assertEqual(walk.proposal_numbers(''), [])

    def test_declines_are_read_from_whole_lines_only(self):
        lines = walk.desk_lines('ent_acme', 5, 0)
        log = '\n'.join(lines + [json.dumps({'rec': 'declined', 'id': 'prop-5', 'at': 9, 'permanent': False})])
        # The torn line names prop-5 too and must NOT count as a decline.
        self.assertEqual(walk.declined_ids(log), ['prop-5'])
        self.assertEqual(walk.declined_ids('\n'.join(lines)), [])

    def test_entity_of_config(self):
        self.assertEqual(walk.entity_of({'entity': 'ent_acme'}), 'ent_acme')
        self.assertIsNone(walk.entity_of({'entity': '  '}))
        self.assertIsNone(walk.entity_of({}))
        self.assertIsNone(walk.entity_of([]))


if __name__ == '__main__':
    unittest.main()
