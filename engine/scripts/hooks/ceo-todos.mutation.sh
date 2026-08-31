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
mutant() {
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
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/ceo-todos.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at "%s" (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    PASS=$((PASS + 1))
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

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ %s/%s mutants killed — every property is load-bearing.\033[0m\n' "$PASS" "$PASS"
    exit 0
fi
printf '\033[31m✗ %s killed, %s SURVIVED.\033[0m\n' "$PASS" "$FAIL" >&2
exit 1
