#!/usr/bin/env bash
#
# operator-complete.test.sh: the ECS app adapter's `operator-complete` verb, case
# by case (richos-hq operator back-end spec r1 (c), r3 (c)). The cases are
# OperatorCompleteTests in test_app.py, run one at a time so each prints its own
# PASS or FAIL line with its id (O1-O8), which is what the mutation harness
# (operator-complete.mutation.sh) reads.
#
# Usage: ecs/tests/operator-complete.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT="$(cd "$HERE/.." && pwd)"

(cd "$COMPONENT" && python3 - <<'P')
import sys
import unittest

sys.path.insert(0, ".")
from tests.test_app import OperatorCompleteTests

names = sorted(n for n in dir(OperatorCompleteTests) if n.startswith("test_O"))
failed = 0
for name in names:
    result = unittest.TestResult()
    OperatorCompleteTests(name).run(result)
    case = name[len("test_"):].replace("_", " ", 1)
    if result.wasSuccessful():
        print("  PASS  %s" % case)
    else:
        failed += 1
        print("  FAIL  %s" % case)
        for _test, trace in result.failures + result.errors:
            print("        " + trace.strip().splitlines()[-1][:300])
print("operator-complete: %d passed, %d FAILED" % (len(names) - failed, failed))
sys.exit(1 if failed else 0)
P
rc=$?

if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/operator-complete.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$HERE/operator-complete.mutation.sh"; then
        echo "  PASS  M. every rule above has been watched fail"
    else
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
        rc=1
    fi
fi
exit "$rc"
