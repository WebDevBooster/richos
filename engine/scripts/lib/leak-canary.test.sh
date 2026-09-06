#!/usr/bin/env bash
#
# leak-canary.test.sh — PROVE THE DETECTOR IN BOTH DIRECTIONS BEFORE TRUSTING IT.
#
# A canary that cannot go red is worse than no canary: it is a green tick
# printed over the defect. escalations.test.sh printed 59 passed, 0 failed on
# every run while it was leaking a fixture into a stranger's worktree. So this
# suite drives the detector onto the real defect and off it again, and pins the
# three properties that its per-suite ancestor learned the hard way:
#
#   THE WITNESS IS CONTENTS, NOT PATHS (case 2d). The first version of that
#   canary compared paths only and reported CLEAN on the second consecutive
#   leaking run: the residue was already in its baseline and the leak
#   overwrote it in place. A canary that only catches the first occurrence
#   goes quiet exactly when residue proves it is needed.
#
#   AN UNREADABLE ROOT IS A FAILURE, NEVER A QUIET PASS (cases 4a-4c). It
#   yields an empty snapshot both times and so an empty diff, which reads
#   identically to a clean sheet.
#
#   IT MUST NOT FIRE ON A LAND (case 5). This is the property that decides
#   whether it can live at the runner at all: `git status` stays clean across
#   a merge because the files and HEAD move together, whereas a canary that
#   hashed file CONTENTS would go red on every land. The claim is in the
#   runner's header, so it is measured here rather than asserted there.
#
# Everything happens inside the sandbox. This suite writes nothing to any live
# tree — which, given what it is about, would be a poor look.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t leak-canary-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

# shellcheck source=tree-witness.sh
. "$SCRIPT_DIR/tree-witness.sh"
# shellcheck source=leak-canary.sh
. "$SCRIPT_DIR/leak-canary.sh"
tw_pick_mtime "$SANDBOX"

echo "=== leak-canary: proven red on the defect and green on the fix ==="

# The fixture repository is a throwaway, but it is created on a machine whose
# git config carries real hooks — this repository's own identity guard among
# them, which refuses any commit not authored by the operator. Inheriting it
# made section 5's commits fail silently the first time this suite was run:
# 5a went red because the land never happened, and 5b passed because the files
# were on disk from the `printf` rather than from a merge. A control that fails
# for a reason unrelated to what it is testing proves nothing, so the fixture
# gets an empty hooks path and section 5 now checks for the merge COMMIT.
NO_HOOKS="$SANDBOX/empty-hooks"
mkdir -p "$NO_HOOKS"
git_q() { git -C "$1" -c core.hooksPath="$NO_HOOKS" -c user.email=t@t -c user.name=t "${@:2}"; }

# --- the fixture checkout ---------------------------------------------------
REPO="$SANDBOX/checkout"
mkdir -p "$REPO/docs"
git init -q -b main "$REPO"
printf 'seed\n' > "$REPO/docs/seed.md"
git_q "$REPO" add -A
git_q "$REPO" commit -q -m seed
if [ -z "$(git -C "$REPO" log --oneline 2>/dev/null)" ]; then
    echo "FATAL: the fixture repository has no commits — every case below would be testing an empty head" >&2
    exit 2
fi

# ===========================================================================
# 1. IT WATCHES SOMETHING, AND KNOWS HOW MUCH
# ===========================================================================
lc_reset
lc_add_root "$REPO"
if [ "$(lc_count)" -eq 1 ]; then
    ok "1a  one root resolves to one watched root"
else
    bad "1a  one root resolves to one watched root" "lc_count = $(lc_count)"
fi
lc_add_root "$REPO/docs"
if [ "$(lc_count)" -eq 1 ]; then
    ok "1b  a SUBDIRECTORY of a watched checkout resolves to the same toplevel and is not watched twice — a doubled root would report every escape twice"
else
    bad "1b  subdirectory dedupes to the toplevel" "lc_count = $(lc_count)"
fi
lc_add_root "$SANDBOX/does-not-exist"
if [ "$(lc_count)" -eq 1 ]; then
    ok "1c  a root that does not exist is ignored rather than watched as empty"
else
    bad "1c  a nonexistent root is ignored" "lc_count = $(lc_count)"
fi
lc_reset
if [ "$(lc_count)" -eq 0 ]; then
    ok "1d  lc_reset really empties the roots, so the runner's 'watching zero roots' refusal is reachable rather than decorative"
else
    bad "1d  lc_reset empties the roots" "lc_count = $(lc_count)"
fi

# ===========================================================================
# 2. RED ON THE REAL DEFECT — an untracked file appearing, then appearing AGAIN
#    at the SAME path with different contents.
# ===========================================================================
lc_reset; lc_add_root "$REPO"
B="$SANDBOX/baseline-1"
lc_baseline "$B"
if [ "$LC_HEALTHY" -eq 1 ]; then
    ok "2a  the baseline is healthy — every watched root was witnessed, so a later 'nothing escaped' will mean something"
else
    bad "2a  the baseline is healthy" "LC_HEALTHY=0 with a readable fixture checkout"
fi
if [ -z "$(lc_escaped "$B")" ]; then
    ok "2b  and nothing has escaped yet — the detector is not simply reporting everything"
else
    bad "2b  quiet before the leak" "got: $(lc_escaped "$B")"
fi

mkdir -p "$REPO/docs/verification/escalations"
printf 'id: 2026-09-05-a\nfrom: a-teammate\n' > "$REPO/docs/verification/escalations/leaked.md"
ESC="$(lc_escaped "$B")"
case "$ESC" in
    *docs/verification/escalations/leaked.md*)
        ok "2c  RED: a file written outside the sandbox is caught AND NAMED" ;;
    "")
        bad "2c  RED on the real defect" "a file appeared in the watched checkout and the canary reported nothing — it could not catch the leak it exists for" ;;
    *)
        bad "2c  the escape is named" "saw an escape but not the file: $ESC" ;;
esac

# THE PATH-ONLY BUG, AS A CASE. Re-baseline WITH the residue present — which is
# what the second run of a leaking suite sees — and leak again to the SAME
# filename with different contents.
B2="$SANDBOX/baseline-residue"
lc_baseline "$B2"
if grep -q 'leaked.md' "$B2/1.txt"; then
    ok "2d  the residue really is in the re-taken baseline, so 2e asks the hard question rather than repeating 2c"
else
    bad "2d  residue is in the new baseline" "2e would just be repeating 2c"
fi
printf 'id: 2026-09-05-b\nfrom: a-teammate\ndifferent bytes\n' > "$REPO/docs/verification/escalations/leaked.md"
ESC="$(lc_escaped "$B2")"
case "$ESC" in
    *leaked.md*)
        ok "2e  RED AGAIN: a SECOND leak to the SAME path is still caught — the content witness, not the path list, is doing the work" ;;
    "")
        bad "2e  RED on a repeat leak" "the file was overwritten in place and the canary saw nothing. This is the path-only bug: on a second consecutive leaking run it would report a clean sheet over a live leak" ;;
    *)
        bad "2e  the repeat leak is named" "got: $ESC" ;;
esac

# --- GREEN once the leak is gone, and the reset PROVEN ---------------------
rm -rf "$REPO/docs/verification"
B3="$SANDBOX/baseline-clean"
lc_baseline "$B3"
if ! grep -q 'leaked.md' "$B3/1.txt" 2>/dev/null; then
    ok "2f  the fixture really is gone, so 2g cannot pass by absorbing the evidence into its own baseline"
else
    bad "2f  the reset is real" "the leaked file is still in the baseline"
fi
printf 'work\n' > "$SANDBOX/outside-the-checkout.txt"
if [ -z "$(lc_escaped "$B3")" ]; then
    ok "2g  GREEN: a suite that writes only outside the watched checkout is silent — so 2c was a LEAK, not a detector that reports activity"
else
    bad "2g  GREEN when nothing leaked" "still reporting: $(lc_escaped "$B3")"
fi

# ===========================================================================
# 3. TRACKED CHANGES ARE CAUGHT, AND CLASSIFIED SEPARATELY FROM RESIDUE.
#    This is the mutation-harness case: a shipped file modified mid-run means
#    the suites before and after it tested different code.
# ===========================================================================
B4="$SANDBOX/baseline-tracked"
lc_baseline "$B4"
printf 'seed\nMUTATED BY A HARNESS\n' > "$REPO/docs/seed.md"
ESC="$(lc_escaped "$B4")"
case "$ESC" in
    *docs/seed.md*) ok "3a  RED: a TRACKED file modified during the run is caught and named" ;;
    *)              bad "3a  a tracked modification is caught" "got: '$ESC'" ;;
esac
ENTRY="$(printf '%s' "$ESC" | head -1 | cut -f2-)"
if lc_is_tracked_change "$ENTRY"; then
    ok "3b  and classified as a TRACKED change, so the runner can say 'every suite after this tested different code' rather than 'residue'"
else
    bad "3b  classified as a tracked change" "lc_is_tracked_change said no for: '$ENTRY'"
fi
if lc_is_tracked_change '?? docs/new-file.md  [123 4]'; then
    bad "3c  an untracked entry is NOT classified as a tracked change" "the classifier says yes for an untracked entry, so both findings would be reported with the wrong explanation"
else
    ok "3c  an untracked entry is NOT classified as a tracked change — the two findings keep their own explanations"
fi
git_q "$REPO" checkout -q -- docs/seed.md

# ===========================================================================
# 4. A ROOT IT CANNOT WITNESS IS REFUSED, NEVER SAMPLED — and the refusal is
#    reported by name, because "could not check" must not read as "clean".
# ===========================================================================
SAVED="$LC_MAX_ENTRIES"
printf 'x\n' > "$REPO/untracked-a.txt"
LC_MAX_ENTRIES=0
if lc_snapshot "$REPO" >/dev/null 2>&1; then
    bad "4a  a root above the ceiling is REFUSED" "lc_snapshot sampled it instead, so LC_HEALTHY can never reach 0 and the runner's 'canary blind' branch is unreachable code"
else
    ok "4a  a root above its witness ceiling is REFUSED, never sampled — a canary that watches some of a tree and reports on all of it is a lie"
fi
LC_HEALTHY=1
B5="$SANDBOX/baseline-blind"
lc_baseline "$B5"
if [ "$LC_HEALTHY" -eq 0 ]; then
    ok "4b  and the baseline records itself as UNHEALTHY, so the caller can refuse to report a pass it has no evidence for"
else
    bad "4b  an unwitnessable baseline is marked unhealthy" "LC_HEALTHY stayed 1"
fi
case "$(lc_escaped "$B5")" in
    *UNREADABLE*) ok "4c  and the root is named UNREADABLE rather than reported as 'nothing escaped'" ;;
    "")           bad "4c  an unwitnessable root is named" "it reported nothing at all, which reads identically to a clean sheet — the exact confusion this canary exists to remove" ;;
    *)            ok "4c  and the root is named rather than reported as 'nothing escaped'" ;;
esac
LC_MAX_ENTRIES="$SAVED"
LC_HEALTHY=1
if lc_snapshot "$REPO" >/dev/null 2>&1; then
    ok "4d  restored, the same root reads fine again — so 4a was the ceiling firing, not the snapshot being broken"
else
    bad "4d  the refusal was the ceiling" "the root is still unreadable with the ceiling restored, so 4a proved something other than what it claims"
fi
rm -f "$REPO/untracked-a.txt"

# ===========================================================================
# 5. IT MUST NOT FIRE ON A LAND. The runner's header claims this; here is the
#    measurement. A commit (and a merge) rewrites files and moves HEAD
#    together, so `git status` is unchanged across it — whereas a canary that
#    hashed file contents would go red on every land and be muted within a week.
# ===========================================================================
lc_reset; lc_add_root "$REPO"
B6="$SANDBOX/baseline-land"
lc_baseline "$B6"
git_q "$REPO" checkout -q -b a-feature
printf 'a new landed line\n' >> "$REPO/docs/seed.md"
printf 'a whole new landed file\n' > "$REPO/docs/landed.md"
git_q "$REPO" add -A
git_q "$REPO" commit -q -m "work on a branch"
git_q "$REPO" checkout -q main
git_q "$REPO" merge -q --no-ff -m "land the branch" a-feature
LANDED="$(lc_escaped "$B6")"
if [ -z "$LANDED" ]; then
    ok "5a  a full land — new file, modified file, merge commit — leaves the canary SILENT, so it can live at the runner without firing on every merge"
else
    bad "5a  a land does not fire the canary" "it went red on a merge, which would make it noise on any machine where somebody lands during a run: $LANDED"
fi
# The files being on disk is NOT evidence of a land: `printf` put them there.
# The evidence is a MERGE COMMIT in the history and a clean working tree, which
# is what makes 5a a statement about insensitivity to a land rather than about a
# land that never happened. It is checked in that form because the first run of
# this suite passed this case while every commit above it had been refused by an
# inherited pre-commit hook.
LAND_MERGES="$(git -C "$REPO" log --merges --oneline 2>/dev/null | grep -c .)"
LAND_DIRTY="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -c .)"
if [ "$LAND_MERGES" -ge 1 ] && [ "$LAND_DIRTY" -eq 0 ] && grep -q 'a new landed line' "$REPO/docs/seed.md"; then
    ok "5b  and the land really happened — a merge commit is in the history, the new content is in the working tree, and the tree is clean"
else
    bad "5b  the land really happened" "merge commits=$LAND_MERGES, dirty entries=$LAND_DIRTY. 5a would then be silence over a land that never occurred, which proves nothing"
fi

# ===========================================================================
# 6. THE NON-GIT BRANCH. A run started from a plain directory must be watched
#    as closely as one started from a checkout; an unexercised branch inside a
#    detector is a hole in the thing doing the guaranteeing.
# ===========================================================================
PLAIN="$SANDBOX/plain-directory"
mkdir -p "$PLAIN"
lc_reset; lc_add_root "$PLAIN"
B7="$SANDBOX/baseline-plain"
lc_baseline "$B7"
printf 'x\n' > "$PLAIN/escaped.md"
case "$(lc_escaped "$B7")" in
    *escaped.md*) ok "6a  the non-git branch catches an escape too, and names it" ;;
    *)            bad "6a  a plain directory is watched" "a file appeared and the canary did not name it: '$(lc_escaped "$B7")'" ;;
esac
rm -f "$PLAIN/escaped.md"
if [ -z "$(lc_escaped "$B7")" ]; then
    ok "6b  and it is silent when nothing appeared — both branches report escapes, not activity"
else
    bad "6b  the non-git branch is quiet when clean" "got: $(lc_escaped "$B7")"
fi

# ===========================================================================
# 7. THE EXCLUDE ARGUMENT, for the pathological case of a sandbox living
#    inside a watched tree. Without it the canary reports its own workspace.
# ===========================================================================
lc_reset; lc_add_root "$REPO"
B8="$SANDBOX/baseline-exclude"
lc_baseline "$B8"
mkdir -p "$REPO/my-own-scratch"
printf 'x\n' > "$REPO/my-own-scratch/tempfile"
printf 'x\n' > "$REPO/a-real-leak.md"
EXC="$(lc_escaped "$B8" "my-own-scratch")"
case "$EXC" in
    *my-own-scratch*) bad "7a  the excluded path is dropped" "it still reported the caller's own scratch: $EXC" ;;
    *a-real-leak.md*) ok "7a  the excluded path is dropped AND the real leak beside it is still reported — the exclusion is a path filter, not an off switch" ;;
    *)                bad "7a  the exclusion keeps reporting real leaks" "got: '$EXC'" ;;
esac
rm -rf "$REPO/my-own-scratch" "$REPO/a-real-leak.md"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
