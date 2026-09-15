#!/usr/bin/env bash
#
# workspace-probes.test.sh — the runner is now the thing every other check of
# workspaces.py depends on, so it is not allowed to be the one piece with
# nothing asking whether it works.
#
# Each case builds a throwaway repository in the shape the runner expects — a
# git toplevel with engine/mega-lander/workspaces.py and docs/verification/ —
# and puts synthetic probes in it. Nothing here touches the real tree, the real
# probes, or the operator's registry: the registry is redirected into the
# sandbox (RICHOS_WORKSPACES_DIR) and the integration branch is RECORDED there,
# exactly as point 14 requires of Rich before a body of work starts.
#
# THE FIXTURE HAS THE SHAPE THE REAL REPOSITORY HAS (2026-09-12). `main` is the
# recorded integration branch, which only Rich writes; the branch under test is
# `cc/engineer`, cut from main. A reviewer's retirement is committed on the
# reviewer's own branch, LANDED on main by Rich, and merged into cc/engineer —
# that is what gives it a witness other than the work being judged (A3). A
# retirement the engineer commits on cc/engineer has none, however many other
# branches are cut at its tip. Before 2026-09-12 the fixture's HEAD was main
# itself and the witness was "any other branch", which is the shape both
# reviewers silenced from inside the work.
#
#   W1  a probe is DISCOVERED by being LISTED in the committed manifest
#   W2  a file that is not a probe of this library is NOT counted as one
#   W3  a red probe makes the runner exit non-zero and print what may retire it
#   W4  a retirement signed by the probe's OWN AUTHOR and LANDED retires it
#   W5  a retirement signed by ANYONE ELSE is refused, naming both names --
#       this is the whole point, and without it the refusal is a suggestion
#   W6  a probe the runner cannot execute is NOT a probe that passed: it blocks
#   W7  a probe on ANOTHER LOCAL BRANCH is discovered through that branch's
#       manifest and named by its branch
#   W8  --at <commit> tests that commit's workspaces.py, not the tree's
#   W9  a file that declares `not-a-probe: <reason>` in the commit that added it
#       is not run and is named; a BARE marker exempts nothing (UNLISTED)
#   W10 A RUN THAT ASKED NOTHING IS NOT A RUN THAT PASSED. An --only that matches
#       no probe must not print the green line and exit 0 -- that is
#       byte-for-byte what a clean full run looks like
#
# AND THE ROUTES PAST THE GATE, each reproduced by a reviewer in a throwaway
# repository before it was closed. Every one of them made the run print "every
# discovered probe ran, and every one of them is green" and exit 0.
#
#   W11 AN UNCOMMITTED RETIREMENT IS NOT A RETIREMENT (A1). It was enough to
#       write the line; nothing asked whether it had ever been committed.
#   W12 A RETIREMENT COMMITTED ONLY ON THE BRANCH UNDER TEST IS REFUSED (A3):
#       it has not landed on the recorded integration branch.
#   W13 A RETIREMENT IN THE SAME COMMIT AS A LIBRARY EDIT IS REFUSED (A2). The
#       commit that breaks a probe may not be the commit that retires it.
#   W14 A `not-a-probe:` MARKER ADDED TO SOMEBODY ELSE'S PROBE IS REFUSED, and
#       the probe goes on being a probe. This is route 1, and it needed no name
#       at all -- one comment line removed the probe from discovery.
#   W15 A PROBE THE TEXT RULE CANNOT SEE IS DISCOVERED BY BEING LISTED. Route 3:
#       it reaches the library through getattr, spells no entry point and never
#       names the file; UNDISCOVERED IS WORSE THAN RED.
#   W16 A PROBE THAT WAS DELETED IS MISSING, AND MISSING BLOCKS. Route 4: the
#       file simply disappears, and the only thing that changes is a count
#       nothing was checking. W16c: a file at that path in the WORKING TREE
#       does not un-delete it. W16d: an UNCOMMITTED retirement line does not
#       excuse it. W16e: a landed line signed by the WRONG NAME does not either.
#   W17 --show-all NAMES THE FILES IT COUNTS. It was offered as the answer to
#       W15 and W2 and it named 0 of the 242 it counted.
#   W18 THE PAIRED TWIN FOR W12: the identical line, identical author, committed
#       on the AUTHOR'S OWN branch and landed, is accepted -- and the report
#       names the commit and the branch it landed on.
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
#       that one not landed on the recorded branch is refused -- the per-case
#       path does not get a weaker check than the whole-file one.
#   W25 THE THREE-FIELD (whole-file) LINES STILL WORK, unrewritten. Rewriting one
#       would make the engineer the author of its introducing commit, and A3
#       would then refuse the reviewer's own retirement.
#
# THE THREE ROUND-6 CHANGES (W26..W29), each the route both reviewers named:
#
#   W26 A COMMITTED PROBE THE MANIFEST DOES NOT LIST IS UNLISTED, AND UNLISTED
#       BLOCKS: a probe cannot be quietly left off the list either.
#   W27 THE MANIFEST IS READ FROM GIT: a line typed into the working tree lists
#       nothing until it is committed.
#   W28 THE WITNESS SURVIVES BRANCH DELETION: a landed retirement stays RETIRED
#       after its author's branch is deleted (point 4 deletes branches). W28b:
#       a branch cut AT the engineer's tip -- the ordinary review handoff, which
#       defeated the old A3 with no forgery at all -- witnesses nothing.
#   W29 WITH NO INTEGRATION BRANCH RECORDED, every retirement is refused and the
#       refusal names the recording command; the runner never assumes main.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../workspace-probes.py"
LIB="$SCRIPT_DIR/../workspaces.py"

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
mkdir -p "$R/engine/mega-lander" "$R/docs/verification"
git -C "$R" init -q -b main
[ -n "$GIT_ID_EMAIL" ] && git -C "$R" config user.email "$GIT_ID_EMAIL"
[ -n "$GIT_ID_NAME" ]  && git -C "$R" config user.name "$GIT_ID_NAME"
git -C "$R" config commit.gpgsign false
git -C "$R" config core.hooksPath "$SANDBOX/nohooks"
cp "$RUNNER" "$R/engine/mega-lander/"
cp "$LIB" "$R/engine/mega-lander/"
# Bytecode is never part of a commit here. Python writes __pycache__/ beside a
# library it imports; the runner itself no longer does (sys.dont_write_bytecode),
# and the fixture ignores it too, so `git add -A` in a reviewer's commit can
# never sweep a .pyc into the commit A2 then refuses for "changing the engine".
printf '__pycache__/\n' > "$R/.gitignore"
export PYTHONDONTWRITEBYTECODE=1

# THE REGISTRY IS THE SANDBOX'S, and the integration branch is RECORDED in it
# before anything else, the way point 14 asks it of Rich. The runner's A3 asks
# this record and nothing else; the operator's own registry is never read.
export RICHOS_WORKSPACES_DIR="$SANDBOX/ws" RICHOS_SESSION_ID="probes-suite"
mkdir -p "$RICHOS_WORKSPACES_DIR"

MANIFEST="docs/verification/workspace-probes.manifest"
TSV="docs/verification/workspace-probe-retirements.tsv"

# --- the synthetic probes --------------------------------------------------
# A GREEN one, in the argv shape both reviewers use.
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

printf '# the suite manifest\ndocs/verification/certification-alice-green.probe.py\ndocs/verification/certification-bob-red.probe.py\n' > "$R/$MANIFEST"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "the fixture" >/dev/null 2>&1

python3 "$R/engine/mega-lander/workspaces.py" integration --repo "$R" --branch main --why "the suite's body of work" >/dev/null 2>&1 \
    || { echo "FATAL: the sandbox could not record its integration branch" >&2; exit 1; }
git -C "$R" checkout -q -b cc/engineer                # THE BRANCH UNDER TEST

run() { OUT="$(python3 "$R/engine/mega-lander/workspace-probes.py" "$@" 2>&1)"; RC=$?; }

# A RETIREMENT IN THE SHAPE A REAL ONE HAS: written on its AUTHOR'S own branch
# from main, committed there, LANDED on main by Rich, and merged into the branch
# under test. That is what gives it a witness other than the work being judged
# (A3): the recorded integration branch, which survives every land.
land_from_author() { # <branch> <tsv contents>
    git -C "$R" checkout -q -b "$1" main
    printf '%s' "$2" > "$R/$TSV"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m "retirement by $1" >/dev/null 2>&1
    git -C "$R" checkout -q main
    git -C "$R" merge -q --ff-only "$1" >/dev/null 2>&1
    git -C "$R" checkout -q cc/engineer
    # The engineer's branch may carry its OWN committed line in the same file
    # (W12, W24 put one there on purpose); on a conflicting hunk main's side
    # wins, which is what a land does to a line the branch under test wrote.
    # Without this the merge stopped half-way and every checkout after it
    # failed silently, so the cases downstream measured a broken fixture.
    git -C "$R" merge -q --no-edit -X theirs main >/dev/null 2>&1
}

# The same line, committed ONLY on the branch under test. Not landed anywhere.
retire_on_this_branch() { # <tsv contents>
    printf '%s' "$1" > "$R/$TSV"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m "a retirement written by whoever is failing the probe" >/dev/null 2>&1
}

# A probe (or any file) the engineer commits on the branch under test, listed.
commit_listed() { # <path-under-docs/verification> <message>
    printf 'docs/verification/%s\n' "$1" >> "$R/$MANIFEST"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m "$2" >/dev/null 2>&1
}

# --- W1 / W2: discovery is the committed manifest ---------------------------
run --list --tree-only
if grep -q "certification-alice-green.probe.py" <<<"$OUT" \
   && grep -q "certification-bob-red.probe.py" <<<"$OUT" \
   && grep -q "probes discovered:        2 (2 listed at HEAD" <<<"$OUT" \
   && grep -q "integration branch:       main @" <<<"$OUT"; then
    ok "W1  a probe is discovered by being LISTED in the committed manifest, and the report names the recorded integration branch"
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
# Landed, so the ONE thing wrong with it is the name.
land_from_author cc/alice-review \
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
printf 'certification-bob-red.probe.py\tbob\tan unstaged line nobody committed\n' \
    > "$R/$TSV"
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A1:" <<<"$OUT" \
   && grep -q "not in any commit" <<<"$OUT"; then
    ok "W11 an UNCOMMITTED retirement retires nothing — an unstaged edit is not a reviewer's act"
else
    bad "W11 rc=$RC — a working-tree-only retirement took effect: <$OUT>"
fi

# --- W12: COMMITTED, CORRECTLY SIGNED, ONLY ON THE BRANCH UNDER TEST (A3) ---
retire_on_this_branch \
    'certification-bob-red.probe.py	bob	I am failing this probe and I say it is obsolete
'
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A3:" <<<"$OUT" \
   && grep -q "has not landed on main" <<<"$OUT"; then
    ok "W12 a retirement that has not landed on the recorded branch is REFUSED — work cannot retire the probe it fails"
else
    bad "W12 rc=$RC — the failing party retired the probe by typing the right name: <$OUT>"
fi

# --- W28b: THE ORDINARY HANDOFF WITNESSES NOTHING ---------------------------
# Rich cuts a reviewer's branch AT the engineer's tip. Under the old A3 that
# branch "contained" every engineer commit, so every one was witnessed.
git -C "$R" branch cc/frank-review HEAD
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A3:" <<<"$OUT" && grep -q "has not landed on main" <<<"$OUT"; then
    ok "W28b a branch cut AT the engineer's tip is no witness: the same retirement is still refused"
else
    bad "W28b rc=$RC — a branch cut at the tip witnessed the engineer's own retirement: <$OUT>"
fi
git -C "$R" branch -D cc/frank-review >/dev/null 2>&1

# --- W13: BUNDLED WITH A LIBRARY EDIT (A2) ---------------------------------
# On a branch of its own, correctly signed, LANDED -- and the same commit edits
# the library. That is the commit that broke the probe retiring it.
git -C "$R" checkout -q -b cc/bob-bundled main
printf 'certification-bob-red.probe.py\tbob\tobsolete, says the commit that also rewrites the library\n' \
    > "$R/$TSV"
printf '\n# a change to the library in the very same commit\n' >> "$R/engine/mega-lander/workspaces.py"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "fix the library and retire the probe it fails" >/dev/null 2>&1
git -C "$R" checkout -q main
git -C "$R" merge -q --ff-only cc/bob-bundled >/dev/null 2>&1
git -C "$R" checkout -q cc/engineer
git -C "$R" merge -q --no-edit -X theirs main >/dev/null 2>&1     # as land_from_author does
run --tree-only
if [ "$RC" -ne 0 ] && grep -q "A2:" <<<"$OUT" \
   && grep -q "workspaces.py" <<<"$OUT"; then
    ok "W13 a retirement in the same commit as a library edit is REFUSED even when landed — the commit that breaks it may not retire it"
else
    bad "W13 rc=$RC — a retirement bundled into the fix took effect: <$OUT>"
fi

# --- W4 / W18 / W28: signed by its own author, LANDED, it retires -----------
land_from_author cc/bob-review \
    'certification-bob-red.probe.py	bob	the rule it pinned was deleted by the CEO ruling
'
run --tree-only
if [ "$RC" -eq 0 ] && grep -q "RETIRED" <<<"$OUT" \
   && grep -q "deleted by the CEO ruling" <<<"$OUT"; then
    ok "W4  a retirement signed by the probe's own author and landed on the recorded branch retires it"
else
    bad "W4  rc=$RC — a correctly signed and landed retirement did not take: <$OUT>"
fi
if grep -q "landed on main @" <<<"$OUT"; then
    ok "W18 and the report NAMES the commit and the branch it landed on — a RETIRED with no witness is the typed name again"
else
    bad "W18 the witness is not on the record: <$OUT>"
fi
git -C "$R" branch -D cc/bob-review >/dev/null 2>&1        # point 4: the author's branch is gone after the land
run --tree-only
if [ "$RC" -eq 0 ] && grep -q "RETIRED" <<<"$OUT" && grep -q "landed on main @" <<<"$OUT"; then
    ok "W28 the witness SURVIVES the deletion of the author's branch: still RETIRED, same witness"
else
    bad "W28 rc=$RC — deleting the landed branch un-retired the probe (the witness was a branch name): <$OUT>"
fi
# CLEARED BY LANDING AN EMPTY FILE, NEVER BY DELETING IT. A deletion on the
# branch under test against a modification on main is a modify/delete conflict,
# which no merge strategy resolves; the next land then stopped half-way and
# W7's `git add -A` folded a reviewer's probe into that unfinished merge.
land_from_author cc/rich-clears '# cleared: no retirement stands
'

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
commit_listed certification-carol-unrunnable.probe.py "an unrunnable probe, listed"
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
# her own retirement, on her own branch, landed.
git -C "$R" rm -q "docs/verification/certification-carol-unrunnable.probe.py" >/dev/null 2>&1
git -C "$R" commit -q -m "drop it" >/dev/null 2>&1
land_from_author cc/carol-review \
    'certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
'

# --- W7: a probe committed on ANOTHER LOCAL BRANCH is discovered ------------
# A reviewer commits its probe on its own branch and LISTS it in that branch's
# manifest, which is precisely the branch the engineer has not merged.
git -C "$R" checkout -q -b cc/dave-review main
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
printf 'docs/verification/certification-dave-green.probe.py\n' >> "$R/$MANIFEST"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "dave's probe, on dave's branch, listed there" >/dev/null 2>&1
CO_ERR="$(git -C "$R" checkout -q cc/engineer 2>&1)"
CUR_BR="$(git -C "$R" branch --show-current)"
run --list
if [ "$CUR_BR" = cc/engineer ] && grep -q "certification-dave-green" <<<"$OUT" && grep -q "cc/dave-review" <<<"$OUT"; then
    ok "W7  a probe committed and listed on another local branch is discovered and named by its branch"
else
    bad "W7  a reviewer's unmerged probe was invisible (fixture on '$CUR_BR', checkout said '$CO_ERR'): <$OUT>"
fi
run --list --tree-only
if ! grep -q "certification-dave-green" <<<"$OUT"; then
    ok "W7b --tree-only really does skip other branches (so W7 measured something)"
else
    bad "W7b --tree-only still read another branch: <$OUT>"
fi

# --- W8: --at tests THAT COMMIT's library, not the tree's -------------------
AT_BEFORE="$(git -C "$R" rev-parse HEAD)"
printf 'def nothing():\n    return 0\n' > "$R/engine/mega-lander/workspaces.py"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "a library without the rule" >/dev/null 2>&1
AT_HOLLOW="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q "$AT_BEFORE" -- engine/mega-lander/workspaces.py
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
   && grep -q "^UNLISTED   docs/verification/bare-marker.py" <<<"$OUT" \
   && [ "$RC" -ne 0 ] \
   && ! grep -q "(not run)  docs/verification/build-some-probes.py" <<<"$OUT"; then
    ok "W9  a declared non-probe is not run and IS NAMED; a BARE marker exempts nothing — the file is UNLISTED and blocks"
else
    bad "W9  rc=$RC the declaration is wrong in one direction or the other: <$OUT>"
fi
# A declaration ADDED LATER, then LANDED by Rich, stands (the twin of W14).
python3 - "$R/docs/verification/bare-marker.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read().replace('"""not-a-probe:\n', '"""not-a-probe: a helper that only reads the version.\n')
io.open(p, "w", encoding="utf-8").write(s)
PY
git -C "$R" commit -q -am "give the helper its reason" >/dev/null 2>&1
git -C "$R" checkout -q main; git -C "$R" merge -q --no-edit cc/engineer >/dev/null 2>&1; git -C "$R" checkout -q cc/engineer
run --list --tree-only
if grep -q "^DECLARED   docs/verification/bare-marker.py" <<<"$OUT" && grep -q "landed on main @" <<<"$OUT"; then
    ok "W9b a declaration added later and LANDED stands, and the report says what landed it"
else
    bad "W9b a landed declaration was refused: <$OUT>"
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
# `not-a-probe:` to bob's file on the branch under test.
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
git -C "$R" branch cc/reviewer-at-tip HEAD                   # and a branch cut at the tip, for good measure
run --tree-only --only bob
if [ "$RC" -ne 0 ] && grep -q "DECLARATION REFUSED" <<<"$OUT" \
   && grep -q "A3:" <<<"$OUT" \
   && ! grep -q "every one of them is green" <<<"$OUT"; then
    ok "W14 a not-a-probe marker ADDED to somebody else's probe is REFUSED, and the probe goes on being a probe"
else
    bad "W14 rc=$RC — one comment line removed a red probe from the run: <$OUT>"
fi
git -C "$R" branch -D cc/reviewer-at-tip >/dev/null 2>&1
git -C "$R" checkout -q "HEAD~1" -- docs/verification/certification-bob-red.probe.py
git -C "$R" commit -q -am "restore bob's probe" >/dev/null 2>&1
if grep -q "not-a-probe" "$R/docs/verification/certification-bob-red.probe.py"; then
    bad "W14b the fixture cleanup did not restore bob's probe, so every case after this one is unsound"
else
    ok "W14b the annotation is gone again — the cases after this one are back on a clean fixture"
fi

# --- W15: ROUTE 3 — A PROBE THE TEXT RULE CANNOT SEE -----------------------
# It reaches the library through getattr, spells no entry point with a
# parenthesis, and never writes the file's name. The text rule cannot see it;
# its author's LISTING can.
cat > "$R/docs/verification/certification-erin-nameless.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Erin's probe. The library arrives as argv[1]; its name is never written and
no entry point is spelled with a parenthesis."""
import importlib.util, sys
CASES = ["e"]
def main(argv):
    spec = importlib.util.spec_from_file_location("underTest", argv[0])
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    fn = getattr(mod, "integration" + "_for")
    branch, tip, why = fn("/no/such/repository")
    return 0 if why else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "erin's probe, committed but not yet listed" >/dev/null 2>&1
run --list --tree-only
if ! grep -q "workspaces.py" "$R/docs/verification/certification-erin-nameless.probe.py" \
   && ! grep -q "certification-erin-nameless" <<<"$OUT"; then
    ok "W15a POSITIVE CONTROL: unlisted, the text rule really cannot see it (it is neither a probe nor UNLISTED)"
else
    bad "W15a the fixture is visible to the text rule, so W15 would prove nothing: <$OUT>"
fi
commit_listed certification-erin-nameless.probe.py "list erin's probe"
run --list --tree-only
if grep -q "certification-erin-nameless" <<<"$OUT"; then
    ok "W15 a probe the text rule cannot see is discovered by being LISTED"
else
    bad "W15 a listed probe was invisible: <$OUT>"
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
printf '# a file at the deleted path, in the working tree only\n' > "$R/docs/verification/certification-erin-nameless.probe.py"
run --tree-only --only erin
if [ "$RC" -ne 0 ] && grep -q "MISSING" <<<"$OUT"; then
    ok "W16c a file at the deleted path in the WORKING TREE does not un-delete it: MISSING is asked of git"
else
    bad "W16c rc=$RC — a working-tree file concealed a committed deletion: <$OUT>"
fi
rm -f "$R/docs/verification/certification-erin-nameless.probe.py"
printf 'certification-carol-unrunnable.probe.py\tcarol\tit offered this runner no way in and I have replaced it\ncertification-erin-nameless.probe.py\terin\tan unstaged line signed with the right name\n' > "$R/$TSV"
run --tree-only --only erin
if [ "$RC" -ne 0 ] && grep -q "MISSING" <<<"$OUT" && grep -q "A1:" <<<"$OUT"; then
    ok "W16d an UNCOMMITTED retirement line does not excuse the deletion (A1)"
else
    bad "W16d rc=$RC — an unstaged line concealed a committed deletion: <$OUT>"
fi
git -C "$R" checkout -q -- "$R/$TSV" 2>/dev/null || git -C "$R" checkout -q -- "$TSV"
land_from_author cc/bob-again \
    'certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
certification-erin-nameless.probe.py	bob	I am not erin and I say her deleted probe is obsolete
'
run --tree-only --only erin
if [ "$RC" -ne 0 ] && grep -q "MISSING" <<<"$OUT" && grep -q "signed 'bob'" <<<"$OUT"; then
    ok "W16e a LANDED retirement signed by the wrong name does not excuse the deletion either"
else
    bad "W16e rc=$RC — the wrong name excused a deletion: <$OUT>"
fi
# THE PAIRED TWIN: her own retirement, landed, and the same deletion stops blocking.
land_from_author cc/erin-review \
    'certification-carol-unrunnable.probe.py	carol	it offered this runner no way in and I have replaced it
certification-erin-nameless.probe.py	erin	replaced by a probe that asserts the same rule per case
'
run --tree-only --only erin
if ! grep -q "MISSING" <<<"$OUT"; then
    ok "W16b SILENT TWIN: retired by its own author and landed, the same deletion no longer blocks"
else
    bad "W16b a retired-and-deleted probe still blocks: <$OUT>"
fi

# --- W17: --show-all NAMES WHAT IT COUNTS ----------------------------------
run --tree-only --show-all
if grep -q "some-other-measurement.py" <<<"$OUT" && grep -q "named; the count above was" <<<"$OUT"; then
    ok "W17 --show-all NAMES the files it counts, and prints both numbers so they can be compared"
else
    bad "W17 --show-all counted without naming: <$OUT>"
fi

# --- W26 / W27: UNLISTED blocks, and the manifest is read from git ----------
cat > "$R/docs/verification/certification-gus-unlisted.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Gus's probe of workspaces.py, committed and green, and nobody listed it."""
import importlib.util, sys
CASES = ["g"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    return 0 if hasattr(ws, "barrier") else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "gus's probe, committed, not listed" >/dev/null 2>&1
# ALONGSIDE A GREEN LISTED PROBE, deliberately: with gus alone selected, a
# runner that ignored UNLISTED would refuse anyway for "NOTHING WAS RUN", and
# this case would pass for the wrong reason. With alice green beside it, the
# only thing standing between the run and its all-clear is the unlisted probe.
run --tree-only --only gus --only alice
if [ "$RC" -ne 0 ] && grep -q "^UNLISTED   docs/verification/certification-gus-unlisted.probe.py" <<<"$OUT" \
   && grep -q "^GREEN      docs/verification/certification-alice-green.probe.py" <<<"$OUT" \
   && ! grep -q "every one of them is green" <<<"$OUT"; then
    ok "W26 a committed probe the manifest does not list is UNLISTED, by name, and it BLOCKS a run that is otherwise green"
else
    bad "W26 rc=$RC — an unlisted probe was silently dropped or silently run: <$OUT>"
fi
printf 'docs/verification/certification-gus-unlisted.probe.py\n' >> "$R/$MANIFEST"     # typed, not committed
run --tree-only --only gus --only alice
if [ "$RC" -ne 0 ] && grep -q "^UNLISTED" <<<"$OUT"; then
    ok "W27 a manifest line in the WORKING TREE lists nothing: the manifest is read from git"
else
    bad "W27 rc=$RC — an uncommitted manifest edit changed what was asked: <$OUT>"
fi
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "list gus's probe" >/dev/null 2>&1
run --tree-only --only gus --only alice
if [ "$RC" -eq 0 ] && grep -q "^GREEN      docs/verification/certification-gus-unlisted.probe.py" <<<"$OUT"; then
    ok "W27b committed, the same line lists it and it runs green"
else
    bad "W27b rc=$RC — the committed listing did not take: <$OUT>"
fi

# --- W30: A PROBE DELETED TOGETHER WITH ITS MANIFEST LINE, IN ONE COMMIT ---
# Round 6's closure (RN2d, certification-frank-round6 §4): a listed probe the
# text rule cannot see (it reaches the library through getattr and never
# spells its name), deleted in the same commit that drops its manifest line,
# left NO trace — the deletion scan judged the file's text, the manifest scan
# read HEAD, and both were satisfied. The manifest is now read at every
# commit that touched it, so an entry ever listed and absent at HEAD is
# MISSING unless its author retired it.
cat > "$R/docs/verification/certification-hank-invisible.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Hank's probe. It never spells the library's name or an entry point: the text rule cannot see it."""
import importlib.util, sys
CASES = ["h"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    return 0 if getattr(ws, "integration" + "_target", None) else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
commit_listed certification-hank-invisible.probe.py "hank's probe, listed"
run --tree-only --only hank --only alice
if [ "$RC" -eq 0 ] && grep -q "^GREEN      docs/verification/certification-hank-invisible.probe.py" <<<"$OUT"; then
    ok "W30a POSITIVE CONTROL: the text-invisible probe is discovered by its manifest line and runs green"
else
    bad "W30a rc=$RC — the listed invisible probe did not run: <$OUT>"
fi
git -C "$R" rm -q docs/verification/certification-hank-invisible.probe.py >/dev/null 2>&1
grep -v 'certification-hank-invisible' "$R/$MANIFEST" > "$R/$MANIFEST.new" && mv "$R/$MANIFEST.new" "$R/$MANIFEST"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "the probe and its manifest line, gone in one commit" >/dev/null 2>&1
run --tree-only --only hank --only alice
if [ "$RC" -ne 0 ] && grep -q "^MISSING    docs/verification/certification-hank-invisible.probe.py" <<<"$OUT" \
   && grep -q "listed in the manifest at" <<<"$OUT"; then
    ok "W30 a probe deleted TOGETHER WITH ITS MANIFEST LINE in one commit is still MISSING: the manifest is read at the commit that listed it, not at HEAD"
else
    bad "W30 rc=$RC — a probe and its manifest line deleted in one commit left no trace: <$OUT>"
fi
land_from_author hank "$(printf 'certification-hank-invisible.probe.py\t*\thank\tsuperseded by the fixture, says hank\n')"
run --tree-only --only hank --only alice
if [ "$RC" -eq 0 ] && ! grep -q "MISSING" <<<"$OUT"; then
    ok "W30b SILENT TWIN: retired by its own author and landed, the same manifest-history deletion no longer blocks"
else
    bad "W30b rc=$RC — a retired-and-deleted probe found through the manifest's history still blocks: <$OUT>"
fi

# --- W31: A PROBE GUTTED INTO A STUB AND DELISTED, IN ONE COMMIT ---------------
# Round 8, item 1 (certification-sage-round7 §0/§6, brief-audit-sage-round8 §2):
# "holds nothing" was implemented as "the path is absent at HEAD", so a docs-only
# commit that replaced a RED probe with a non-probe stub AND dropped its manifest
# line left DELETED 0, NOT LISTED 0, the probe gone from the report, exit 0.
# Outright deletion was caught (W16, W30) and must stay caught (W31c). The rule
# is now read from the manifest alone: listed at any commit and not listed at
# HEAD is MISSING unless its author retired it, whatever sits at the path.
cat > "$R/docs/verification/certification-ivy-red.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Ivy's probe of workspaces.py. Deliberately red: the build lacks a rule."""
import importlib.util, sys
CASES = ["i"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    ws.integration_for  # the entry point this probe drives
    return 0 if hasattr(ws, "a_rule_ivy_wants_and_the_build_lacks") else 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
commit_listed certification-ivy-red.probe.py "ivy's probe, listed, red"
run --tree-only --only ivy --only alice
if [ "$RC" -ne 0 ] && grep -q "^RED        docs/verification/certification-ivy-red.probe.py" <<<"$OUT"; then
    ok "W31a POSITIVE CONTROL: ivy's listed probe runs and is RED (it blocks)"
else
    bad "W31a rc=$RC — the fixture probe is not red before the gutting: <$OUT>"
fi
# The gut-and-delist commit: the file stays at its path as a non-probe stub (no
# library name, no entry point — the text rule cannot see it), and the manifest
# line goes, in ONE docs-only commit.
cat > "$R/docs/verification/certification-ivy-red.probe.py" <<'STUB'
#!/usr/bin/env python3
"""A note that used to be a probe. It imports nothing and asserts nothing."""
print("nothing to see")
STUB
grep -v 'certification-ivy-red' "$R/$MANIFEST" > "$R/$MANIFEST.new" && mv "$R/$MANIFEST.new" "$R/$MANIFEST"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "tidy: an old note, and its stale manifest line" >/dev/null 2>&1
run --tree-only --only ivy --only alice
if [ "$RC" -ne 0 ] && grep -q "^MISSING    docs/verification/certification-ivy-red.probe.py" <<<"$OUT" \
   && grep -q "NOT LISTED at HEAD" <<<"$OUT"; then
    ok "W31 a RED probe gutted into a non-probe stub AND delisted in one commit is MISSING and blocks: listed at any commit and not listed at HEAD, whatever sits at the path"
else
    bad "W31 rc=$RC — a gutted-and-delisted probe left no trace: <$OUT>"
fi
# The deletion case must STAY caught: a second probe deleted outright together with its line.
cat > "$R/docs/verification/certification-jon-red.probe.py" <<'PROBE'
#!/usr/bin/env python3
"""Jon's probe of workspaces.py. Deliberately red."""
import importlib.util, sys
CASES = ["j"]
def main(argv):
    spec = importlib.util.spec_from_file_location("ws", argv[0])
    ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
    ws.integration_for
    return 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PROBE
commit_listed certification-jon-red.probe.py "jon's probe, listed, red"
git -C "$R" rm -q docs/verification/certification-jon-red.probe.py >/dev/null 2>&1
grep -v 'certification-jon-red' "$R/$MANIFEST" > "$R/$MANIFEST.new" && mv "$R/$MANIFEST.new" "$R/$MANIFEST"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "jon's probe and its line, gone in one commit" >/dev/null 2>&1
run --tree-only --only jon --only ivy --only alice
if [ "$RC" -ne 0 ] && grep -q "^MISSING    docs/verification/certification-jon-red.probe.py" <<<"$OUT" \
   && grep -q "^MISSING    docs/verification/certification-ivy-red.probe.py" <<<"$OUT"; then
    ok "W31c deletion is still caught beside delisting: both probes are MISSING"
else
    bad "W31c rc=$RC — deletion stopped being caught, or delisting did: <$OUT>"
fi
# A legitimately retired probe still reads as retired: ivy retires her file whole and lands it.
land_from_author ivy "$(printf 'certification-ivy-red.probe.py\t*\tivy\tobsolete, says ivy, and the stub is a note now\n')"
run --tree-only --only ivy --only alice
if [ "$RC" -eq 0 ] && ! grep -q "certification-ivy-red" <<<"$OUT"; then
    ok "W31b retired by its own author and landed, the delisted probe no longer blocks (and jon's deletion, unretired, still would)"
else
    bad "W31b rc=$RC — a retired-and-delisted probe still blocks: <$OUT>"
fi

# ===========================================================================
# RETIREMENT PER CASE — W19..W25
# ===========================================================================
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
commit_listed certification-fay-cases.probe.py "fay's probe, four cases, one of them red"
export FAY_LOG="$SANDBOX/fay-was-asked.txt"

# CAROL'S AND ERIN'S RETIREMENTS ARE CARRIED FORWARD through every rewrite of the
# file below, because land_from_author WRITES it. Dropping them would resurrect
# two deletions and put the wrong probes in this section's output.
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
land_from_author cc/fay-review "$CARRIED"'certification-fay-cases.probe.py	three	fay	the rule case three pinned was deleted by the CEO ruling
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
land_from_author cc/fay-typo "$CARRIED"'certification-fay-cases.probe.py	thre	fay	a case name with a typo in it
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "which this probe does not have" <<<"$OUT" \
   && grep -q "one, two, three, four" <<<"$OUT"; then
    ok "W21 a retirement naming a case the probe does not have is REFUSED, and the real cases are named"
else
    bad "W21 rc=$RC — a retirement that matches nothing was ignored rather than refused: <$OUT>"
fi

# --- W23: per case, signed by the wrong author -----------------------------
land_from_author cc/fay-wrongname "$CARRIED"'certification-fay-cases.probe.py	three	bob	I am not fay and I say this case is obsolete
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "signed 'bob'" <<<"$OUT" \
   && grep -q "case 'three'" <<<"$OUT"; then
    ok "W23 a per-case retirement signed by anyone but the author is REFUSED, naming the case"
else
    bad "W23 rc=$RC — the per-case path skipped the signature check: <$OUT>"
fi

# --- W24: per case, not landed on the recorded branch ----------------------
retire_on_this_branch "$CARRIED"'certification-fay-cases.probe.py	three	fay	written by whoever is failing it, with the right name on it
'
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "A3:" <<<"$OUT" && grep -q "case 'three'" <<<"$OUT"; then
    ok "W24 a per-case retirement that has not landed on the recorded branch is REFUSED — no weaker than the whole-file path"
else
    bad "W24 rc=$RC — the per-case path skipped the attribution check: <$OUT>"
fi

# --- W22: every case retired IS the whole file -----------------------------
land_from_author cc/fay-all "$CARRIED"'certification-fay-cases.probe.py	one	fay	obsolete
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
land_from_author cc/fay-legacy "$CARRIED"'certification-fay-cases.probe.py	fay	the whole file is obsolete, in the three-field shape
'
run --tree-only --only fay
if [ "$RC" -eq 0 ] && grep -q "^RETIRED" <<<"$OUT" \
   && grep -q "three-field shape" <<<"$OUT"; then
    ok "W25 a three-field whole-file retirement is still read, so no reviewer's committed line needs rewriting"
else
    bad "W25 rc=$RC — the legacy whole-file shape stopped working: <$OUT>"
fi

# --- W29: NO INTEGRATION BRANCH RECORDED — refuse, name the command ---------
SAVED_WS="$RICHOS_WORKSPACES_DIR"
export RICHOS_WORKSPACES_DIR="$SANDBOX/ws-empty"; mkdir -p "$RICHOS_WORKSPACES_DIR"
run --tree-only --only fay
if [ "$RC" -ne 0 ] && grep -q "integration branch:       NOT RECORDED" <<<"$OUT" \
   && grep -q "A3: no branch is recorded" <<<"$OUT" \
   && grep -q "workspaces.sh integration" <<<"$OUT" \
   && ! grep -q "^RETIRED" <<<"$OUT"; then
    ok "W29 with no integration branch recorded, the same landed retirement is REFUSED and the refusal names the recording command — the runner never assumes main"
else
    bad "W29 rc=$RC — with nothing recorded the runner accepted a retirement (it assumed a branch): <$OUT>"
fi
export RICHOS_WORKSPACES_DIR="$SAVED_WS"

# --- THE MUTATION HARNESS -------------------------------------------------
# Most of what this suite asserts is that something was REFUSED, and a runner
# that refuses everything would pass those cases while being useless -- which is
# why W4/W18/W28, W9b, W14b, W15a, W16b and W27b are paired twins. The harness
# is the other half: each refusal watched going red on its own.
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
