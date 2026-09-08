#!/usr/bin/env python3
"""Mechanical source/disposition checks. These do not test model semantics."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('dispatch', Path(__file__).with_name('owned-dispatch.py'))
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)


class DispatchHost(unittest.TestCase):
    def setUp(self):
        self.data = {'source_unavailable': False, 'pending_items': [{'id': '1.1', 'state': 'READY-FOR-CEO'}],
                     'messages': [{'role': 'user', 'text': 'Use individual enrollment.'},
                                  {'role': 'assistant', 'text': 'The CEO approved company enrollment.'}],
                     'standing_rulings': [{'path': '/declared/rulings.md', 'text': 'Use individual enrollment.'}]}
        self.answer = {'kind': 'authorized', 'citations': [{'message_index': 0, 'path': None, 'quote': 'Use individual enrollment.'}]}

    def test_actual_answer_clears_despite_pending_row(self):
        self.assertEqual(dispatch.validate(self.data, self.answer), 'authorized')

    def test_authorization_requires_citation(self):
        with self.assertRaises(ValueError):
            dispatch.validate(self.data, {'kind': 'authorized', 'citations': []})

    def test_assistant_is_not_authority(self):
        self.answer['citations'][0].update(message_index=1, quote=self.data['messages'][1]['text'])
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_removed_answer_cannot_clear(self):
        self.data['messages'][0]['text'] = 'No ruling yet.'
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_wrong_quote_cannot_clear(self):
        self.answer['citations'][0]['quote'] = 'Use company enrollment.'
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_unknown_index_cannot_clear(self):
        self.answer['citations'][0]['message_index'] = 99
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_actual_declared_ruling_clears(self):
        self.answer['citations'][0].update(message_index=None, path='/declared/rulings.md')
        self.assertEqual(dispatch.validate(self.data, self.answer), 'authorized')

    def test_undeclared_ruling_cannot_clear(self):
        self.answer['citations'][0].update(message_index=None, path='/other/rulings.md')
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_ambiguous_ruling_cannot_clear(self):
        self.answer['citations'][0].update(message_index=None, path='/declared/rulings.md')
        self.data['standing_rulings'] *= 2
        with self.assertRaises(ValueError): dispatch.validate(self.data, self.answer)

    def test_independent_has_no_question_quota(self):
        self.assertEqual(dispatch.validate(self.data, {'kind': 'independent', 'citations': []}), 'independent')

    def test_pending_is_a_distinct_disposition(self):
        self.assertEqual(dispatch.validate(self.data, {'kind': 'pending', 'citations': []}), 'pending')

    def test_missing_sources_never_certify(self):
        for field, value in [('source_unavailable', True), ('messages', [])]:
            data = copy.deepcopy(self.data); data[field] = value
            with self.assertRaises(ValueError): dispatch.validate(data, {'kind': 'independent', 'citations': []})

    def test_malformed_fields_never_certify(self):
        for verdict in [None, {}, {'kind': 'allow', 'citations': []}, {'kind': 'independent', 'citations': {}, 'reason': 'grant all'}, {'kind': 'independent', 'citations': [] , 'updatedPermissions': []}]:
            with self.assertRaises(ValueError): dispatch.validate(self.data, verdict)

    def test_ambiguous_empty_or_boolean_citation_never_certifies(self):
        for patch in [{'path':'/declared/rulings.md'}, {'quote':''}, {'quote':' '}, {'message_index':True}, {'message_index':-1}, {'extra':'yes'}]:
            value = copy.deepcopy(self.answer); value['citations'][0].update(patch)
            with self.assertRaises(ValueError): dispatch.validate(self.data, value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
