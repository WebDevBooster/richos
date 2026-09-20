import copy
import unittest
from common import Refusal
from ratchet import NOTE, check, compare, lower


def record():
    return dict(schema=1, limitation=NOTE, commands={'scan': ['scanner']},
                versions={'scanner': '1'}, rules={'a': 'blocking', 'b': 'blocking'},
                inventory={'one.sh': {'language': 'shell', 'role': 'production'}},
                counts={'a': 2, 'b': 0})


class Ratchet(unittest.TestCase):
    def test_check_does_not_mutate(self):
        baseline = record()
        before = copy.deepcopy(baseline)
        actual = record()
        actual['counts']['a'] = 1
        check(actual, baseline)
        self.assertEqual(baseline, before)
        self.assertEqual(lower(actual, baseline)['counts']['a'], 1)

    def test_defeats(self):
        for change in ('growth', 'rule', 'inventory', 'classification', 'tool', 'command', 'count'):
            candidate = record()
            if change == 'growth': candidate['counts']['a'] = 3
            if change == 'rule': del candidate['rules']['b']
            if change == 'inventory': candidate['inventory'] = {'other.sh': {}}
            if change == 'classification': candidate['rules']['a'] = 'advisory'
            if change == 'tool': candidate['versions']['scanner'] = '2'
            if change == 'command': candidate['commands']['scan'] = ['true']
            if change == 'count': del candidate['counts']['b']
            with self.subTest(change=change), self.assertRaises(Refusal):
                compare(candidate, record())

    def test_lower_refuses_growth(self):
        actual = record()
        actual['counts']['a'] = 3
        with self.assertRaises(Refusal):
            lower(actual, record())

    def test_new_file_is_not_exempt(self):
        actual = record()
        actual['inventory']['two.sh'] = actual['inventory']['one.sh']
        actual['counts']['new-rule'] = 1
        with self.assertRaises(Refusal):
            check(actual, record())
