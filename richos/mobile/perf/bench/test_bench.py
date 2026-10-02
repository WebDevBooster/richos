"""Tests of `randroid device bench`: argument handling, the refusals, and the parsers. No phone is touched.

    python3 -m unittest richos/mobile/perf/bench/test_bench.py
"""
import contextlib
import io
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench  # noqa: E402

REPORT = """2K performance run parameters for coremark.
Iterations/Sec   : 1234.567890
Iterations       : 14000
Total time (secs): 11.340000
Correct operation validated. See README.md for run and reporting rules.
CoreMark 1.0 : 1234.567890 / GCC / -O2 / Heap / 8:PThreads
"""


class Args(unittest.TestCase):
    def test_defaults(self):
        a = bench.parse_args(["--serial", "S"])
        self.assertEqual((a.what, a.runs, a.trials), ("all", 3, 20))

    def test_a_serial_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            bench.parse_args(["chip"])

    def test_unknown_what_and_zero_counts_are_refused(self):
        for argv in (["--serial", "S", "nope"], ["--serial", "S", "--runs", "0"], ["--serial", "S", "--trials", "0"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                bench.parse_args(argv)

    def test_it_refuses_a_phone_outside_the_randroid_verb(self):
        os.environ.pop("RICHOS_DEVICE_VERB", None)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = bench.main(["--serial", "S", "chip"])
        self.assertEqual(code, 3)
        self.assertIn("randroid device", err.getvalue())

    def test_only_the_benchmark_app_is_ever_removed(self):
        self.assertEqual(bench.EMPTY_PACKAGE, "dev.richos.bench.empty")
        self.assertNotEqual(bench.EMPTY_PACKAGE, "dev.richos.connect")


class Parsers(unittest.TestCase):
    def test_coremark_valid_run(self):
        r = bench.parse_coremark(REPORT)
        self.assertEqual((r["iterations_per_sec"], r["total_seconds"], r["valid"]), (1234.56789, 11.34, True))

    def test_coremark_short_or_unvalidated_run_is_not_valid(self):
        self.assertFalse(bench.parse_coremark(REPORT.replace("11.340000", "4.0"))["valid"])
        self.assertFalse(bench.parse_coremark(REPORT.replace("Correct operation validated", "ERROR"))["valid"])

    def test_coremark_garbage_raises(self):
        with self.assertRaises(ValueError):
            bench.parse_coremark("Segmentation fault")

    def test_percentiles(self):
        values = list(range(1, 21))
        s = bench.summarize(values)
        self.assertEqual((s["median"], s["p95"], s["min"], s["max"], s["n"]), (10.5, 19, 1, 20, 20))

    def test_chip(self):
        chip = bench.parse_chip({"ro.soc.model": "MT6769"}, {0: 1800000, 1: 1800000, 2: 2000000},
                                "MemTotal:        3853036 kB\n", "CPU part\t: 0xd05\nCPU part\t: 0xd0a\n")
        self.assertEqual(chip["cores"], 3)
        self.assertEqual([c["max_mhz"] for c in chip["clusters"]], [1800, 2000])
        self.assertEqual(chip["ram_mib"], 3763)


if __name__ == "__main__":
    unittest.main()
