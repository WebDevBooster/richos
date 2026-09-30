#!/usr/bin/env python3
"""escalations-delivery.test.py — an oversized first escalation is never
recorded as delivered while the model could not read all of it (P5-37).

The host caps a Stop hook's additionalContext at 10,000 characters and swaps a
longer value for a 2,000-character preview. render_delivery stays under
DELIVERY_BUDGET for everything but the FIRST entry, which was allowed past it so
delivery always makes progress. That entry's id was then recorded as delivered
although its end never reached the model.
"""

import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("escalations", os.path.join(HERE, "escalations.py"))
E = importlib.util.module_from_spec(spec)
sys.modules["escalations"] = E
spec.loader.exec_module(E)


def entry(n, question):
    return {"id": "esc-20260930T0000%02dZ-0000000%d" % (n, n), "title": "t%d" % n,
            "teammate": "zach", "state": "stopped", "for": "lead", "question": question,
            "age_min": 1}


class OversizedFirstEntry(unittest.TestCase):
    def test_whole_delivery_stays_under_the_host_cap(self):
        text, sent = E.render_delivery([entry(1, "Q" * 12000 + " QUESTION-END")], 0)
        self.assertLess(len(text), E.HOST_CONTEXT_CAP)

    def test_a_cut_question_says_so_and_names_how_to_read_it(self):
        e = entry(1, "Q" * 12000 + " QUESTION-END")
        text, sent = E.render_delivery([e], 0)
        self.assertTrue("QUESTION-END" not in text, "the end of a cut question leaked through")
        self.assertTrue("TRUNCATED" in text, "a cut question does not say it was cut")
        self.assertTrue("escalate.sh show %s" % e["id"] in text, "no pointer to the full text")

    def test_the_visible_preview_is_not_the_only_place_the_pointer_lives(self):
        # The host's preview is the first 2,000 characters when the value is
        # over the cap; staying under the cap means the model gets all of it,
        # pointer included.
        e = entry(1, "Q" * 12000)
        text, _ = E.render_delivery([e], 0)
        self.assertLessEqual(len(text), E.DELIVERY_BUDGET + 1500)

    def test_a_normal_entry_is_untouched(self):
        e = entry(1, "short question")
        text, sent = E.render_delivery([e], 0)
        self.assertIn("short question", text)
        self.assertNotIn("TRUNCATED", text)
        self.assertEqual(sent, [e["id"]])


if __name__ == "__main__":
    unittest.main()
