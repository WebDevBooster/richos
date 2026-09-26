#!/usr/bin/env python3
"""nightly-local.mutation.py -- each property of gates-at-once, watched going red.

A green case is evidence of nothing until it has been seen to fail for its own reason. For
each mutant this removes ONE property from nightly-local.py, runs the case that owns the
property against the mutated module, and demands that case fail -- after first demanding it
pass against the unmutated source, so a case that cannot pass is never scored as a catch.

THE SHIPPED FILE IS NEVER OPENED FOR WRITING. The mutated text is compiled in memory under
the real file's name, so every path the module derives from `__file__` (the engine's
worker_tokens.py and proc_tree.py, the repository root) is the real one; nothing needs to
be restored however this run ends. The engine's mutation-harness.sh is the same idea for
engine files; this file lives outside the engine, so it carries its own small loop.

Invoked by nightly-local.test.sh. Exit 0 = every property proven load-bearing.
"""
import importlib.util
import io
from pathlib import Path
import sys
import time
import types
import unittest

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "nightly-local.py"

# (name, case in GatesAtOnceTests, old text, new text, what the build would do without it)
MUTANTS = (
    ("gates-run-one-at-a-time-despite-all",
     "test_independent_gates_run_at_the_same_time",
     'limit = len(gates) if self.gates_at_once == "all" else int(self.gates_at_once)',
     'limit = 1',
     "every gate would wait for the one before it however free the Mac is."),
    ("a-gate-starts-before-what-it-reads",
     "test_a_gate_waits_only_for_the_gate_whose_output_it_reads",
     'if not all(d in passed for d in GATE_AFTER.get(name, ())):',
     'if False:',
     "the lint would read a suite receipt not yet written, the privacy sweep a tree mid-rewrite."),
    ("more-gates-than-the-operator-chose",
     "test_the_number_of_gates_at_once_is_honored",
     'if len(running) >= limit:',
     'if False:',
     "ten busy engineers' Mac would get every gate at once whatever number was chosen."),
    ("a-failure-does-not-stop-the-rest",
     "test_one_failing_gate_refuses_the_build_and_stops_the_rest",
     'first = (name, error)\n                    self.groups.stop()',
     'first = (name, error)',
     "a refused build would keep simulators and cores busy until its slowest gate finished."),
    ("a-failure-does-not-refuse-the-build",
     "test_one_failing_gate_refuses_the_build_and_stops_the_rest",
     'raise first[1]',
     'pass',
     "a build with a red gate would go on to sign, notarize and publish."),
    ("the-phone-count-never-reaches-the-suites",
     "test_the_simulated_phone_count_reaches_the_suites_and_nothing_else_sets_it",
     'SIMULATED_PHONES_ENV: str(self.simulated_phones)}',
     'SIMULATED_PHONES_ENV: "1"}',
     "the chosen number of phones would be logged and ignored."),
    ("the-desktop-build-runs-the-phone-apps-suites",
     "test_the_desktop_build_runs_only_the_desktop_apps_suites",
     '"run-tests.sh", "--for", "desktop",',
     '"run-tests.sh",',
     "every phone-app suite, simulators included, would run inside the desktop nightly again."),
    ("the-desktop-build-asks-for-the-iphone-middle-size",
     "test_the_desktop_build_runs_only_the_desktop_apps_suites",
     '"RICHOS_IOS_POOL_WAIT": str(GATE_BUDGETS["gates/script-suites"]),',
     '"RICHOS_NATIVE_IOS_APP_A8": "1", "RICHOS_IOS_POOL_WAIT": str(GATE_BUDGETS["gates/script-suites"]),',
     "the desktop build would ask for A8, a phone-app case, the moment native-ios-app ran in it."),
    ("a-build-starts-without-both-numbers",
     "test_a_build_that_does_not_name_both_numbers_does_not_start",
     'if runs_gates and missing:',
     'if False:',
     "a forgotten decision would be a silent default, not a refusal."),
    ("the-chosen-numbers-are-not-logged",
     "test_the_chosen_numbers_and_who_chose_them_are_the_logs_first_lines",
     '            self.record_settings()\n        if command == "stable":',
     '            pass\n        if command == "stable":',
     "nobody could tell from a run log how it was told to run, or who told it."),
)


def load(text):
    """nightly-local.py from `text`, under the real file's name and path."""
    module = types.ModuleType("nightly_local_under_test")
    module.__file__ = str(SOURCE)
    exec(compile(text, str(SOURCE), "exec"), module.__dict__)
    return module


def tests_against(module):
    spec = importlib.util.spec_from_file_location("nightly_local_tests",
                                                  HERE / "nightly-local.test.py")
    tests = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tests)
    tests.m = module
    return tests


def passes(module, case):
    tests = tests_against(module)
    suite = unittest.defaultTestLoader.loadTestsFromName(f"GatesAtOnceTests.{case}", tests)
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    return result.testsRun == 1 and result.wasSuccessful()


def main():
    shipped = SOURCE.read_text()
    print("=== nightly-local gates-at-once: every property, proven load-bearing by removing it ===")
    failed = 0
    for case in sorted({case for _, case, *_ in MUTANTS}):
        if not passes(load(shipped), case):
            print(f"  FAIL  control: {case} is red on the UNMUTATED source, so it proves nothing")
            failed += 1
    proven = 0
    for name, case, old, new, why in MUTANTS:
        started = time.monotonic()
        count = shipped.count(old)
        if count != 1:
            print(f"  FAIL  {name}: the text to mutate appears {count} times, not once")
            failed += 1
            continue
        caught = not passes(load(shipped.replace(old, new)), case)
        took = time.monotonic() - started
        if caught:
            proven += 1
            print(f"  PASS  {name} -- removing it turns {case} red  [{took:.1f}s]")
        else:
            print(f"  FAIL  {name} -- {case} stayed green without it: {why}")
            failed += 1
    print(f"=== mutation: {proven} of {len(MUTANTS)} properties proven"
          f"{'' if failed else ' -- all load-bearing'} ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
