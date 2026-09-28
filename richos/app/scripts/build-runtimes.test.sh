#!/usr/bin/env bash
# run-tests: no-host-screen: runs one Python import check; nothing is built, downloaded or launched
# run-tests: inputs richos/app/scripts/build-runtimes.test.sh richos/app/scripts/build-runtimes.py
# run-tests: covers richos/app/scripts/build-runtimes.py
#
# build-runtimes.test.sh — the delivered Python's dependency closure, as build-runtimes.py
# checks it inside every fresh runtime build.
#
# A runtime is built once and reused (`nightly-local.py`'s `runtime()`), so the closure line in
# build-runtimes.py runs only when a runtime is rebuilt, which is rare. This suite runs THE SAME
# snippet (the module's CLOSURE_CHECK, read from the file, not a copy) now:
#   1. under the delivered runtime's Python when RICHOS_RUNTIME_DIR names one, else under the
#      Python 3 running this suite, so the check itself is proven to pass on a real interpreter;
#   2. it names ctypes and libproc, which provider-supervisor.py needs to reap a lease's tool
#      commands (the product reap gap design C8);
#   3. a positive probe: the same check with a module that does not exist FAILS, so a pass
#      above is not a snippet that cannot fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="python3"
if [ -n "${RICHOS_RUNTIME_DIR:-}" ] && [ -x "$RICHOS_RUNTIME_DIR/bin/python3" ]; then
  PYTHON="$RICHOS_RUNTIME_DIR/bin/python3"
fi
fail=0
check=$(python3 - "$HERE/build-runtimes.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("build_runtimes", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.CLOSURE_CHECK)
PY
) || { echo "  FAIL  B0 build-runtimes.py has no CLOSURE_CHECK"; exit 1; }

if out=$("$PYTHON" -c "$check" 2>&1); then
  echo "  PASS  B1 the closure check passes under $PYTHON ($out)"
else
  echo "  FAIL  B1 the closure check failed under $PYTHON: $out"; fail=1
fi
case "$check" in
  *ctypes*libproc.dylib*) echo "  PASS  B2 the closure check loads ctypes and libproc (reap gap C8)" ;;
  *) echo "  FAIL  B2 the closure check no longer loads ctypes and libproc: $check"; fail=1 ;;
esac
if "$PYTHON" -c "${check/import sqlite3/import sqlite3, richos_no_such_module}" >/dev/null 2>&1; then
  echo "  FAIL  B3 a closure check with a missing module still passed"; fail=1
else
  echo "  PASS  B3 a closure check with a missing module fails"
fi
exit "$fail"
