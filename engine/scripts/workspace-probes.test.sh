#!/usr/bin/env bash
#
# workspace-probes.test.sh — the runner is now the thing every other check of
# workspaces.py depends on, so it is not allowed to be the one piece with
# nothing asking whether it works.
#
# Each case builds a throwaway repository in the shape the runner expects — a
# git toplevel with engine/scripts/lib/workspaces.py and docs/verification/ —
# and puts synthetic probes in it. Nothing here touches the real tree, the real
# probes, or the operator's registry.
#
#   W1  a probe is DISCOVERED by being committed: it names workspaces.py and
#       drives an entry point, and nothing registers it anywhere
#   W2  a file that is not a probe of this library is NOT counted as one
#   W3  a red probe makes the runner exit non-zero and print what may retire it
#   W4  a retirement signed by the probe's OWN AUTHOR retires it
#   W5  a retirement signed by ANYONE ELSE is refused, naming both names --
#       this is the whole point, and without it the refusal is a suggestion
#   W6  a probe the runner cannot execute is NOT a probe that passed: it blocks
#   W7  a probe on ANOTHER LOCAL BRANCH is discovered and named by its branch
#   W8  --at <commit> tests that commit's workspaces.py, not the tree's
#   W9  a file that declares `not-a-probe: <reason>` is not run and not counted;
#       a BARE marker with no reason exempts nothing
#   W10 A RUN THAT ASKED NOTHING IS NOT A RUN THAT PASSED. An --only that matches
#       no probe must not print the green line and exit 0 -- that is
#       byte-for-byte what a clean full run looks like
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/workspace-probes.py"
LIB="$SCRIPT_DIR/lib/workspaces.py"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$RUNNER" ] || { echo "FATAL: missing $RUNNER" >&2; exit 1; }
[ -f "$LIB" ]    || { echo "FATAL: missing $LIB" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/workspace-probes.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== workspace-probes tests ==="

# The identity is borrowed from this machine, for the reason every other suite
# in this engine borrows it: a commit hook that checks identity is satisfied by
# construction rather than stepped around.
GIT_ID_EMAIL="$(git config --get user.email 2>/dev/null || true)"
GIT_ID_NAME="$(git config --get user.name 2>/dev/null || true)"

R="$SANDBOX/repo"
mkdir -p "$R/engine/scripts/lib" "$R/docs/verification"
git -C "$R" init -q -b main
[ -n "$GIT_ID_EMAIL" ] && git -C "$R" config user.email "$GIT_ID_EMAIL"
[ -n "$GIT_ID_NAME" ]  && git -C "$R" config user.name "$GIT_ID_NAME"
git -C "$R" config commit.gpgsign false
git -C "$R" config core.hooksPath "$SANDBOX/nohooks"
cp "$RUNNER" "$R/engine/scripts/"
cp "$LIB" "$R/engine/scripts/lib/"

# --- the synthetic probes --------------------------------------------------
# A GREEN one, in the argv shape both reviewers use. It mentions workspaces.py
# and calls an entry point, which is the whole of the discovery rule.
cat > "$R/docs/verification/certification-alice-green.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Alice's probe. Takes a path-to-workspaces.py and holds the build to a rule."""
import importlib.util, sys
CASES = ["a"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    return 0 if hasattr(ws, "integration_target") else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE

# A RED one, by the same shape and a different author.
cat > "$R/docs/verification/certification-bob-red.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Bob's probe. Takes a path-to-workspaces.py and is deliberately red."""
import importlib.util, sys
CASES = ["b"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    print("this build does not have ws.a_rule_that_never_existed")
    ws.integration_for  # the entry point this probe would drive
    return 0 if hasattr(ws, "a_rule_that_never_existed") else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE

# NOT a probe of this library: it mentions no workspaces.py at all.
cat > "$R/docs/verification/some-other-measurement.py" <<'OTHER'
#!/usr/bin/env python3
"""Counts rows in a log. Nothing to do with the workspace library."""
print(0)
OTHER

git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "the fixture" >/dev/null 2>&1

run() { OUT="$(python3 "$R/engine/scripts/workspace-probes.py" "$@" 2>&1)"; RC=$?; }

# --- W1 / W2: discovery is structural --------------------------------------
run --list --tree-only
if grep -q "certification-alice-green.probe.py" <<<"$OUT" \
   && grep -q "certification-bob-red.probe.py" <<<"$OUT" \
   && grep -q "probes discovered:        2" <<<"$OUT"; then
    ok "W1  a probe is discovered by being committed — no registration anywhere"
else
    bad "W1  discovery: <$OUT>"
fi
if grep -q "not probes of this library: 1" <<<"$OUT" \
   && ! grep -q "some-other-measurement" <<<"$OUT"; then
    ok "W2  a file that is not a probe of this library is counted, not mistaken for one"
else
    bad "W2  classification: <$OUT>"
fi

# --- W3: a red probe blocks, and the refusal says who may retire it ---------
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "certification-bob-red" <<<"$OUT" \
   && grep -q "THE REVIEWER WHO WROTE IT" <<<"$OUT" \
   && grep -q "workspace-probe-retirements.tsv" <<<"$OUT"; then
    ok "W3  a red prior probe exits non-zero and names what may retire it"
else
    bad "W3  rc=$RC — a red probe must block: <$OUT>"
fi

# --- W5 FIRST: a retirement signed by the wrong person is REFUSED -----------
# Before W4, deliberately. If the signature check were absent, W4 would pass on
# its own and the suite would look green over a runner anyone could silence.
printf 'certification-bob-red.probe.py\talice\tI decided this one is obsolete\n' \
    > "$R/docs/verification/workspace-probe-retirements.tsv"
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "signed 'alice'" <<<"$OUT" \
   && grep -q "author is 'bob'" <<<"$OUT"; then
    ok "W5  a retirement signed by anyone but the probe's own author is REFUSED, naming both"
else
    bad "W5  rc=$RC — the signature check did not fire: <$OUT>"
fi

# --- W4: signed by its own author, it retires ------------------------------
printf 'certification-bob-red.probe.py\tbob\tthe rule it pinned was deleted by the CEO ruling\n' \
    > "$R/docs/verification/workspace-probe-retirements.tsv"
run --tree-only
if [ "$RC" -eq 0 ] && grep -q "RETIRED" <<<"$OUT" \
   && grep -q "deleted by the CEO ruling" <<<"$OUT"; then
    ok "W4  a retirement signed by the probe's own author retires it, with its reason shown"
else
    bad "W4  rc=$RC — a correctly signed retirement did not take: <$OUT>"
fi
rm -f "$R/docs/verification/workspace-probe-retirements.tsv"

# --- W6: a probe that cannot be executed is not a probe that passed ---------
cat > "$R/docs/verification/certification-carol-unrunnable.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Carol's probe. It loads workspaces.py and drives it, but offers this runner
no way in at all: no case list, no entry point that takes the library path, and
it does not import the engine's own test file either. (This docstring avoids
spelling those shapes out, because the runner reads the file as TEXT and would
otherwise match its own pattern in a sentence denying it.)"""
import importlib.util, os
spec = importlib.util.spec_from_file_location("ws", os.environ.get("WS", ""))
print("nothing here can be driven")
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "an unrunnable probe" >/dev/null 2>&1
run --tree-only --only carol
if [ "$RC" -ne 0 ] && grep -q "UNRUNNABLE" <<<"$OUT" \
   && grep -q "DID NOT RUN" <<<"$OUT" \
   && grep -q "certification-carol-unrunnable" <<<"$OUT"; then
    ok "W6  a probe the runner cannot execute BLOCKS, by name — it is not a probe that passed"
else
    bad "W6  rc=$RC — an unrunnable probe was let through: <$OUT>"
fi
git -C "$R" rm -q "docs/verification/certification-carol-unrunnable.probe.py" >/dev/null 2>&1
git -C "$R" commit -q -m "drop it" >/dev/null 2>&1

# --- W7: a probe committed on ANOTHER LOCAL BRANCH is discovered ------------
# This is the case the runner exists for: a reviewer commits its probe on its
# own branch, which is precisely the branch the engineer has not merged.
git -C "$R" checkout -q -b cc/dave-review
cat > "$R/docs/verification/certification-dave-green.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Dave's probe, committed on Dave's own branch. Takes a workspaces.py path."""
import importlib.util, sys
CASES = ["d"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    return 0 if hasattr(ws, "barrier") else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "dave's probe, on dave's branch" >/dev/null 2>&1
git -C "$R" checkout -q main
run --list
if grep -q "certification-dave-green" <<<"$OUT" && grep -q "cc/dave-review" <<<"$OUT"; then
    ok "W7  a probe committed on another local branch is discovered and named by its branch"
else
    bad "W7  a reviewer's unmerged probe was invisible: <$OUT>"
fi
run --list --tree-only
if ! grep -q "certification-dave-green" <<<"$OUT"; then
    ok "W7b --tree-only really does skip other branches (so W7 measured something)"
else
    bad "W7b --tree-only still read another branch: <$OUT>"
fi

# --- W8: --at tests THAT COMMIT's library, not the tree's -------------------
# The tree's workspaces.py has integration_target; a commit whose copy does not
# must make alice's probe red. Same probe, same tree, different library.
AT_BEFORE="$(git -C "$R" rev-parse HEAD)"
printf 'def nothing():\n    return 0\n' > "$R/engine/scripts/lib/workspaces.py"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "a library without the rule" >/dev/null 2>&1
AT_HOLLOW="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q "$AT_BEFORE" -- engine/scripts/lib/workspaces.py
git -C "$R" commit -q -am "restore the library" >/dev/null 2>&1
run --tree-only --only alice --at "$AT_HOLLOW"
W8_RED=$RC
run --tree-only --only alice
W8_GREEN=$RC
if [ "$W8_RED" -ne 0 ] && [ "$W8_GREEN" -eq 0 ]; then
    ok "W8  --at <commit> tests THAT commit's workspaces.py: red there, green on the tree"
else
    bad "W8  at-hollow=$W8_RED at-tree=$W8_GREEN — --at did not change the library under test"
fi

# --- W9: the declaration, and that a bare marker exempts nothing -----------
# A tool that BUILDS probes looks exactly like a probe from outside, and a path
# rule cannot tell them apart -- a reviewer's real probe lives under a -logs/
# directory today. The way out is a declaration with a reason, visible to
# whoever reads the file.
git -C "$R" checkout -q main
cat > "$R/docs/verification/build-some-probes.py" <<'TOOL'
#!/usr/bin/env python3
"""not-a-probe: this writes derived copies of other probes and asserts nothing.
It loads workspaces.py only to read its version, via exec_module."""
import importlib.util
TOOL
cat > "$R/docs/verification/bare-marker.py" <<'TOOL'
#!/usr/bin/env python3
"""not-a-probe:
Loads workspaces.py with exec_module and says nothing about why it is exempt."""
import importlib.util
TOOL
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "a declared tool and a bare marker" >/dev/null 2>&1
run --list --tree-only
if ! grep -q "build-some-probes" <<<"$OUT" && grep -q "bare-marker" <<<"$OUT"; then
    ok "W9  a declared non-probe is not run; a BARE marker with no reason exempts nothing"
else
    bad "W9  the declaration is wrong in one direction or the other: <$OUT>"
fi

# --- W10: an empty run is not a pass ---------------------------------------
run --tree-only --only there-is-no-probe-by-this-name
if [ "$RC" -ne 0 ] && grep -q "NOTHING WAS RUN" <<<"$OUT" \
   && ! grep -q "every one of them is green" <<<"$OUT"; then
    ok "W10 a run that selected no probe REFUSES — it does not print the all-clear"
else
    bad "W10 rc=$RC — an empty run read as a pass: <$OUT>"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== workspace-probes tests: all $PASS passed ==="
    exit 0
fi
echo "=== workspace-probes tests: $PASS passed, $FAIL FAILED ==="
exit 1
