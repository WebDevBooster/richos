#!/usr/bin/env bash
#
# run-tests.sh — every *.test.sh under app/scripts, discovered from disk.
#
# WHY THE INVENTORY IS NOT TYPED. This repository has now shipped the same defect
# five times: a hand-written list of things to check that drifted from the things
# that existed, under a reassuring fraction. "13/13 guards", "18/18 suites", an
# install.sh whose HOOK_FILES had drifted from its registration, a `run.js` that
# reported "all 4 suites passed" while running none of `steering.js`'s 24 checks.
# `engine/scripts/run-all-tests.sh` and `app/ui/tests/run.js` both ended up here.
# So: add a suite next to this file and it runs. There is no second place to edit.
#
# ZERO SUITES IS EXIT 2, not "all 0 suites passed". An empty inventory reporting
# green is how an unreachable workflow looked healthy for months.
#
# macOS ONLY, and it says so rather than skipping. Every suite under this directory
# is about codesign, keychains and TCC. On Linux they would not fail; they would be
# meaningless, and a green run of meaningless suites is worse than no run.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "run-tests.sh: these suites exercise codesign, the keychain and TCC — macOS only." >&2
  echo "              (uname -s reports $(uname -s).) Refusing to report a result." >&2
  exit 3
fi

SUITES=()
while IFS= read -r t; do [ -n "$t" ] && SUITES+=("$t"); done <<EOF
$(find "$DIR" -maxdepth 1 -type f -name '*.test.sh' | LC_ALL=C sort)
EOF

if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "run-tests.sh: found NO *.test.sh under $DIR — refusing to report green over an empty inventory." >&2
  exit 2
fi

echo "${#SUITES[@]} suite(s) discovered under $DIR"
echo ""

FAILED=()
TOTAL_CHECKS=0
for t in "${SUITES[@]}"; do
  rel="${t#"$DIR"/}"
  echo "--- $rel"
  out="$(bash "$t" 2>&1)"; code=$?
  printf '%s\n' "$out"
  # Each suite ends with "all N passed" or "N FAILED, M passed"; the count is read
  # off the suite's own output rather than asserted here, for the same reason the
  # inventory is not typed.
  n="$(printf '%s' "$out" | sed -n 's/.*all \([0-9]*\) passed ===.*/\1/p' | tail -1)"
  [ -n "$n" ] && TOTAL_CHECKS=$((TOTAL_CHECKS + n))
  [ "$code" -ne 0 ] && FAILED+=("$rel")
  echo ""
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "=== app/scripts: ${#FAILED[@]} of ${#SUITES[@]} suite(s) FAILED: ${FAILED[*]} ==="
  exit 1
fi
echo "=== app/scripts: all ${#SUITES[@]} suites passed — $TOTAL_CHECKS checks ==="
