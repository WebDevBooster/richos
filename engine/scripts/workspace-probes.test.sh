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
# AND THE FOUR ROUTES PAST THE GATE, each reproduced by a reviewer in a throwaway
# repository before it was closed. Every one of them made the run print "every
# discovered probe ran, and every one of them is green" and exit 0.
#
#   W11 AN UNCOMMITTED RETIREMENT IS NOT A RETIREMENT (A1). It was enough to
#       write the line; nothing asked whether it had ever been committed.
#   W12 A RETIREMENT COMMITTED ONLY ON THE BRANCH UNDER TEST IS REFUSED (A3).
#       This is route 2: the name was checked and the name is a string anybody
#       can type, so the party failing the probe signed the reviewer's name and
#       the probe went RETIRED.
#   W13 A RETIREMENT IN THE SAME COMMIT AS A LIBRARY EDIT IS REFUSED (A2). The
#       commit that breaks a probe may not be the commit that retires it.
#   W14 A `not-a-probe:` MARKER ADDED TO SOMEBODY ELSE'S PROBE IS REFUSED, and
#       the probe goes on being a probe. This is route 1, and it needed no name
#       at all -- one comment line removed the probe from discovery.
#   W15 A PROBE THAT NEVER NAMES THE LIBRARY IS STILL DISCOVERED. Route 3: it
#       takes the library as an argument, and UNDISCOVERED IS WORSE THAN RED.
#   W16 A PROBE THAT WAS DELETED IS MISSING, AND MISSING BLOCKS. Route 4: the
#       file simply disappears, and the only thing that changes is a count
#       nothing was checking.
#   W17 --show-all NAMES THE FILES IT COUNTS. It was offered as the answer to
#       W15 and W2 and it named 0 of the 242 it counted.
#   W18 THE PAIRED TWIN FOR W12: the identical line, identical author, committed
#       on the AUTHOR'S OWN branch and landed, is accepted -- and the report
#       names the commit and the witnessing branch. Without this pair, refusing
#       every retirement would pass W11-W13.
#
# RETIREMENT IS PER CASE, NOT PER FILE (W19..W25). A reviewer ruled three of his
# cases obsolete and one still valid and then wrote NO retirement, because
# retirement was keyed on the FILE and retiring his would have dropped five GREEN
# assertions to buy one green exit code. He was right to refuse that trade.
#
#   W19 ONE CASE RETIRED, THE PROBE STILL RUNS, and its other cases still decide
#       the verdict. The retired case is NOT asked.
#   W20 THE PAIRED TWIN: the identical probe with no retirement is RED. Without
#       it, W19 would pass over a probe that was green anyway.
#   W21 A CASE THE PROBE DOES NOT HAVE IS REFUSED, naming the cases it does
#       have. A retirement that matches nothing is a typo or a copied line.
#   W22 EVERY CASE RETIRED IS THE WHOLE FILE, said as one verdict rather than
#       arrived at by subtraction.
#   W23 A PER-CASE RETIREMENT SIGNED BY THE WRONG AUTHOR is refused, and W24
#       that one witnessed only by the branch under test is refused -- the
#       per-case path does not get a weaker check than the whole-file one.
#   W25 THE THREE-FIELD (whole-file) LINES STILL WORK, unrewritten. Rewriting one
#       would make the engineer the author of its introducing commit, and A3
#       would then refuse the reviewer's own retirement.
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

TSV="docs/verification/workspace-probe-retirements.tsv"

# A RETIREMENT IN THE SHAPE A REAL ONE HAS: written on its AUTHOR'S own branch,
# committed there, and landed onto the branch under test. That is what gives it a
# witness other than the branch being judged (A3), and it is the only shape the
# runner accepts. A test that wrote the file and asserted RETIRED was testing the
# absence of this check.
retire_on_author_branch() { # <branch> <tsv contents>
    git -C "$R" checkout -q -b "$1" main
    printf '%s' "$2" > "$R/$TSV"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m "retirement by $1" >/dev/null 2>&1
    git -C "$R" checkout -q main
    git -C "$R" merge -q --ff-only "$1" >/dev/null 2>&1
}

# The same line, committed ONLY here. No witness but the branch under test.
retire_on_this_branch() { # <tsv contents>
    printf '%s' "$1" > "$R/$TSV"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m "a retirement written by whoever is failing the probe" >/dev/null 2>&1
}

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
# It is committed on alice's own branch and landed, so the ONE thing wrong with
# it is the name -- otherwise this case could pass on the attribution check and
# prove nothing about the signature.
retire_on_author_branch cc/alice-review \
    'certification-bob-red.probe.py	alice	I decided this one is obsolete
'
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "signed 'alice'" <<<"$OUT" \
   && grep -q "author is 'bob'" <<<"$OUT"; then
    ok "W5  a retirement signed by anyone but the probe's own author is REFUSED, naming both"
else
    bad "W5  rc=$RC — the signature check did not fire: <$OUT>"
fi

# --- W11: AN UNCOMMITTED RETIREMENT IS NOT A RETIREMENT (A1) ----------------
# Route 2, at its cheapest. This is what the suite used to do, and it passed.
printf 'certification-bob-red.probe.py\tbob\tan unstaged line nobody committed\n' \
    > "$R/$TSV"
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A1:" <<<"$OUT" \
   && grep -q "not in any commit" <<<"$OUT"; then
    ok "W11 an UNCOMMITTED retirement retires nothing — an unstaged edit is not a reviewer's act"
else
    bad "W11 rc=$RC — a working-tree-only retirement took effect: <$OUT>"
fi

# --- W12: COMMITTED, CORRECTLY SIGNED, AND ONLY ON THIS BRANCH (A3) --------
# ROUTE 2 AS IT WAS REPRODUCED: the party failing the probe types the reviewer's
# name. The name is right. Nothing else about it is.
retire_on_this_branch \
    'certification-bob-red.probe.py	bob	I am failing this probe and I say it is obsolete
'
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A3:" <<<"$OUT" \
   && grep -q "branch under test" <<<"$OUT"; then
    ok "W12 a retirement whose only witness is the branch under test is REFUSED — work cannot retire the probe it fails"
else
    bad "W12 rc=$RC — the failing party retired the probe by typing the right name: <$OUT>"
fi

# --- W13: BUNDLED WITH A LIBRARY EDIT (A2) ---------------------------------
# On a branch of its own, correctly signed, witnessed -- and the same commit
# edits the library. That is the commit that broke the probe retiring it.
git -C "$R" checkout -q -b cc/bob-bundled main
printf 'certification-bob-red.probe.py\tbob\tobsolete, says the commit that also rewrites the library\n' \
    > "$R/$TSV"
printf '\n# a change to the library in the very same commit\n' >> "$R/engine/scripts/lib/workspaces.py"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "fix the library and retire the probe it fails" >/dev/null 2>&1
git -C "$R" checkout -q main
git -C "$R" merge -q --ff-only cc/bob-bundled >/dev/null 2>&1
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A2:" <<<"$OUT" \
   && grep -q "workspaces.py" <<<"$OUT"; then
    ok "W13 a retirement in the same commit as a library edit is REFUSED — the commit that breaks it may not retire it"
else
    bad "W13 rc=$RC — a retirement bundled into the fix took effect: <$OUT>"
fi

# --- W4 / W18: signed by its own author, ON ITS OWN BRANCH, it retires ------
# THE PAIRED TWIN for W11..W13: refusing every retirement would pass all three.
retire_on_author_branch cc/bob-review \
    'certification-bob-red.probe.py	bob	the rule it pinned was deleted by the CEO ruling
'
run --tree-only
if [ "$RC" -eq 0 ] && grep -q "RETIRED" <<<"$OUT" \
   && grep -q "deleted by the CEO ruling" <<<"$OUT"; then
    ok "W4  a retirement signed by the probe's own author, on the author's own branch, retires it"
else
    bad "W4  rc=$RC — a correctly signed and witnessed retirement did not take: <$OUT>"
fi
if grep -q "witnessed by cc/bob-review" <<<"$OUT"; then
    ok "W18 and the report NAMES the commit and the witnessing branch — a RETIRED with no witness is the typed name again"
else
    bad "W18 the witness is not on the record: <$OUT>"
fi
git -C "$R" rm -q "$TSV" >/dev/null 2>&1
git -C "$R" commit -q -m "clear the retirements" >/dev/null 2>&1

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
# THE CLEANUP IS ITSELF THE DOCUMENTED REMEDY. Deleting a probe now makes it
# MISSING (W16), so carol's probe leaves the way a probe is supposed to leave:
# her own retirement, on her own branch, landed. A suite that cleaned up with a
# bare `git rm` would be asserting that deletion is free.
git -C "$R" rm -q "docs/verification/certification-carol-unrunnable.probe.py" >/dev/null 2>&1
git -C "$R" commit -q -m "drop it" >/dev/null 2>&1
retire_on_author_branch cc/carol-review \
    'certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
'

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
if grep -q "^DECLARED   docs/verification/build-some-probes.py" <<<"$OUT" \
   && grep -q "declared in the commit that added the file" <<<"$OUT" \
   && grep -q "bare-marker" <<<"$OUT" \
   && ! grep -q "(not run)  docs/verification/build-some-probes.py" <<<"$OUT"; then
    ok "W9  a declared non-probe is not run and IS NAMED; a BARE marker with no reason exempts nothing"
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

# --- W14: ROUTE 1 — SILENCE A PROBE BY ANNOTATING IT ------------------------
# No name, no retirement, one comment line. The party failing bob's probe adds
# `not-a-probe:` to bob's file, on its own branch, and the run reported every
# discovered probe green and exited 0.
git -C "$R" checkout -q main
python3 - "$R/docs/verification/certification-bob-red.probe.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace('"""Bob\'s probe.',
              '"""not-a-probe: superseded elsewhere, says the party failing it.\nBob\'s probe.')
io.open(p, "w", encoding="utf-8").write(s)
PY
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "annotate bob's probe out of existence" >/dev/null 2>&1
run --tree-only --only bob
if [ "$RC" -ne 0 ] && grep -q "DECLARATION REFUSED" <<<"$OUT" \
   && grep -q "A3:" <<<"$OUT" \
   && ! grep -q "every one of them is green" <<<"$OUT"; then
    ok "W14 a not-a-probe marker ADDED to somebody else's probe is REFUSED, and the probe goes on being a probe"
else
    bad "W14 rc=$RC — one comment line removed a red probe from the run: <$OUT>"
fi
# RESTORE, don't revert: `git revert` needs a clean index and an editor, and
# when it silently failed here the annotation survived into W15 and made that
# case read as a discovery bug.
git -C "$R" checkout -q "HEAD~1" -- docs/verification/certification-bob-red.probe.py
git -C "$R" commit -q -am "restore bob's probe" >/dev/null 2>&1
if grep -q "not-a-probe" "$R/docs/verification/certification-bob-red.probe.py"; then
    bad "W14b the fixture cleanup did not restore bob's probe, so every case after this one is unsound"
else
    ok "W14b the annotation is gone again — the cases after this one are back on a clean fixture"
fi

# --- W15: ROUTE 3 — A PROBE THAT NEVER NAMES THE LIBRARY -------------------
# It takes the library as an argument and drives it. Discovery keyed on the file
# name never saw it, and UNDISCOVERED IS WORSE THAN RED.
cat > "$R/docs/verification/certification-erin-nameless.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Erin's probe. The library arrives as argv[1] and its name is never written."""
import importlib.util, sys
CASES = ["e"]
def main(argv):
    spec = importlib.util.spec_from_file_location("underTest", argv[0])
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    branch, tip, why = mod.integration_for("/no/such/repository")
    return 0 if why else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "erin's probe, which never spells the library's name" >/dev/null 2>&1
if ! grep -q "workspaces.py" "$R/docs/verification/certification-erin-nameless.probe.py"; then
    ok "W15a POSITIVE CONTROL: the probe really does not name the library anywhere"
else
    bad "W15a the fixture names the library, so W15 would prove nothing"
fi
run --list --tree-only
if grep -q "certification-erin-nameless" <<<"$OUT"; then
    ok "W15 a probe that drives the library through an argument is discovered without naming it"
else
    bad "W15 a probe that never spells the file name was invisible: <$OUT>"
fi

# --- W16: ROUTE 4 — A PROBE THAT SIMPLY DISAPPEARS -------------------------
git -C "$R" rm -q "docs/verification/certification-erin-nameless.probe.py" >/dev/null 2>&1
git -C "$R" commit -q -m "delete erin's probe" >/dev/null 2>&1
run --tree-only --only erin
if [ "$RC" -ne 0 ] && grep -q "MISSING" <<<"$OUT" \
   && grep -q "certification-erin-nameless" <<<"$OUT" \
   && grep -q "never by deletion" <<<"$OUT"; then
    ok "W16 a probe that was DELETED is MISSING and blocks — deletion is not attributable to anybody"
else
    bad "W16 rc=$RC — a deleted probe only lowered a count: <$OUT>"
fi
# THE PAIRED TWIN: her own retirement, and the same deletion stops blocking.
# CAROL'S LINE IS CARRIED FORWARD, because retire_on_author_branch WRITES the
# file rather than appending to it. Dropping it here would resurrect carol as a
# deletion and make this case's output about the wrong probe.
retire_on_author_branch cc/erin-review \
    'certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
certification-erin-nameless.probe.py	erin	replaced by a probe that asserts the same rule per case
'
run --tree-only --only erin
if ! grep -q "MISSING" <<<"$OUT"; then
    ok "W16b SILENT TWIN: retired by its own author, the same deletion no longer blocks"
else
    bad "W16b a retired-and-deleted probe still blocks: <$OUT>"
fi

# --- W17: --show-all NAMES WHAT IT COUNTS ----------------------------------
# It was offered as the answer to route 3 and to W2, and it named 0 of the 242 it
# counted -- so it was the count again, in more words.
run --tree-only --show-all
if grep -q "some-other-measurement.py" <<<"$OUT" && grep -q "named; the count above was" <<<"$OUT"; then
    ok "W17 --show-all NAMES the files it counts, and prints both numbers so they can be compared"
else
    bad "W17 --show-all counted without naming: <$OUT>"
fi

# ===========================================================================
# RETIREMENT PER CASE — W19..W25
# ===========================================================================
# The probe has four cases and fails on exactly one of them. That is the shape
# the reviewer was actually in: three rulings of obsolete, one still valid, and a
# mechanism that offered him only all-or-nothing.
git -C "$R" checkout -q main
cat > "$R/docs/verification/certification-fay-cases.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Fay's probe of workspaces.py. Four cases; the third one fails.

It RECORDS the cases it was asked for, in $FAY_LOG. The runner shows a green
probe's stdout nowhere -- correctly, or every clean run would be a wall of text --
so "the retired case was not asked" needs an artifact rather than a printed line.
"""
import importlib.util, os, sys
CASES = ["one", "two", "three", "four"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    wanted = argv[1:] or CASES
    log = os.environ.get("FAY_LOG", "")
    if log:
        with open(log, "w") as fh:
            fh.write(" ".join(wanted))
    bad = 0
    for case in wanted:
        holds = hasattr(ws, "integration_for") and case != "three"
        print("%s: %s" % (case, "holds" if holds else "FAILS"))
        if not holds:
            bad += 1
    return 1 if bad else 0
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "fay's probe, four cases, one of them red" >/dev/null 2>&1
export FAY_LOG="$SANDBOX/fay-was-asked.txt"

# CAROL'S AND ERIN'S RETIREMENTS ARE CARRIED FORWARD through every rewrite of the
# file below, because retire_on_author_branch WRITES it. Dropping them would
# resurrect two deletions and put the wrong probes in this section's output.
CARRIED='certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
certification-erin-nameless.probe.py	erin	replaced by a probe that asserts the same rule per case
'

# --- W20 FIRST: the twin. With nothing retired it is RED. -------------------
rm -f "$FAY_LOG"
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "RED" <<<"$OUT" && grep -q "three: FAILS" <<<"$OUT"; then
    ok "W20 PAIRED TWIN: with no retirement the probe is RED on its one bad case"
else
    bad "W20 rc=$RC — the fixture is not red, so W19 below would prove nothing: <$OUT>"
fi

# --- W19: retire THAT ONE CASE. The other three still run. -----------------
rm -f "$FAY_LOG"
retire_on_author_branch cc/fay-review "$CARRIED"'certification-fay-cases.probe.py	three	fay	the rule case three pinned was deleted by the CEO ruling
'
run --tree-only --only fay
ASKED="$(cat "$FAY_LOG" 2>/dev/null || echo "<the probe never ran>")"
if [ "$RC" -eq 0 ] && grep -q "ran 3 of 4 case" <<<"$OUT" \
   && grep -q "case 'three' retired by fay" <<<"$OUT" \
   && [ "$ASKED" = "one two four" ]; then
    ok "W19 one case retired, the probe RUNS, the retired case is NOT asked (it was asked: one two four), and the rest still decide it"
else
    bad "W19 rc=$RC asked='$ASKED' — per-case retirement did not take, or it silently retired the file: <$OUT>"
fi

# --- W21: a case the probe does not have -----------------------------------
retire_on_author_branch cc/fay-typo "$CARRIED"'certification-fay-cases.probe.py	thre	fay	a case name with a typo in it
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "which this probe does not have" <<<"$OUT" \
   && grep -q "one, two, three, four" <<<"$OUT"; then
    ok "W21 a retirement naming a case the probe does not have is REFUSED, and the real cases are named"
else
    bad "W21 rc=$RC — a retirement that matches nothing was ignored rather than refused: <$OUT>"
fi

# --- W23: per case, signed by the wrong author -----------------------------
retire_on_author_branch cc/fay-wrongname "$CARRIED"'certification-fay-cases.probe.py	three	bob	I am not fay and I say this case is obsolete
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "signed 'bob'" <<<"$OUT" \
   && grep -q "case 'three'" <<<"$OUT"; then
    ok "W23 a per-case retirement signed by anyone but the author is REFUSED, naming the case"
else
    bad "W23 rc=$RC — the per-case path skipped the signature check: <$OUT>"
fi

# --- W24: per case, witnessed only by the branch under test ----------------
retire_on_this_branch "$CARRIED"'certification-fay-cases.probe.py	three	fay	written by whoever is failing it, with the right name on it
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "A3:" <<<"$OUT" && grep -q "case 'three'" <<<"$OUT"; then
    ok "W24 a per-case retirement whose only witness is the branch under test is REFUSED — no weaker than the whole-file path"
else
    bad "W24 rc=$RC — the per-case path skipped the attribution check: <$OUT>"
fi

# --- W22: every case retired IS the whole file -----------------------------
retire_on_author_branch cc/fay-all "$CARRIED"'certification-fay-cases.probe.py	one	fay	obsolete
certification-fay-cases.probe.py	two	fay	obsolete
certification-fay-cases.probe.py	three	fay	obsolete
certification-fay-cases.probe.py	four	fay	obsolete
'
run --tree-only --only fay
if [ "$RC" -eq 0 ] && grep -q "^RETIRED" <<<"$OUT" \
   && grep -q "every one of its 4 case(s) is retired" <<<"$OUT"; then
    ok "W22 retiring every case retires the FILE, and the verdict says so instead of implying it"
else
    bad "W22 rc=$RC — all-cases-retired did not become a file verdict: <$OUT>"
fi

# --- W25: the three-field whole-file line still works, unrewritten ---------
# Byte-identical to the shape every line committed before this change has. If the
# parser ever required four fields, every reviewer's existing retirement would
# have to be rewritten by an engineer -- and A3 would then refuse it, because the
# engineer would be the author of the introducing commit.
retire_on_author_branch cc/fay-legacy "$CARRIED"'certification-fay-cases.probe.py	fay	the whole file is obsolete, in the three-field shape
'
run --tree-only --only fay
if [ "$RC" -eq 0 ] && grep -q "^RETIRED" <<<"$OUT" \
   && grep -q "three-field shape" <<<"$OUT"; then
    ok "W25 a three-field whole-file retirement is still read, so no reviewer's committed line needs rewriting"
else
    bad "W25 rc=$RC — the legacy whole-file shape stopped working: <$OUT>"
fi

# --- THE MUTATION HARNESS -------------------------------------------------
# Most of what this suite asserts is that something was REFUSED, and a runner
# that refuses everything would pass those cases while being useless -- which is
# why W4/W18, W9, W14b, W15a and W16b are paired twins. The harness is the other
# half: each refusal watched going red on its own.
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/workspace-probes.mutation.sh" ]; then
    echo ""
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/workspace-probes.mutation.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== workspace-probes tests: all $PASS passed ==="
    exit 0
fi
echo "=== workspace-probes tests: $PASS passed, $FAIL FAILED ==="
exit 1
