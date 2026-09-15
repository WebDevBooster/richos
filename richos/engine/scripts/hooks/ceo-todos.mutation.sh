#!/usr/bin/env bash
#
# ceo-todos.mutation.sh — PROVES THE DONE-CHECK PROPERTIES CAN FAIL.
#
# 97 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason, and this mechanism is unusually exposed to that: most of
# its properties are of the form "it did not quietly wave something through",
# and the CORRECT outcome for an unautomatable item is SILENCE. A test for
# silence passes for free — including when the evaluator never ran at all. That
# is the exact defect this project has now shipped twice.
#
# So: take the shipped source, remove ONE property at a time, and assert that
#   1. ceo-todos.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives a
#      green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the whole engine subtree. Nothing here
# touches the real tree.
#
# Run directly: scripts/hooks/ceo-todos.mutation.sh   (~7 minutes)
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

# EXPORTED, not set per invocation, and that is deliberate. This harness runs
# the suite it mutates -- sometimes the sandboxed copy, sometimes the one in
# the real tree -- and that suite now invokes this harness at its end. Exported
# once here, the flag reaches every child however many invocation sites this
# file grows; set per-call, one missed site is an infinite regress.
export RICHOS_MUTATION_INNER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t ceo-todos-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case-id> <rel-file> <old> <new> <why>
#
# THE ID, NOT THE SENTENCE. Every case in section (p) of the suite prints the
# same "pN." token whether it passes or fails, because ok() and bad() carry
# different prose — and the first version of this harness matched on the PASS
# sentence, so ten mutants reported "the suite went red, but not at the case I
# named" while the case named was in fact the one that had gone red. A harness
# that cannot attribute a red is a harness that proves nothing.
# --- concurrency ------------------------------------------------------------
# Each mutant builds its own sandbox under $SANDBOX/<name> and runs a whole
# suite against it, so no two mutants share a path and none of them is ordered
# against another. They ran one at a time only because a `for` loop is what this
# harness was first written as. mutation-pool.sh bounds the fan-out, keeps the
# report in declaration order, and counts a KILLED mutant as a failure rather
# than letting it vanish from the tally. RICHOS_MUTANT_JOBS overrides the degree.
# shellcheck source=../lib/stopwatch.sh
. "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

_mutant_body() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir"
    # THE WHOLE TREE, not a hand-picked subset. This suite asserts registration
    # in hooks/hooks.json, in .claude/settings.local.json, in the probe's oracle
    # and in install.sh's sidecar list; a partial copy would go red for reasons
    # that have nothing to do with the mutation, and a mutation harness whose
    # baseline is red proves nothing.
    cp -R "$ENGINE_ROOT/." "$dir/" 2>/dev/null

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    bash "$dir/scripts/hooks/ceo-todos.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        return 1
    fi
    # THE CASE MATCH IS A LITERAL WITH A BOUNDARY, NOT A BARE REGEX, and that
    # is a correction rather than a style. It used to be `grep -q "FAIL  $want"`,
    # in which an unescaped `.` matches ANY character: `g.` matched `FAIL  g1.`,
    # `p1.` matched `FAIL  p10.`, `C1.` matched `FAIL  C10.`. Demonstrated on
    # 2026-09-06 rather than suspected -- case `g.` of turn-manifest.test.sh was
    # deliberately weakened so it could not fail, and the harness still reported
    # `removing it turns g. red`, having matched a sibling case. The mutant was
    # genuinely killed every time; what was false was the claim about WHICH case
    # killed it, and that claim is the entire second clause of this harness's
    # contract. A wrong witness is exactly what root-contract's M1 turned out to
    # be. Metacharacters are escaped and the token must end at a non-alphanumeric
    # or end of line. The token is TRIMMED first, and that is not tidiness:
    # ceo-asks writes its cases as "C3. " with a trailing space, so the
    # boundary landed one character late and demanded a non-alphanumeric where
    # the label's first word begins. Five mutants went red for that reason on
    # the first run of this very change -- a red that looked exactly like a
    # finding and was not one.
    want_re="$(printf '%s' "$want" | sed 's/[[:space:]]*$//' | sed 's/[][\.*^$(){}?+|\/]/\\&/g')"
    # NO TRAILING BOUNDARY, and that is a correction to this very change made an
    # hour after it: the first version required the token to end at a
    # non-alphanumeric, which assumed every suite writes `FAIL  z1. some words`.
    # claim-roles' suite writes `FAIL  z1.landed-claim-about-a-dangling-commit`,
    # so the boundary demanded a space where a slug begins and turned ALL TWENTY
    # of its mutants into misfires -- twenty reds that looked exactly like
    # findings. The boundary was never what fixed anything: ESCAPING is. With
    # `.` taken literally, `z1.` cannot match `z1b.` and `C1.` cannot match
    # `C10.`, because the character after the prefix is a digit and not a dot.
    if ! grep -q "FAIL  ${want_re}" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at "%s" (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    return 0
}
# mutant <name> ... — a SUBMISSION, not an execution. The body above is unchanged
# except that it returns its verdict instead of incrementing a counter: it runs
# in a pool worker, which is a subshell, so an increment in there would mutate a
# copy and be discarded. The pool prints the bodies in DECLARATION order, so this
# harness's report is byte-identical to the serial one but for the durations.
mutant() {
    mut_pool_submit "$1" _mutant_body "$@"
}

echo "=== Done-check: every property, proven load-bearing by removing it ==="

# 1. THE WHOLE POINT. Without this branch an item that is already finished sits
#    in the CEO's queue asking him to do it, which is the 2026-08-31 failure
#    verbatim.
mutant satisfied-not-refused "p1." scripts/lib/ceo-todos.py \
    '        if status == "SATISFIED":' \
    '        if status == "NEVER-MATCHES-ANYTHING":' \
    "A finished item would stay in his queue exactly as item 2.6 did."

# 2. THE COLLAPSE THIS DESIGN FORBIDS. Treating an unevaluable check as "not
#    done yet" turns a typo into a check that is green forever.
mutant broken-reads-as-open "p5." scripts/lib/ceo-todos.py \
    '        elif status == "BROKEN":' \
    '        elif status == "NEVER-MATCHES-ANYTHING":' \
    "A mistyped path would be indistinguishable from work the CEO has not done."

# 3. THE POSITIVE PROBE ITSELF. The correct outcome for an unautomatable item
#    is silence; without the census, silence and never-ran are the same
#    observation.
mutant census-never-counts "p3." scripts/lib/ceo-todos.py \
    '            dc["evaluated"] += 1' \
    '            pass' \
    "A checker that never ran would look exactly like a clean record."

# 4. THE NEAR-MISS KEY. '- **Done-Check:**' reads correct to a human and matches
#    nothing; ignoring it takes an item's check off the air under a green verdict.
mutant unknown-field-ignored "p26." scripts/lib/ceo-todos.py \
    '        um = UNKNOWN_META_RE.match(line)' \
    '        um = None' \
    "One capital letter would silently disable an item's self-closing check."

# 5. THE BOUND MUST BE LOUD. A pattern that never finishes is refused, not
#    quietly recorded as "still open".
mutant timeout-reads-as-open "p30." scripts/lib/ceo-todos.py \
    '    except _DoneCheckTimeout:
        return ("BROKEN",' \
    '    except _DoneCheckTimeout:
        return ("OPEN",' \
    "A check that timed out would report the item as correctly waiting."

# 6. NO COMMAND VERB, AND IT HAS TO SAY SO. A refusal that does not explain
#    itself is one the next person walks straight back into.
mutant run-verb-unexplained "p24." scripts/lib/ceo-todos.py \
    'DONE_CHECK_VERBS = ("exists", "contains", "lacks", "manual")' \
    'DONE_CHECK_VERBS = ("exists", "contains", "lacks", "manual", "run")' \
    "The one design decision most likely to be re-litigated would be undocumented at the point of failure."

# 7. THE OWNER'S SWITCH. Declared and then ignored is worse than not offered.
mutant required-flag-ignored "p27." scripts/lib/ceo-todos.py \
    '    require_done_check = bool(job.get("done_check_required"))' \
    '    require_done_check = False' \
    "A repository that switched enforcement on would get none, silently."

# 8. THE CEO'S PAGE. The distinction between an item that will close itself and
#    one that will not is his, not ours.
mutant view-says-nothing "p31." scripts/lib/ceo-todos.py \
    '            if gloss:' \
    '            if False:' \
    "His page would look identical whether or not anything was watching an item."

# 9. THE FILESYSTEM ANSWER MUST BE THE REAL ONE. A check hard-wired to a
#    comforting constant is the purest form of this project's recurring defect.
mutant exists-always-true "p7." scripts/lib/ceo-todos.py \
    '        return (("SATISFIED", "`%s` exists (%s)" % (rel, target)) if os.path.exists(target)' \
    '        return (("SATISFIED", "`%s` exists (%s)" % (rel, target)) if True' \
    "Every exists-check would report done, and every open item would be refused."

# 10. AN ABSENT ROOT IS NOT A FAILURE. Blocking on a sibling repository nobody
#     cloned is how a guard gets removed.
mutant absent-root-blocks "p25." scripts/lib/ceo-todos.py \
    '    if prefix in (absent_roots or {}):
        return ("SKIP",' \
    '    if prefix in (absent_roots or {}):
        return ("BROKEN",' \
    "Anyone without the sibling repo cloned would be unable to commit."

# 11. THE UNCHECKED NOTE. Absence of a check is the state the 2026-08-31 failure
#     was actually in; a verdict that does not name it is a verdict that hides it.
mutant unchecked-note-dropped "p4." scripts/lib/ceo-todos.py \
    '    if dc["unchecked"] and not require_done_check:' \
    '    if False:' \
    "An entire record with no self-closing checks would read as fully covered."

# 12. THE INVERSION. `lacks` and `contains` are opposites, and swapping them
#     produces a mechanism that is confidently wrong in both directions.
mutant lacks-inverted "p10." scripts/lib/ceo-todos.py \
    '    return (("OPEN", "`%s` still matches %s" % (rel, pattern)) if hit
            else ("SATISFIED", "`%s` no longer matches %s" % (rel, pattern)))' \
    '    return (("SATISFIED", "`%s` still matches %s" % (rel, pattern)) if hit
            else ("OPEN", "`%s` no longer matches %s" % (rel, pattern)))' \
    "Every lacks-check would answer backwards."

# --- the verdict ------------------------------------------------------------
# Drained rather than accumulated: PASS/FAIL below come from the workers' exit
# codes, and a worker that left no exit code is counted as a FAILURE. The tally
# that follows is unchanged and still decides this harness's exit status.
# ADDITIVE, NOT ASSIGNMENT, and that is a correction found by measurement rather
# than by reading: mechanical-findings.mutation.sh scores one case BEFORE its
# mutants, and `PASS="$MUT_POOL_PASS"` silently discarded it. A tally that
# overwrites an earlier verdict is a green fraction over a case that ran and was
# thrown away. Harnesses that score nothing beforehand are unaffected, because
# adding to zero is assignment.
mut_pool_drain
# A harness that declared mutants and ran NONE must not exit 0 -- see
# mut_pool_require_submissions for the run where exactly that happened.
mut_pool_require_submissions "$(basename "$0")"
PASS=$(( PASS + MUT_POOL_PASS ))
FAIL=$(( FAIL + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ %s/%s mutants killed — every property is load-bearing.\033[0m\n' "$PASS" "$PASS"
    exit 0
fi
printf '\033[31m✗ %s killed, %s SURVIVED.\033[0m\n' "$PASS" "$FAIL" >&2
exit 1
