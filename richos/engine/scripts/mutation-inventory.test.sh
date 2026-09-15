#!/usr/bin/env bash
#
# mutation-inventory.test.sh — EVERY MUTATION HARNESS IS RUN BY SOMETHING.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-05 eight `*.mutation.sh` harnesses in this engine were named on no
# non-comment line of any script or workflow in the repository. Rows 3.22,
# 3.23, 3.25, 3.26, 3.27, 3.28, 3.29 and 3.31 of wiki/open-items.md are eight
# separate write-ups of that one fact. The properties those harnesses prove
# load-bearing were proven exactly when somebody typed a path by hand.
#
# They were wired that day, one invocation per suite. That fixes the eight and
# does nothing at all about the ninth. The engine's own runner argues this
# better than a paragraph here can: run-all-tests.sh refuses to hold a typed
# inventory of suites, because a typed list of the things you check drifts from
# the things that exist and the fraction printed over it stays reassuring. A
# set of eight hand-placed invocations IS a typed inventory, distributed across
# eight files so that nobody can see it at once.
#
# So this suite holds no list. It discovers every harness from disk and asserts
# that each one is named on a line somebody could execute.
#
# WHY A RED TEST RATHER THAN TEACHING THE RUNNER TO DISCOVER `*.mutation.sh`:
# the runner already runs 25 harnesses through the suites that invoke them, and
# discovering them a second time would run every one of those TWICE. Measured
# rather than guessed: contract-integrity.test.sh spends 2168 seconds on ten of
# them (docs/measurements/integrity-suite-cost-2026-09-04/), so the duplicate
# pass costs roughly half an hour of wall clock for no new coverage. The two
# designs also fail DIFFERENTLY when the ninth harness arrives, and that is the
# larger reason: runner-discovery would quietly start running it, and quiet is
# how row 3.24 got closed — by accident, because somebody happened to be
# working in that file. This one goes red and names the path.
#
# WHAT THIS CANNOT SEE, stated rather than glossed. The rule is "the basename
# appears on a line whose first non-blank character is not `#`". That is a
# LOOSE test of "is invoked": a live line that merely mentions the name in a
# string would satisfy it. The looseness runs in the safe direction for the
# defect this file is about — an orphan cannot hide behind it, because an
# orphan by definition appears nowhere but comments — and a harness that is
# invoked but broken is caught by its suite going red, which is a different
# check that already exists. The direction that WOULD be dangerous, counting a
# comment as an invocation, is exactly the bug this file was born from: the
# first sweep of the tree used `grep -l` with no comment handling and reported
# five orphans where there were eight, because three were mentioned in prose.
#
# WHAT IT DELIBERATELY DOES NOT CHECK, and why. The recursion guard pairing --
# a suite must skip its harness when RICHOS_MUTATION_INNER is set, and the
# harness must set it before running any copy of that suite -- is not asserted
# here. Half the existing pairs do not use the flag at all and are still
# correct: their harnesses build a sandbox containing the suite and NOT the
# harness, so the `[ -x ... ]` test at the invocation site is simply false. A
# static rule that demanded the flag would go red over eleven correct pairs,
# and a rule that accepted either shape would accept everything. Termination is
# proven the only way it can be -- by running each wired suite once, which the
# runner does on every invocation and which a regress would visibly hang.
#
# Exit codes: 0 every harness is invoked and every control behaved; 1 at least
# one harness is run by nothing, or a control failed; 2 discovery found no
# harnesses at all (refusing to report a green tick over an empty inventory).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

SANDBOX="$(cd "$(mktemp -d -t mutation-inventory.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------------------------------------------------------------------------
# scan_orphans <root> -> prints one root-relative harness path per orphan
#
# Deliberately a function over an arbitrary root, so the controls below can
# exercise the identical code against a tree built to be wrong. A checker
# proven only against the real tree is proven only against a tree that passes.
# ---------------------------------------------------------------------------
scan_orphans() {
    local root="$1" h b rel hits live
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        b="$(basename "$h")"
        rel="${h#"$root"/}"
        hits="$(grep -rn --fixed-strings "$b" \
                    --include='*.sh' --include='*.yml' --include='*.yaml' \
                    "$root" 2>/dev/null | grep -v "^$h:")"
        # Drop every line whose first non-blank character starts a comment.
        live="$(printf '%s\n' "$hits" | awk -F: '{
            line = "";
            for (i = 3; i <= NF; i++) line = line (i > 3 ? ":" : "") $i;
            sub(/^[ \t]+/, "", line);
            if (substr(line, 1, 1) != "#" && line != "") print;
        }')"
        [ -z "$live" ] && printf '%s\n' "$rel"
    done <<EOF
$(find "$root" -type f -name '*.mutation.sh' 2>/dev/null | LC_ALL=C sort)
EOF
}

echo "=== mutation inventory: every harness is run by something ==="
echo ""

# ===========================================================================
# 1. THE LIVE ASSERTION — the real engine, discovered from disk.
# ===========================================================================
HARNESSES="$(find "$ENGINE_ROOT" -type f -name '*.mutation.sh' 2>/dev/null | LC_ALL=C sort)"
N_HARNESS="$(printf '%s\n' "$HARNESSES" | grep -c . || true)"

if [ "$N_HARNESS" -eq 0 ]; then
    echo "ERROR: mutation-inventory.test.sh: found NO *.mutation.sh under $ENGINE_ROOT." >&2
    echo "       That is not a pass with nothing to do — either discovery is broken or this" >&2
    echo "       is not an engine checkout. Refusing to report a green inventory of nothing." >&2
    exit 2
fi
ok "1a  discovery found $N_HARNESS mutation harness(es) from disk, with no typed list"

ORPHANS="$(scan_orphans "$ENGINE_ROOT")"
if [ -z "$ORPHANS" ]; then
    ok "1b  every one of the $N_HARNESS harnesses is named on a line somebody could execute"
else
    bad "1b  harness(es) run by NOTHING — the properties they prove are proven by hand or not at all" \
        "$(printf '%s' "$ORPHANS" | tr '\n' ' ')"
    printf '%s\n' "$ORPHANS" | sed 's/^/          /'
    echo "        Wire each into the .test.sh suite it mutates, guarded by RICHOS_MUTATION_INNER."
fi

# ===========================================================================
# 2. THE NEGATIVE CONTROL — a checker that cannot fail proves nothing.
#
# Built in a sandbox rather than by touching the engine: writing a fixture into
# the real tree is the exact leak run-all-tests.sh's canary was added to catch,
# and it would also read to a stranger like a real harness.
# ===========================================================================
CTL="$SANDBOX/tree"
mkdir -p "$CTL/scripts/hooks"
printf '#!/usr/bin/env bash\necho fake harness\n' >"$CTL/scripts/hooks/decoy.mutation.sh"
printf '#!/usr/bin/env bash\necho fake suite\n'   >"$CTL/scripts/hooks/decoy.test.sh"

R="$(scan_orphans "$CTL")"
if [ "$R" = "scripts/hooks/decoy.mutation.sh" ]; then
    ok "2a  NEGATIVE  an uninvoked harness IS reported (the check can fail)"
else
    bad "2a  an uninvoked harness was not reported — this check cannot fail and proves nothing" "got: '$R'"
fi

# 2b — THE BUG THIS FILE WAS BORN FROM. A mention in prose is not an
# invocation. The first sweep of the tree counted one and under-reported by
# three, so this is asserted rather than assumed.
printf '#!/usr/bin/env bash\n# see decoy.mutation.sh for the mutants\n   # decoy.mutation.sh again\necho fake suite\n' \
    >"$CTL/scripts/hooks/decoy.test.sh"
R="$(scan_orphans "$CTL")"
if [ "$R" = "scripts/hooks/decoy.mutation.sh" ]; then
    ok "2b  NEGATIVE  a harness named ONLY in comments is still an orphan"
else
    bad "2b  a comment counted as an invocation — the original under-reporting bug, rebuilt" "got: '$R'"
fi

# 2c — POSITIVE control. Without this the suite above passes on a checker that
# reports EVERYTHING as an orphan, which is the same wrong-reason green.
printf '#!/usr/bin/env bash\n# see decoy.mutation.sh for the mutants\nbash "$SCRIPT_DIR/decoy.mutation.sh"\n' \
    >"$CTL/scripts/hooks/decoy.test.sh"
R="$(scan_orphans "$CTL")"
if [ -z "$R" ]; then
    ok "2c  POSITIVE  a real invocation clears the harness"
else
    bad "2c  a genuinely invoked harness was still called an orphan" "got: '$R'"
fi

# 2d — discovery is by disk, not by directory. A harness anywhere under the
# root must be seen; the defect this whole family is about began as one glob
# over one directory.
mkdir -p "$CTL/scripts/lib/deep/deeper"
printf '#!/usr/bin/env bash\necho buried\n' >"$CTL/scripts/lib/deep/deeper/buried.mutation.sh"
R="$(scan_orphans "$CTL")"
if printf '%s\n' "$R" | grep -qx 'scripts/lib/deep/deeper/buried.mutation.sh'; then
    ok "2d  a harness buried three directories deep is still discovered"
else
    bad "2d  discovery missed a nested harness — it is globbing, not walking" "got: '$R'"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$PASS"
    exit 0
fi
printf '  %s passed, %s FAILED\n' "$PASS" "$FAIL"
exit 1
