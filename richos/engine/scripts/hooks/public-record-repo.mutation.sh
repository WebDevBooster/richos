#!/usr/bin/env bash
#
# public-record-repo.mutation.sh — PROVES THE PUBLIC-RECORD-REPO SUITE CAN FAIL.
#
# guard-public-record-repo.test.sh is 30 green ticks, and a suite that cannot go
# red is a suite that proves nothing. Each mutant below removes ONE property of
# the guard and requires:
#
#   1. guard-public-record-repo.test.sh FAILS, and
#   2. it fails AT THE NAMED CASE, so the red is caused by the removal and not
#      by some unrelated breakage the mutation happened to cause.
#
# TWO OF THEM ARE DEFECTS THIS GUARD ACTUALLY HAD before it shipped, named as
# such below: verb-list-widened and index-only. They are not hypotheses.
#
# NO BACKTICK APPEARS IN THIS FILE, deliberately — case Z3 of
# host-display-power.mutation.sh is the precedent, and it matters twice as much
# here, because the guard being edited had a live defect caused by exactly one
# stray backtick inside a command substitution.
#
# Run directly: scripts/hooks/public-record-repo.mutation.sh
# Exit 0 = every property is load-bearing; exit 1 = at least one is not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t public-record-repo-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# shellcheck source=../lib/stopwatch.sh
. "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

_mutant_body() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/hooks" "$dir/.claude"
    cp "$ENGINE_ROOT/scripts/hooks/guard-public-record-repo.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-public-record-repo.test.sh" \
       "$dir/scripts/hooks/"
    cp -R "$ENGINE_ROOT/scripts/lib" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/" 2>/dev/null || true
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    RICHOS_MUTATION_INNER=1 bash "$dir/scripts/hooks/guard-public-record-repo.test.sh" \
        >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        return 1
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    return 0
}

mutant() {
    mut_pool_submit "$1" _mutant_body "$@"
}

echo "=== the public-record-repo guard: every property, proven load-bearing by removing it ==="

G="scripts/hooks/guard-public-record-repo.sh"

# --- 1. THE DISPATCH SURFACE BLOCKS AT ALL --------------------------------
mutant dispatch-refuses-to-refuse "A1 " "$G" \
    '        echo "(hook: scripts/hooks/guard-public-record-repo.sh)"\n    } >&2\n    exit 2\n    ;;\n\nBash)' \
    '        echo "(hook: scripts/hooks/guard-public-record-repo.sh)"\n    } >&2\n    exit 0\n    ;;\n\nBash)' \
    "the read would be dispatched into the public repository with a full explanation of why it must not be, which is the shape of a warning rather than a guard."

# --- 2. THE COMMIT SURFACE BLOCKS AT ALL ----------------------------------
mutant commit-refuses-to-refuse "B1 " "$G" \
    '        echo "      git commit ...   # public-record-ack: <why it belongs in public history>"\n        echo ""\n        echo "  Accepted uses are appended to .claude/state/public-record-acks.log."\n        echo "(hook: scripts/hooks/guard-public-record-repo.sh)"\n    } >&2\n    exit 2' \
    '        echo "      git commit ...   # public-record-ack: <why it belongs in public history>"\n        echo ""\n        echo "  Accepted uses are appended to .claude/state/public-record-acks.log."\n        echo "(hook: scripts/hooks/guard-public-record-repo.sh)"\n    } >&2\n    exit 0' \
    "the last gate before history would print a warning and write the file into the published repository anyway. Only a commit that never happens is free; a move afterwards is a rewrite of main."

# --- 3. A PREFIXED PATH IS SOMEBODY ELSE'S --------------------------------
mutant bare-path-not-required "A4 " "$G" \
    'PATH_RE = re.compile(r"(?<![\w/.-])docs/(research|briefs|plans)/(\S+)")' \
    'PATH_RE = re.compile(r"docs/(research|briefs|plans)/(\S+)")' \
    "every CITATION of a record in the private repository would read as this dispatch's own deliverable, so the guard would refuse a brief for quoting its own prior art — and a guard that fires on citations teaches people to stop citing."

# --- 4. THE DELIVERY VERB -------------------------------------------------
# A DEFECT THIS GUARD HAD. The list carried land/lands/output/save/saves and the
# real prompt's prior-art line matched on "lands".
mutant verb-list-widened "A1d" "$G" \
    '    r"commits|committed|create|creates|produce|produces|file it|put it)\b",' \
    '    r"commits|committed|create|creates|produce|produces|file it|put it|lands)\b",' \
    "8 of 19 lands on richos main were our own tooling — one sentence away from a record path in the very prompt this guard is about — would read as a delivery instruction."

# --- 5. THE PUBLICATION DECLARATION DECIDES -------------------------------
mutant every-repo-is-public "B9 " "$G" \
    '    is_public "$REPO" || exit 0' \
    '    is_public "$REPO" || true' \
    "every repository on the machine would be treated as published, so a commit into the PRIVATE record repository — the place this guard sends everything — is itself refused. A guard that blocks its own remedy is uninstalled within the hour."

# --- 6. ADDED, NEVER MODIFIED ---------------------------------------------
mutant modified-also-refused "B5 " "$G" \
    'ADDED="$(git -C "$REPO" diff --cached --name-only --diff-filter=A 2>/dev/null || true)"' \
    'ADDED="$(git -C "$REPO" diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)"' \
    "every edit to a record already in the public tree would be refused, which protects nothing — the file is in history already — and makes the guard unusable on the repository it governs."

# --- 7. WHAT THIS COMMAND WILL STAGE --------------------------------------
# A DEFECT THE INDEX-ONLY SHAPE HAS, recorded by guard-publication-commits.sh
# before this file existed: git add X and git commit in ONE call leaves the
# index empty at PreToolUse time.
mutant index-only "B8 " "$G" \
    'PENDING="$(printf '"'"'%s'"'"' "$COMMAND" | python3 -c "$_PR_PENDING_ADDS" 2>/dev/null || true)"' \
    'PENDING=""' \
    "one ampersand defeats the whole commit surface: git add docs/research/x.md and git commit in a single tool call stages nothing until after the guard has run."

# --- 8. VERIFICATION IS OUT OF SCOPE BY RULING ----------------------------
mutant verification-in-scope "B4 " "$G" \
    "        | grep -E '(^|/)docs/(research|briefs|plans)/' 2>/dev/null || true)\"" \
    "        | grep -E '(^|/)docs/(research|briefs|plans|verification)/' 2>/dev/null || true)\"" \
    "every QA audit would be refused from the public tree where it belongs. The CEO's ruling was to remove the two ledger commits AND NOTHING ELSE, and a guard that quietly widens a ruling is the next thing he has to ask about."

# --- 9. THE HATCH IS ARGUED -----------------------------------------------
mutant ack-length-unmeasured "B3 " "$G" \
    '    if [ "$(printf '"'"'%s'"'"' "$arg" | wc -c | tr -d '"'"' '"'"')" -lt 31 ]; then' \
    '    if false; then' \
    "public-record-ack: yes would exempt anything, so the hatch becomes an off switch anybody can type at the end of a commit line, and the log that makes waiving visible fills with one-word reasons."

# --- 10. A WORKSPACE THAT DOES NOT EXIST YET ------------------------------
mutant no-convention-fallback "E1 " "$G" \
    '                *-wt)' \
    '                *-NOTHING)' \
    "spawn.sh evaluates every PreToolUse[Agent] guard BEFORE it creates the workspace, so the path never exists at the moment this runs. Without the convention the guard is silent on every real dispatch and loud on none."

mut_pool_drain
mut_pool_require_submissions "$(basename "$0")"
PASS=$(( PASS + MUT_POOL_PASS ))
FAIL=$(( FAIL + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d properties proven load-bearing\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d properties proven load-bearing, %d NOT\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
