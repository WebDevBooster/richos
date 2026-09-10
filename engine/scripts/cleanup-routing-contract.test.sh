#!/usr/bin/env bash
#
# cleanup-routing-contract.test.sh — the check is proven against the two
# defects it was built for, replayed from git, not against a fixture invented
# to make it pass.
#
# ===========================================================================
# WHAT IS PROVEN HERE
# ===========================================================================
# C1  THE LIVE TREE.  The contract holds on this checkout, and the run is
#     fast enough to sit at the top of a suite an engineer actually runs.
#
# C2  MISS 1 REPLAYED FROM GIT (2afb9703).  Lock the signature on the tree
#     one commit BEFORE terminalize() gained its second routing key; confirm
#     it holds there; run the SAME lock against the commit itself. R1 names
#     terminalize() and `cleanup_policy`.
#
# C3  MISS 1, THE CONVERTER GAP (2afb9703).  Classify the new key on the
#     after-tree and R2 names hooks/terminalize-agent-worktrees.test.sh as
#     the converter that strips cleanup_owner and not cleanup_policy. That
#     file is the one 2afb9703 forgot; eleven of its cases replayed a route
#     their own fixture had stopped selecting, and it stayed that way for
#     three days.
#
# C4  MISS 2 REPLAYED FROM GIT (6472bb60).  Same shape, different defect:
#     R1 names eligible() and `cleanup_owner`, and prints
#     lib/shell-worktree-sparse.test.sh among the suites that must agree.
#
# C5  MISS 2 IS INVISIBLE TO A CONVERTER CHECK, and this is asserted rather
#     than admitted in a comment. On the 6472bb60 after-tree with every key
#     classified, R2 reports NOTHING: shell-worktree-sparse.test.sh has no
#     converter, has never had one, and was fixed by re-pointing its cases.
#     A check built only on converter pop-lists — the shape this work was
#     briefed as — catches the first defect and is blind to the second.
#     C5 is the case that would go red if R1 were ever removed as redundant.
#
# C6  MISS 1 REINTRODUCED ON TODAY'S TREE. Delete the cleanup_policy pop from
#     hooks/terminalize-agent-worktrees.test.sh in a sandbox copy of the
#     current engine and R2 names that file, that line, and that key.
#
# C7  THE DECLARED PARTIAL. A converter that strips a subset passes when it
#     declares the subset with a reason, and fails when the declaration does
#     not match what it strips — so a declaration cannot be pasted once and
#     left to rot.
#
# C8  THE EXTRACTOR CANARY. Move a routing decision into a shape the walk
#     cannot read and R3 goes red rather than R1 going green.
#
# C9  THE UNCLASSIFIED KEY. --record writes `?` for a key it has never seen
#     and the check refuses to pass on it, naming the key.
#
# C10 THE EXTRACTOR IS NOT A GREP. A routing key in a comment, a docstring
#     and a string literal produces no signature row. This is the property
#     that separates it from `grep cleanup_` and it is asserted, because a
#     regex rewrite would silently reacquire the false positives.
#
# C11 REFUSALS. No scripts/ and no signature are exit 2, never a green tick
#     over a tree that was not read.
#
# The mutation harness proving these assertions load-bearing is
# scripts/cleanup-routing-contract.mutation.sh, run at the end so the runner
# that discovers this file runs it too.
#
# Run directly: scripts/cleanup-routing-contract.test.sh
# Exit 0 = all cases pass; 1 = at least one failure; 2 = the repository
# history needed for the replays is unavailable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/cleanup-routing-contract.py"
REPO="$(git -C "$ENGINE_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

SANDBOX="$(cd "$(mktemp -d -t cleanup-routing-contract.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

[ -f "$CHECK" ] || { echo "FATAL: missing $CHECK" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

# The two commits the check exists because of. Named here and nowhere else.
MISS1=2afb97033b87365217f198bd129407566f62254d   # terminalize() gained cleanup_policy
MISS2=6472bb60e25feaec92d30124b571124293159184   # eligible() gained cleanup_owner

echo "=== cleanup-routing contract: the two defects, replayed ==="
echo ""

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# relock <root> <sig> — re-record and classify. A case that adds or removes a
# module in the sandbox MUST call this afterwards, or the next case reads an
# R1 diff left behind by its predecessor and reports a defect nobody wrote.
relock() {
    python3 "$CHECK" --root "$1" --signature "$2" --record >/dev/null 2>&1
    classify_sig "$2"
}

# classify_sig <sig> — set the class column the way the live signature is set:
# only the two cleanup markers route. Stands in for the human decision the
# check demands, so a case can get past R1 to whatever it is really testing.
classify_sig() {
    python3 - "$1" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
ROUTE = {'cleanup_owner', 'cleanup_policy'}
out = []
for raw in path.read_text().splitlines():
    if raw.startswith('#') or not raw.strip():
        out.append(raw); continue
    field = raw.split('\t')
    if field[3] != 'canary':
        field[3] = 'route' if field[2] in ROUTE else 'structural'
    out.append('\t'.join(field))
path.write_text('\n'.join(out) + '\n')
PY
}

# extract <sha> <dest> — the engine tree at a commit, read-only, no checkout
extract() {
    mkdir -p "$2"
    git -C "$REPO" archive "$1" engine 2>/dev/null | tar -x -C "$2" 2>/dev/null
    [ -d "$2/engine/scripts" ]
}

# run_check <root> <sig> -> stdout+stderr in RESULT, status in RC
RESULT=""; RC=0
run_check() {
    RESULT="$(python3 "$CHECK" --root "$1" --signature "$2" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------------------
# C1 — the live tree
# ---------------------------------------------------------------------------
LIVE_SIG="$SCRIPT_DIR/lib/cleanup-routing.signature"
START_NS="$(python3 -c 'import time; print(time.time_ns())')"
RESULT="$(python3 "$CHECK" 2>&1)"; RC=$?
ELAPSED_MS="$(python3 -c "import time; print((time.time_ns() - $START_NS)//1000000)")"
if [ "$RC" -eq 0 ] && printf '%s' "$RESULT" | grep -q 'contract holds'; then
    ok "C1  the contract holds on this checkout in ${ELAPSED_MS}ms: $RESULT"
else
    bad "C1  the live tree does not satisfy its own contract (rc=$RC)" "$RESULT"
fi

if [ -z "$REPO" ]; then
    bad "C2-C5  no git repository above $ENGINE_ROOT — the historical replays cannot run"
elif ! git -C "$REPO" cat-file -e "$MISS1^{commit}" 2>/dev/null \
     || ! git -C "$REPO" cat-file -e "$MISS2^{commit}" 2>/dev/null; then
    bad "C2-C5  $MISS1 / $MISS2 are not in this clone's history" \
        "a shallow clone cannot replay the defects; git fetch --unshallow"
else

# ---------------------------------------------------------------------------
# C2/C3 — miss 1, replayed from git
# ---------------------------------------------------------------------------
M1="$SANDBOX/miss1"
if extract "$MISS1~1" "$M1/before" && extract "$MISS1" "$M1/after"; then
    SIG1="$M1/sig"
    python3 "$CHECK" --root "$M1/before/engine" --signature "$SIG1" --record >/dev/null 2>&1
    classify_sig "$SIG1"
    run_check "$M1/before/engine" "$SIG1"
    BEFORE_RC="$RC"; BEFORE_OUT="$RESULT"
    run_check "$M1/after/engine" "$SIG1"
    if [ "$BEFORE_RC" -eq 0 ] && [ "$RC" -eq 1 ] \
       && printf '%s' "$RESULT" | grep -q "R1  THE ROUTING SIGNATURE MOVED" \
       && printf '%s' "$RESULT" | grep -q "terminalize() now tests member\['cleanup_policy'\]"; then
        ok "C2  2afb9703: the lock held one commit earlier and R1 names the change itself — $(printf '%s' "$RESULT" | grep "terminalize() now tests" | sed 's/^ *//')"
    else
        bad "C2  R1 did not name terminalize()/cleanup_policy (before rc=$BEFORE_RC, after rc=$RC)" \
            "$(printf 'before: %s\nafter: %s' "$BEFORE_OUT" "$RESULT" | head -20)"
    fi

    # C3: classify the new keys as the engineer would, then read R2
    python3 "$CHECK" --root "$M1/after/engine" --signature "$SIG1" --record >/dev/null 2>&1
    classify_sig "$SIG1"
    run_check "$M1/after/engine" "$SIG1"
    if [ "$RC" -eq 1 ] && printf '%s' "$RESULT" \
            | grep -A3 'hooks/terminalize-agent-worktrees.test.sh' | grep -q 'MISSING: *cleanup_policy'; then
        ok "C3  2afb9703: R2 names the converter the commit forgot — $(printf '%s' "$RESULT" | grep -c 'INCOMPLETE HISTORICAL FIXTURE CONVERTER') incomplete converter(s), including hooks/terminalize-agent-worktrees.test.sh missing cleanup_policy"
    else
        bad "C3  R2 did not name hooks/terminalize-agent-worktrees.test.sh (rc=$RC)" \
            "$(printf '%s' "$RESULT" | head -20)"
    fi
else
    bad "C2  git archive of $MISS1 failed"
    bad "C3  git archive of $MISS1 failed"
fi

# ---------------------------------------------------------------------------
# C4/C5 — miss 2, replayed from git
# ---------------------------------------------------------------------------
M2="$SANDBOX/miss2"
if extract "$MISS2~1" "$M2/before" && extract "$MISS2" "$M2/after"; then
    SIG2="$M2/sig"
    python3 "$CHECK" --root "$M2/before/engine" --signature "$SIG2" --record >/dev/null 2>&1
    classify_sig "$SIG2"
    run_check "$M2/before/engine" "$SIG2"
    BEFORE_RC="$RC"
    run_check "$M2/after/engine" "$SIG2"
    if [ "$BEFORE_RC" -eq 0 ] && [ "$RC" -eq 1 ] \
       && printf '%s' "$RESULT" | grep -q "eligible() now tests member\['cleanup_owner'\]" \
       && printf '%s' "$RESULT" | grep -q "shell-worktree-sparse.test.sh"; then
        ok "C4  6472bb60: R1 names the change and the suite that must agree — $(printf '%s' "$RESULT" | grep "eligible() now tests" | sed 's/^ *//')"
    else
        bad "C4  R1 did not name eligible()/cleanup_owner + the sparse suite (before rc=$BEFORE_RC, after rc=$RC)" \
            "$(printf '%s' "$RESULT" | head -20)"
    fi

    # C5: with every key classified, R2 has nothing to say about this defect
    python3 "$CHECK" --root "$M2/after/engine" --signature "$SIG2" --record >/dev/null 2>&1
    classify_sig "$SIG2"
    run_check "$M2/after/engine" "$SIG2"
    if [ "$RC" -eq 0 ] && ! printf '%s' "$RESULT" | grep -q "INCOMPLETE HISTORICAL FIXTURE CONVERTER"; then
        ok "C5  6472bb60 is INVISIBLE to a converter check: R2 reports nothing and the tree passes — the sparse suite has no converter to be incomplete. R1 is the only assertion that catches this defect."
    else
        bad "C5  R2 unexpectedly spoke about 6472bb60 (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
    fi
else
    bad "C4  git archive of $MISS2 failed"
    bad "C5  git archive of $MISS2 failed"
fi

fi  # history available

# ---------------------------------------------------------------------------
# a writable copy of TODAY's engine, for the mutation cases
# ---------------------------------------------------------------------------
COPY="$SANDBOX/today"
mkdir -p "$COPY"
cp -R "$ENGINE_ROOT/scripts" "$COPY/scripts"
COPY_SIG="$COPY/scripts/lib/cleanup-routing.signature"
run_check "$COPY" "$COPY_SIG"
COPY_BASE_RC="$RC"

# ---------------------------------------------------------------------------
# C6 — miss 1, reintroduced on today's tree
# ---------------------------------------------------------------------------
VICTIM="$COPY/scripts/hooks/terminalize-agent-worktrees.test.sh"
if [ "$COPY_BASE_RC" -ne 0 ]; then
    bad "C6  the sandbox copy of today's engine is already broken" "$RESULT"
elif [ ! -f "$VICTIM" ]; then
    bad "C6  $VICTIM is gone — the converter this check was built for no longer exists"
else
    # the exact line 7d0c838f added, removed again
    python3 - "$VICTIM" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "            member.pop('cleanup_policy',None)\n"
assert needle in text, "the converter no longer has the line 7d0c838f added"
path.write_text(text.replace(needle, "", 1))
PY
    if [ $? -ne 0 ]; then
        bad "C6  could not reintroduce the miss — the converter's shape changed"
    else
        run_check "$COPY" "$COPY_SIG"
        if [ "$RC" -eq 1 ] \
           && printf '%s' "$RESULT" | grep -q 'converter: *scripts/hooks/terminalize-agent-worktrees.test.sh' \
           && printf '%s' "$RESULT" | grep -q 'MISSING: *cleanup_policy' \
           && printf '%s' "$RESULT" | grep -q 'strips: *cleanup_owner'; then
            ok "C6  the 2afb9703 miss, reintroduced on today's tree, is named exactly — $(printf '%s' "$RESULT" | grep 'converter:' | sed 's/^ *//')"
        else
            bad "C6  the reintroduced miss was not caught or not named (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
        fi
        # C6b: the message has to be actionable, not merely red
        if printf '%s' "$RESULT" | grep -q 'routed by:.*terminalize()'; then
            ok "C6b the failure names the routing function that consumes the missing key, so the fix does not need a search"
        else
            bad "C6b the failure did not say which function routes on the missing key" "$(printf '%s' "$RESULT" | head -20)"
        fi
        git -C "$ENGINE_ROOT" show HEAD:engine/scripts/hooks/terminalize-agent-worktrees.test.sh >"$VICTIM" 2>/dev/null \
            || cp "$ENGINE_ROOT/scripts/hooks/terminalize-agent-worktrees.test.sh" "$VICTIM"
    fi
fi

# ---------------------------------------------------------------------------
# C7 — the declared partial, and a declaration that has rotted
# ---------------------------------------------------------------------------
PARTIAL="$COPY/scripts/lib/partial-fixture.test.py"
cat >"$PARTIAL" <<'PY'
"""A fixture that strips one routing key on purpose."""
def make_historical(member):
    # historical-fixture-partial: cleanup_owner — this member is built by hand
    # and never carries cleanup_policy, so this removal is complete.
    member.pop('cleanup_owner', None)
    return member
PY
run_check "$COPY" "$COPY_SIG"
if [ "$RC" -eq 0 ]; then
    ok "C7  a declared partial converter passes: the subset and a reason, in the comment attached to the removal"
else
    bad "C7  a correctly declared partial was still reported (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
fi

# now let the declaration rot: it claims a subset the converter no longer strips
python3 - "$PARTIAL" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "member.pop('cleanup_owner', None)", "member.pop('cleanup_policy', None)"))
PY
run_check "$COPY" "$COPY_SIG"
if [ "$RC" -eq 1 ] && printf '%s' "$RESULT" | grep -q 'DECLARATION DOES NOT MATCH THE CONVERTER'; then
    ok "C7b a declaration that no longer matches what the converter strips is a failure, not a permanent pass"
else
    bad "C7b a rotted declaration was accepted (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
fi
rm -f "$PARTIAL"

# ---------------------------------------------------------------------------
# C8 — the extractor canary
# ---------------------------------------------------------------------------
BLIND="$COPY/scripts/lib/blind-router.py"
cat >"$BLIND" <<'PY'
"""A routing decision written in a shape the AST walk cannot follow.

It loads a transaction and branches on a member key without ever naming the
member, which is blind-spot shape 2. update_member and members put it in the
discovered module set."""
def route(tx):
    if tx["members"][0].get("cleanup_owner") == "claude-code":
        return "platform"
    return "quarantine"

def update_member():
    pass
PY
run_check "$COPY" "$COPY_SIG"
if [ "$RC" -eq 1 ] && printf '%s' "$RESULT" | grep -q "R3  EXTRACTOR CANARY" \
   && printf '%s' "$RESULT" | grep -q 'blind-router.py.*route().*no-member-variable'; then
    ok "C8  a routing decision hidden from the walk fails R3 by name, instead of leaving R1 green over nothing"
else
    bad "C8  a new blind spot did not fail R3 (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
fi
rm -f "$BLIND"
relock "$COPY" "$COPY_SIG"

# ---------------------------------------------------------------------------
# C9 — a new routing key cannot be locked in unclassified
# ---------------------------------------------------------------------------
NEWKEY="$COPY/scripts/lib/new-routing-key.py"
cat >"$NEWKEY" <<'PY'
"""A new key on the routing path, with nobody yet having said what it means."""
def update_member():
    pass

def route(tx):
    for member in tx.get("members") or []:
        if member.get("cleanup_custodian") == "someone-else":
            return "skip"
    return "quarantine"
PY
python3 "$CHECK" --root "$COPY" --signature "$COPY_SIG" --record >/dev/null 2>&1
run_check "$COPY" "$COPY_SIG"
if [ "$RC" -eq 1 ] && printf '%s' "$RESULT" | grep -q 'UNCLASSIFIED ROUTING KEY: .*cleanup_custodian'; then
    ok "C9  --record writes \`?\` for a key it has never seen and the check refuses it by name: a routing key cannot enter the lock without a human saying what it is"
else
    bad "C9  an unclassified new key was accepted (rc=$RC)" "$(printf '%s' "$RESULT" | head -20)"
fi
rm -f "$NEWKEY"
relock "$COPY" "$COPY_SIG"

# ---------------------------------------------------------------------------
# C10 — the extractor is not a grep
# ---------------------------------------------------------------------------
PROSE="$COPY/scripts/lib/prose-only.py"
cat >"$PROSE" <<'PY'
"""cleanup_owner and cleanup_policy are discussed at length in this docstring.

A grep for cleanup_ matches every line of this file and none of them routes
anything. That difference is the reason the extractor is an AST walk."""
# cleanup_owner is also named in this comment, and in the string below.
NOTE = "member.get('cleanup_policy') == 'integrated-daily'"

def update_member():
    pass

def route(tx):
    for member in tx.get("members") or []:
        return member.get("path")   # a READ, not a routing decision
    return None
PY
relock "$COPY" "$COPY_SIG"
run_check "$COPY" "$COPY_SIG"
ROWS="$(grep -c 'prose-only.py' "$COPY_SIG" || true)"
if [ "$RC" -eq 0 ] && [ "$ROWS" -eq 0 ]; then
    ok "C10 a routing key in a docstring, a comment and a string literal produces no signature row: the extractor reads code, not text"
else
    bad "C10 prose was read as routing (rc=$RC, rows=$ROWS)" "$(grep 'prose-only' "$COPY_SIG" | head -5)"
fi
rm -f "$PROSE"
relock "$COPY" "$COPY_SIG"

# ---------------------------------------------------------------------------
# C11 — refusals
# ---------------------------------------------------------------------------
EMPTY="$SANDBOX/empty"; mkdir -p "$EMPTY"
run_check "$EMPTY" "$SANDBOX/nowhere.signature"
if [ "$RC" -eq 2 ]; then
    ok "C11 a root with no scripts/ is exit 2 — a refusal to read, never a green tick over nothing"
else
    bad "C11 an unreadable root did not exit 2 (rc=$RC)" "$RESULT"
fi
run_check "$COPY" "$SANDBOX/nowhere.signature"
if [ "$RC" -eq 2 ] && printf '%s' "$RESULT" | grep -q 'Create it with --record'; then
    ok "C11b a missing signature is exit 2 and says how to create one"
else
    bad "C11b a missing signature did not exit 2 (rc=$RC)" "$RESULT"
fi

# ---------------------------------------------------------------------------
echo ""
printf '=== cleanup-routing contract: %s passed, %s failed ===\n' "$PASS" "$FAIL"

# ---------------------------------------------------------------------------
# the mutation harness — run here so the runner that finds this suite runs it
# ---------------------------------------------------------------------------
MUTATION="$SCRIPT_DIR/cleanup-routing-contract.mutation.sh"
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$MUTATION" ]; then
    echo ""
    "$MUTATION" || FAIL=$((FAIL + 1))
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
