#!/usr/bin/env bash
#
# git-jurisdiction.test.sh — regression tests for scripts/lib/git-jurisdiction.sh
# and for the five guards that now resolve a repository through it.
#
# ===========================================================================
# THE DEFECT THIS SUITE PINS
# ===========================================================================
# A worktree-isolated agent's session cwd is the checkout the harness gave it.
# Its work is somewhere else. So it types
#
#     cd /Users/alex/ab/richos-wt/<branch> && git commit -m "..."
#
# and until 2026-09-01 four of the five Bash commit/push guards resolved the
# SESSION's repository from that command, found no adoption declaration there,
# and stood down. Measured that day: the identical commit was REFUSED through
# the `-C` form and ACCEPTED through the `cd` form minutes apart.
#
# ===========================================================================
# HOW CASE (c) MEASURES A GUARD'S ANSWER — no fixture per guard
# ===========================================================================
# Every one of these guards calls richos_assert_jurisdiction with the repository
# it resolved, and that call PRINTS it ("its repo: …") whenever it differs from
# the seat. So the suite seats the session in a THIRD repository and reads each
# guard's own announcement. That is the guard's actual resolution, not a
# re-implementation of it — a suite that re-derived the answer would pass over a
# guard that had stopped asking.
#
# Covers:
#   (a) THE RESOLUTION — every shape a person types, one expected anchor each.
#   (b) THE PARITY INVARIANT — for a command with no `cd`, the resolver returns
#       what the five hand-copied blocks returned, byte for byte. This is the
#       whole argument that the change moves WHERE a guard looks and not WHAT it
#       decides, so it is a case rather than a comment.
#   (c) THE BYPASS, PER GUARD — eight command shapes against all five guards,
#       each asserted to resolve the TARGET repository. Every one of these
#       fails against the engine as it stood on 2026-09-01.
#   (d) WHAT IT CANNOT KNOW — an unexpandable `cd "$D"` is REPORTED as
#       unresolved and falls back to the payload cwd, which is today's answer.
#       A resolver that guessed here would judge a repository the command was
#       never going to touch.
#   (e) NO SIXTH COPY — the set of hooks that resolve a git command's repository
#       is stated here, and every one of them must source the shared library.
#       A future guard with its own copy fails this case.
#   (f) FAIL-CLOSED — each of the five refuses to START without the library,
#       with the shipped BROKEN INSTALL banner. A guard that carried on would be
#       the bypass again, silently.
#
# Run directly: scripts/lib/git-jurisdiction.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$SCRIPT_DIR/git-jurisdiction.sh"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t gjtest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 1; }
# shellcheck source=./git-jurisdiction.sh
. "$LIB"

payload() { # <command> <cwd>
    GJ_CMD="$1" GJ_C="$2" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["GJ_C"],
                  "session_id": "gjtest00-0000-4000-8000-000000000000",
                  "tool_input": {"command": os.environ["GJ_CMD"]}}))
'
}

anchor_of() { # <command> <cwd> [verbs] -> prints anchor
    richos_git_anchor "$(payload "$1" "$2")" "${3:-commit push}" | cut -f2
}
how_of() {    # <command> <cwd> [verbs] -> prints how
    richos_git_anchor "$(payload "$1" "$2")" "${3:-commit push}" | cut -f1
}

echo "=== git-jurisdiction.test.sh ==="

# ---------------------------------------------------------------------------
echo "--- (a) the resolution"
# ---------------------------------------------------------------------------
SESS="/tmp/gj-session"
res() { # <name> <cmd> <expected-anchor>
    local got
    got="$(anchor_of "$2" "$SESS")"
    if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (expected $3, got $got)"; fi
}

res "a bare commit anchors on the session cwd"        'git commit -m x'                      "$SESS"
res "-C names the repository"                         'git -C /a/b commit -m x'              "/a/b"
res "THE BYPASS: cd && commit anchors on the cd"      'cd /a/b && git commit -m x'           "/a/b"
res "cd ; commit, the other separator"                'cd /a/b; git commit -m x'             "/a/b"
res "cd then stage then commit, one Bash call"        'cd /a/b && git add -A && git commit -m x' "/a/b"
res "two cds accumulate"                              'cd /a && cd b && git commit'          "/a/b"
res "a relative cd resolves against the payload cwd"  'cd sub && git commit'                 "$SESS/sub"
res "-C wins over the cd it sits inside"              'cd /a && git -C /b commit'            "/b"
res "-C is relative to the cd in effect"              'cd /a && git -C sub commit'           "/a/sub"
res "a subshell cd does not leak past its paren"      '(cd /a && echo hi) ; git commit'      "$SESS"
res "a commit INSIDE the subshell sees the cd"        '(cd /a && git commit)'                "/a"
res "the verb is what anchors: add is not commit"     'cd /a && git log && git commit'       "/a"
# The verb filter's teeth. An earlier `git -C /other <anything>` in the same
# line must not become the anchor of the commit that follows it — that is the
# guard inspecting a tree the command is not committing to, which is the same
# family of wrong answer as the cd bypass itself.
res "an earlier git on ANOTHER repo does not anchor the commit" \
    'git -C /other log --oneline && cd /a && git commit -m x'                                "/a"
res "a push anchors the same way"                     'cd /a && git push origin main'        "/a"
res "cd - goes back where it came from"               'cd /a && cd - && git commit'          "$SESS"
res "--work-tree names the repository too"            'cd /a && git --work-tree=/c commit'   "/c"
res "--git-dir names it through its parent"           'cd /a && git --git-dir=/b/.git commit' "/b"
res "a message containing && and ; is not a separator" \
    'cd /a/b && git commit -m "one; two && three"'    "/a/b"
res "~ expands"                                       'cd ~ && git commit'                   "$HOME"

# THE ONE THAT IS NOT COSMETIC. A commit MESSAGE naming another directory must
# not move the anchor; the tokenizer, not a regex over the raw line, is what
# makes that true.
res "a quoted path in the message is not a cd"        'cd /a && git commit -m "cd /elsewhere and retry"' "/a"

# ---------------------------------------------------------------------------
echo "--- (b) THE PARITY INVARIANT: no cd, no change"
# ---------------------------------------------------------------------------
# The legacy resolution, transcribed from the block the five guards carried. If
# this drifts from the library's own copy the case below stops meaning anything,
# so it is written out here rather than imported.
legacy_anchor() { # <cmd> <cwd>
    LG_CMD="$1" LG_C="$2" python3 -c '
import os, re
cmd = os.environ["LG_CMD"]; cwd = os.environ["LG_C"]
m = re.search(r"\bgit\b\s+(?:[^\n;|&]*?\s)?-C\s+(\"[^\"]+\"|\x27[^\x27]+\x27|\S+)", cmd)
hint = m.group(1).strip("\"\x27") if m else ""
a = hint or cwd
print(a if a.startswith("/") else os.path.normpath(os.path.join(cwd, a)))
'
}

PARITY_OK=1
PARITY_N=0
while IFS= read -r c; do
    [ -n "$c" ] || continue
    PARITY_N=$((PARITY_N + 1))
    want="$(legacy_anchor "$c" "$SESS")"
    got="$(anchor_of "$c" "$SESS")"
    if [ "$want" != "$got" ]; then
        PARITY_OK=0
        printf '        DIVERGED on %s: legacy=%s new=%s\n' "$c" "$want" "$got" >&2
    fi
done <<'CORPUS'
git commit -m x
git commit -am "a message"
git -C /a/b commit -m x
git -C "/a b" commit -m x
git commit -m "stop pushing to main"
git add -A && git commit -m x
git push origin main
git -C /a/b push origin main
git commit --amend --no-edit
git -c user.name=x commit -m y
git status --short
git log --oneline -3
git commit -m "one; two && three"
git merge --no-ff branch
git commit -F - <<'EOF'
CORPUS

# THE OTHER HALF OF THE INVARIANT, and the one that must not be quiet: where the
# resolver DOES differ from the legacy block, it differs in exactly one way. A
# command with several git invocations anchors on the one being judged rather
# than on the first -C in the line. guard-publication-commits.sh already made
# this correction locally and its own suite pins it as a control case; the four
# other guards were the ones out of step.
MULTI='git -C /other add -A && git -C /here commit -m x'
if [ "$(anchor_of "$MULTI" "$SESS")" = "/here" ] \
   && [ "$(legacy_anchor "$MULTI" "$SESS")" = "/other" ]; then
    ok "several git calls: the anchor is the COMMIT's repository, not the first -C"
else
    bad "multi-invocation anchor is $(anchor_of "$MULTI" "$SESS"), wanted /here"
fi
if [ "$PARITY_OK" = 1 ] && [ "$PARITY_N" -ge 14 ]; then
    ok "$PARITY_N cd-free shapes: the resolver returns the LEGACY answer, exactly"
else
    bad "parity broken over $PARITY_N cd-free shapes — this change is no longer only about where a guard looks"
fi

# ---------------------------------------------------------------------------
echo "--- (c) THE BYPASS, measured off each guard's own announcement"
# ---------------------------------------------------------------------------
mkrepo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main 2>/dev/null || { git init -q "$1"; git -C "$1" checkout -q -b main 2>/dev/null; }
    printf 'x\n' > "$1/f.txt"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -qm seed >/dev/null 2>&1
}
SEAT="$SCRATCH/seat";     mkrepo "$SEAT"; printf '# adopted\n' > "$SEAT/orchestration.config"
CWDREPO="$SCRATCH/session"; mkrepo "$CWDREPO"
TARGET="$SCRATCH/target";   mkrepo "$TARGET"
mkdir -p "$TARGET/sub"
TP="$(cd "$TARGET" && pwd -P)"

# Each guard, and WHY it is on this list. The list is hand-maintained on
# purpose: a scan that stopped matching would produce a shorter list and a
# greener suite, which is the failure mode this engine keeps finding in itself.
GUARDS=(
    guard-completeness-commits.sh   # publication completeness, at commit and push
    guard-publication-commits.sh    # private bytes reaching a public commit
    guard-ceo-todos-commits.sh      # the CEO-TODOs record, at every commit
    guard-row-currency-commits.sh   # warrant staleness, at commit and merge
    guard-inflight-notify.sh        # a push that leaves a teammate behind
)

guard_repo() { # <hook> <command> -> the repository that guard resolved
    local hook="$1" cmd="$2" tmp out
    tmp="$(mktemp -d -t gjguard.XXXXXX)"
    out="$(payload "$cmd" "$CWDREPO" | TMPDIR="$tmp" RICHOS_ENTITY_ROOT="$SEAT" \
        bash "$ENGINE_ROOT/scripts/hooks/$hook" 2>&1 >/dev/null)"
    rm -rf "$tmp"
    printf '%s' "$out" | sed -n 's/^ *its repo *: *//p' | head -1
}

for hook in "${GUARDS[@]}"; do
    case "$hook" in
        guard-inflight-notify.sh) VERB="push origin main" ;;
        *)                        VERB="commit -m msg" ;;
    esac
    BAD=""
    for form in "cd $TARGET && git $VERB" \
                "cd $TARGET; git $VERB" \
                "cd $TARGET && git add -A && git $VERB" \
                "cd $TARGET/sub && git $VERB" \
                "cd $TARGET && cd sub && git $VERB" \
                "(cd $TARGET && git $VERB)" \
                "cd /tmp && cd $TARGET && git $VERB" \
                "cd $TARGET && git --work-tree=$TARGET $VERB"; do
        got="$(guard_repo "$hook" "$form")"
        case "$got" in
            "$TP"|"$TP"/*) ;;
            *) BAD="$BAD
        $form  ->  ${got:-<nothing announced>}" ;;
        esac
    done
    if [ -z "$BAD" ]; then
        ok "$hook resolves the repository the command CDs into (8 shapes)"
    else
        bad "$hook resolved the wrong repository:$BAD"
    fi
done

# The positive control for the case above. It reports a problem by finding an
# announcement that names the wrong repository — so it must first be shown that
# an announcement appears at all, or "no announcement" would read as success.
CTRL="$(guard_repo guard-completeness-commits.sh "git -C $TARGET commit -m msg")"
case "$CTRL" in
    "$TP") ok "POSITIVE CONTROL: the -C form announces a repository at all" ;;
    *)     bad "POSITIVE CONTROL failed — no announcement to read, so case (c) proves nothing (got ${CTRL:-<nothing>})" ;;
esac

# ---------------------------------------------------------------------------
echo "--- (d) what it cannot know is REPORTED, never guessed"
# ---------------------------------------------------------------------------
UH="$(how_of 'cd "$D" && git commit' "$SESS")"
UA="$(anchor_of 'cd "$D" && git commit' "$SESS")"
if [ "$UH" = "unresolved-cd" ] && [ "$UA" = "$SESS" ]; then
    ok "an unexpandable cd is named unresolved-cd and falls back to the payload cwd"
else
    bad "unexpandable cd: how=$UH anchor=$UA (wanted unresolved-cd / $SESS)"
fi

PH="$(how_of 'cd /a && popd && git commit' "$SESS")"
if [ "$PH" = "unresolved-cd" ]; then
    ok "popd is not tracked, and says so rather than answering /a"
else
    bad "popd: how=$PH (wanted unresolved-cd)"
fi

BH="$(how_of 'cd /a && git commit -m "unbalanced '"'"' quote' "$SESS")"
if [ "$BH" = "unparsed" ]; then
    ok "a command that cannot be tokenized falls back to the legacy answer, named"
else
    bad "unbalanced quote: how=$BH (wanted unparsed)"
fi

if [ "$(how_of 'git commit -m x' "$SESS")" = "cwd" ] \
   && [ "$(how_of 'git -C /a commit' "$SESS")" = "-C" ] \
   && [ "$(how_of 'cd /a && git commit' "$SESS")" = "cd" ]; then
    ok "every answer says HOW it was reached — cwd / -C / cd"
else
    bad "the how field does not distinguish the three resolutions"
fi

# ---------------------------------------------------------------------------
echo "--- (e) NO SIXTH COPY"
# ---------------------------------------------------------------------------
MISSING=""
for hook in "${GUARDS[@]}"; do
    grep -q 'lib/git-jurisdiction.sh' "$ENGINE_ROOT/scripts/hooks/$hook" \
        || MISSING="$MISSING $hook"
done
if [ -z "$MISSING" ]; then
    ok "all ${#GUARDS[@]} commit/push guards source the shared resolver"
else
    bad "these guards do not source scripts/lib/git-jurisdiction.sh:$MISSING"
fi

# The other half: nobody keeps a private copy of the -C regex. It lives in the
# library (which needs it, to honor the parity invariant) and nowhere else.
STRAY=""
for f in "$ENGINE_ROOT"/scripts/hooks/guard-*.sh; do
    grep -q -- '-C\\s+(\\"' "$f" && STRAY="$STRAY $(basename "$f")"
done
if [ -z "$STRAY" ]; then
    ok "no guard carries its own copy of the repository regex"
else
    bad "a private copy of the resolution has come back in:$STRAY"
fi

# ---------------------------------------------------------------------------
echo "--- (f) FAIL-CLOSED: no library, no guard"
# ---------------------------------------------------------------------------
SB="$SCRATCH/sandbox"
mkdir -p "$SB/scripts/hooks" "$SB/scripts/lib"
cp "$ENGINE_ROOT"/scripts/hooks/*.sh "$SB/scripts/hooks/" 2>/dev/null
cp "$ENGINE_ROOT"/scripts/hooks/*.py "$SB/scripts/hooks/" 2>/dev/null
cp "$ENGINE_ROOT"/scripts/lib/* "$SB/scripts/lib/" 2>/dev/null
rm -f "$SB/scripts/lib/git-jurisdiction.sh"
BROKEN=""
for hook in "${GUARDS[@]}"; do
    rc=0
    OUT="$(payload "git -C $TARGET commit -m x" "$TARGET" | bash "$SB/scripts/hooks/$hook" 2>&1 >/dev/null)" || rc=$?
    printf '%s' "$OUT" | grep -q 'BROKEN INSTALL' && [ "$rc" = 2 ] || BROKEN="$BROKEN $hook(rc=$rc)"
done
if [ -z "$BROKEN" ]; then
    ok "every guard REFUSES to start without the resolver, with the shipped banner"
else
    bad "these carried on without the resolver:$BROKEN"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
