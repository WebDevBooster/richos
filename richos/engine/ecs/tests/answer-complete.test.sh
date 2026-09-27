#!/usr/bin/env bash
#
# answer-complete.test.sh: the ECS app adapter's `answer-complete` verb, case by
# case. It is how the app closes the obligation of an assignment its own back end
# handled itself (a command he asked for, or an answer), on the digest of the words
# he was given; a code change still closes only through `complete` with its workers.
# The cases are AnswerCompleteTests in test_app.py, run one at a time so each prints
# its own PASS or FAIL line with its id (A1-A5).
#
# Usage: ecs/tests/answer-complete.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT="$(cd "$HERE/.." && pwd)"

(cd "$COMPONENT" && python3 - <<'P')
import sys
import unittest

sys.path.insert(0, ".")
from tests.test_app import AnswerCompleteTests

names = sorted(n for n in dir(AnswerCompleteTests) if n.startswith("test_A"))
failed = 0
for name in names:
    result = unittest.TestResult()
    AnswerCompleteTests(name).run(result)
    case = name[len("test_"):].replace("_", " ", 1)
    if result.wasSuccessful():
        print("  PASS  %s" % case)
    else:
        failed += 1
        print("  FAIL  %s" % case)
        for _test, trace in result.failures + result.errors:
            print("        " + trace.strip().splitlines()[-1][:300])
print("answer-complete: %d passed, %d FAILED" % (len(names) - failed, failed))
sys.exit(1 if failed or not names else 0)
P
