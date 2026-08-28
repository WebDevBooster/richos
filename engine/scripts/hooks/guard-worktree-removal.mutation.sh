#!/usr/bin/env bash
# Mutation harness for guard-worktree-removal.sh's rule-4 rewrite.
# Each mutant strips ONE fix back out and asserts (a) the suite fails, (b) the
# SPECIFIC named case fails, and (c) the mutation actually applied — a sed that
# matched nothing would give a green run that looked like a green run.
set -uo pipefail
ENG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ENG/scripts/hooks/guard-worktree-removal.sh"
SUITE="$ENG/scripts/hooks/guard-worktree-removal.test.sh"
BAK="$(mktemp)"
cp "$GUARD" "$BAK"
restore() { cp "$BAK" "$GUARD"; }
trap 'restore; rm -f "$BAK"' EXIT

PROVEN=0; UNPROVEN=0

check() { # <id> <desc> <expected-red-case-substrings...>
    local id="$1" desc="$2"; shift 2
    local out rc missing=""
    out="$("$SUITE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'UNPROVEN  %-4s %s  <- suite still GREEN\n' "$id" "$desc"
        UNPROVEN=$((UNPROVEN+1)); return
    fi
    for want in "$@"; do
        printf '%s' "$out" | grep -qE "^  FAIL  ${want}" || missing="$missing $want"
    done
    if [ -z "$missing" ]; then
        printf 'PROVEN    %-4s %s ... turns%s red\n' "$id" "$desc" "$(printf ' %s' "$@")"
        PROVEN=$((PROVEN+1))
    else
        printf 'UNPROVEN  %-4s %s  <- red but NOT at:%s\n' "$id" "$desc" "$missing"
        printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/            /'
        UNPROVEN=$((UNPROVEN+1))
    fi
}

applied() { # <id> <desc> ; returns 1 if the file did not change
    local id="$1" desc="$2"
    local after; after="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"
    if [ "$after" = "$BASE_MD5" ]; then
        printf 'UNPROVEN  %-4s %s  <- MUTATION DID NOT APPLY\n' "$id" "$desc"
        UNPROVEN=$((UNPROVEN+1)); return 1
    fi
    return 0
}

BASE_MD5="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"

echo "=== guard-worktree-removal mutation harness ==="

# --- M1: the WHOLE rule-4 rewrite reverted to the pre-move co-occurrence form.
# This is the code that actually shipped in the entity before the move: `\brm\b`
# anywhere, `-r` anywhere, and a path that is `.claude/worktrees/agent-*` or
# merely NAMED `*-wt`, all matched against the whole command line rather than
# one verb's own arguments.
restore
python3 - "$GUARD" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
start = s.index("RM_CLAUSE = re.compile(")
end = s.index("# Sanctioned helper invocation?")
old = '''if re.search(r"\\brm\\b", cmd):
    recursive = re.search(r"(?:^|\\s)-[A-Za-z]*[rR][A-Za-z]*\\b", cmd) or re.search(r"--recursive\\b", cmd)
    path_hit = re.search(r"\\.claude/worktrees/agent-\\S+", cmd) or re.search(r"\\S*-wt(?=$|/|\\s)", cmd)
    if recursive and path_hit:
        reasons.append("rm -r of a worktree path (pre-move co-occurrence rule)")

'''
open(p, "w").write(s[:start] + old + s[end:])
PY
if applied M1 "rule 4 reverted to the pre-move co-occurrence form"; then
    # NOT g7: that shape passes under BOTH versions (the pre-move heuristic never
    # matched this worktree's name), so it is a pin. g8b is the faithful
    # reproduction of the incident. d2/g7c are the OTHER direction — the pre-move
    # rule also UNDER-blocked a real worktree that is not named `*-wt`.
    check M1 "rule 4 reverted to the pre-move co-occurrence form" "g7d" "g8 " "g8b" "d2 " "g7c"
fi

# --- M1b: ONLY the git-rm exclusion removed (clause scoping + structural test
# both kept). Isolates what that one line buys on its own.
restore
perl -0pi -e 's/    before = cmd\[:m\.start\(\)\]\.rstrip\(\)\n    if before\.split\(\)\[-1:\] == \["git"\]:\n        continue[^\n]*\n/    pass\n/' "$GUARD"
if applied M1b "the git-rm exclusion alone is removed"; then
    check M1b "the git-rm exclusion alone is removed" "g7d"
fi

# --- M2: the structural linked-worktree test becomes the old `*-wt` string match.
restore
perl -0pi -e 's/        if is_linked_worktree "\$_tok"; then _hit="\$_tok"; break; fi/        case "\$_tok" in *-wt|*-wt\/*) _hit="\$_tok"; break ;; esac/' "$GUARD"
if applied M2 "the *-wt naming heuristic comes back"; then
    check M2 "the *-wt naming heuristic comes back" "g8 "
fi

# --- M3: the structural test is gutted to "everything is a worktree" (the
# over-blocking direction — a guard that blocks everything satisfies "does it
# fire?" while being useless).
restore
perl -0pi -e 's/is_linked_worktree\(\) \{ # <path>/is_linked_worktree() { return 0; }\nunused_is_linked_worktree() { # <path>/' "$GUARD"
if applied M3 "every rm -r target counts as a worktree"; then
    check M3 "every rm -r target counts as a worktree" "g4 "
fi

# --- M4: the structural test always says NO (the under-blocking direction).
restore
perl -0pi -e 's/is_linked_worktree\(\) \{ # <path>/is_linked_worktree() { return 1; }\nunused_is_linked_worktree() { # <path>/' "$GUARD"
if applied M4 "no rm -r target ever counts as a worktree"; then
    check M4 "no rm -r target ever counts as a worktree" "d2 "
fi

restore
echo ""
if [ "$UNPROVEN" -gt 0 ]; then
    echo "=== mutation harness: $UNPROVEN UNPROVEN, $PROVEN proven ==="
    exit 1
fi
echo "=== mutation harness: all $PROVEN mutants proven load-bearing ==="
