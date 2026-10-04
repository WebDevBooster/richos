#!/usr/bin/env python3
"""No tunnel needed: a reading without the request counter is a gap, never zero requests
(hunt part 2 v3, R39). The readings are hand-written in the file shape `sample` writes."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("tunnel_requests", Path(__file__).with_name("tunnel-requests.py"))
tunnel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tunnel)


class MissingCounterIsAGap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file = Path(self.tmp.name) / "counters.txt"

    def tearDown(self):
        self.tmp.cleanup()

    def between(self, text, frm, to):
        self.file.write_text(text)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tunnel.between(SimpleNamespace(file=str(self.file), frm=frm, to=to))
        return code, out.getvalue(), err.getvalue()

    def test_readings_without_the_request_counter_are_not_zero_requests(self):
        code, out, _ = self.between("1 total_requests=7 request_errors=0\n2 request_errors=0\n3 request_errors=0\n", 2.0, 3.0)
        self.assertEqual(code, 2, f"a window with no request counter was counted: {out}")

    def test_an_explicit_unreadable_reading_is_still_refused(self):
        code, _, _ = self.between("1 total_requests=7\n2 unreadable missing\n3 total_requests=8\n", 1.0, 3.0)
        self.assertEqual(code, 2)

    def test_complete_readings_are_counted(self):
        code, out, _ = self.between("1 total_requests=7\n2 total_requests=7\n3 total_requests=9\n", 1.0, 3.0)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["requests"], 2)

    def test_sample_writes_a_reading_without_the_counter_as_unreadable(self):
        reads = []

        def read(_port):  # the first reading has the counter, every later one lacks it
            reads.append(1)
            return "cloudflared_tunnel_total_requests 7\n" if len(reads) == 1 else "cloudflared_tunnel_request_errors 0\n"
        clock = [100.0]

        def now():
            clock[0] += 0.1
            return clock[0]
        with patch.object(tunnel, "read", read), patch.object(tunnel.time, "time", now), \
                patch.object(tunnel.time, "sleep", lambda _s: None):
            code = tunnel.sample(SimpleNamespace(port=1, out=str(self.file), seconds=0.5, interval=0.1))
        lines = self.file.read_text().splitlines()
        self.assertEqual(code, 0)
        self.assertIn("total_requests=7", lines[0])
        self.assertIn("unreadable", lines[1], lines)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    print("OK" if result.wasSuccessful() else "FAILED")
    raise SystemExit(0 if result.wasSuccessful() else 1)
