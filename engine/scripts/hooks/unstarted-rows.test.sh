#!/usr/bin/env bash
#
# unstarted-rows.test.sh — the unstarted-row sweep, end to end, in a sandbox.
#
# Builds a real git repository with a real record, a real queue and a real
# linked worktree, and drives the SHIPPED hook with synthetic Stop payloads.
# Nothing is stubbed except the entity root (RICHOS_ENTITY_ROOT), because that
# is the one thing a test must not share with the live session.
#
# THE FOUR TRANSCRIPTS THE BRIEF ASKS FOR, and where each is asserted:
#   1. an unblocked row with nothing running for it  -> NOTICE, NAMING IT
#        cases 1a-1d
#   2. the same row with a live worktree for it      -> SILENT
#        cases 2a-2e
#   3. a row declared as waiting on the CEO          -> SILENT, and the silence
#      is PROVEN to be a result rather than a hook that never ran
#        cases 3a-3e
#   4. an unparseable record                         -> LOUD, never a clean
#      sweep over whatever survived
#        cases 4a-4p
#
# Plus the two properties that keep the notice worth reading:
#   5. state-change de-duplication  (a stable set is announced once)
#   6. a claim token stands alone in BOTH directions, each with a control
#   8. the strike-through closes a row; the cell may name who owns the residual
#
# NOTHING HERE IS EVER TORN DOWN, and every sandbox branch is named under
# `agent/`. The un-claimed state is reached by RENAMING the branch: this
# machine guards destructive workspace operations for good reasons, and a test
# that has to be waved through a guard is a test that stops being run.
#
# Run directly:  scripts/hooks/unstarted-rows.test.sh [--verbose]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t unstarted-rows.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib" "$REPO/wiki"

# --- the sandbox engine copy ----------------------------------------------
# The hook resolves its libraries relative to its own location, so the sandbox
# hosts both. A copy, not a symlink: a mutation test rewrites one.
cp "$SRC_DIR/notice-unstarted-rows.sh" "$REPO/scripts/hooks/"
chmod +x "$REPO/scripts/hooks/notice-unstarted-rows.sh"
for l in unstarted-rows.sh unstarted-rows.py row-currency.sh row-currency.py \
         ceo-todos.sh ceo-todos.py declaration-path.sh \
         resolve-roots.sh resolve-main-checkout.sh \
         seat-jurisdiction.sh stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$REPO/scripts/lib/$l" 2>/dev/null || true
done
cp "$ENGINE_ROOT/scripts/unstarted-rows-lint.sh" "$REPO/scripts/"
chmod +x "$REPO/scripts/unstarted-rows-lint.sh"

HOOK="$REPO/scripts/hooks/notice-unstarted-rows.sh"
LINT="$REPO/scripts/unstarted-rows-lint.sh"
RECEIPT="$REPO/.claude/state/unstarted-rows/last-sweep.txt"

printf 'PROTECTED_PATHS="wiki"\n' > "$REPO/orchestration.config"

cat > "$REPO/.ceo-todos" <<'EOF'
TODO_RECORD="wiki/open-items.md"
TODO_VIEW="CEO-TODOs.md"
ROOT_README="README.md"
CEO_SECTIONS="1"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="self=."
EOF

cat > "$REPO/.row-currency" <<'EOF'
ROW_SECTIONS="3"
ROW_STATUS_TOKENS="OPEN BUILT BOUNDED BLOCKED-ON-RICH CLOSED"
ROW_TERMINAL_TOKENS="CLOSED"
EOF

echo "# sandbox" > "$REPO/README.md"
echo "# view" > "$REPO/CEO-TODOs.md"
echo "artifact" > "$REPO/a.txt"

# --- the two records -------------------------------------------------------
write_queue() { # <blocked-cell-for-row-12>
    cat > "$REPO/RICH-TODOs.md" <<EOF
# The lead's ordered backlog

## Next

| # | Item | Blocked by |
|---|---|---|
| ~~0~~ | ~~**A landed thing**~~ — LANDED | done |
| ~~9~~ | ~~**A finished row whose residual belongs to the CEO**~~ | **CEO — a product decision** |
| 1 | **A short-id row** — its id is a prefix of row 11's | — |
| 11 | **A row nobody has started** — buildable, needs nobody | — |
| 12 | **A second unstarted row** — also buildable | ${1:-—} |
| 13 | **A row the CEO owns** — his billing account | **CEO — his account** |

## Standing, not schedulable

- prose that is not a table
EOF
}

write_record() { # <extra-prose-for-3.1>
    cat > "$REPO/wiki/open-items.md" <<EOF
# Open items

## 1. Waiting on the CEO — a decision

### 1.1 READY-FOR-CEO — a decision

- **Open:** \`README.md\`

## 3. Buildable now — nobody blocked

| # | Item | State — the warrant this row is checked against |
|---|---|---|
| 3.1 | **An open section row.** ${1:-}Buildable now. | **State:** \`OPEN\` — \`self/a.txt\`@\`000000000000\` |
| 3.2 | **A finished section row.** | **State:** \`CLOSED\` — \`self/a.txt\` |

## Deliberately NOT open

- prose
EOF
}

write_queue
write_record

git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
git -C "$REPO" config user.name "$(git config user.name 2>/dev/null || echo tester)"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m "base" >/dev/null 2>&1

export RICHOS_ENTITY_ROOT="$REPO"

stop_payload() {
    python3 -c '
import json
print(json.dumps({"hook_event_name": "Stop",
                  "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "cwd": "", "stop_hook_active": False,
                  "last_assistant_message": "Done.",
                  "background_tasks": [], "session_crons": []}))'
}

forget() { rm -rf "$REPO/.claude/state/stop-hook-notices"; }

run_hook() { # -> HRC / HOUT ; from a forgotten ledger unless --remember
    [ "${1:-}" = "--remember" ] || forget
    HOUT="$(stop_payload | bash "$HOOK" 2>&1)"
    HRC=$?
}

spoke() { printf '%s' "$HOUT" | grep -q 'systemMessage'; }
names() { printf '%s' "$HOUT" | grep -q "$1"; }

echo "=== unstarted rows: the notice, the silences, and the loud failures ==="

# ===========================================================================
# 1. AN UNBLOCKED ROW WITH NOTHING RUNNING FOR IT -> NOTICE, NAMING IT
# ===========================================================================
run_hook
if spoke; then ok "1a  an unblocked row with nothing running ends the turn with a notice"
else bad "1a  an unblocked row with nothing running ends the turn with a notice" "the hook said nothing: $HOUT"; fi
say "1a" "$HOUT"

if names '1, 11, 12, 3.1'; then
    ok "1b  the notice NAMES the rows rather than counting them"
else bad "1b  the notice NAMES the rows rather than counting them" "$HOUT"; fi

if names 'NOTHING RUNNING FOR IT'; then
    ok "1c  the notice says what is wrong: nothing is running for them"
else bad "1c  the notice says what is wrong: nothing is running for them" "$HOUT"; fi

if [ "$HRC" -eq 0 ]; then ok "1d  it NOTICES, it does not block — exit 0"
else bad "1d  it NOTICES, it does not block — exit 0" "rc=$HRC"; fi

# ===========================================================================
# 2. THE SAME ROW WITH A LIVE WORKTREE FOR IT -> SILENT
# ===========================================================================
# The directory name is deliberately NEUTRAL, so this case tests the branch
# name and nothing else.
WT="$SANDBOX/wt/norm-sonnet-a1"
mkdir -p "$SANDBOX/wt"
git -C "$REPO" worktree add -q -b agent/row-11 "$WT" >/dev/null 2>&1
run_hook
if spoke && names '1, 12, 3.1' && ! names '11'; then
    ok "2a  a live worktree whose BRANCH names row 11 takes it off the list"
else bad "2a  a live worktree whose BRANCH names row 11 takes it off the list" "$HOUT"; fi
say "2a" "$HOUT"

bash "$LINT" "$REPO" > "$SANDBOX/lint2.txt" 2>&1
if grep -qE '^  CLAIMED    11 ' "$SANDBOX/lint2.txt"; then
    ok "2b  the sweep records WHY it is quiet about row 11: a claim, from a named worktree"
else bad "2b  the sweep records WHY it is quiet about row 11" "$(cat "$SANDBOX/lint2.txt")"; fi

# ===========================================================================
# 6. A CLAIM TOKEN MUST STAND ALONE — IN BOTH DIRECTIONS
# ===========================================================================
# `row-1` is a prefix of `row-11`, and the failure is available going either
# way. Each case carries its OWN positive control — the branch that must not
# claim one row MUST claim the other, in the same run — because a suite that
# only asserts "not claimed" passes perfectly over claim matching that is
# broken end to end. That is not hypothetical: it happened to this suite.
bash "$LINT" "$REPO" > "$SANDBOX/lint6b.txt" 2>&1
if grep -qE '^  UNSTARTED  1  ' "$SANDBOX/lint6b.txt" && grep -qE '^  CLAIMED    11 ' "$SANDBOX/lint6b.txt"; then
    ok "6b  a worktree named row-11 claims 11 and does NOT claim row 1"
else bad "6b  row-11 must claim 11 and not 1" "$(cat "$SANDBOX/lint6b.txt")"; fi

git -C "$WT" branch -m agent/row-1 >/dev/null 2>&1
bash "$LINT" "$REPO" > "$SANDBOX/lint6.txt" 2>&1
if grep -qE '^  UNSTARTED  11 ' "$SANDBOX/lint6.txt" && grep -qE '^  CLAIMED    1  ' "$SANDBOX/lint6.txt"; then
    ok "6a  a worktree named row-1 claims 1 and does NOT claim row 11"
else bad "6a  row-1 must claim 1 and not 11" "$(cat "$SANDBOX/lint6.txt")"; fi

# ===========================================================================
# 2 (continued). THE EXPLICIT CLAIM FILE — the escape hatch for a worktree
# whose branch was named before anybody knew which row it was for.
# ===========================================================================
mkdir -p "$WT/.claude"
printf '# one row id per line\n1\n11\n12\n3.1\n' > "$WT/.claude/row-claims.txt"
run_hook
if ! spoke; then ok "2c  every row claimed by the claim file -> the turn ends SILENTLY"
else bad "2c  every row claimed -> the turn ends SILENTLY" "$HOUT"; fi

if [ -s "$RECEIPT" ] && grep -q '^unstarted:     0' "$RECEIPT" && grep -q '^claimed:       4' "$RECEIPT"; then
    ok "2d  POSITIVE PROBE: the receipt proves the silence came from a sweep of 4 claims"
else bad "2d  POSITIVE PROBE: the receipt proves the silence came from a sweep" "$(cat "$RECEIPT" 2>/dev/null || echo '(no receipt)')"; fi

bash "$LINT" "$REPO" > "$SANDBOX/lint2c.txt" 2>&1
if grep -q 'row-claims.txt' "$SANDBOX/lint2c.txt"; then
    ok "2e  the sweep names the claim FILE as the source, not merely 'claimed'"
else bad "2e  the sweep names the claim file as the source" "$(cat "$SANDBOX/lint2c.txt")"; fi

# back to nothing claimed, without tearing the workspace down
rm -f "$WT/.claude/row-claims.txt"
git -C "$WT" branch -m agent/neutral >/dev/null 2>&1

# ===========================================================================
# 3. A ROW DECLARED AS WAITING ON THE CEO -> SILENT, PROVABLY
# ===========================================================================
write_queue '**CEO — his Railway credentials**'
write_record '**Blocked:** the CEO — he has to decide. '
# rows 1 and 11 still name nobody, so they are claimed here to isolate the
# declaration as the only reason for the silence
mkdir -p "$WT/.claude"
printf '1\n11\n' > "$WT/.claude/row-claims.txt"
run_hook
if ! spoke; then ok "3a  every remaining row names a blocker -> the turn ends SILENTLY"
else bad "3a  every remaining row names a blocker -> the turn ends SILENTLY" "$HOUT"; fi
say "3a" "$HOUT"

if [ -s "$RECEIPT" ]; then ok "3b  POSITIVE PROBE: the sweep wrote a receipt, so it RAN"
else bad "3b  POSITIVE PROBE: the sweep wrote a receipt, so it RAN" "no receipt at $RECEIPT"; fi

if grep -q '^rows-swept:    8' "$RECEIPT" 2>/dev/null; then
    ok "3c  POSITIVE PROBE: it swept 8 rows — the silence is not a sweep of nothing"
else bad "3c  POSITIVE PROBE: it swept 8 rows" "$(grep '^rows-swept' "$RECEIPT" 2>/dev/null)"; fi

if grep -q '^blocker-named: 3' "$RECEIPT" 2>/dev/null && grep -q '^unstarted:     0' "$RECEIPT" 2>/dev/null; then
    ok "3d  POSITIVE PROBE: 3 rows named a blocker and 0 were unstarted"
else bad "3d  POSITIVE PROBE: 3 rows named a blocker, 0 unstarted" "$(cat "$RECEIPT")"; fi

bash "$LINT" "$REPO" > "$SANDBOX/lint3.txt" 2>&1
if grep -qE '^  DECLARED   3\.1 .*CEO' "$SANDBOX/lint3.txt"; then
    ok "3e  the section's in-place \`**Blocked:**\` declaration is what silenced 3.1"
else bad "3e  the section's in-place declaration silenced 3.1" "$(cat "$SANDBOX/lint3.txt")"; fi

# A DECLARATION THAT NAMES NOBODY IS NOT A DECLARATION. Found live 2026-09-02:
# rows 3.19 and 3.20 of the real record each read `**Blocked:** nothing —
# buildable now, nobody blocked.` and were SILENT, because the construct's
# presence was taken as a declaration without reading what it declared.
write_record '**Blocked:** nothing — buildable now, nobody blocked. '
run_hook
if spoke && names '3.1'; then
    ok "3f  \`**Blocked:** nothing — …\` names NOBODY, so 3.1 is unstarted and NAMED"
else bad "3f  a blocker of 'nothing' must not silence the row" "$HOUT"; fi
bash "$LINT" "$REPO" > "$SANDBOX/lint3f.txt" 2>&1
if grep -qE '^  UNSTARTED  3\.1 ' "$SANDBOX/lint3f.txt"; then
    ok "3g  the lint classifies it UNSTARTED, not DECLARED"
else bad "3g  UNSTARTED not DECLARED" "$(grep ' 3\.1 ' "$SANDBOX/lint3f.txt")"; fi
write_record '**Blocked:** the CEO — he has to decide. '
write_queue 'nothing — buildable, see the row'
run_hook
if spoke && names '12'; then
    ok "3h  the queue's cell reading 'nothing — <why>' names nobody by its first word, so row 12 is unstarted and NAMED"
else bad "3h  a queue cell of 'nothing — …' must not silence the row" "$HOUT"; fi
write_queue '**CEO — his Railway credentials**'

rm -f "$WT/.claude/row-claims.txt"

# ===========================================================================
# 5. STATE-CHANGE DE-DUPLICATION — a stable set is announced ONCE
# ===========================================================================
write_queue
write_record
run_hook
FIRST="$HOUT"
run_hook --remember
if printf '%s' "$FIRST" | grep -q systemMessage && ! spoke; then
    ok "5a  an unchanged set of unstarted rows is announced ONCE, not every turn"
else bad "5a  an unchanged set is announced once" "first=$FIRST second=$HOUT"; fi

write_queue '**CEO — his account**'
run_hook --remember
if spoke; then ok "5b  the set CHANGING speaks again — the moment a row is created or picked up"
else bad "5b  the set changing speaks again" "silent"; fi

write_queue
write_record

# ===========================================================================
# 4. AN UNPARSEABLE RECORD -> LOUD, NEVER A CLEAN SWEEP
# ===========================================================================
loud_because() { # <case> <label> <needle>
    run_hook
    if spoke && names "$3"; then ok "$1  $2"
    else bad "$1  $2" "$HOUT"; fi
}

# 4a the queue's table header moves
sed -i.bak 's/| # | Item | Blocked by |/| # | Item | Waiting on |/' "$REPO/RICH-TODOs.md"
loud_because "4a" "the queue's \`Blocked by\` column renamed -> LOUD, not a clean sweep" "Blocked by"
if ! printf '%s' "$HOUT" | grep -qi 'clear again'; then ok "4b  ...and it does NOT report the queue as clear"
else bad "4b  it must not report the queue as clear" "$HOUT"; fi
write_queue

# 4c the governed section is renamed away
sed -i.bak 's/^## 3\. Buildable now.*$/## 4. Somewhere else entirely/' "$REPO/wiki/open-items.md"
loud_because "4c" "the governed section renamed -> LOUD" "no section 3"
write_record

# 4d half the corpus disappears — the CEO's own rule, mechanized. A DECLARED
# queue that is not on disk: somebody wrote down where it lives, and believing
# them and finding nothing is the loudest fact available.
printf 'QUEUE_RECORD="RICH-TODOs.md"\n' > "$REPO/.unstarted-rows"
mv "$REPO/RICH-TODOs.md" "$SANDBOX/queue.hidden"
loud_because "4d" "a declared queue that is not there -> LOUD (\"the queue is two files\")" "queue is two files"
mv "$SANDBOX/queue.hidden" "$REPO/RICH-TODOs.md"
rm -f "$REPO/.unstarted-rows"

# 4e the working record itself disappears
mv "$REPO/wiki/open-items.md" "$SANDBOX/rec.hidden0"
loud_because "4e" "the working record gone -> LOUD, never a sweep of the queue alone" "not present"
mv "$SANDBOX/rec.hidden0" "$REPO/wiki/open-items.md"

# 4f the predicate's own half-corpus branch, driven directly. Reachable in the
# wild only as a race (the file vanishes between the resolve and the read), so
# it is exercised here as a unit rather than left as an untested arm.
python3 -c '
import json, sys
print(json.dumps({"queue_label": "RICH-TODOs.md", "queue_text": None,
                  "record_label": "wiki/open-items.md", "record_text": "# x",
                  "row_sections": ["3"], "status_tokens": ["OPEN", "CLOSED"],
                  "terminal_tokens": ["CLOSED"], "actionable_tokens": ["OPEN"],
                  "claims": {"worktrees": []}}))' \
    | python3 "$REPO/scripts/lib/unstarted-rows.py" - > "$SANDBOX/half.txt" 2>&1
if grep -q 'QUEUE IS TWO FILES' "$SANDBOX/half.txt"; then
    ok "4f  the predicate refuses a half corpus outright, in its own words"
else bad "4f  the predicate refuses a half corpus" "$(cat "$SANDBOX/half.txt")"; fi

# 4k a status token outside the declared vocabulary
sed -i.bak 's/`OPEN`/`PROBABLY-FINE`/' "$REPO/wiki/open-items.md"
loud_because "4k" "a warrant token outside the vocabulary -> LOUD" "PROBABLY-FINE"
write_record

# 4l the same id in both files, which would make every claim ambiguous
sed -i.bak 's/^| 12 |/| 3.1 |/' "$REPO/RICH-TODOs.md"
loud_because "4l" "one id in both files -> LOUD (a claim could mean either)" "both"
write_queue

# 4g the queue table is emptied — the exact failure of 2026-08-31
python3 - "$REPO/RICH-TODOs.md" <<'PY'
import sys
p = sys.argv[1]
out, drop = [], False
for line in open(p, encoding="utf-8"):
    if line.startswith("|---"):
        out.append(line); drop = True; continue
    if drop and line.startswith("|"):
        continue
    if line.startswith("## ") and not line.startswith("## Next"):
        drop = False
    out.append(line)
open(p, "w", encoding="utf-8").write("".join(out))
PY
loud_because "4m" "the queue table emptied -> LOUD, never \"the backlog is empty\"" "NOT ONE ROW"
write_queue

# 4h the section's rows are emptied
python3 - "$REPO/wiki/open-items.md" <<'PY'
import sys
p = sys.argv[1]
out = [l for l in open(p, encoding="utf-8") if not l.startswith("| 3.")]
open(p, "w", encoding="utf-8").write("".join(out))
PY
loud_because "4n" "the governed section emptied -> LOUD (\"not an empty queue, an unread one\")" "ZERO rows"
write_record

# 4i the predicate itself is missing
mv "$REPO/scripts/lib/unstarted-rows.py" "$SANDBOX/py.hidden"
loud_because "4o" "the predicate absent -> LOUD (an absent checker is not a clean queue)" "unstarted-rows.py"
mv "$SANDBOX/py.hidden" "$REPO/scripts/lib/unstarted-rows.py"

# 4j the queue is renamed after a sweep has already seen it
run_hook   # re-adopt, so the "I swept this before" memory is current
mv "$REPO/RICH-TODOs.md" "$SANDBOX/queue.hidden2"
loud_because "4p" "a queue swept before and now vanished -> LOUD, never a quiet stand-down" "LOST ITS QUEUE"
mv "$SANDBOX/queue.hidden2" "$REPO/RICH-TODOs.md"

rm -f "$REPO"/*.bak "$REPO/wiki"/*.bak

# ===========================================================================
# 8. WHAT CLOSES A ROW, AND WHAT MERELY DESCRIBES ITS RESIDUAL
# ===========================================================================
# THE STRIKE-THROUGH IS THE CLOSURE SIGNAL AND IT IS THE ONLY ONE. The first
# version of this parser treated a "done" cell as a corroborating second
# signal and refused any row where the two disagreed; the live record killed
# that within the hour, with a struck-through row whose blocked-by cell read
# `**CEO — a product decision**` and was entirely correct — the work was
# finished, and the cell names who owns what is LEFT. Two facts, one slot,
# and the guard was wrong about which was which.
write_queue
write_record
bash "$LINT" "$REPO" > "$SANDBOX/lint8.txt" 2>&1
if grep -qE '^  CLOSED     9 .*residual: CEO' "$SANDBOX/lint8.txt"; then
    ok "8a  a struck row that names who owns its RESIDUAL is closed, quietly, with the residual kept"
else bad "8a  a struck row naming a residual owner stays closed" "$(cat "$SANDBOX/lint8.txt")"; fi

# The other direction IS a genuine ambiguity and is still refused: a row that
# claims to be finished in its cell while its id says it is open.
sed -i.bak 's/^| 12 |\(.*\)| — |$/| 12 |\1| done |/' "$REPO/RICH-TODOs.md"
loud_because "8b" "an UNSTRUCK row whose cell says 'done' -> LOUD (finished in one place, open in the other)" "NOT struck through"
write_queue
rm -f "$REPO"/*.bak

# ===========================================================================
# 7. THE LINT'S EXIT CODES — three answers, three codes
# ===========================================================================
write_queue
write_record
bash "$LINT" "$REPO" >/dev/null 2>&1
if [ "$?" -eq 1 ]; then ok "7a  the lint exits 1 when a row is unstarted"
else bad "7a  the lint exits 1 when a row is unstarted"; fi

write_queue '**CEO — his account**'
write_record '**Blocked:** the CEO. '
printf '1\n11\n' > "$WT/.claude/row-claims.txt"
bash "$LINT" "$REPO" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then ok "7b  the lint exits 0 when every row is accounted for"
else bad "7b  the lint exits 0 when every row is accounted for"; fi
rm -f "$WT/.claude/row-claims.txt"

mv "$REPO/wiki/open-items.md" "$SANDBOX/rec.hidden"
bash "$LINT" "$REPO" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "7c  the lint exits 2 when it could not read — never the same code as clean"
else bad "7c  the lint exits 2 when it could not read"; fi
mv "$SANDBOX/rec.hidden" "$REPO/wiki/open-items.md"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
