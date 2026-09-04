#!/usr/bin/env bash
#
# completeness-commits.test.sh — regression tests for the chokepoint that makes
# the publication-completeness contract fire on its own:
# scripts/hooks/guard-completeness-commits.sh.
#
# The PREDICATE has its own suite (scripts/publication-completeness.test.sh) and
# nothing here re-tests it. This suite tests the only things the guard adds:
# WHEN it runs, WHERE it stands down, WHAT it does with each of the checker's
# three exit codes, and whether it can be committed out of.
#
# THE CASE THAT MATTERS MOST IS (b): THE REPLAY. On 2026-08-30 the flywheel
# README shipped a citation to a plan file that lives only in richos-hq, and it
# reached main and got pushed, because the completeness check ran when somebody
# remembered and nobody did. Case (b) reconstructs that exact document shape and
# asserts the commit is refused. If that case ever passes-by-not-running, the
# guard is decorative — so it also asserts the refusal NAMES the dangling path,
# which a stand-down could never do.
#
# A NOTE ON THE HARNESS, inherited from publication-boundary.test.sh's scar:
# content travels by FILE and every assertion runs in the top-level shell. Bash
# runs the right-hand side of a pipe in a SUBSHELL, so a PASS/FAIL increment
# inside one is discarded and the suite reports a tally that is not the
# inventory it claims to describe — the "18/18 suites" defect, reproduced inside
# a suite written to prevent that defect's cousin.
#
# Covers:
#   (a) STAND-DOWN, the precision floor — a repository with no
#       .publication-boundary is untouched, and so is every Bash command that is
#       not a commit or a push. Get this wrong and the guard fires in every
#       repository on the machine, which is how a guard gets switched off.
#   (b) THE REPLAY — the real 2026-08-30 miss, refused at commit AND at push,
#       with the dangling path named.
#   (c) THE WHOLE TREE, NOT THE DIFF — a commit that touches an unrelated file
#       is still refused by a citation somebody else left, and the refusal says
#       so instead of blaming the author. This is the trade the guard makes on
#       purpose; a test that did not pin it would let a future "optimization"
#       quietly turn it into a diff check.
#   (d) THE MERGE ARM — a defect that exists on NEITHER branch and only in the
#       merge is invisible at commit time and caught at push. This is the whole
#       reason this guard has a second arm its siblings decline.
#   (e) NO DEADLOCK — fixing the citation, adding the missing file, or writing
#       an exemption each make the very next commit pass, from the INDEX and
#       from the WORKTREE. A guard you cannot commit your way out of gets
#       removed within the day.
#   (f) THE EXEMPTION IS SELF-EXPIRING — an entry that suppresses nothing is
#       still a refusal, through this chokepoint and not only in CI.
#   (g) CLASSIFIER PRECISION — a commit message containing the word "push" is
#       not a push; `git log`, `git status` and an unrelated command never reach
#       the checker at all.
#   (h) FAIL-CLOSED / BROKEN-INSTALL conventions, matching the hook family: a
#       broken declaration and a missing predicate both refuse, and neither
#       degrades into a quiet pass.
#   (i) REGISTRATION on BOTH surfaces plus the probe's oracle — the guard is
#       wired where the host will actually load it.
#
# Run directly: scripts/hooks/completeness-commits.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Declare the root under test, for the reason publication-boundary.test.sh
# states: run from a session seated elsewhere the guard would resolve THAT
# repository, find no adoption marker, stand down, and every case below would
# pass by never running — the most dangerous way for a suite to be green.
RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/guard-completeness-commits.sh"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t cctest-scratch.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing or not executable" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
payload() { # <command> <cwd>
    CC_CMD="$1" CC_C="$2" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["CC_C"],
                  "tool_input": {"command": os.environ["CC_CMD"]}}))
'
}

# LAST_OUT is written by every invocation so a case can assert on the REASON,
# not only on the exit code. A guard that refuses for the wrong reason is a
# guard that will refuse the wrong thing tomorrow.
LAST_OUT=""
invoke() { # <command> <cwd> -> rc, sets LAST_OUT
    local rc=0
    LAST_OUT="$(payload "$1" "$2" | "$HOOK" 2>&1 >/dev/null)" || rc=$?
    return $rc
}

cc_case() { # <name> <expect-rc> <cwd> [command]
    local name="$1" want="$2" cwd="$3" cmd="${4:-git -C $3 commit -m msg}" rc=0
    invoke "$cmd" "$cwd" || rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$name"; else bad "$name (expected exit $want, got $rc)"; fi
}

says() { # <name> <needle>
    if printf '%s' "$LAST_OUT" | grep -qF -- "$2"; then
        ok "$1"
    else
        bad "$1 (refusal did not mention \"$2\")"
    fi
}

# ---------------------------------------------------------------------------
# mktree <name> — a minimal COMPLETE publication-bound tree.
#
# Deliberately the same shape as publication-completeness.test.sh's fixture, and
# deliberately its own copy: this suite must keep passing while that one's
# fixture evolves for reasons of its own, and a shared fixture between two
# suites is a coupling that turns one suite's edit into the other's mystery
# failure.
# ---------------------------------------------------------------------------
mktree() {
    local t="$SCRATCH/$1"
    mkdir -p "$t/scripts/hooks" "$t/docs"
    # NO user.email/user.name override. This machine runs a global
    # core.hooksPath identity guard that REFUSES any commit not authored by the
    # operator's address, so a helpfully-set test identity makes every fixture
    # commit fail silently and the whole suite pass over empty repositories.
    git -C "$t" init -q 2>/dev/null || git init -q "$t"
    printf 'build/\n' > "$t/.gitignore"

    cat > "$t/.publication-boundary" <<'EOF'
PRIVATE_RECORD="the private HQ repository"
PRIVATE_SOURCES=""
EOF

    cat > "$t/scripts/hooks/guard-widget.sh" <<'EOF'
#!/usr/bin/env bash
: "${WIDGET_DECLARATION:=.widget}"
[ -f "$PWD/$WIDGET_DECLARATION" ] || exit 0
echo "widget guard active"
EOF
    chmod +x "$t/scripts/hooks/guard-widget.sh"
    printf 'WIDGET_RECORD="wherever"\n' > "$t/.widget.example"

    cat > "$t/README.md" <<'EOF'
# Sample

Create a `.widget` file at your repository root to switch the widget guard on;
copy `.widget.example` and edit it. The guard itself is
`scripts/hooks/guard-widget.sh`.
EOF
    printf 'VERSION 1\n' > "$t/VERSION"
    printf 'notes\n' > "$t/docs/notes.md"
    git -C "$t" add -A >/dev/null 2>&1
    git -C "$t" commit -qm "sample tree" >/dev/null 2>&1
    printf '%s' "$t"
}

commit_all() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "case" >/dev/null 2>&1; }

echo "=== completeness-commits.test.sh ==="

# ---------------------------------------------------------------------------
echo "--- (a) stand-down: the precision floor"
# ---------------------------------------------------------------------------
NODECL="$SCRATCH/nodecl"
mkdir -p "$NODECL/docs"
git -C "$NODECL" init -q 2>/dev/null || git init -q "$NODECL"
# A citation that WOULD be a finding, in a repository that never declared
# itself published. It must be invisible: adoption is declared, never inferred.
printf 'See `docs/gone.md`.\n' > "$NODECL/docs/a.md"
cc_case "undeclared repo: commit untouched"      0 "$NODECL"
cc_case "undeclared repo: push untouched"        0 "$NODECL" "git -C $NODECL push"
cc_case "a directory in no repository at all"    0 "/tmp" "git -C /tmp commit -m x"

BASE="$(mktree base)"
cc_case "a complete tree commits"                0 "$BASE"
cc_case "a complete tree pushes"                 0 "$BASE" "git -C $BASE push"

# ---------------------------------------------------------------------------
echo "--- (b) THE REPLAY: the real 2026-08-30 miss"
# ---------------------------------------------------------------------------
# docs/measurements/correction-flywheel-2026-08-29/README.md cited
# `docs/plans/richos-techy-mode-2026-08-26.md`, which exists only in richos-hq.
# It was committed, merged and pushed, and the contract sat red on main.
REPLAY="$(mktree replay)"
mkdir -p "$REPLAY/docs/measurements/flywheel"
cat > "$REPLAY/docs/measurements/flywheel/README.md" <<'EOF'
# Correction flywheel

It reuses the shape and the exact numbers the techy-mode journal already
committed to (`docs/plans/richos-techy-mode-2026-08-26.md` §2.4) rather than
inventing a third thing to reason about.
EOF
# THE IDIOM THAT ALMOST DEFEATED THIS GUARD. The file is still UNTRACKED at
# hook time; `git ls-files` does not list it; a naive read audits the tree minus
# the very file being added. Asserted FIRST because if this one regresses the
# guard is decorative and every case below it is theatre.
cc_case "'git add -A && git commit' — the file is UNTRACKED and still caught" 2 "$REPLAY" \
        "git -C $REPLAY add -A && git -C $REPLAY commit -m msg"
says    "and the refusal NAMES the path a reader would be sent to" \
        "docs/plans/richos-techy-mode-2026-08-26.md"
says    "and it says which verb it refused" "REFUSING THIS commit"

# A bare commit of an untracked file is NOT a defect and must not be refused:
# nothing is staged, so nothing is about to be published. The guard audits the
# tree that is about to exist, not every byte lying in the directory.
cc_case "a BARE commit, with the file untracked, is untouched"  0 "$REPLAY"

git -C "$REPLAY" add -A >/dev/null 2>&1
cc_case "still refused once staged"                            2 "$REPLAY"
cc_case "and refused at push, which is where it escaped"       2 "$REPLAY" "git -C $REPLAY push"
says    "the push refusal says push, not commit" "REFUSING THIS push"

# The fix the checker itself prints: name the private record in prose.
cat > "$REPLAY/docs/measurements/flywheel/README.md" <<'EOF'
# Correction flywheel

It reuses the shape and the exact numbers the techy-mode journal already
committed to (the techy-mode plan §2.4, in the private record `richos-hq`, not
this repository) rather than inventing a third thing to reason about.
EOF
cc_case "repointing at the private record by name unblocks it" 0 "$REPLAY"

# ---------------------------------------------------------------------------
echo "--- (c) the WHOLE TREE, not the diff"
# ---------------------------------------------------------------------------
# The economy this guard deliberately refuses. A scoped check would pass this
# commit — the finding is in a file it does not touch — and the defect would go
# on sitting there, which is exactly how the real one survived.
WHOLE="$(mktree whole)"
printf 'See `docs/never-shipped.md` for the details.\n' > "$WHOLE/docs/claim.md"
commit_all "$WHOLE"          # the defect is now HISTORY, not this commit's doing
printf 'unrelated\n' > "$WHOLE/docs/unrelated.md"
git -C "$WHOLE" add docs/unrelated.md >/dev/null 2>&1
cc_case "an UNRELATED commit is still refused by a pre-existing finding" 2 "$WHOLE"
says    "and it does not blame the author for it" "NONE of the paths named above"

# The other half of the same trade: when it IS yours, it says so.
MINE="$(mktree mine)"
printf 'See `docs/never-shipped.md`.\n' > "$MINE/docs/claim.md"
git -C "$MINE" add docs/claim.md >/dev/null 2>&1
cc_case "a commit that introduces the finding is refused"               2 "$MINE"
says    "and it says the author owns this one" "touched by this commit"

# ---------------------------------------------------------------------------
echo "--- (d) the MERGE arm: why this guard has a push half"
# ---------------------------------------------------------------------------
# Branch A moves a file. Branch B cites the old path. BOTH COMMIT CLEAN — each
# is complete on its own — and the merge is broken. No per-commit check of
# either branch can see this, because the defect exists on neither. `git merge`
# does not run `git commit`, so the commit arm never fires on it either. The
# push is the only chokepoint left, and this is the case that proves it.
MERGE="$(mktree merge)"
printf 'the target\n' > "$MERGE/docs/target.md"
commit_all "$MERGE"
MAIN_BRANCH="$(git -C "$MERGE" rev-parse --abbrev-ref HEAD)"
git -C "$MERGE" branch mover >/dev/null 2>&1

# Branch B: cite it where it is. Complete.
printf 'See `docs/target.md`.\n' > "$MERGE/docs/citer.md"
cc_case "branch B commits clean — the citation resolves"    0 "$MERGE" \
        "git -C $MERGE add -A && git -C $MERGE commit -m msg"
commit_all "$MERGE"

# Branch A: move it. Also complete — nothing on A cites it.
git -C "$MERGE" checkout -q mover
git -C "$MERGE" mv docs/target.md docs/moved.md >/dev/null 2>&1
cc_case "branch A commits clean — nothing there cites it"   0 "$MERGE"
commit_all "$MERGE"

git -C "$MERGE" checkout -q "$MAIN_BRANCH"
git -C "$MERGE" merge --no-edit mover >/dev/null 2>&1
cc_case "the MERGE is broken and the push is refused"       2 "$MERGE" "git -C $MERGE push"
says    "naming the path the merge stranded"               "docs/target.md"

# ---------------------------------------------------------------------------
echo "--- (e) no deadlock: three ways out, all of them a normal edit"
# ---------------------------------------------------------------------------
# A guard that blocks the commit that would fix it is a guard that gets deleted.
# Each arm below is asserted separately because each reads a different source:
# the WORKTREE (an edit), the INDEX (a staged add), and the declaration file.
OUT1="$(mktree out1)"
printf 'See `docs/missing.md`.\n' > "$OUT1/docs/claim.md"
git -C "$OUT1" add -A >/dev/null 2>&1
cc_case "blocked"                                            2 "$OUT1"
printf 'See the private record.\n' > "$OUT1/docs/claim.md"
cc_case "1. editing the citation in the WORKTREE unblocks"   0 "$OUT1"

OUT2="$(mktree out2)"
printf 'See `docs/missing.md`.\n' > "$OUT2/docs/claim.md"
git -C "$OUT2" add -A >/dev/null 2>&1
cc_case "blocked"                                            2 "$OUT2"
printf 'here it is\n' > "$OUT2/docs/missing.md"
git -C "$OUT2" add docs/missing.md >/dev/null 2>&1
cc_case "2. STAGING the missing file unblocks (index, not HEAD)" 0 "$OUT2"

OUT3="$(mktree out3)"
mkdir -p "$OUT3/reference"
# The citation must ANCHOR to be a claim about this tree at all — its first
# segment has to name something that exists here — or the checker correctly
# ignores it and this case would pass by never firing. `docs/` exists.
printf 'Adopter note: `docs/your-own-notes.md` lives in YOUR repository.\n' > "$OUT3/reference/tmpl.md"
git -C "$OUT3" add -A >/dev/null 2>&1
cc_case "blocked by adopter-template prose"                  2 "$OUT3"
printf 'CITATION_EXEMPT="reference/"\n' > "$OUT3/.publication-completeness"
git -C "$OUT3" add -A >/dev/null 2>&1
cc_case "3. a reviewed exemption unblocks"                   0 "$OUT3"

# ---------------------------------------------------------------------------
echo "--- (f) the exemption cannot outlive its reason"
# ---------------------------------------------------------------------------
# The property that makes an escape hatch safe to have, asserted THROUGH the
# chokepoint. If it only held in CI, an exemption could be added to get past
# this guard and then quietly license the next instance of the defect forever.
git -C "$OUT3" rm -q -f reference/tmpl.md >/dev/null 2>&1
cc_case "with the defect gone, the now-empty exemption REFUSES" 2 "$OUT3"
says    "and names itself for deletion" "suppresses nothing"

# ---------------------------------------------------------------------------
echo "--- (g) classifier precision"
# ---------------------------------------------------------------------------
# Everything here runs against the REPLAY tree in its BROKEN state, so a case
# that "passes" by never reaching the checker is indistinguishable from one that
# passes because the tree is clean — unless the tree is dirty. It is.
PREC="$(mktree prec)"
printf 'See `docs/missing.md`.\n' > "$PREC/docs/claim.md"
git -C "$PREC" add -A >/dev/null 2>&1
cc_case "sanity: this tree IS broken"                        2 "$PREC"
cc_case "an unrelated Bash command is untouched"             0 "$PREC" "ls -la $PREC"
cc_case "git status is untouched"                            0 "$PREC" "git -C $PREC status"
cc_case "git log is untouched"                               0 "$PREC" "git -C $PREC log --oneline"
cc_case "git commit --amend is a commit"                     2 "$PREC" "git -C $PREC commit --amend --no-edit"
cc_case "a -m message containing 'push' is not a push"       0 "$NODECL" \
        "git -C $NODECL commit -m 'stop pushing to main'"
cc_case "the repository comes from -C, not the cwd"          2 "$NODECL" \
        "git -C $PREC commit -m msg"

# ---------------------------------------------------------------------------
echo "--- (h) fail-closed: no quiet degradation"
# ---------------------------------------------------------------------------
BROKE="$(mktree broke)"
printf 'THIS IS NOT KEY=VALUE\n' > "$BROKE/.publication-boundary"
cc_case "a malformed .publication-boundary REFUSES"          2 "$BROKE"

# A missing predicate is a broken install, not a license to proceed. Exercised
# against a COPY of the engine so the real one is never disturbed.
FAKE_ENGINE="$SCRATCH/fake-engine"
mkdir -p "$FAKE_ENGINE/scripts/hooks" "$FAKE_ENGINE/scripts/lib"
cp "$HOOK" "$FAKE_ENGINE/scripts/hooks/"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$FAKE_ENGINE/scripts/lib/"
cp "$SCRIPT_DIR/../lib/publication-boundary.sh" "$FAKE_ENGINE/scripts/lib/"
cp "$SCRIPT_DIR/../lib/publication-boundary.py" "$FAKE_ENGINE/scripts/lib/"
# The declaration resolver publication-boundary.sh sources. Carried so that the
# ONE thing missing from this copy is the one the case is about — a sandbox
# short two files proves nothing about which of them the refusal named.
cp "$SCRIPT_DIR/../lib/declaration-path.sh" "$FAKE_ENGINE/scripts/lib/"
cp "$ENGINE_ROOT/orchestration.config" "$FAKE_ENGINE/" 2>/dev/null || true
# ...and NO scripts/publication-completeness.sh.
rc=0
out="$(payload "git -C $BASE commit -m msg" "$BASE" \
       | RICHOS_ENTITY_ROOT="$FAKE_ENGINE" RICHOS_ENGINE_ROOT="$FAKE_ENGINE" \
         bash "$FAKE_ENGINE/scripts/hooks/guard-completeness-commits.sh" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'BROKEN INSTALL'; then
    ok "a missing predicate is a BROKEN INSTALL refusal, never a quiet pass"
else
    bad "a missing predicate should refuse with BROKEN INSTALL (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "--- (i) registration: a guard the host will actually load"
# ---------------------------------------------------------------------------
# A guard on disk is not enforcement. Both surfaces are asserted because the
# engine ships two and Layer R's R4 exists because they can silently diverge.
G="guard-completeness-commits.sh"
if grep -q "$G" "$ENGINE_ROOT/hooks/hooks.json" 2>/dev/null; then
    ok "registered in the plugin hook table (hooks/hooks.json)"
else
    bad "NOT registered in hooks/hooks.json — a by-reference engine would never run it"
fi
if grep -q "$G" "$ENGINE_ROOT/.claude/settings.local.json" 2>/dev/null; then
    ok "registered in the seated hook table (.claude/settings.local.json)"
else
    bad "NOT registered in .claude/settings.local.json — a seated engine would never run it"
fi
if grep -q "$G|PreToolUse" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null; then
    ok "declared in the probe's BR_EXPECTED oracle"
else
    bad "NOT in BR_EXPECTED — BR2's reverse arm would report it as wired-but-undeclared"
fi
if grep -q 'guard-completeness-commits ' "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null; then
    ok "declared in Layer R's rooted-hook set"
else
    bad "NOT in R_ROOTED_HOOKS — its root-resolution bootstrap would go unverified"
fi

# R3 in miniature, so a divergence is caught by this suite too and not only by a
# probe somebody has to run. Same normalization the probe applies.
norm_bootstrap() {
    sed -n '/^# --- ROOT RESOLUTION ---/,/^ENGINE_ROOT="\$(resolve_engine_root/p' "$1" \
        | sed -e 's|scripts/hooks/[a-z-]*\.sh|<HOOK>|' -e 's|^    exit [0-9]*$|    exit <RC>|'
}
if [ "$(norm_bootstrap "$HOOK")" = "$(norm_bootstrap "$SCRIPT_DIR/guard-publication-commits.sh")" ]; then
    ok "root-resolution bootstrap is byte-identical to its sibling's"
else
    bad "root-resolution bootstrap DIVERGED from guard-publication-commits.sh"
fi

echo ""
echo "=== summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
