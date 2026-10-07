#!/usr/bin/env python3
"""token-track report: fixture transcript + fixture readings give a known tokens-per-point."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = 1791360000  # 2026-10-07T06:40:00Z


def iso(epoch):
    import datetime
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class Report(unittest.TestCase):
    def test_tokens_per_weekly_point(self):
        with tempfile.TemporaryDirectory() as d:
            folder = os.path.join(d, "acct")
            os.makedirs(os.path.join(folder, "projects", "p"))
            rows = []
            # msg a streamed twice (the larger copy counts); 3 weekly points in total
            for mid, at, model, u in [
                ("a", T0 + 10, "m1", dict(input_tokens=1, output_tokens=1, cache_creation_input_tokens=0, cache_read_input_tokens=0)),
                ("a", T0 + 11, "m1", dict(input_tokens=10, output_tokens=100, cache_creation_input_tokens=1000, cache_read_input_tokens=10000)),
                ("b", T0 + 400, "m2", dict(input_tokens=20, output_tokens=200, cache_creation_input_tokens=2000, cache_read_input_tokens=20000)),
                ("c", T0 + 5000, "m1", dict(input_tokens=999, output_tokens=999, cache_creation_input_tokens=999, cache_read_input_tokens=999)),
            ]:
                rows.append({"timestamp": iso(at), "message": {"id": mid, "model": model, "usage": u}})
            with open(os.path.join(folder, "projects", "p", "s.jsonl"), "w") as fh:
                fh.write("\n".join(json.dumps(r) for r in rows) + "\n")
            state = os.path.join(d, "state")
            os.makedirs(state)
            reset = T0 + 86400
            with open(os.path.join(state, "readings.jsonl"), "w") as fh:
                for at, used in [(T0, 50), (T0 + 600, 53)]:  # a and b fall inside; c after
                    fh.write(json.dumps({"at": at, "account": "x", "seven_day": {"used": used, "resets_at": reset}}) + "\n")
            env = dict(os.environ, TOKEN_TRACK_STATE=state)
            out = subprocess.run([sys.executable, os.path.join(HERE, "token-track.py"), "report", "--account", "x=" + folder],
                                 env=env, capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            # tokens: input 30, output 300, write 3000, read 30000 over 3 points
            self.assertIn("1 point = 11,110 tokens (input 10, output 100, cache write 1000, cache read 10000)", out.stdout)
            self.assertIn("3 points over 1 rises", out.stdout)


if __name__ == "__main__":
    unittest.main()
