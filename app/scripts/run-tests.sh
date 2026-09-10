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
#
# =======================================================================================
# EXIT 2 FROM A SUITE MEANS "THIS HOST CANNOT ANSWER", AND IT USED TO BE READ AS "FAILED"
# =======================================================================================
#
# `gui-boot.test.sh` has said, in its own words, since it was written:
#
#     That is a fact about THIS MACHINE, not a verdict about the code.
#     ... exit 2
#
# and this harness had no notion of such a host, so it counted that suite as a failure.
# On a public GitHub runner it always will be one: the fixture needs the loro compiler
# (`bin/loro-context.mjs`, `bin/loro-write.mjs`), which is not tracked in this repository
# at all — it lives in the private record repository, 37 files of it. No runner can have
# it. So the whole workflow that points at this file was switched off rather than made to
# lie, and SEVEN suites that pass perfectly on a runner have not run in CI since
# 2026-09-01 to protect the reporting of the eighth. Measured on the runner, 2026-09-10:
# `docs/verification/packaging-ci-2026-09-10/`.
#
# THE DANGEROUS VERSION OF THIS FIX IS THE OBVIOUS ONE — treat exit 2 as a skip and move
# on. That is how a suite stops running and nobody finds out, which is the defect this
# repository has now paid for five times and the exact reason the workflow's author
# refused to patch it in a hurry. So the allowance is not "exit 2 is fine". It is:
#
#   * a gap is only tolerated if the CALLER DECLARED IT, by suite name, WITH A REASON —
#     a bare name declares nothing, exactly as `gui-boot.test.sh`'s own A4 case requires
#     of the gaps it accounts for;
#   * a suite that gaps WITHOUT a declaration is red — so a NEW suite that starts
#     reporting "this host cannot answer" stops the build on the first run;
#   * a declaration whose suite DID answer is red — so an allowance cannot outlive the
#     condition it was written for and quietly hide a later gap;
#   * the summary line never says "all N suites passed" while a gap exists. It says how
#     many ran, how many could not, and which.
#
# The failure modes therefore all point at RED, and the tolerated set can only ever get
# smaller without somebody editing a declaration. Drift makes the unaccounted list longer.
#
#   RUN_TESTS_DECLARED_GAPS="gui-boot.test.sh: <why this host cannot answer>"
#
# one declaration per line, `<suite>: <reason>`. Unset — the default, and what an operator
# on a complete machine gets — means no gap is tolerated at all.
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

# The declarations, read once, before anything runs — a malformed one should stop the run
# rather than be discovered after fifteen minutes of runner time.
DECLARED_SUITE=()
DECLARED_WHY=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  d_suite="${line%%:*}"
  d_why="${line#*:}"
  # Trim, without an external process.
  d_suite="${d_suite#"${d_suite%%[![:space:]]*}"}"; d_suite="${d_suite%"${d_suite##*[![:space:]]}"}"
  d_why="${d_why#"${d_why%%[![:space:]]*}"}";       d_why="${d_why%"${d_why##*[![:space:]]}"}"
  if [ "$d_suite" = "$line" ] || [ -z "$d_why" ]; then
    echo "run-tests.sh: RUN_TESTS_DECLARED_GAPS names '$d_suite' with no reason after a colon." >&2
    echo "              A bare name declares nothing. Write '<suite>: <why this host cannot answer>'." >&2
    exit 2
  fi
  DECLARED_SUITE+=("$d_suite")
  DECLARED_WHY+=("$d_why")
done <<EOF
${RUN_TESTS_DECLARED_GAPS:-}
EOF

echo "${#SUITES[@]} suite(s) discovered under $DIR"
if [ "${#DECLARED_SUITE[@]}" -gt 0 ]; then
  for i in "${!DECLARED_SUITE[@]}"; do
    echo "  declared host gap: ${DECLARED_SUITE[$i]} — ${DECLARED_WHY[$i]}"
  done
fi
echo ""

FAILED=()
GAPPED=()
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
  if [ "$code" -eq 2 ]; then
    GAPPED+=("$rel")
  elif [ "$code" -ne 0 ]; then
    FAILED+=("$rel")
  fi
  echo ""
done

# A real failure outranks everything: report it and stop, so a gap can never be the
# headline over a suite that ran and lost.
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "=== app/scripts: ${#FAILED[@]} of ${#SUITES[@]} suite(s) FAILED: ${FAILED[*]} ==="
  exit 1
fi

# An undeclared gap. This is the case that must never pass, because it is the shape of a
# suite that silently stopped running.
UNDECLARED=()
for g in "${GAPPED[@]:-}"; do
  [ -n "$g" ] || continue
  known=""
  for d in "${DECLARED_SUITE[@]:-}"; do [ "$d" = "$g" ] && known=1 && break; done
  [ -n "$known" ] || UNDECLARED+=("$g")
done
if [ "${#UNDECLARED[@]}" -gt 0 ]; then
  echo "=== app/scripts: ${#UNDECLARED[@]} suite(s) reported that this host cannot answer, and nobody declared them: ${UNDECLARED[*]} ==="
  echo "    Exit 2 from a suite is 'a fact about THIS MACHINE'. Undeclared, it is indistinguishable"
  echo "    from a suite that quietly stopped running, so it is refused rather than tolerated."
  echo "    Declare it — with a reason — in RUN_TESTS_DECLARED_GAPS, or fix the host."
  exit 2
fi

# A declaration that is no longer needed. Left alone it would sit there ready to swallow a
# future gap in the same suite for a reason that has nothing to do with the one written down.
STALE=()
for d in "${DECLARED_SUITE[@]:-}"; do
  [ -n "$d" ] || continue
  gapped=""
  for g in "${GAPPED[@]:-}"; do [ "$g" = "$d" ] && gapped=1 && break; done
  [ -n "$gapped" ] || STALE+=("$d")
done
if [ "${#STALE[@]}" -gt 0 ]; then
  echo "=== app/scripts: a host gap is declared for ${STALE[*]}, and that suite answered on this host ==="
  echo "    The allowance has outlived its reason. Remove the declaration; an allowance nobody needs"
  echo "    is an allowance waiting to hide something else."
  exit 2
fi

if [ "${#GAPPED[@]}" -gt 0 ]; then
  RAN=$(( ${#SUITES[@]} - ${#GAPPED[@]} ))
  echo "=== app/scripts: $RAN of ${#SUITES[@]} suites passed — $TOTAL_CHECKS checks — ${#GAPPED[@]} could not run on this host: ${GAPPED[*]} ==="
  for i in "${!DECLARED_SUITE[@]}"; do
    echo "    ${DECLARED_SUITE[$i]}: ${DECLARED_WHY[$i]}"
  done
  exit 0
fi
echo "=== app/scripts: all ${#SUITES[@]} suites passed — $TOTAL_CHECKS checks ==="
